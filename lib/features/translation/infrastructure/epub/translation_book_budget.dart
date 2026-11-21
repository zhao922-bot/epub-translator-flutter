import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as paths;
import 'package:win32/win32.dart' as win32;

import '../../../../shared/io/atomic_file_writer.dart';
import '../../domain/repositories/translation_repository.dart';
import 'cancellation_listener.dart';
import 'translation_api_metrics.dart';
import 'translation_budget_paused.dart';

/// One EPUB revision and target language share cumulative usage across run and
/// style invocations. Each reservation reaches disk before the request is sent.
class TranslationBookBudget {
  TranslationBookBudget._(
    this.maxTokens,
    this._file,
    this._lock,
    this._lockKey,
  );

  final int maxTokens;
  final File? _file;
  final void Function()? _lock;
  final String? _lockKey;
  static final _openFiles = <String>{};

  TranslationApiMetrics _metrics = TranslationApiMetrics();
  final _runMetrics = TranslationApiMetrics();
  final _pending = <int, TranslationBookReservation>{};
  int _priorChargedTokens = 0;
  Map<String, int> _priorChargedTokensByKind = const {};
  int _reservedTokens = 0;
  int _nextId = 0;
  int? _refusedTokens;
  bool _storageFailed = false;
  Future<void> _writes = Future.value();
  Completer<void> _settled = Completer<void>();

  static Future<TranslationBookBudget> open({
    required Future<File> file,
    required int maxTokens,
    required void Function() throwIfCancelled,
  }) async {
    void Function()? lock;
    String? lockKey;
    try {
      final ledger = await file;
      await ledger.parent.create(recursive: true);
      final lockPath = '${ledger.absolute.path}.lock';
      final key = Platform.isWindows ? lockPath.toLowerCase() : lockPath;
      final wait = Stopwatch()..start();
      while (lock == null) {
        throwIfCancelled();
        if (_openFiles.add(key)) {
          lockKey = key;
          lock = _tryAcquireLock(lockPath);
          if (lock == null) {
            _openFiles.remove(key);
            lockKey = null;
          }
        }
        if (lock == null) {
          if (wait.elapsed >= const Duration(seconds: 10)) {
            throw const TranslationBudgetAccountingException(inUse: true);
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final budget = TranslationBookBudget._(maxTokens, ledger, lock, lockKey);
      await budget._load();
      budget._priorChargedTokens = budget._metrics.chargedTokensEstimate;
      budget._priorChargedTokensByKind = Map.of(
        budget._metrics.chargedTokensEstimateByKind,
      );
      return budget;
    } catch (error) {
      try {
        lock?.call();
      } finally {
        _openFiles.remove(lockKey);
      }
      if (error is FileSystemException || error is FormatException) {
        // The cap must fail closed. An unlimited run may report usage for the
        // current invocation even if its ledger is temporarily unavailable.
        if (maxTokens == 0) return TranslationBookBudget._(0, null, null, null);
        throw const TranslationBudgetAccountingException();
      }
      rethrow;
    }
  }

  bool get isPaused => _refusedTokens != null;

  void throwIfAccountingFailed() {
    if (_storageFailed) throw const TranslationBudgetAccountingException();
  }

  /// A profile can be generated before the translation run starts. Its paid
  /// attempts already belong to the ledger and are attributed to this workflow.
  void includeStyleUsage(TranslationApiMetrics usage) => _runMetrics.add(usage);

  Map<String, Object> get apiUsage => {
    ..._runMetrics.toJson(),
    'chargedTokensEstimate': _metrics.chargedTokensEstimate,
    'estimatedUnreportedTokens': _metrics.estimatedUnreportedTokens,
    'chargedTokensEstimateByKind': Map.of(_metrics.chargedTokensEstimateByKind),
    'priorChargedTokensEstimate': _priorChargedTokens,
    'priorChargedTokensEstimateByKind': Map.of(_priorChargedTokensByKind),
    'cumulativeUsage': _metrics.toJson(),
    'maxBookTokens': maxTokens,
    'nextRequestEstimatedTokens': _refusedTokens ?? 0,
  };

  Future<TranslationBookReservation> reserve({
    required String kind,
    required TranslationAttemptEstimate estimate,
    required void Function() throwIfCancelled,
    CancelToken? cancelToken,
  }) async {
    final tokens = estimate.input + estimate.output;
    while (true) {
      Future<void>? waitForSettlement;
      final reservation = await _serialize(() async {
        throwIfCancelled();
        throwIfAccountingFailed();
        if (maxTokens > 0) {
          final remaining = maxTokens - _metrics.chargedTokensEstimate;
          if (_refusedTokens != null || tokens > remaining) {
            _refusedTokens ??= tokens;
            throw TranslationBudgetPausedException(apiUsage);
          }
          if (tokens > remaining - _reservedTokens) {
            waitForSettlement = _settled.future;
            return null;
          }
        }
        final id = _nextId++;
        final reservation = TranslationBookReservation._(id, kind, estimate);
        _pending[id] = reservation;
        _reservedTokens += tokens;
        try {
          await _save();
        } catch (_) {
          _pending.remove(id);
          _reservedTokens -= tokens;
          rethrow;
        }
        return reservation;
      });
      if (reservation != null) return reservation;
      await _waitForSettlement(waitForSettlement!, cancelToken);
    }
  }

  Future<void> settle(
    TranslationBookReservation reservation,
    TranslationApiMetrics? attempt,
  ) => _serialize(() async {
    if (_pending.remove(reservation._id) == null) return;
    _reservedTokens -=
        reservation._estimate.input + reservation._estimate.output;
    if (attempt != null) {
      _metrics.add(attempt);
      _runMetrics.add(attempt);
    }
    try {
      await _save();
    } on TranslationBudgetAccountingException {
      // The previous disk record still holds the reservation. Refuse more
      // sends but let this paid response reach the caller's validated cache.
    } finally {
      _settled.complete();
      _settled = Completer<void>();
    }
  });

  static Future<void> _waitForSettlement(
    Future<void> settled,
    CancelToken? token,
  ) async {
    if (token == null) return settled;
    final cancelled = Completer<void>();
    final detach = CancellationListener.listen(token, cancelled.complete);
    try {
      await Future.any([settled, cancelled.future]);
      if (token.isCancelled) throw const TranslationCancelledException();
    } finally {
      detach();
    }
  }

  Future<void> close() async {
    await _writes;
    try {
      _lock?.call();
    } finally {
      _openFiles.remove(_lockKey);
    }
  }

  static void Function()? _tryAcquireLock(String path) {
    if (Platform.isWindows) return _tryAcquireWindowsLock(path);
    final lock = File(path).openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      return lock.closeSync;
    } on FileSystemException {
      lock.closeSync();
      return null;
    }
  }

  static void Function()? _tryAcquireWindowsLock(String path) => using((arena) {
    // Open with no sharing, so another process cannot acquire this name
    // until the handle closes. The kernel then removes the temporary file,
    // including when the process exits without running Dart cleanup.
    final result = win32.CreateFile(
      win32.PCWSTR(_extendedWindowsPath(path).toNativeUtf16(allocator: arena)),
      win32.GENERIC_WRITE,
      win32.FILE_SHARE_NONE,
      null,
      win32.OPEN_ALWAYS,
      win32.FILE_ATTRIBUTE_TEMPORARY | win32.FILE_FLAG_DELETE_ON_CLOSE,
      null,
    );
    if (result.value == win32.INVALID_HANDLE_VALUE) {
      if (result.error == win32.ERROR_SHARING_VIOLATION ||
          result.error == win32.ERROR_DELETE_PENDING) {
        return null;
      }
      throw FileSystemException(
        'Could not open translation usage lock',
        path,
        OSError('', result.error),
      );
    }
    return () {
      final closed = win32.CloseHandle(result.value);
      if (!closed.value) {
        throw FileSystemException(
          'Could not close translation usage lock',
          path,
          OSError('', closed.error),
        );
      }
    };
  });

  static String _extendedWindowsPath(String path) {
    final native = path.replaceAll('/', '\\');
    if (native.startsWith(r'\\?\') || native.startsWith(r'\\.\')) return native;
    final normalized = paths.windows.normalize(native);
    if (normalized.startsWith(r'\\')) {
      return r'\\?\UNC\' + normalized.substring(2);
    }
    return r'\\?\' + normalized;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _load() async {
    final String raw;
    try {
      raw = await _file!.readAsString();
    } on PathNotFoundException {
      return;
    }
    final newline = raw.indexOf('\n');
    if (newline < 0 ||
        raw.substring(0, newline) != _digest(raw.substring(newline + 1))) {
      throw const FormatException('Translation usage checksum mismatch.');
    }
    final json = jsonDecode(raw.substring(newline + 1));
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        json['usage'] is! Map<String, dynamic> ||
        json['pending'] is! List) {
      throw const FormatException('Invalid translation usage record.');
    }
    _metrics = TranslationApiMetrics.fromJson(
      json['usage'] as Map<String, dynamic>,
    );
    final pending = json['pending'] as List;
    for (final entry in pending) {
      if (entry case {
        'kind': final String kind,
        'input': final int input,
        'output': final int output,
      } when input > 0 && output > 0) {
        _metrics.recordAttempt(
          kind: kind,
          estimate: (input: input, output: output),
          failed: true,
        );
      } else {
        throw const FormatException('Invalid pending translation request.');
      }
    }
    if (pending.isNotEmpty) await _save();
  }

  Future<void> _save() async {
    if (_file == null) return;
    final body = jsonEncode({
      'version': 1,
      'usage': _metrics.toJson(),
      'pending': [
        for (final entry in _pending.values)
          {
            'kind': entry._kind,
            'input': entry._estimate.input,
            'output': entry._estimate.output,
          },
      ],
    });
    try {
      await writeFileAtomically(_file, '${_digest(body)}\n$body');
    } on FileSystemException {
      if (maxTokens == 0) return;
      _storageFailed = true;
      throw const TranslationBudgetAccountingException();
    }
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

class TranslationBookReservation {
  const TranslationBookReservation._(this._id, this._kind, this._estimate);

  final int _id;
  final String _kind;
  final TranslationAttemptEstimate _estimate;
}
