import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../../shared/logging/app_logger.dart';
import '../../../shared/io/output_file_lock.dart';
import 'epub/epub_text_decoder.dart';
import 'epub/epub_navigation.dart';
import 'epub/epub_dom.dart';
import 'epub/epub_source_guard.dart';
import '../domain/repositories/translation_repository.dart';
import '../domain/models/inspected_chapter.dart';
import 'epub/epub_html_extractor.dart';
import 'epub/xhtml_html_compatibility.dart';

/// Navigation only looks up container, OPF and manifest-selected nav/NCX
/// entries. Indexing names must not inflate unrelated chapter/media payloads.
class _LazyArchiveView extends MapBase<String, List<int>> {
  _LazyArchiveView(Archive archive, {required this.inputPath})
    : _entries = {
        for (final file in archive)
          if (file.isFile) file.name: file,
      };

  /// Carried for the streaming zip-bomb guard: entry inflation counts actual
  /// decompressed bytes and reports over-limit entries against this path.
  final String inputPath;
  final Map<String, ArchiveFile> _entries;
  final Map<String, List<int>> _bytes = {};

  @override
  List<int>? operator [](Object? key) {
    final file = _entries[key];
    if (file == null) return null;
    // Reading via the guarded inflate leaves ArchiveFile.isCompressed intact
    // (nothing is memoized into .content), even for container.xml, which is
    // read for navigation but copied unchanged.
    return _bytes.putIfAbsent(
      file.name,
      () => EpubIsolateWorker._fileBytes(file, inputPath: inputPath),
    );
  }

  @override
  bool containsKey(Object? key) => _entries.containsKey(key);

  @override
  Iterable<String> get keys => _entries.keys;

  @override
  void operator []=(String key, List<int> value) =>
      throw UnsupportedError('Read-only archive view');

  @override
  void clear() => throw UnsupportedError('Read-only archive view');

  @override
  List<int>? remove(Object? key) =>
      throw UnsupportedError('Read-only archive view');
}

class _ProgressWork<T> {
  const _ProgressWork(this.operation, this.messages);
  final T Function(void Function(int, int)) operation;
  final SendPort messages;
}

void _progressWorkEntry<T>(_ProgressWork<T> work) {
  try {
    final result = work.operation((done, total) {
      work.messages.send(['progress', done, total]);
    });
    Isolate.exit(work.messages, ['result', result]);
  } catch (error, stack) {
    work.messages.send(['error', error, stack]);
  }
}

/// A `.tmp.*` file counts as a stale orphan only when older than this. The
/// temp file of a live commit is always seconds old; orphans from a dead
/// previous process or session are far older. An age gate (instead of
/// "older than this process started") is robust against filesystem
/// timestamp granularity (FAT32/exFAT: 2s) and clock skew, and also
/// protects the temp files of a second concurrently running app instance.
const Duration _kStaleTempAge = Duration(minutes: 30);

/// Budget for `.recovery.*` spares kept after lock-conflict commits. Every
/// lock conflict preserves one full translated copy; without a cap a stuck
/// lock would fill the disk with a spare per retry. Enforced oldest-first in
/// [preserveRecoveryTempForTest]; a successful commit reclaims all spares
/// for that output (the final file now holds the translation).
const int _kMaxRecoveryFiles = 5;
const int _kMaxRecoveryBytes = 512 * 1024 * 1024;

enum RecoveryBudgetKind { recoverySpare, fallbackTmp, indexLedger }

typedef RecoveryBudgetEntry = ({
  String name,
  int sizeBytes,
  RecoveryBudgetKind kind,
});

/// Decoded archive plus the entry names that occur more than once in the raw
/// central directory. The decoder merges duplicates in place (keeping the
/// first payload but overwriting crc32 with the last duplicate's), so
/// duplicates are invisible when iterating the decoded [Archive] — they must
/// be detected from the decoder's raw file headers instead.
typedef DecodedEpubArchive = ({Archive archive, Set<String> duplicateNames});

/// Pure eviction policy; the ledger counts toward both limits but sorts last.
/// A complete payload always survives, even when it alone exceeds the budget.
/// The ledger itself survives while any registered `.tmp.*` fallback payload
/// does: it is the orphan sweeper's only record of deliberate recovery
/// copies (P1-#2).
@visibleForTesting
List<String> recoveryBudgetDeletions(
  List<RecoveryBudgetEntry> entries, {
  Set<String> exemptNames = const {},
}) {
  bool isComplete(RecoveryBudgetEntry entry) =>
      entry.kind == RecoveryBudgetKind.fallbackTmp ||
      (entry.kind == RecoveryBudgetKind.recoverySpare &&
          RegExp(r'\.recovery\.\d+$').hasMatch(entry.name));
  final ordered = [...entries]
    ..sort((a, b) {
      final aIsIndex = a.kind == RecoveryBudgetKind.indexLedger;
      final bIsIndex = b.kind == RecoveryBudgetKind.indexLedger;
      if (aIsIndex != bIsIndex) return aIsIndex ? 1 : -1;
      // Compare timestamps across prefixes, rather than sorting all tmp files
      // after all recovery files regardless of age.
      final suffix = RegExp(r'\.(\d+)$');
      final aStamp = int.tryParse(suffix.firstMatch(a.name)?.group(1) ?? '');
      final bStamp = int.tryParse(suffix.firstMatch(b.name)?.group(1) ?? '');
      if (aStamp != null && bStamp != null && aStamp != bStamp) {
        return aStamp.compareTo(bStamp);
      }
      return a.name.compareTo(b.name);
    });
  var remaining = ordered.length;
  var complete = ordered.where(isComplete).length;
  var totalBytes = ordered.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
  final deletions = <String>[];
  for (final entry in ordered) {
    if (remaining <= _kMaxRecoveryFiles && totalBytes <= _kMaxRecoveryBytes) {
      break;
    }
    // P1-#2: the ledger is the orphan sweeper's only record of which `.tmp.*`
    // payloads are deliberate recovery copies. Evicting it while a registered
    // fallback payload survives would let a later process restart sweep the
    // user's only complete translation as a stale orphan (the in-memory
    // _retainedRecoveryPaths do not survive restarts) — this is how v1.6.19's
    // quota cleanup fought the orphan protection. The ledger sorts last, so
    // every fallback payload has been decided by the time it is evaluated:
    // it may only go once no registered fallback payload remains. Recovery
    // spares need no ledger: the orphan sweep never touches `.recovery.*`.
    final bool ledgerStillNeeded =
        entry.kind == RecoveryBudgetKind.indexLedger &&
        ordered.any(
          (other) =>
              other.kind == RecoveryBudgetKind.fallbackTmp &&
              !deletions.contains(other.name),
        );
    if (exemptNames.contains(entry.name) ||
        (isComplete(entry) && complete == 1) ||
        ledgerStillNeeded) {
      continue;
    }
    deletions.add(entry.name);
    remaining--;
    totalBytes -= entry.sizeBytes;
    if (isComplete(entry)) complete--;
  }
  return deletions;
}

/// A commit failed, but the complete translated payload remains recoverable.
///
/// The fully-translated temp file is deliberately NOT deleted: the user can
/// close the locking program and retry the translation (available block cache
/// reduces repeated work), or rename [tempFilePath] manually.
/// [message] is already localized by the caller via [EpubIsolateWorker.commitTempFile]'s
/// `lockedMessage` callback.
class OutputFileRecoveryException extends FileSystemException {
  OutputFileRecoveryException(String message, this.tempFilePath)
    : super(message, tempFilePath);

  final String tempFilePath;

  @override
  String toString() => message;
}

class OutputFileLockedException extends OutputFileRecoveryException {
  OutputFileLockedException(super.message, super.tempFilePath);
}

/// Preserve the established timeout classification while carrying recovery.
class OutputFileRecoveryTimeoutException extends OutputFileRecoveryException
    implements TimeoutException {
  OutputFileRecoveryTimeoutException(
    super.message,
    super.tempFilePath,
    this.duration,
  );

  @override
  final Duration? duration;
}

/// Thrown when the SOURCE file is locked by another process at read time
/// (Windows: a reader holding it open without share access), mirroring
/// [OutputFileLockedException].
///
/// Unlike the output case there is no temp file to preserve: the read never
/// started, and the block cache on disk is unaffected, so closing the locking
/// program and retrying is cheap. Catchers build the user-facing message via
/// `AppStrings.inputFileLocked`.
class InputFileLockedException implements Exception {
  InputFileLockedException(this.inputPath);

  final String inputPath;

  @override
  String toString() => 'InputFileLockedException: $inputPath';
}

/// Thrown when a source EPUB trips the zip-bomb guards in
/// [_decodeArchiveWithLimits]: the compressed file itself is implausibly
/// large, the header-declared uncompressed total exceeds the cap, the
/// overall compression ratio is absurd, or the entry count exceeds the cap
/// (millions of near-empty entries). Rejected BEFORE any entry content is
/// materialized, so a malicious archive cannot OOM the isolate.
/// Thrown AGAIN during inflation by [_GuardedInflateStream] when an entry's
/// ACTUAL decompressed bytes exceed the cap: the preflight only sees the
/// header-declared sizes, which a malicious entry can under-report.
/// Catchers build the user-facing message via
/// `AppStrings.epubDecompressionLimit`.
class EpubDecompressionLimitException implements Exception {
  EpubDecompressionLimitException({
    required this.inputPath,
    required this.compressedBytes,
    required this.uncompressedBytes,
    required this.limitBytes,
  });

  final String inputPath;
  final int compressedBytes;
  final int uncompressedBytes;
  final int limitBytes;

  @override
  String toString() =>
      'EpubDecompressionLimitException: $inputPath expands beyond the '
      'decompression limit ($uncompressedBytes bytes vs $limitBytes allowed).';
}

/// [OutputStream] that accumulates inflated ZIP-entry bytes and throws
/// [EpubDecompressionLimitException] the moment the total exceeds
/// [limitBytes] — instead of growing to a malicious entry's full size first.
/// The dart:io ZLib decoder writes decompressed output incrementally, so
/// counting actual bytes as they arrive aborts a lying entry mid-inflate:
/// the full payload is never materialized. Backs the streaming half of the
/// zip-bomb guard in [EpubIsolateWorker._fileBytes]; the preflight half
/// ([EpubIsolateWorker.checkArchiveLimitsForTest]) only sees header-declared
/// sizes, which an attacker can under-report.
class _GuardedInflateStream extends OutputMemoryStream {
  _GuardedInflateStream({
    required this.inputPath,
    required this.entryName,
    required this.compressedBytes,
    required this.limitBytes,
  });

  final String inputPath;
  final String entryName;
  final int compressedBytes;
  final int limitBytes;

  Never _overflow(int incoming) => throw EpubDecompressionLimitException(
    inputPath: '$inputPath!$entryName',
    compressedBytes: compressedBytes,
    uncompressedBytes: length + incoming,
    limitBytes: limitBytes,
  );

  @override
  void writeByte(int value) {
    if (length + 1 > limitBytes) _overflow(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final int count = length ?? bytes.length;
    if (this.length + count > limitBytes) _overflow(count);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    // Stored (uncompressed) entries arrive whole via writeStream; the cap
    // must apply here too, not just to the incremental inflate writes.
    if (length + stream.length > limitBytes) _overflow(stream.length);
    super.writeStream(stream);
  }
}

/// Forwards each decompressed chunk from the native chunked ZLib decoder
/// straight into the guard stream, so the byte cap is enforced per chunk
/// instead of after the whole payload materialized (see P1-#1).
class _GuardedChunkSink implements ChunkedConversionSink<List<int>> {
  _GuardedChunkSink(this.output);

  final _GuardedInflateStream output;

  @override
  void add(List<int> chunk) => output.writeBytes(chunk);

  @override
  void close() {}
}

/// Heavy ZIP work off the UI isolate (Windows/Android).
class EpubIsolateWorker {
  const EpubIsolateWorker._();

  static const String _opfNamespaceUri = 'http://www.idpf.org/2007/opf';

  /// Mirrors `EpubInspector._isOpfManifestChild`: only matches OPF-manifest
  /// `<item>` elements, so a foreign-namespace `<item>` cannot hijack the
  /// nav/NCX lookup during repack (B-1).
  static bool _isOpfManifestChild(xml.XmlElement element, String localName) {
    if (element.name.local != localName) return false;
    final String? ns = element.name.namespaceUri;
    if (ns != null && ns != _opfNamespaceUri) return false;
    final xml.XmlNode? parent = element.parent;
    if (parent is! xml.XmlElement || parent.name.local != 'manifest') {
      return false;
    }
    final String? parentNs = parent.name.namespaceUri;
    return parentNs == null || parentNs == _opfNamespaceUri;
  }

  /// Runs CPU-only preparation with progress messages. Cancellation sends an
  /// immediate isolate control message, so even a single huge DOM parse can
  /// be stopped. File-producing work must reserve its temp path in the parent
  /// and clean it after termination (as writeTranslatedEpub does); killing an
  /// isolate cannot run its finally blocks or report a newly created path.
  /// [finishBeforeCancellation] lets file-producing operations finish their
  /// synchronous work and close native handles before cancellation returns.
  static Future<T> prepareWithProgress<T>({
    required T Function(void Function(int, int)) operation,
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
    bool finishBeforeCancellation = false,
  }) async {
    if (isCancelled()) throw const TranslationCancelledException();
    final messages = ReceivePort();
    final completed = Completer<T>();
    final exited = Completer<void>();
    Isolate? worker;
    Timer? cancellationPoll;
    final subscription = messages.listen((dynamic message) {
      if (message == null && !exited.isCompleted) exited.complete();
      if (completed.isCompleted) return;
      try {
        if (isCancelled()) throw const TranslationCancelledException();
        if (message == null) {
          throw StateError('EPUB preparation worker exited without a result.');
        }
        final values = message as List<dynamic>;
        switch (values[0]) {
          case 'progress':
            onProgress?.call(values[1] as int, values[2] as int);
          case 'result':
            completed.complete(values[1] as T);
          case 'error':
            completed.completeError(
              values[1] as Object,
              values[2] as StackTrace,
            );
          default:
            // Uncaught isolate errors use the VM's [error, stack] envelope.
            completed.completeError(
              StateError(values[0].toString()),
              StackTrace.fromString(values[1].toString()),
            );
        }
      } catch (error, stack) {
        completed.completeError(error, stack);
      }
    });
    try {
      worker = await Isolate.spawn<_ProgressWork<T>>(
        _progressWorkEntry<T>,
        _ProgressWork(operation, messages.sendPort),
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
      cancellationPoll = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (completed.isCompleted) return;
        try {
          if (isCancelled()) throw const TranslationCancelledException();
        } catch (error, stack) {
          completed.completeError(error, stack);
        }
      });
      return await completed.future;
    } finally {
      cancellationPoll?.cancel();
      // Synchronous file operations cannot receive a cooperative port message
      // while encoding. Let file-producing workers unwind and close handles
      // before termination; CPU-only workers remain immediately killable.
      if (finishBeforeCancellation && worker != null) await exited.future;
      worker?.kill(priority: Isolate.immediate);
      // Await termination, not just the kill request. File-producing callers
      // can then clean their owned temp without racing a still-running writer.
      if (worker != null) await exited.future;
      await subscription.cancel();
      messages.close();
    }
  }

  /// Reads and decodes an EPUB into a name -> bytes map on a background isolate.
  static Future<Map<String, Uint8List>> loadArchiveFiles(String inputPath) {
    return Isolate.run(() => _loadArchiveSnapshotSync(inputPath).files);
  }

  /// Hash and decoded entries come from the same read, so an external save
  /// cannot associate an old inspection with a newer file's hash.
  static Future<({Map<String, Uint8List> files, String fingerprint})>
  loadArchiveSnapshot(String inputPath) {
    return Isolate.run(() => _loadArchiveSnapshotSync(inputPath));
  }

  /// Inflate only package metadata and the entries selected from its OPF.
  /// The selector runs in the worker; binary resources never cross isolates.
  static Future<({Map<String, Uint8List> files, String fingerprint})>
  loadInspectionSnapshot(
    String inputPath, {
    required Set<String> Function(Map<String, List<int>> files, String opfPath)
    selectEntries,
    bool Function()? isCancelled,
    // Test-only: shrinks the cross-entry actual-inflated-bytes cap (P1-#2)
    // so the cumulative enforcement is exercisable without a 512 MiB bomb.
    int? totalInflatedLimitOverrideForTest,
  }) async {
    final cancelled = isCancelled ?? () => false;
    // Keep native file ownership outside the killable CPU worker. Killing a
    // synchronous read skips its finally block and can retain a Windows handle.
    final source = await _readInspectionBytes(inputPath, cancelled);
    if (cancelled()) throw const TranslationCancelledException();
    final transferable = TransferableTypedData.fromList([source]);
    return prepareWithProgress(
      operation: _inspectionOperation(
        inputPath,
        transferable,
        selectEntries,
        totalInflatedLimitOverrideForTest,
      ),
      isCancelled: cancelled,
    );
  }

  static Future<Uint8List> _readInspectionBytes(
    String inputPath,
    bool Function() isCancelled,
  ) async {
    void checkCancellation() {
      if (isCancelled()) throw const TranslationCancelledException();
    }

    checkCancellation();
    try {
      final handle = await File(inputPath).open();
      try {
        Uint8List buffer = Uint8List(64 * 1024);
        int length = 0;
        while (true) {
          checkCancellation();
          final chunk = await handle.read(64 * 1024);
          checkCancellation();
          if (chunk.isEmpty) break;
          final actualLength = length + chunk.length;
          if (actualLength > _kMaxEpubCompressedBytes) {
            throw EpubDecompressionLimitException(
              inputPath: inputPath,
              compressedBytes: actualLength,
              uncompressedBytes: -1,
              limitBytes: _kMaxEpubCompressedBytes,
            );
          }
          if (actualLength > buffer.length) {
            var capacity = buffer.length * 2;
            if (capacity < actualLength) capacity = actualLength;
            if (capacity > _kMaxEpubCompressedBytes) {
              capacity = _kMaxEpubCompressedBytes;
            }
            final grown = Uint8List(capacity);
            grown.setRange(0, length, buffer);
            buffer = grown;
          }
          buffer.setRange(length, actualLength, chunk);
          length = actualLength;
        }
        return Uint8List.view(buffer.buffer, 0, length);
      } finally {
        await handle.close();
      }
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) throw InputFileLockedException(inputPath);
      rethrow;
    }
  }

  // Build sendable closures in scopes containing only worker data, never UI
  // cancellation callbacks/tokens (which can capture unsendable state).
  static ({Map<String, Uint8List> files, String fingerprint}) Function(
    void Function(int, int),
  )
  _inspectionOperation(
    String inputPath,
    TransferableTypedData source,
    Set<String> Function(Map<String, List<int>>, String) selectEntries,
    // Test-only: shrinks the cross-entry actual-inflated-bytes cap (P1-#2)
    // so the cumulative enforcement is exercisable without a 512 MiB bomb.
    // A positional (not optional-named) parameter: this signature's
    // function-typed parameter trips a Dart parser quirk when `{` follows
    // it and the body is a block.
    int? totalInflatedLimitOverride,
  ) {
    return (_) {
      final bytes = source.materialize().asUint8List();
      final archive = _decodeArchiveWithLimits(inputPath, bytes).archive;
      final files = <String, Uint8List>{};
      int totalInflatedBytes = 0;
      // P1-#2: the per-entry streaming cap stops a single lying entry
      // mid-inflate, but many small liars could still add up: enforce the
      // same total cap on ACTUAL inflated bytes here too, mirroring the
      // header-declared preflight and _loadArchiveSnapshotSync.
      final int totalLimit =
          totalInflatedLimitOverride ?? _kMaxEpubUncompressedBytes;
      void read(String name) {
        if (files.containsKey(name)) return;
        final file = archive.find(name);
        if (file == null || !file.isFile) return;
        final content = _fileBytes(file, inputPath: inputPath);
        totalInflatedBytes += content.length;
        if (totalInflatedBytes > totalLimit) {
          throw EpubDecompressionLimitException(
            inputPath: inputPath,
            compressedBytes: bytes.length,
            uncompressedBytes: totalInflatedBytes,
            limitBytes: totalLimit,
          );
        }
        // Stored ZIP entries are views into the entire source archive. Detach
        // those views so transferring a tiny OPF cannot retain the whole ZIP.
        // Inflated entries with an exact-sized buffer need no second copy.
        files[name] =
            content is Uint8List &&
                content.buffer.lengthInBytes == content.lengthInBytes
            ? content
            : Uint8List.fromList(content);
      }

      read('META-INF/container.xml');
      final containerBytes = files['META-INF/container.xml'];
      if (containerBytes == null) {
        throw const FormatException(
          'Invalid EPUB: META-INF/container.xml is missing.',
        );
      }
      final container = xml.XmlDocument.parse(
        decodeEpubText(
          bytes: containerBytes,
          filePath: 'META-INF/container.xml',
          strict: true,
        ),
      );
      final rootfile = container.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local == 'rootfile')
          .firstOrNull;
      if (rootfile == null) {
        throw const FormatException(
          'Invalid EPUB: META-INF/container.xml is missing a rootfile entry.',
        );
      }
      final opfPath = rootfile.getAttribute('full-path');
      if (opfPath == null || opfPath.isEmpty) {
        throw const FormatException(
          'Invalid EPUB: package document path is empty.',
        );
      }
      read(opfPath);
      for (final name in selectEntries(files, opfPath)) {
        read(name);
      }
      return (files: files, fingerprint: sha256.convert(bytes).toString());
    };
  }

  /// Same synchronous extractor semantics, but the outer isolate is killable;
  /// nesting the extractor's Isolate.run would leave that child unmanaged.
  static Future<List<InspectedChapter>> inspectChapterBatchCancellable({
    required Map<String, List<int>> chapters,
    required EpubHtmlExtractor extractor,
    required bool Function() isCancelled,
  }) => prepareWithProgress(
    operation: _chapterOperation(chapters, extractor),
    isCancelled: isCancelled,
  );

  static List<InspectedChapter> Function(void Function(int, int))
  _chapterOperation(
    Map<String, List<int>> chapters,
    EpubHtmlExtractor extractor,
  ) =>
      (_) => [
        for (final entry in chapters.entries)
          extractor.inspectChapterBytes(
            chapterPath: entry.key,
            bytes: entry.value,
          ),
      ];

  /// Only the small title crosses the isolate boundary. ZIP limits and source
  /// identity still apply, but only container.xml and its OPF are inflated.
  static Future<String?> readBookTitle(
    String inputPath, {
    String? expectedSourceFingerprint,
  }) {
    return Isolate.run(
      () => _readBookTitleSync(
        inputPath,
        expectedSourceFingerprint: expectedSourceFingerprint,
      ),
    );
  }

  /// Visible for testing: [readBookTitle] with a shrunk inflate cap, so the
  /// P2-#14 loud-failure path is exercisable without a 512 MiB bomb.
  @visibleForTesting
  static Future<String?> readBookTitleForTest(
    String inputPath, {
    required int limitBytes,
  }) => Isolate.run(
    () => _readBookTitleSync(inputPath, limitBytesOverride: limitBytes),
  );

  static String? _readBookTitleSync(
    String inputPath, {
    String? expectedSourceFingerprint,
    int? limitBytesOverride,
  }) {
    final archive = _decodeEpubArchive(
      inputPath,
      expectedSourceFingerprint,
    ).archive;
    try {
      final containerFile = archive.find('META-INF/container.xml');
      if (containerFile == null || !containerFile.isFile) return null;
      final container = xml.XmlDocument.parse(
        decodeEpubText(
          bytes: _fileBytes(
            containerFile,
            inputPath: inputPath,
            limitBytesOverride: limitBytesOverride,
          ),
          filePath: 'META-INF/container.xml',
          strict: true,
        ),
      );
      final opfPath = container.descendants
          .whereType<xml.XmlElement>()
          .where((e) => e.name.local == 'rootfile')
          .firstOrNull
          ?.getAttribute('full-path');
      if (opfPath == null || opfPath.isEmpty) return null;
      final opfFile = archive.find(opfPath);
      if (opfFile == null || !opfFile.isFile) return null;
      final opf = xml.XmlDocument.parse(
        decodeEpubText(
          bytes: _fileBytes(
            opfFile,
            inputPath: inputPath,
            limitBytesOverride: limitBytesOverride,
          ),
          filePath: opfPath,
          strict: true,
        ),
      );
      final title = opf.descendants
          .whereType<xml.XmlElement>()
          .where(
            (e) =>
                e.name.local == 'title' &&
                e.name.namespaceUri == 'http://purl.org/dc/elements/1.1/',
          )
          .firstOrNull
          ?.innerText
          .trim();
      return title == null || title.isEmpty ? null : title;
    } on EpubDecompressionLimitException {
      // P2-#14: a zip-bomb guard tripping while reading the title must
      // fail loudly, not degrade into "the book has no title" — swallowing
      // it here would let a malicious archive continue into translation.
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Read only package language declarations; XHTML quotations are not book
  /// languages. Keep the original order for subsequent review conversions.
  static List<String> bookLanguages(Map<String, List<int>> files) {
    final containerBytes = files['META-INF/container.xml'];
    if (containerBytes == null) return [];
    final container = xml.XmlDocument.parse(
      decodeEpubText(
        bytes: containerBytes,
        filePath: 'META-INF/container.xml',
        strict: true,
      ),
    );
    final opfPath = container.descendants
        .whereType<xml.XmlElement>()
        .where((e) => e.name.local == 'rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    final bytes = files[opfPath];
    if (bytes == null || opfPath == null) return [];
    final opf = xml.XmlDocument.parse(
      decodeEpubText(bytes: bytes, filePath: opfPath, strict: true),
    );
    final metadata = opf.rootElement.childElements
        .where(
          (e) =>
              e.name.local == 'metadata' &&
              (e.namespaceUri == 'http://www.idpf.org/2007/opf' ||
                  e.namespaceUri == null),
        )
        .firstOrNull;
    return (metadata?.childElements ?? const <xml.XmlElement>[])
        .where(
          (e) =>
              e.name.local == 'language' &&
              e.namespaceUri == 'http://purl.org/dc/elements/1.1/',
        )
        .map((e) => e.innerText.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static Future<List<String>> readBookLanguages(
    String inputPath, {
    String? expectedSourceFingerprint,
  }) => Isolate.run(() {
    final decoded = _decodeEpubArchive(inputPath, expectedSourceFingerprint);
    return bookLanguages(
      _LazyArchiveView(decoded.archive, inputPath: inputPath),
    );
  });

  /// Repacks an EPUB, replacing selected XHTML payloads, on a background isolate.
  ///
  /// Writes to a same-directory temp file first, then commits to [outputFilePath]
  /// only after encoding succeeds. [shouldCommit] is also polled during ZIP
  /// work; refusal waits for handle closure and cleans its temp. Legacy shouldCommit
  /// callers receive false (the repacker converts it to cancellation); explicit
  /// [isCancelled] callers receive [TranslationCancelledException].
  ///
  /// [navigationLabelsByPath] / [navigationLanguageTag] let the isolate render
  /// OPF/NCX navigation metadata from the same decoded archive in one pass, so
  /// callers never have to load the whole book into the main isolate just to
  /// read three small XML files.
  ///
  /// When [shouldCommit] returns false after the isolate finishes (e.g. cancel),
  /// the temp file is deleted and the existing final output is left untouched.
  /// Returns `true` when the final file was committed, `false` when
  /// [shouldCommit] refused the commit (temp cleaned; final path untouched).
  ///
  /// [lockedMessage] builds the localized error for a locked output file; see
  /// [OutputFileLockedException]. When omitted, a plain English message is
  /// used.
  static Future<bool> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    List<String>? sourceLanguageTags,
    bool bilingual = false,
    bool Function()? shouldCommit,
    bool Function()? isCancelled,
    String Function(String outputPath, String tempPath)? lockedMessage,
    String? expectedSourceFingerprint,
    String? translatedTitle,
  }) async {
    // Reserve a unique path in the parent before spawning. A killed worker
    // cannot report its path or run finally; parent ownership enables cleanup.
    final String tempPath =
        '$outputFilePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final File tempFile = File(tempPath);
    try {
      await prepareWithProgress(
        operation: _exportOperation(
          inputPath,
          outputFilePath,
          tempPath,
          translatedHtmlByPath,
          navigationLabelsByPath,
          navigationLanguageTag,
          bilingual,
          expectedSourceFingerprint,
          translatedTitle,
          sourceLanguageTags,
        ),
        isCancelled: () =>
            (isCancelled?.call() ?? false) ||
            (shouldCommit != null && !shouldCommit()),
        finishBeforeCancellation: true,
      );
      if (isCancelled?.call() ?? false) {
        throw const TranslationCancelledException();
      }
      if (shouldCommit != null && !shouldCommit()) {
        await _deleteQuietly(tempFile);
        return false;
      }
      return await commitTempFile(
        tempFile,
        File(outputFilePath),
        shouldCommit: () =>
            !(isCancelled?.call() ?? false) && (shouldCommit?.call() ?? true),
        lockedMessage: lockedMessage,
      );
    } catch (error) {
      // A failed commit keeps its temp file by design (see
      // OutputFileRecoveryException): deleting it here would destroy the
      // recovery path commitTempFile just preserved.
      if (error is! OutputFileRecoveryException) {
        await _deleteQuietly(tempFile);
      }
      // Keep the established bool contract for commit-veto-only callers;
      // the repacker already turns false into TranslationCancelledException.
      if (error is TranslationCancelledException && isCancelled == null) {
        return false;
      }
      rethrow;
    }
  }

  static String Function(void Function(int, int)) _exportOperation(
    String inputPath,
    String outputFilePath,
    String tempPath,
    Map<String, String> html,
    Map<String, String> labels,
    String? language,
    bool bilingual,
    String? fingerprint,
    String? title,
    List<String>? sourceLanguages,
  ) =>
      (_) => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: html,
        navigationLabelsByPath: labels,
        navigationLanguageTag: language,
        bilingual: bilingual,
        expectedSourceFingerprint: fingerprint,
        translatedTitle: title,
        sourceLanguageTags: sourceLanguages,
        ownedTempPath: tempPath,
      );

  /// Test seam: write only the temp payload without committing.
  static Future<String> writeTranslatedEpubToTempForTest({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    bool bilingual = false,
  }) {
    return Isolate.run(
      () => _writeTranslatedEpubToTempSync(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: navigationLanguageTag,
        bilingual: bilingual,
      ),
    );
  }

  /// Renders OPF/NCX navigation metadata replacements (target language tag +
  /// translated chapter labels) from already-decoded archive bytes. Pure
  /// function: safe to call on a background isolate or in tests.
  static Map<String, String> renderNavigationMetadata({
    required Map<String, List<int>> archiveFiles,
    required Map<String, String> labelsByPath,
    required String? languageTag,
    bool bilingual = false,
    Map<String, String> renderedHtmlByPath = const <String, String>{},
    String? translatedTitle,
    List<String>? sourceLanguageTags,
  }) {
    // Unknown language only prevents language annotations, not already-paid
    // title/label translations. Preserve existing language metadata verbatim.
    final List<int>? containerBytes = archiveFiles['META-INF/container.xml'];
    if (containerBytes == null) {
      return const <String, String>{};
    }
    final xml.XmlDocument container = xml.XmlDocument.parse(
      decodeEpubText(
        bytes: containerBytes,
        filePath: 'META-INF/container.xml',
        strict: true,
      ),
    );
    final xml.XmlElement rootFile = container.descendants
        .whereType<xml.XmlElement>()
        .firstWhere(
          (xml.XmlElement element) => element.name.local == 'rootfile',
          orElse: () => xml.XmlElement(xml.XmlName('missing')),
        );
    final String opfPath = rootFile.getAttribute('full-path') ?? '';
    final List<int>? opfBytes = archiveFiles[opfPath];
    if (opfPath.isEmpty || opfBytes == null) {
      return const <String, String>{};
    }

    final xml.XmlDocument opf = xml.XmlDocument.parse(
      decodeEpubText(bytes: opfBytes, filePath: opfPath, strict: true),
    );
    final metadata = opf.rootElement.childElements
        .where(
          (element) =>
              element.name.local == 'metadata' &&
              (element.namespaceUri == 'http://www.idpf.org/2007/opf' ||
                  element.namespaceUri == null),
        )
        .firstOrNull;
    final List<xml.XmlElement> languages =
        (metadata?.childElements ?? const <xml.XmlElement>[])
            .where(
              (element) =>
                  element.name.local == 'language' &&
                  element.namespaceUri == 'http://purl.org/dc/elements/1.1/',
            )
            .toList();
    if (languageTag != null) {
      if (bilingual && sourceLanguageTags != null) {
        // A monolingual baseline has overwritten the source declarations.
        // Restore their values before applying the usual bilingual policy.
        // Reuse nodes where possible to retain IDs and metadata attributes.
        for (var i = 0; i < sourceLanguageTags.length; i++) {
          if (i < languages.length) {
            languages[i].innerText = sourceLanguageTags[i];
          } else if (metadata != null) {
            final element = _dcLanguageElement(opf, sourceLanguageTags[i]);
            metadata.children.add(element);
            languages.add(element);
          }
        }
        for (var i = sourceLanguageTags.length; i < languages.length; i++) {
          languages[i].innerText = languageTag;
        }
      }
      if (bilingual && languages.isNotEmpty) {
        final seen = <String>{};
        for (final language in languages) {
          final value = language.innerText.trim().toLowerCase();
          if (value.isEmpty || !seen.add(value)) {
            language.parent?.children.remove(language);
          }
        }
        if (!seen.contains(languageTag.toLowerCase())) {
          metadata?.children.add(_dcLanguageElement(opf, languageTag));
        }
      } else if (languages.isEmpty) {
        // No dc:language present: append one instead of skipping, so the
        // finished book still carries the target language.
        if (metadata != null) {
          metadata.children.add(_dcLanguageElement(opf, languageTag));
        }
      } else {
        for (final xml.XmlElement language in languages) {
          language.innerText = languageTag;
        }
        // A bilingual baseline has an extra target declaration. Retain one
        // target entry when converting back, as a direct monolingual export
        // does. Preserve metadata refinements attached to removed IDs.
        final first = languages.first;
        for (final duplicate in languages.skip(1)) {
          final id = duplicate.getAttribute('id');
          if (id != null) {
            final retainedId = first.getAttribute('id') ?? id;
            first.setAttribute('id', retainedId);
            for (final element in opf.descendants.whereType<xml.XmlElement>()) {
              if (element.getAttribute('refines') == '#$id') {
                element.setAttribute('refines', '#$retainedId');
              }
            }
          }
          duplicate.parent?.children.remove(duplicate);
        }
      }
    }

    // Translated book title: update OPF dc:title so e-readers show the
    // target-language title in the library. Fail-safe: any problem leaves
    // the original title untouched.
    final String? newTitle = translatedTitle?.trim();
    if (newTitle != null && newTitle.isNotEmpty && metadata != null) {
      try {
        final xml.XmlElement? titleElement = metadata.childElements
            .where(
              (xml.XmlElement e) =>
                  e.name.local == 'title' &&
                  e.name.namespaceUri == 'http://purl.org/dc/elements/1.1/',
            )
            .firstOrNull;
        if (titleElement != null) {
          titleElement.innerText = newTitle;
          if (languageTag != null) {
            titleElement.setAttribute('xml:lang', languageTag);
          }
        }
      } catch (_) {
        // Keep the original title on any XML manipulation failure.
      }
    }

    final Map<String, String> replacements = <String, String>{
      opfPath: opf.toXmlString(),
    };
    for (final item in opf.descendants.whereType<xml.XmlElement>().where(
      (element) =>
          _isOpfManifestChild(element, 'item') &&
          (element.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .contains('nav'),
    )) {
      final href = item.getAttribute('href') ?? '';
      final uri = Uri.tryParse(href);
      if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
        continue;
      }
      // Manifest hrefs may carry a "#fragment" (seen in the wild, though
      // unusual); archive keys never contain it. Strip it from the raw href
      // before lookup — mirroring EpubInspector.validateNavigationEncodings
      // — so the nav document is not silently skipped. (Stripping the raw
      // href, not the decoded key, keeps a literal %23 in filenames intact.)
      // A bare "#fragment" with no path cannot resolve to a content
      // document; skip it instead of matching the OPF itself.
      final String hrefPath = href.split('#').first;
      if (hrefPath.isEmpty) {
        continue;
      }
      final navPath = navigationTargetKey(opfPath, hrefPath);
      if (!archiveFiles.containsKey(navPath)) continue;
      // Use rendered content when navigation is also a translated chapter,
      // preserving translated prose outside its toc rather than restoring it.
      final markup =
          renderedHtmlByPath[navPath] ??
          decodeEpubText(
            bytes: archiveFiles[navPath]!,
            filePath: navPath,
            strict: true,
          );
      replacements[navPath] = _synchronizeNavigation(
        markup: markup,
        documentPath: navPath,
        labelsByPath: labelsByPath,
        languageTag: languageTag,
        preserveSourceLabels:
            bilingual && renderedHtmlByPath.containsKey(navPath),
      );
      xml.XmlDocument.parse(replacements[navPath]!);
    }
    final xml.XmlElement? spine = opf.descendants
        .whereType<xml.XmlElement>()
        .where((xml.XmlElement element) => element.name.local == 'spine')
        .firstOrNull;
    final String ncxId = spine?.getAttribute('toc') ?? '';
    final items = opf.descendants.whereType<xml.XmlElement>().where(
      (item) => _isOpfManifestChild(item, 'item'),
    );
    final explicit = items
        .where(
          (item) =>
              ncxId.isNotEmpty &&
              item.getAttribute('id') == ncxId &&
              (item.getAttribute('href') ?? '').isNotEmpty,
        )
        .firstOrNull;
    final fallback = items
        .where(
          (item) =>
              item.getAttribute('media-type') == 'application/x-dtbncx+xml' &&
              (item.getAttribute('href') ?? '').isNotEmpty,
        )
        .firstOrNull;
    final ncxItem = explicit ?? fallback;
    final String ncxHref = ncxItem?.getAttribute('href') ?? '';
    if (ncxHref.isEmpty) {
      return replacements;
    }
    final String ncxPath = path.posix.normalize(
      path.posix.join(
        path.posix.dirname(opfPath),
        // Manifest hrefs are URI-encoded while archive entry names are
        // decoded; decode defensively (falling back to the raw href) so an
        // encoded NCX file name still resolves, mirroring the `content src`
        // handling via _decodeNcxSrc below.
        _decodeNcxSrc(ncxHref),
      ),
    );
    final List<int>? ncxBytes = archiveFiles[ncxPath];
    if (ncxBytes == null) {
      return replacements;
    }

    final xml.XmlDocument ncx = xml.XmlDocument.parse(
      decodeEpubText(bytes: ncxBytes, filePath: ncxPath, strict: true),
    );
    if (languageTag != null) {
      ncx.rootElement.setAttribute('xml:lang', languageTag);
    }
    // Translated book title: keep NCX docTitle in sync with OPF dc:title.
    final String? ncxTitle = translatedTitle?.trim();
    if (ncxTitle != null && ncxTitle.isNotEmpty) {
      try {
        final xml.XmlElement? docTitleText = ncx.descendants
            .whereType<xml.XmlElement>()
            .where((xml.XmlElement e) => e.name.local == 'docTitle')
            .firstOrNull
            ?.descendants
            .whereType<xml.XmlElement>()
            .where((xml.XmlElement e) => e.name.local == 'text')
            .firstOrNull;
        if (docTitleText != null) {
          docTitleText.innerText = ncxTitle;
          if (languageTag != null) {
            // NCX text only permits id/class. Language belongs on docTitle/root.
            docTitleText.removeAttribute('xml:lang');
            (docTitleText.parent as xml.XmlElement).setAttribute(
              'xml:lang',
              languageTag,
            );
          }
        }
      } catch (_) {
        // Keep the original docTitle on any XML manipulation failure.
      }
    }
    for (final xml.XmlElement navPoint
        in ncx.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'navPoint',
        )) {
      final xml.XmlElement? content = navPoint.children
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'content')
          .firstOrNull;
      final String source = content?.getAttribute('src') ?? '';
      if (source.isEmpty) {
        continue;
      }
      final chapterPath = navigationTargetKey(ncxPath, source);
      final String? label = labelsByPath[chapterPath];
      if (label == null) {
        continue;
      }
      final navLabel = navPoint.children
          .whereType<xml.XmlElement>()
          .where((element) => element.name.local == 'navLabel')
          .firstOrNull;
      final xml.XmlElement? text = navLabel?.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'text')
          .firstOrNull;
      if (text != null) {
        text.innerText = label;
      }
    }
    replacements[ncxPath] = ncx.toXmlString();
    return replacements;
  }

  // The shared EPUB 3 helper requires a known tag. For unknown targets use
  // its same TOC/link protections and nullable label primitive, without
  // inventing a tag or removing source language attributes.
  static String _synchronizeNavigation({
    required String markup,
    required String documentPath,
    required Map<String, String> labelsByPath,
    required String? languageTag,
    required bool preserveSourceLabels,
  }) {
    if (languageTag != null) {
      return synchronizeEpub3Navigation(
        markup: markup,
        documentPath: documentPath,
        labelsByPath: labelsByPath,
        languageTag: languageTag,
        preserveSourceLabels: preserveSourceLabels,
      );
    }
    final document = XhtmlHtmlCompatibility.parseDocument(markup);
    var changed = false;
    for (final nav in epubTags(document, const {'nav'})) {
      if (!isEpubTocElement(nav)) continue;
      for (final anchor in epubTags(nav, const {
        'a',
      }).where((a) => a.attributes.containsKey('href'))) {
        if (preserveSourceLabels && !isTranslatedNavigationAnchor(anchor)) {
          continue;
        }
        final href = anchor.attributes['href'] ?? '';
        final uri = Uri.tryParse(href);
        if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
          continue;
        }
        final label = labelsByPath[navigationTargetKey(documentPath, href)];
        if (label == null || anchor.text.trim().isEmpty) continue;
        changed = replaceNavigationAnchorLabel(anchor, label) || changed;
      }
    }
    return changed ? serializeEpubNavigation(document, markup) : markup;
  }

  /// Declare the namespace on the new element itself: a declaration on a
  /// sibling or descendant cannot bind this element's prefix.
  static xml.XmlElement _dcLanguageElement(
    xml.XmlDocument opf,
    String languageTag,
  ) {
    final xml.XmlElement element = xml.XmlElement(
      xml.XmlName.fromString('dc:language'),
      <xml.XmlAttribute>[
        xml.XmlAttribute(
          xml.XmlName.fromString('xmlns:dc'),
          'http://purl.org/dc/elements/1.1/',
        ),
      ],
    );
    element.innerText = languageTag;
    return element;
  }

  /// NCX `content src` values are URI-encoded while [labelsByPath] keys are
  /// decoded archive paths; decode defensively so a malformed escape can't
  /// break the whole navigation pass.
  static String _decodeNcxSrc(String raw) {
    try {
      return Uri.decodeFull(raw);
    } catch (_) {
      return raw;
    }
  }

  /// Atomically-ish replace [finalFile] with fully-written [tempFile].
  ///
  /// Never truncates [finalFile] before the new content is ready. On failure the
  /// original [finalFile] is restored when a backup was taken.
  ///
  /// [shouldCommit] is re-checked before each irreversible rename step so a
  /// cancel between awaits cannot leave a half-committed final file.
  /// Returns `false` when [shouldCommit] refuses (backup restored if needed).
  ///
  /// A lock probe before translation cannot close the TOCTOU window (the
  /// user may open the output file mid-run), and probing with
  /// `FileMode.append` only checks WRITE access while the commit rename
  /// needs DELETE. So instead of a bigger probe, the failure path is made
  /// recoverable: a locked target throws [OutputFileLockedException] with
  /// the translated temp file preserved, instead of a raw
  /// FileSystemException with the temp file deleted.
  ///
  /// [lockedMessage] builds the localized lock message from the output and
  /// temp paths; when omitted a plain English message is used.
  static Future<bool> commitTempFile(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
    Duration lockTimeout = const Duration(seconds: 45),
  }) async {
    try {
      return await OutputFileLock.run(
        finalFile,
        () => _commitTempFileLocked(
          tempFile,
          finalFile,
          shouldCommit: shouldCommit,
          lockedMessage: lockedMessage,
        ),
        isCancelled: () => shouldCommit != null && !shouldCommit(),
        timeout: lockTimeout,
      );
    } on OutputLockCancelledException {
      await _deleteQuietly(tempFile);
      return false;
    } catch (error) {
      if (error is OutputFileRecoveryException) rethrow;
      final recovery = await preserveRecoveryTempForTest(tempFile, finalFile);
      if (error is TimeoutException) {
        throw OutputFileRecoveryTimeoutException(
          'Timed out committing output. The translated file was kept at: ${recovery.path}',
          recovery.path,
          error.duration,
        );
      }
      throw OutputFileRecoveryException(
        'Could not commit the output (${error.runtimeType}). '
        'The translated file was kept at: ${recovery.path}',
        recovery.path,
      );
    }
  }

  // Recovery, promotion and rollback are one transaction under the same lock.
  static Future<bool> _commitTempFileLocked(
    File tempFile,
    File finalFile, {
    bool Function()? shouldCommit,
    String Function(String outputPath, String tempPath)? lockedMessage,
  }) async {
    bool allowCommit() => shouldCommit == null || shouldCommit();

    await finalFile.parent.create(recursive: true);
    if (!await tempFile.exists()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    // A previous process may have died between moving the original aside
    // and promoting the temp file, leaving `.bak.*` files behind.
    await _reclaimStaleBackups(finalFile);
    // A previous process may also have died between the isolate returning
    // the temp path and the commit running, leaving `.tmp.*` orphans
    // behind (unlike `.bak.*` files, nothing reclaimed these until now).
    await _reclaimStaleTempFiles(finalFile, tempFile);

    try {
      if (!await finalFile.exists()) {
        if (!allowCommit()) {
          await _deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        // The final file now holds the translation: lock-conflict spares
        // kept for this output are obsolete.
        await _reclaimRecoveryFiles(finalFile, committedTempFile: tempFile);
        return true;
      }

      // Dart's File.rename on Windows uses MOVEFILE_REPLACE_EXISTING, so
      // renaming over an existing file works fine; it only throws
      // FileSystemException when the target is locked by another process.
      // Still move final aside first: if promotion fails or commit is refused
      // after the backup move, the backup can be restored instead of losing
      // the original.
      final File backupFile = File(
        '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
      );
      if (!allowCommit()) {
        await _deleteQuietly(tempFile);
        return false;
      }
      await finalFile.rename(backupFile.path);
      try {
        if (!allowCommit()) {
          if (await backupFile.exists() && !await finalFile.exists()) {
            await backupFile.rename(finalFile.path);
          }
          await _deleteQuietly(tempFile);
          return false;
        }
        await tempFile.rename(finalFile.path);
        // Best effort: the promotion already succeeded; a stuck backup
        // delete must not fail the commit or stall it on retry backoff.
        await _deleteBestEffort(backupFile);
        // The final file now holds the translation: lock-conflict spares
        // kept for this output are obsolete.
        await _reclaimRecoveryFiles(finalFile, committedTempFile: tempFile);
        return true;
      } catch (error) {
        if (await backupFile.exists() && !await finalFile.exists()) {
          await backupFile.rename(finalFile.path);
        }
        rethrow;
      }
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) {
        // The output file is locked (Windows sharing violation): keep the
        // translated temp file and report a localized message. The user
        // closes the locking program and retries with available cached blocks,
        // or renames the complete temp file manually. Uncached steps may
        // still make API requests.
        final recoveryFile = await preserveRecoveryTempForTest(
          tempFile,
          finalFile,
        );
        throw OutputFileLockedException(
          lockedMessage?.call(finalFile.path, recoveryFile.path) ??
              'The output file is locked by another program: ${finalFile.path}. '
                  'The translated file was kept at: ${recoveryFile.path}',
          recoveryFile.path,
        );
      }
      rethrow;
    } catch (error) {
      rethrow;
    }
  }

  /// True when [error] looks like a Windows file-lock (sharing/lock
  /// violation) rather than a different filesystem failure.
  ///
  /// Shared by the EPUB pipeline and the settings store: a sharing violation
  /// (osError 32/33) can only be produced by a real Windows file lock, so the
  /// classification is tested directly with synthetic exceptions.
  static bool isFileLockError(FileSystemException error) {
    // ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION.
    final int? code = error.osError?.errorCode;
    if (code == 32 || code == 33) {
      return true;
    }
    // Prefer the OS-provided message: Dart's FileSystemException.message
    // embeds the file path, and a file literally named
    // "...being used by another process.epub" must not be misclassified
    // as a lock violation.
    const String lockPhrase = 'being used by another process';
    if ((error.osError?.message ?? '').toLowerCase().contains(lockPhrase)) {
      return true;
    }
    // Fallback for exceptions without OSError details: strip the path
    // before matching so a matching file name can't trigger a false
    // positive. (Single-character paths are test artifacts, not real file
    // paths; stripping those would mangle the message itself.)
    String message = error.message.toLowerCase();
    final String? path = error.path;
    if (path != null && path.length > 1) {
      message = message.replaceAll(path.toLowerCase(), '');
    }
    return message.contains(lockPhrase);
  }

  /// Recovers from a commit that died mid-rename: if the final file is
  /// missing but a `.bak.*` backup survived, the newest backup is restored;
  /// remaining stale backups are deleted. Best effort; never throws.
  static Future<void> _reclaimStaleBackups(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.bak.';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? _deleteBestEffort;
      final List<File> backups = <File>[];
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is File && path.basename(entity.path).startsWith(prefix)) {
          backups.add(entity);
        }
      }
      if (backups.isEmpty) {
        return;
      }
      // The timestamp suffix sorts chronologically; the newest is last.
      backups.sort((File a, File b) => a.path.compareTo(b.path));
      if (!await finalFile.exists()) {
        final File newest = backups.removeLast();
        try {
          await newest.rename(finalFile.path);
          AppLogger.warn(
            'Restored ${finalFile.path} from stale backup ${newest.path} '
            'left by an interrupted commit.',
            tag: 'repack',
          );
        } catch (_) {
          // Leave the backup file in place if the restore fails: it is the
          // only surviving copy of the user's output. Older stale backups
          // are still safe to delete below.
        }
      }
      for (final File stale in backups) {
        try {
          await deleteFile(stale);
        } catch (_) {
          // Best effort: one stuck file must not block the rest.
        }
      }
    } catch (_) {
      // Best effort: stale backups must never break a commit.
    }
  }

  @visibleForTesting
  static Future<void> reclaimStaleBackupsForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => _reclaimStaleBackups(finalFile, deleteForTest: deleteForTest);

  /// Deletes `.tmp.*` orphans left by a previous process that died after
  /// the isolate wrote the temp EPUB but before [commitTempFile] promoted
  /// it. Only files older than [_kStaleTempAge] are touched, and the temp
  /// file this commit is about to promote is always excluded — so a live
  /// commit is protected. Recovery files use a separate `.recovery.*`
  /// prefix and are never swept here: they are count/size-capped in
  /// [preserveRecoveryTempForTest] and reclaimed by [_reclaimRecoveryFiles]
  /// once a later commit succeeds.
  /// Best effort; never throws.
  static Future<void> _reclaimStaleTempFiles(
    File finalFile,
    File tempFile, {
    Future<void> Function(File file)? deleteForTest,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.tmp.';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? _deleteBestEffort;
      final DateTime cutoff = DateTime.now().subtract(_kStaleTempAge);
      final retained = <String>{..._retainedRecoveryPaths};
      final index = File('${finalFile.path}.recovery-index');
      if (await index.exists()) {
        retained.addAll(
          (await index.readAsLines())
              .where((name) => name.isNotEmpty && path.basename(name) == name)
              .map((name) => path.join(finalFile.parent.path, name)),
        );
      }
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File || !path.basename(entity.path).startsWith(prefix)) {
          continue;
        }
        if (sameFilesystemPath(entity.path, tempFile.path)) {
          continue;
        }
        if (retained.any((name) => sameFilesystemPath(name, entity.path))) {
          continue;
        }
        if ((await entity.lastModified()).isBefore(cutoff)) {
          try {
            await deleteFile(entity);
          } catch (_) {
            // Best effort: one stuck file must not block the rest.
          }
        }
      }
    } catch (_) {
      // Best effort: stale temps must never break a commit.
    }
  }

  @visibleForTesting
  static bool sameFilesystemPath(String first, String second, {bool? windows}) {
    if (windows ?? Platform.isWindows) {
      return path.windows
              .normalize(path.windows.absolute(first))
              .toLowerCase() ==
          path.windows.normalize(path.windows.absolute(second)).toLowerCase();
    }
    return path.normalize(path.absolute(first)) ==
        path.normalize(path.absolute(second));
  }

  @visibleForTesting
  static Future<void> reclaimStaleTempFilesForTest(
    File finalFile,
    File tempFile, {
    Future<void> Function(File file)? deleteForTest,
  }) =>
      _reclaimStaleTempFiles(finalFile, tempFile, deleteForTest: deleteForTest);

  /// Rename before reporting the path so automatic orphan sweeping cannot
  /// destroy the sole translated copy deliberately retained for recovery.
  @visibleForTesting
  static Future<File> preserveRecoveryTempForTest(
    File tempFile,
    File finalFile,
  ) async {
    try {
      final File recoveryFile = await tempFile.rename(
        '${finalFile.path}.recovery.${DateTime.now().microsecondsSinceEpoch}',
      );
      // A stuck lock would otherwise leave one full translated copy per
      // retry with no bound; enforce the count/size budget oldest-first.
      await _enforceRecoveryBudget(finalFile, exemptFile: recoveryFile);
      return recoveryFile;
    } on FileSystemException {
      // Even recovery naming can fail (component length, permissions, locks).
      // Keep the original payload and mark it exempt from orphan sweeping.
      _retainedRecoveryPaths.add(path.absolute(tempFile.path));
      try {
        await File('${finalFile.path}.recovery-index').writeAsString(
          '${path.basename(tempFile.path)}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (error) {
        AppLogger.warn(
          'Could not record recovery path ${tempFile.path}: ${error.runtimeType}',
          tag: 'repack',
        );
      }
      await _enforceRecoveryBudget(finalFile, exemptFile: tempFile);
      return tempFile;
    }
  }

  static final Set<String> _retainedRecoveryPaths = {};

  /// Only local, output-specific ledger entries authorize touching tmp files.
  static Future<Set<String>> _indexedRecoveryTemps(File finalFile) async {
    final index = File('${finalFile.path}.recovery-index');
    if (!await index.exists()) return {};
    final prefix = '${path.basename(finalFile.path)}.tmp.';
    return (await index.readAsLines())
        .where((name) => path.basename(name) == name && name.startsWith(prefix))
        .toSet();
  }

  /// Enforces the `.recovery.*` budget for one output: keeps at most
  /// [_kMaxRecoveryFiles] newest entries within [_kMaxRecoveryBytes] total,
  /// deleting oldest-first but retaining the last complete payload. Indexed
  /// tmp payloads and the pinned-last recovery ledger count toward the budget.
  /// Best effort; never throws.
  static Future<void> _enforceRecoveryBudget(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? exemptFile,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.recovery.';
      // `<basename>.recovery-index` does not start with
      // `<basename>.recovery.` — match it explicitly.
      final String indexName =
          '${path.basename(finalFile.path)}.recovery-index';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? _deleteBestEffort;
      final indexedTemps = await _indexedRecoveryTemps(finalFile);
      final spares = <String, File>{};
      final entries = <RecoveryBudgetEntry>[];
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File) continue;
        final String name = path.basename(entity.path);
        if (!name.startsWith(prefix) &&
            name != indexName &&
            !indexedTemps.contains(name)) {
          continue;
        }
        int size = 0;
        try {
          size = await entity.length();
        } catch (_) {
          // Treat an unreadable spare as empty; it is still count-capped.
        }
        spares[name] = entity;
        entries.add((
          name: name,
          sizeBytes: size,
          kind: name == indexName
              ? RecoveryBudgetKind.indexLedger
              : indexedTemps.contains(name)
              ? RecoveryBudgetKind.fallbackTmp
              : RecoveryBudgetKind.recoverySpare,
        ));
      }
      final exemptNames = {
        for (final entry in spares.entries)
          if (exemptFile != null &&
              sameFilesystemPath(entry.value.path, exemptFile.path))
            entry.key,
      };
      // P2-#15: the ledger is the orphan sweeper's only record of deliberate
      // recovery copies. recoveryBudgetDeletions only knows the PLAN — a
      // stuck file survives a failed delete, so the ledger must be
      // re-evaluated after the payload deletions actually land: it goes
      // only when no registered fallback payload still exists on disk.
      // Delete payloads first, then decide the ledger against reality.
      final Set<String> ledgerNames = <String>{
        for (final entry in entries)
          if (entry.kind == RecoveryBudgetKind.indexLedger) entry.name,
      };
      final List<String> planned = recoveryBudgetDeletions(
        entries,
        exemptNames: exemptNames,
      );
      Future<void> deleteSpare(String name) async {
        final spare = spares[name]!;
        try {
          await deleteFile(spare);
          if (!await spare.exists()) {
            _retainedRecoveryPaths.remove(path.absolute(spare.path));
          }
        } catch (_) {
          // Best effort: one stuck spare must not block the rest.
        }
      }

      for (final name in planned) {
        if (ledgerNames.contains(name)) continue;
        await deleteSpare(name);
      }
      for (final name in planned) {
        if (!ledgerNames.contains(name)) continue;
        bool fallbackSurvives = false;
        for (final entry in entries) {
          if (entry.kind != RecoveryBudgetKind.fallbackTmp) continue;
          final File? payload = spares[entry.name];
          if (payload == null) continue;
          try {
            if (await payload.exists()) {
              fallbackSurvives = true;
              break;
            }
          } catch (_) {
            // An unreadable payload is treated as surviving: keep the
            // ledger rather than risk orphan-sweeping a live recovery copy.
            fallbackSurvives = true;
            break;
          }
        }
        if (fallbackSurvives) continue;
        await deleteSpare(name);
      }
    } catch (_) {
      // Best effort: budget enforcement must never break a commit.
    }
  }

  /// Deletes all `.recovery.*` spares for [finalFile]. Called after a
  /// successful commit: the final file now holds the translation, so the
  /// spares kept for lock-conflict recovery are obsolete. Best effort;
  /// never throws.
  static Future<void> _reclaimRecoveryFiles(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? committedTempFile,
  }) async {
    try {
      final String prefix = '${path.basename(finalFile.path)}.recovery.';
      // `<basename>.recovery-index` does not start with
      // `<basename>.recovery.` — match it explicitly so the ledger is
      // reclaimed together with the spares it describes.
      final String indexName =
          '${path.basename(finalFile.path)}.recovery-index';
      final Future<void> Function(File file) deleteFile =
          deleteForTest ?? _deleteBestEffort;
      final indexedTemps = await _indexedRecoveryTemps(finalFile);
      await for (final FileSystemEntity entity in finalFile.parent.list()) {
        if (entity is! File) continue;
        final String name = path.basename(entity.path);
        if (committedTempFile != null &&
            sameFilesystemPath(entity.path, committedTempFile.path)) {
          continue;
        }
        if (name.startsWith(prefix) ||
            name == indexName ||
            indexedTemps.contains(name)) {
          try {
            await deleteFile(entity);
            if (!await entity.exists()) {
              _retainedRecoveryPaths.remove(path.absolute(entity.path));
            }
          } catch (_) {
            // Best effort: one stuck file must not block the rest.
          }
        }
      }
    } catch (_) {
      // Best effort: stale spares must never break a commit.
    }
  }

  @visibleForTesting
  static Future<void> enforceRecoveryBudgetForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
  }) => _enforceRecoveryBudget(finalFile, deleteForTest: deleteForTest);

  @visibleForTesting
  static Future<void> reclaimRecoveryFilesForTest(
    File finalFile, {
    Future<void> Function(File file)? deleteForTest,
    File? committedTempFile,
  }) => _reclaimRecoveryFiles(
    finalFile,
    deleteForTest: deleteForTest,
    committedTempFile: committedTempFile,
  );

  /// Sync helper used by tests that exercise pure filesystem commit logic.
  static void commitTempFileSyncForTest(File tempFile, File finalFile) {
    finalFile.parent.createSync(recursive: true);
    if (!tempFile.existsSync()) {
      throw StateError('Temp EPUB file is missing: ${tempFile.path}');
    }
    if (!finalFile.existsSync()) {
      tempFile.renameSync(finalFile.path);
      return;
    }
    final File backupFile = File(
      '${finalFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      finalFile.renameSync(backupFile.path);
      try {
        tempFile.renameSync(finalFile.path);
        if (backupFile.existsSync()) {
          backupFile.deleteSync();
        }
      } catch (error) {
        if (backupFile.existsSync() && !finalFile.existsSync()) {
          backupFile.renameSync(finalFile.path);
        }
        rethrow;
      }
    } catch (error) {
      // Match production commit semantics: a completed payload is recoverable.
      rethrow;
    }
  }

  /// Reads and decodes the source EPUB in a tight scope so the raw download
  /// buffer has no live local reference once decoding returns.
  static DecodedEpubArchive _decodeEpubArchive(
    String inputPath,
    String? expectedFingerprint,
  ) {
    final bytes = _readSourceBytesGuarded(inputPath);
    if (expectedFingerprint != null) {
      checkEpubSourceHash(
        sha256.convert(bytes).toString(),
        expectedFingerprint,
      );
    }
    return _decodeArchiveWithLimits(inputPath, bytes);
  }

  static ({Map<String, Uint8List> files, String fingerprint})
  _loadArchiveSnapshotSync(String inputPath) {
    final List<int> bytes = _readSourceBytesGuarded(inputPath);
    final Archive archive = _decodeArchiveWithLimits(inputPath, bytes).archive;
    final Map<String, Uint8List> files = <String, Uint8List>{};
    int totalInflatedBytes = 0;
    for (final ArchiveFile file in archive) {
      if (!file.isFile) {
        continue;
      }
      final Uint8List inflated = Uint8List.fromList(
        _fileBytes(file, inputPath: inputPath),
      );
      // The per-entry streaming cap stops a single lying entry mid-inflate,
      // but many small liars could still add up: enforce the same total cap
      // on ACTUAL inflated bytes, mirroring the header-declared preflight.
      totalInflatedBytes += inflated.length;
      if (totalInflatedBytes > _kMaxEpubUncompressedBytes) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: bytes.length,
          uncompressedBytes: totalInflatedBytes,
          limitBytes: _kMaxEpubUncompressedBytes,
        );
      }
      files[file.name] = inflated;
    }
    return (files: files, fingerprint: sha256.convert(bytes).toString());
  }

  /// Zip-bomb guards for [_decodeArchiveWithLimits]. A legitimate EPUB is
  /// tens of megabytes at most; these caps only trip on malicious or
  /// degenerate archives.
  ///
  /// Enforced while reading, before appending each chunk, so even a source
  /// growing after stat cannot make the accumulated payload exceed the cap.
  static const int _kMaxEpubCompressedBytes = 256 * 1024 * 1024;

  /// Cap on the header-declared uncompressed total across all entries.
  static const int _kMaxEpubUncompressedBytes = 512 * 1024 * 1024;

  /// Unix symlinks are rejected outright before the decoder eagerly inflates
  /// their paths. Retain this value for limit-exception diagnostics.
  static const int _kMaxSymlinkCompressedBytes = 64 * 1024;

  /// Cap on total-uncompressed / compressed-bytes. Real books sit far below
  /// this (text compresses ~3-5x, images barely at all); a classic 42.zip
  /// style bomb is many orders of magnitude above it.
  static const int _kMaxCompressionRatio = 100;

  /// Cap on the number of entries in the archive. Real books carry hundreds
  /// to low thousands of entries; tens of thousands is already implausible.
  /// Without this, a bomb of millions of near-empty entries sails under the
  /// size/ratio guards above while every entry still costs a decoded header
  /// object and per-entry processing downstream.
  static const int _kMaxEpubEntryCount = 50000;

  /// Reads the source file with two guards: a cap on the compressed size
  /// (see [_kMaxEpubCompressedBytes]) and Windows file-lock classification
  /// that throws [InputFileLockedException] instead of a raw English
  /// [FileSystemException].
  static List<int> _readSourceBytesGuarded(String inputPath) {
    final File file = File(inputPath);
    try {
      final handle = file.openSync();
      try {
        return _readChunksGuarded(
          inputPath,
          () => handle.readSync(64 * 1024),
          _kMaxEpubCompressedBytes,
        );
      } finally {
        handle.closeSync();
      }
    } on FileSystemException catch (error) {
      if (isFileLockError(error)) {
        throw InputFileLockedException(inputPath);
      }
      rethrow;
    }
  }

  /// Reads chunks into a single growable buffer instead of buffering every
  /// chunk and then copying them all again (BytesBuilder.takeBytes): that
  /// older shape peaked at ~2x the source size for large books. Growth is
  /// amortized doubling, and the returned view aliases the buffer with no
  /// final copy. The per-chunk limit check is preserved: the payload can
  /// never exceed [limitBytes], even for a source that grows mid-read.
  ///
  /// Fully streaming decode is not possible here: the ZIP central directory
  /// (and the EOCD scan in [checkZipEntryCountForTest]) requires random
  /// access to the whole payload, so one contiguous buffer is the minimum.
  static Uint8List _readChunksGuarded(
    String inputPath,
    List<int> Function() nextChunk,
    int limitBytes,
  ) {
    Uint8List buffer = Uint8List(64 * 1024);
    int length = 0;
    while (true) {
      final List<int> chunk = nextChunk();
      if (chunk.isEmpty) {
        break;
      }
      final int actualLength = length + chunk.length;
      // Check and accumulation are one operation; no stat/read TOCTOU gap.
      if (actualLength > limitBytes) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: actualLength,
          uncompressedBytes: -1,
          limitBytes: limitBytes,
        );
      }
      if (actualLength > buffer.length) {
        int newCapacity = buffer.length * 2;
        if (newCapacity < actualLength) {
          newCapacity = actualLength;
        }
        if (newCapacity > limitBytes) {
          newCapacity = limitBytes;
        }
        final Uint8List grown = Uint8List(newCapacity);
        grown.setRange(0, length, buffer);
        buffer = grown;
      }
      buffer.setRange(length, actualLength, chunk);
      length = actualLength;
    }
    if (length == buffer.length) {
      return buffer;
    }
    // Zero-copy trim: callers only ever read length bytes.
    return Uint8List.view(buffer.buffer, 0, length);
  }

  @visibleForTesting
  static Uint8List readChunksGuardedForTest({
    required String inputPath,
    required List<int> Function() nextChunk,
    required int limitBytes,
  }) => _readChunksGuarded(inputPath, nextChunk, limitBytes);

  /// Decodes ZIP bytes with zip-bomb guards. `archive` decodes lazily, so
  /// the header-declared entry sizes are accumulated BEFORE any entry
  /// content is touched: a malicious archive is rejected without ever
  /// materializing its payload. Entry inflation itself is guarded separately
  /// (see [_fileBytes]): the preflight cannot catch entries that lie about
  /// their declared sizes.
  static DecodedEpubArchive _decodeArchiveWithLimits(
    String inputPath,
    List<int> bytes,
  ) {
    checkZipEntryCountForTest(inputPath, bytes);
    checkSymlinkEntrySizesForTest(inputPath, bytes);
    final ZipDecoder decoder = ZipDecoder();
    final Archive archive = decoder.decodeBytes(bytes);
    final Set<String> seen = <String>{};
    final Set<String> duplicates = <String>{};
    for (final ZipFileHeader header in decoder.directory.fileHeaders) {
      final file = header.file;
      final name = file?.filename;
      if (file == null || name == null || name.isEmpty) continue;
      if (!seen.add(name)) {
        duplicates.add(name);
        // archive 4.0.9 merges metadata onto the FIRST payload. Rebuild the
        // duplicate entry from its final raw header so read and repack both
        // honor the promised last-wins content and a matching CRC.
        final entry = name.endsWith('/') || name.endsWith('\\')
            ? ArchiveFile.directory(name)
            : ArchiveFile.file(name, file.uncompressedSize, file);
        entry
          ..compression = file.compressionMethod
          ..mode = header.externalFileAttributes >> 16
          ..crc32 = file.crc32
          ..lastModTime = file.lastModFileDate << 16 | file.lastModFileTime;
        archive.add(entry);
      }
    }
    checkArchiveLimitsForTest(
      inputPath: inputPath,
      archive: archive,
      compressedBytes: bytes.length,
    );
    return (archive: archive, duplicateNames: duplicates);
  }

  /// Validates the EOCD comment length and requires archive 4.0.9's signature
  /// scan to select the same record before any directory entries are decoded.
  static int _findValidatedEocdEnd(List<int> bytes) {
    Never invalid() => throw const FormatException('Invalid ZIP directory.');
    int u16(int at) {
      if (at < 0 || at + 2 > bytes.length) invalid();
      return bytes[at] | (bytes[at + 1] << 8);
    }

    int u32(int at) => u16(at) | (u16(at + 2) << 16);

    int end = bytes.length - 22;
    final int searchStart = bytes.length - 22 - 65535;
    while (end >= 0 && end >= searchStart) {
      if (u32(end) == 0x06054b50 && end + 22 + u16(end + 20) == bytes.length) {
        break;
      }
      end--;
    }
    if (end < 0 || end < searchStart) invalid();

    // Mirror ZipDirectory._findSignature, including its chunk boundaries,
    // reading the existing buffer directly without allocating chunk copies.
    final length = bytes.length - 4;
    const bufferSize = 1024;
    final chunkSize = length < bufferSize ? length : bufferSize;
    var startPos = length - chunkSize;
    while (startPos >= 0) {
      for (var chunkPos = chunkSize - 4; chunkPos >= 0; --chunkPos) {
        if (u32(startPos + chunkPos) == 0x06054b50) {
          if (startPos + chunkPos != end) invalid();
          return end;
        }
      }
      if (startPos > 0 && startPos < chunkSize) {
        startPos = 0;
      } else {
        startPos -= chunkSize;
      }
    }
    invalid();
  }

  /// The decoder builds *all* central-directory headers before its first
  /// callback, even with decodeStream. Walk their lengths without allocating
  /// entry objects before handing the bytes to it. Count actual headers too:
  /// an attacker can under-report the EOCD count or repeat identical names.
  @visibleForTesting
  static void checkZipEntryCountForTest(String inputPath, List<int> bytes) {
    Never invalid() => throw const FormatException('Invalid ZIP directory.');
    int u16(int at) {
      if (at < 0 || at + 2 > bytes.length) invalid();
      return bytes[at] | (bytes[at + 1] << 8);
    }

    int u32(int at) => u16(at) | (u16(at + 2) << 16);
    int u64(int at) {
      final low = u32(at);
      final high = u32(at + 4);
      // No supported input can need a >32-bit count, size or offset.
      if (high != 0) invalid();
      return low;
    }

    void checkCount(int count) {
      if (count > _kMaxEpubEntryCount) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: bytes.length,
          uncompressedBytes: count,
          limitBytes: _kMaxEpubEntryCount,
        );
      }
    }

    final int end = _findValidatedEocdEnd(bytes);
    if (u16(end + 4) != 0 || u16(end + 6) != 0) invalid();
    int count = u16(end + 10);
    int size = u32(end + 12);
    int offset = u32(end + 16);
    int directoryBoundary = end;
    if (end >= 20 && u32(end - 20) == 0x07064b50) {
      final locator = end - 20;
      if (u32(locator + 4) != 0 || u32(locator + 16) != 1) invalid();
      final zip64 = u64(locator + 8);
      if (zip64 + 56 > locator || u32(zip64) != 0x06064b50) invalid();
      final recordSize = u64(zip64 + 4);
      if (recordSize < 44 || zip64 + 12 + recordSize != locator) invalid();
      if (u32(zip64 + 16) != 0 || u32(zip64 + 20) != 0) invalid();
      count = u64(zip64 + 32);
      checkCount(count);
      if (u64(zip64 + 24) != count) invalid();
      size = u64(zip64 + 40);
      offset = u64(zip64 + 48);
      directoryBoundary = zip64;
    } else {
      checkCount(count);
      if (u16(end + 8) != count) invalid();
    }
    final directoryEnd = offset + size;
    if (directoryEnd != directoryBoundary) invalid();
    int actualCount = 0;
    while (offset < directoryEnd) {
      if (offset + 46 > directoryEnd || u32(offset) != 0x02014b50) {
        invalid();
      }
      checkCount(++actualCount);
      final length =
          46 + u16(offset + 28) + u16(offset + 30) + u16(offset + 32);
      if (offset + length > directoryEnd) invalid();
      offset += length;
    }
    if (actualCount != count) invalid();
  }

  /// Rejects all Unix symlinks in the raw central directory before the decoder
  /// eagerly reads their payloads, regardless of compression method or size.
  @visibleForTesting
  static void checkSymlinkEntrySizesForTest(String inputPath, List<int> bytes) {
    Never invalid() => throw const FormatException('Invalid ZIP directory.');
    int u16(int at) {
      if (at < 0 || at + 2 > bytes.length) invalid();
      return bytes[at] | (bytes[at + 1] << 8);
    }

    int u32(int at) => u16(at) | (u16(at + 2) << 16);
    int u64(int at) {
      final low = u32(at);
      if (u32(at + 4) != 0) invalid();
      return low;
    }

    // Mirror the ZIP64 locator handling in checkZipEntryCountForTest.
    final int end = _findValidatedEocdEnd(bytes);
    if (u16(end + 4) != 0 || u16(end + 6) != 0) invalid();
    int size = u32(end + 12);
    int offset = u32(end + 16);
    int directoryBoundary = end;
    if (end >= 20 && u32(end - 20) == 0x07064b50) {
      final locator = end - 20;
      if (u32(locator + 4) != 0 || u32(locator + 16) != 1) invalid();
      final zip64 = u64(locator + 8);
      if (zip64 + 56 > locator || u32(zip64) != 0x06064b50) invalid();
      final recordSize = u64(zip64 + 4);
      if (recordSize < 44 || zip64 + 12 + recordSize != locator) invalid();
      if (u32(zip64 + 16) != 0 || u32(zip64 + 20) != 0) invalid();
      size = u64(zip64 + 40);
      offset = u64(zip64 + 48);
      directoryBoundary = zip64;
    }
    final directoryEnd = offset + size;
    if (directoryEnd != directoryBoundary) invalid();
    while (offset < directoryEnd) {
      if (offset + 46 > directoryEnd || u32(offset) != 0x02014b50) {
        invalid();
      }
      final length =
          46 + u16(offset + 28) + u16(offset + 30) + u16(offset + 32);
      if (offset + length > directoryEnd) invalid();
      final versionMadeBy = u16(offset + 4);
      final externalFileAttributes = u32(offset + 38);
      if ((versionMadeBy >> 8) == 3 &&
          ((externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        final compressedSize = u32(offset + 20);
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedSize,
          uncompressedBytes: -1,
          limitBytes: _kMaxSymlinkCompressedBytes,
        );
      }
      offset += length;
    }
  }

  /// Visible for testing: the pure limit check behind
  /// [_decodeArchiveWithLimits]. Takes a decoded [archive] so tests can
  /// feed synthetic entries with huge declared sizes without building a
  /// real multi-hundred-megabyte file.
  @visibleForTesting
  static void checkArchiveLimitsForTest({
    required String inputPath,
    required Archive archive,
    required int compressedBytes,
  }) {
    int entryCount = 0;
    int totalUncompressed = 0;
    for (final ArchiveFile entry in archive) {
      // Count every entry (files and directories): each one costs a decoded
      // header object, so millions of near-empty entries are a DoS vector
      // even when their declared sizes stay under the byte caps below.
      entryCount += 1;
      if (entryCount > _kMaxEpubEntryCount) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedBytes,
          uncompressedBytes: entryCount,
          limitBytes: _kMaxEpubEntryCount,
        );
      }
      if (!entry.isFile) {
        continue;
      }
      totalUncompressed += entry.size;
      if (totalUncompressed > _kMaxEpubUncompressedBytes) {
        throw EpubDecompressionLimitException(
          inputPath: inputPath,
          compressedBytes: compressedBytes,
          uncompressedBytes: totalUncompressed,
          limitBytes: _kMaxEpubUncompressedBytes,
        );
      }
    }
    if (totalUncompressed > compressedBytes * _kMaxCompressionRatio) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedBytes,
        uncompressedBytes: totalUncompressed,
        limitBytes: compressedBytes * _kMaxCompressionRatio,
      );
    }
  }

  /// Encodes the EPUB and writes only a same-directory temp file.
  /// Returns the absolute temp path. Does not touch [outputFilePath].
  static String _writeTranslatedEpubToTempSync({
    required String inputPath,
    required String outputFilePath,
    required Map<String, String> translatedHtmlByPath,
    Map<String, String> navigationLabelsByPath = const <String, String>{},
    String? navigationLanguageTag,
    List<String>? sourceLanguageTags,
    bool bilingual = false,
    String? expectedSourceFingerprint,
    String? translatedTitle,
    String? ownedTempPath,
  }) {
    // Keep source payloads compressed and share their ArchiveFile objects.
    // Only navigation metadata is inflated; output goes straight to disk.
    final DecodedEpubArchive decoded = _decodeEpubArchive(
      inputPath,
      expectedSourceFingerprint,
    );
    final Archive sourceArchive = decoded.archive;
    // Names occurring more than once in the raw central directory. The
    // decoder merges duplicates in place, so they cannot be counted from the
    // decoded archive (a per-archive name count is always 1).
    final Set<String> duplicateNames = decoded.duplicateNames;
    final Archive repacked = Archive();

    // Navigation metadata (OPF language + translated NCX labels) is rendered
    // here from the same decoded archive: one decode pass, and the whole
    // book never has to cross into the main isolate. Navigation entries win
    // on collision, matching the old main-isolate addAll order.
    // Note: unlike chapter HTML, the rendered navigation XML is not passed
    // through _validateXmlReplacements — it is produced by the xml package
    // itself (well-formed by construction), not by model output.
    final Map<String, String> replacements = Map<String, String>.of(
      translatedHtmlByPath,
    );
    // Title/label translations remain useful even for unknown language tags;
    // the renderer independently guards language-only changes.
    final Map<String, List<int>> archiveView = _LazyArchiveView(
      sourceArchive,
      inputPath: inputPath,
    );
    replacements.addAll(
      renderNavigationMetadata(
        archiveFiles: archiveView,
        labelsByPath: navigationLabelsByPath,
        languageTag: navigationLanguageTag,
        sourceLanguageTags: sourceLanguageTags,
        bilingual: bilingual,
        renderedHtmlByPath: translatedHtmlByPath,
        translatedTitle: translatedTitle,
      ),
    );

    // The EPUB spec requires the mimetype entry to exist, be first,
    // uncompressed, and contain exactly "application/epub+zip". A missing
    // entry is synthesized; an empty or whitespace-padded entry (some tools
    // write "application/epub+zip\n") is normalized to the standard value
    // instead of propagating the defect into the output.
    const String standardMimetype = 'application/epub+zip';
    final ArchiveFile? mimetypeFile = sourceArchive.find('mimetype');
    String declaredMimetype = '';
    if (mimetypeFile != null) {
      declaredMimetype = utf8
          .decode(
            _fileBytes(mimetypeFile, inputPath: inputPath),
            allowMalformed: true,
          )
          .trim();
    }
    final List<int> mimetypeBytes = utf8.encode(
      declaredMimetype == standardMimetype
          ? declaredMimetype
          : standardMimetype,
    );
    final ArchiveFile repackedMimetype = ArchiveFile.noCompress(
      'mimetype',
      mimetypeBytes.length,
      mimetypeBytes,
    );
    final int? sourceModTime = mimetypeFile?.lastModTime;
    if (sourceModTime != null) {
      repackedMimetype.lastModTime = sourceModTime;
    }
    final int? sourceMode = mimetypeFile?.mode;
    if (sourceMode != null) {
      repackedMimetype.mode = sourceMode;
    }
    repacked.add(repackedMimetype);

    // The read path (_loadArchiveSnapshotSync) keys entries by name in a Map,
    // so duplicate entry names resolve last-wins there. The copy loop used
    // to emit every copy — including an untranslated first copy of a
    // replaced chapter, which some readers prefer. Dedupe to last-wins so
    // both sides agree on which copy survives. Insertion order (first-seen
    // position) is preserved, so entry ordering is unchanged.
    final Map<String, ArchiveFile> dedupedSource = <String, ArchiveFile>{};
    for (final ArchiveFile sourceFile in sourceArchive) {
      dedupedSource[sourceFile.name] = sourceFile;
    }

    // P-#44: the duplicate CRC check and its repair path inflate the same
    // entry; share one per-repack cache so the payload is inflated once
    // and reused instead of inflating twice.
    final Map<ArchiveFile, List<int>> duplicateBytesCache =
        <ArchiveFile, List<int>>{};
    int duplicateCacheBytes = 0;
    void onDuplicateCacheInsert(ArchiveFile file, List<int> inserted) {
      final int compressedBytes = file.rawContent is ZipFile
          ? (file.rawContent as ZipFile).compressedSize
          : inserted.length;
      duplicateCacheBytes = checkDuplicateCacheBudgetForTest(
        currentTotalBytes: duplicateCacheBytes,
        insertedBytes: inserted,
        inputPath: inputPath,
        compressedBytes: compressedBytes,
      );
    }

    for (final ArchiveFile sourceFile in dedupedSource.values) {
      if (sourceFile.name == 'mimetype') {
        continue;
      }
      if (!sourceFile.isFile) {
        repacked.add(
          ArchiveFile.directory(sourceFile.name)
            ..lastModTime = sourceFile.lastModTime
            ..mode = sourceFile.mode,
        );
        continue;
      }

      final String? replacement = replacements[sourceFile.name];
      if (replacement != null) {
        final List<int> utf8Bytes = utf8.encode(replacement);
        repacked.add(
          ArchiveFile.bytes(sourceFile.name, utf8Bytes)
            ..compression = sourceFile.compression
            ..lastModTime = sourceFile.lastModTime
            ..mode = sourceFile.mode,
        );
        continue;
      }

      // Compressed pass-through reuses the source payload verbatim, but for
      // duplicate entry names the decoded ArchiveFile is corrupt by
      // construction: ZipDecoder keeps the FIRST duplicate's payload while
      // overwriting crc32 with the LAST duplicate's value. ZipEncoder would
      // then write a CRC that does not match the content. Verify the stored
      // CRC against the payload for duplicates and recompress on mismatch
      // so the encoder writes a correct CRC.
      //
      // The trigger is deliberately NOT a per-archive name count: the
      // decoder merges duplicates in place, so counting names over the
      // decoded archive is always 1 and that branch could never fire.
      // Duplicates are detected from the raw central-directory headers
      // ([DecodedEpubArchive.duplicateNames]) instead. Deleting the branch
      // instead would regress the corrupt-CRC protection (see
      // b_round7_regression_test.dart #28, which asserts valid CRCs in the
      // repacked output for duplicate entries).
      if (duplicateNames.contains(sourceFile.name) &&
          !_storedCrcMatchesPayload(
            sourceFile,
            inputPath: inputPath,
            bytesCache: duplicateBytesCache,
            onCacheInsert: onDuplicateCacheInsert,
          )) {
        final List<int> payload = _fileBytes(
          sourceFile,
          inputPath: inputPath,
          bytesCache: duplicateBytesCache,
          onCacheInsert: onDuplicateCacheInsert,
        );
        AppLogger.warn(
          'Duplicate entry "${sourceFile.name}" has a CRC mismatch; '
          'recompressing instead of reusing the stored payload.',
          tag: 'repack',
        );
        repacked.add(
          ArchiveFile.bytes(sourceFile.name, payload)
            ..compression = sourceFile.compression
            ..lastModTime = sourceFile.lastModTime
            ..mode = sourceFile.mode,
        );
        continue;
      }

      repacked.add(sourceFile);
    }

    final File outputFile = File(outputFilePath);
    outputFile.parent.createSync(recursive: true);

    final String tempPath =
        ownedTempPath ??
        path.join(
          outputFile.parent.path,
          '${path.basename(outputFilePath)}.tmp.${DateTime.now().microsecondsSinceEpoch}',
        );
    final File tempFile = File(tempPath);
    try {
      final output = OutputFileStream(tempPath);
      try {
        ZipEncoder().encodeStream(repacked, output);
      } finally {
        output.closeSync();
      }
      // OutputFileStream.flush drains its buffer but does not fsync. Preserve
      // the previous flush:true durability before exposing a committable temp.
      final handle = tempFile.openSync(mode: FileMode.append);
      try {
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      return tempFile.path;
    } catch (error) {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      rethrow;
    }
  }

  /// Single-attempt best-effort delete for sweep/commit paths: stale
  /// backups, stale temps, recovery spares and the post-promotion backup
  /// are obsolete files whose deletion must never stall a commit on retry
  /// backoff. Never throws.
  static Future<void> _deleteBestEffort(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  /// Visible for testing.
  @visibleForTesting
  static Future<void> deleteBestEffortForTest(File file) =>
      _deleteBestEffort(file);

  /// Retrying delete for the cancel path only: right after the isolate
  /// releases the temp file's handle, Windows may hold a transient lock,
  /// so a single attempt would spuriously fail. Never throws; warns on the
  /// final failed attempt.
  static Future<void> _deleteQuietly(File file) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        if (await file.exists()) await file.delete();
        return;
      } catch (error) {
        if (attempt == 4) {
          AppLogger.warn(
            'Could not delete ${file.path}: ${error.runtimeType}',
            tag: 'repack',
          );
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 25 * (1 << attempt)));
      }
    }
  }

  /// Inflates [file]'s content, guarding against zip-bomb entries that lie
  /// about their header-declared size.
  ///
  /// The preflight ([checkArchiveLimitsForTest]) only accumulates the
  /// header-declared [ArchiveFile.size], so a malicious entry can declare a
  /// tiny size while inflating to gigabytes and sail through it. Lazily
  /// decoded entries (whose [ArchiveFile.rawContent] is a [ZipFile]) are
  /// therefore inflated through [_GuardedInflateStream], which counts the
  /// ACTUAL decompressed bytes as they arrive and throws
  /// [EpubDecompressionLimitException] the moment the cap is exceeded — the
  /// inflate aborts mid-stream instead of materializing the payload first.
  /// Already-materialized entries (built in memory by the repacker) hold no
  /// attacker-controlled bytes and take the direct path. Like the old
  /// `rawContent.getStream()` shape, this never memoizes into
  /// [ArchiveFile.content], so [ArchiveFile.isCompressed] stays intact for
  /// the repacker's compressed pass-through.
  static List<int> _fileBytes(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
    // Test-only: shrinks the per-entry inflate cap (P2-#14) so the guard is
    // exercisable without a 512 MiB bomb.
    int? limitBytesOverride,
  }) {
    final FileContent? raw = file.rawContent;
    if (raw is ZipFile) {
      // P-#44: callers that inflate the same entry twice in a row (CRC
      // verification followed by the repair path) share one cache so the
      // second call reuses the first call's bytes instead of inflating
      // again. The cache is caller-owned and never escapes the operation,
      // and nothing is memoized into ArchiveFile.content, so
      // ArchiveFile.isCompressed stays intact for the repacker.
      final int limit = limitBytesOverride ?? _kMaxEpubUncompressedBytes;
      if (bytesCache != null) {
        return bytesCache.putIfAbsent(file, () {
          final List<int> bytes = _inflateZipFileGuarded(
            inputPath: inputPath,
            file: file,
            zipFile: raw,
            limitBytes: limit,
          );
          onCacheInsert?.call(file, bytes);
          return bytes;
        });
      }
      return _inflateZipFileGuarded(
        inputPath: inputPath,
        file: file,
        zipFile: raw,
        limitBytes: limit,
      );
    }
    final Object content = file.content;
    if (content is Uint8List) {
      return content;
    }
    if (content is List<int>) {
      return content;
    }
    if (content is String) {
      return utf8.encode(content);
    }
    return <int>[];
  }

  static Uint8List _inflateZipFileGuarded({
    required String inputPath,
    required ArchiveFile file,
    required ZipFile zipFile,
    required int limitBytes,
  }) {
    // getStream(decompress: false) returns the raw payload stream, decrypting
    // first when needed (mirroring ZipFile.decompress). The stream position
    // is restored in finally: ZipFile.decompress does not restore it when the
    // output throws, and our guard aborts mid-inflate by throwing — without
    // this, a guarded entry would be left at EOS for any later use.
    final InputStream compressed = zipFile.getStream(decompress: false);
    final int savePos = compressed.position;
    try {
      if (zipFile.compressionMethod == CompressionType.deflate) {
        final output = _GuardedInflateStream(
          inputPath: inputPath,
          entryName: file.name,
          compressedBytes: zipFile.compressedSize,
          limitBytes: limitBytes,
        );
        _decodeRawInflateChunked(compressed, output);
        return output.getBytes();
      }
      if (zipFile.compressionMethod == CompressionType.bzip2) {
        final output = _GuardedInflateStream(
          inputPath: inputPath,
          entryName: file.name,
          compressedBytes: zipFile.compressedSize,
          limitBytes: limitBytes,
        );
        // BZip2Decoder.decodeStream writes to the output incrementally
        // (byte by byte), so the guard aborts mid-stream here without help.
        BZip2Decoder().decodeStream(compressed, output);
        return output.getBytes();
      }
      // Stored (uncompressed) entries need no inflate work: bound the
      // payload and hand back the source bytes directly instead of copying
      // them through the guard stream's growable buffer (P-#43). The
      // returned view aliases the decoded archive buffer; callers never
      // mutate it.
      if (compressed.length > limitBytes) {
        throw EpubDecompressionLimitException(
          inputPath: '$inputPath!${file.name}',
          compressedBytes: zipFile.compressedSize,
          uncompressedBytes: compressed.length,
          limitBytes: limitBytes,
        );
      }
      return compressed.toUint8List();
    } finally {
      compressed.setPosition(savePos);
    }
  }

  /// Incrementally inflates raw deflate data, feeding the guard stream chunk
  /// by chunk as the native decoder emits them.
  ///
  /// P1-#1: `ZLibDecoder().decodeStream` cannot back the guard — its io
  /// implementation funnels the whole decompressed payload through a
  /// `ChunkedConversionSink.withCallback` that only fires on close, so the
  /// full payload materializes before the guard ever sees a byte. Driving
  /// the chunked conversion manually lets the guard count actual output
  /// bytes per chunk and abort mid-stream the moment the cap is exceeded.
  static void _decodeRawInflateChunked(
    InputStream compressed,
    _GuardedInflateStream output,
  ) {
    final Sink<List<int>> inSink = ZLibCodec(
      raw: true,
    ).decoder.startChunkedConversion(_GuardedChunkSink(output));
    while (!compressed.isEOS) {
      final int remaining = compressed.length;
      final int chunkSize = remaining < 64 * 1024 ? remaining : 64 * 1024;
      inSink.add(compressed.readBytes(chunkSize).toUint8List());
    }
    inSink.close();
  }

  /// Visible for testing: inflate [file] with a caller-owned byte cache
  /// (P-#44), proving the CRC-verification and repair paths share one
  /// inflation instead of decoding the entry twice.
  @visibleForTesting
  static List<int> fileBytesForTest(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
  }) => _fileBytes(
    file,
    inputPath: inputPath,
    bytesCache: bytesCache,
    onCacheInsert: onCacheInsert,
  );

  /// Checks the cumulative inflated payload retained by the duplicate cache.
  @visibleForTesting
  static int checkDuplicateCacheBudgetForTest({
    required int currentTotalBytes,
    required List<int> insertedBytes,
    required String inputPath,
    required int compressedBytes,
    int? budgetBytesOverride,
  }) {
    final int next = currentTotalBytes + insertedBytes.length;
    final int budget = budgetBytesOverride ?? _kMaxEpubUncompressedBytes;
    if (next > budget) {
      throw EpubDecompressionLimitException(
        inputPath: inputPath,
        compressedBytes: compressedBytes,
        uncompressedBytes: next,
        limitBytes: budget,
      );
    }
    return next;
  }

  /// Visible for testing: inflate [file] with a custom byte cap, proving the
  /// guard counts actual decompressed bytes rather than header-declared
  /// sizes (a lying entry declares small but inflates large).
  @visibleForTesting
  static List<int> inflateZipFileGuardedForTest({
    required ArchiveFile file,
    required String inputPath,
    required int limitBytes,
  }) {
    final FileContent? raw = file.rawContent;
    if (raw is ZipFile) {
      return _inflateZipFileGuarded(
        inputPath: inputPath,
        file: file,
        zipFile: raw,
        limitBytes: limitBytes,
      );
    }
    return _fileBytes(file, inputPath: inputPath);
  }

  /// True when the decoded entry's stored CRC32 matches its payload, so the
  /// compressed payload can be passed through to the encoder untouched. A
  /// null stored CRC is fine: the encoder recomputes it. Only duplicate
  /// entry names can corrupt the stored value (the decoder keeps the first
  /// duplicate's payload but overwrites crc32 with the last duplicate's),
  /// so callers only need this check for duplicates.
  static bool _storedCrcMatchesPayload(
    ArchiveFile file, {
    String inputPath = '',
    Map<ArchiveFile, List<int>>? bytesCache,
    void Function(ArchiveFile file, List<int> inserted)? onCacheInsert,
  }) {
    final int? stored = file.crc32;
    if (stored == null) {
      return true;
    }
    try {
      return getCrc32(
            _fileBytes(
              file,
              inputPath: inputPath,
              bytesCache: bytesCache,
              onCacheInsert: onCacheInsert,
            ),
          ) ==
          stored;
    } on EpubDecompressionLimitException {
      // A lying entry must abort via the limit handling, not degrade into a
      // "CRC mismatch → recompress" retry that would inflate it again.
      rethrow;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool storedCrcMatchesPayloadForTest(ArchiveFile file) =>
      _storedCrcMatchesPayload(file);
}
