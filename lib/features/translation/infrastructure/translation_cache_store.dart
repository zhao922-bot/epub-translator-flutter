import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../../../shared/io/atomic_file_writer.dart';
import '../domain/models/job_resume_state.dart';

final translationCacheStoreProvider = Provider<TranslationCacheStore>(
  (ref) => TranslationCacheStore(),
);

class TranslationCacheStore {
  TranslationCacheStore({
    Directory? cacheRoot,
    int maxCacheBytes = _maxCacheBytes,
    this.pruneInterval = const Duration(minutes: 5),
    DateTime Function()? now,
    @visibleForTesting this.onMaintenanceScan,
    @visibleForTesting this.resolveCacheRoot,
  }) : _rootOverride = cacheRoot,
       _capacity = maxCacheBytes,
       _now = now ?? DateTime.now;

  final Directory? _rootOverride;
  final int _capacity;
  final Duration pruneInterval;
  final DateTime Function() _now;
  @visibleForTesting
  final Future<void> Function()? onMaintenanceScan;
  @visibleForTesting
  final Future<Directory> Function()? resolveCacheRoot;
  Future<Directory>? _rootFuture;

  /// Parent directories already swept for stale `.tmp.*` files. Atomic
  /// writes can leave orphans if the process is killed between the temp
  /// write and the rename; each directory is swept once per instance,
  /// lazily, on first write there. Only temp files older than 30 minutes
  /// are removed, so a sweep racing concurrent writes in the same directory
  /// can never delete a live temp file (see `cleanStaleAtomicTempFiles`).
  final Set<String> _sweptTempDirs = <String>{};

  /// Upper bound for block translations under `blocks/`. Beyond this, the
  /// oldest block entries are evicted first. Job checkpoints under `jobs/`
  /// are deliberately excluded from this cap: each is a single tiny JSON
  /// file, they are resume-critical (evicting one loses paid progress after
  /// a crash), so they are neither counted toward the total nor ever
  /// evicted (see [pruneCacheDirectoryForTest]).
  static const int _maxCacheBytes = 512 * 1024 * 1024;

  // A full pass establishes/reconciles the disk baseline. Between passes,
  // successful writes update it by byte delta, not by accumulating payloads.
  final Map<String, int> _sizes = <String, int>{};
  final Map<String, Future<void>> _fileGates = <String, Future<void>>{};
  Map<String, int>? _scanChanges;
  int _estimatedBytes = 0;
  DateTime? _lastPrune;
  bool _maintenancePending = false;
  Future<void> _maintenanceTail = Future<void>.value();
  int _writeGeneration = 0;
  int _ineffectivePrunes = 0;
  DateTime? _retryAfter;

  static const String _envelopePrefix = 'epub-translation-cache-v1:sha256:';

  @visibleForTesting
  int get estimatedCacheBytesForTest => _estimatedBytes;

  @visibleForTesting
  Future<void> waitForMaintenanceForTest() async {
    Future<void> tail;
    do {
      tail = _maintenanceTail;
      await tail;
    } while (!identical(tail, _maintenanceTail));
  }

  void _resetBackoff() {
    _ineffectivePrunes = 0;
    _retryAfter = null;
  }

  // Writes and eviction share a per-file gate; unrelated keys stay parallel.
  Future<void> _withFileGate(File file, Future<void> Function() action) {
    final String key = file.path;
    final Future<void> previous = _fileGates[key] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _fileGates[key] = gate.future;
    return previous.then((_) async {
      try {
        await action();
      } finally {
        gate.complete();
        if (identical(_fileGates[key], gate.future)) {
          _fileGates.remove(key);
        }
      }
    });
  }

  void _recordSize(String key, int size) {
    _estimatedBytes += size - (_sizes[key] ?? 0);
    _sizes[key] = size;
    _scanChanges?[key] = size;
    if (_estimatedBytes <= _capacity) _resetBackoff();
  }

  Future<void> _sweepStaleTempFiles(Directory directory) async {
    if (!_sweptTempDirs.add(directory.path)) {
      return;
    }
    await cleanStaleAtomicTempFiles(directory);
  }

  Future<String?> getBlockTranslation(String cacheKey) async {
    final File file = await _blockCacheFile(cacheKey);
    try {
      final String raw = await file.readAsString();
      // Legacy entries have no checksum. Trust them to preserve paid progress;
      // all new writes use the versioned integrity envelope below.
      if (!raw.startsWith(_envelopePrefix)) return raw;
      final int newline = raw.indexOf('\n');
      if (newline < 0) return null;
      final String digest = raw.substring(_envelopePrefix.length, newline);
      final String payload = raw.substring(newline + 1);
      return sha256.convert(utf8.encode(payload)).toString() == digest
          ? payload
          : null;
    } on FileSystemException catch (error) {
      // ENOENT on POSIX; ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND on
      // Windows. Other failures remain unreadable-cache errors to callers.
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) return null;
      rethrow;
    }
  }

  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    final File file = await _blockCacheFile(cacheKey);
    await file.parent.create(recursive: true);
    await _sweepStaleTempFiles(file.parent);
    // Write to a temp file and rename: a kill mid-write must never leave a
    // truncated half-written cache entry behind, otherwise resume would
    // silently treat torn HTML as a valid cached translation.
    // `writeFileAtomically` gives each concurrent write a unique temp path,
    // so parallel writes to the same key cannot interleave into torn HTML.
    await _withFileGate(file, () async {
      if (!_sizes.containsKey(file.path)) {
        final FileStat stat = await file.stat();
        _recordSize(
          file.path,
          stat.type == FileSystemEntityType.file ? stat.size : 0,
        );
      }
      final String envelope =
          '$_envelopePrefix'
          '${sha256.convert(utf8.encode(translatedHtml))}\n$translatedHtml';
      await writeFileAtomically(file, envelope);
      _writeGeneration++;
      _recordSize(file.path, utf8.encode(envelope).length);
    });
    _pruneIfNeeded();
  }

  /// Schedules an initial baseline scan, then maintenance on writes when the
  /// time interval expires or estimated capacity is exceeded. Pending requests
  /// are coalesced; failures cannot break a translation run.
  void _pruneIfNeeded({bool capacityFollowUp = false}) {
    final DateTime now = _now();
    if (_estimatedBytes <= _capacity) _resetBackoff();
    if (_maintenancePending ||
        (_retryAfter != null && now.isBefore(_retryAfter!)) ||
        (_lastPrune != null &&
            now.difference(_lastPrune!) < pruneInterval &&
            _estimatedBytes <= _capacity)) {
      return;
    }
    _maintenancePending = true;
    _lastPrune = now;
    // Start on a separate event turn, and never join this future from put.
    _maintenanceTail = _maintenanceTail.then(
      (_) => Future<void>(() async {
        final int generation = _writeGeneration;
        bool scanned = false;
        int deletedBytes = 0;
        try {
          deletedBytes = await _scanAndPrune(await _cacheRoot(), _capacity);
          scanned = true;
        } catch (_) {
          // Cache maintenance must never break translation.
        } finally {
          if (_estimatedBytes <= _capacity || deletedBytes > 0) {
            _resetBackoff();
          } else if (!scanned ||
              generation == _writeGeneration ||
              capacityFollowUp) {
            // No reclaimable space (or a failed pass): don't rescan on every
            // put. Concurrent writes get one immediate follow-up pass first,
            // but cannot keep no-effect scans spinning indefinitely.
            _ineffectivePrunes++;
            final int minutes = _ineffectivePrunes >= 5
                ? 60
                : 5 * (1 << (_ineffectivePrunes - 1));
            _retryAfter = _now().add(Duration(minutes: minutes));
          }
          _maintenancePending = false;
          if (_estimatedBytes > _capacity) {
            _pruneIfNeeded(capacityFollowUp: true);
          }
        }
      }),
    );
  }

  /// Scans [root] and evicts the oldest entries under `blocks/` until the
  /// total is back under [maxBytes] (default [_maxCacheBytes]).
  ///
  /// Job checkpoints under `jobs/` are never evicted and their bytes are
  /// not counted: they are tiny, and losing one to eviction would discard
  /// already-paid translation progress after a process crash. Leftover
  /// `.tmp.*` files count toward the cap (they occupy real disk space) but
  /// are never evicted here: they may belong to an in-flight write in
  /// another isolate or process. Stale ones are removed before accounting.
  Future<void> pruneCacheDirectoryForTest(
    Directory root, {
    int maxBytes = _maxCacheBytes,
  }) {
    final Future<void> pass = _maintenanceTail.then((_) async {
      await _scanAndPrune(root, maxBytes);
    });
    _maintenanceTail = pass.catchError((Object _) {});
    return pass;
  }

  Future<int> _scanAndPrune(Directory root, int maxBytes) async {
    final Map<String, int> changes = <String, int>{};
    _scanChanges = changes;
    try {
      if (!await root.exists()) return 0;
      // Sweep every shard, including ones no longer receiving writes. Do not
      // memoize this maintenance pass: a previously fresh orphan can age out.
      await cleanStaleAtomicTempFiles(root);
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Directory) {
          await cleanStaleAtomicTempFiles(entity);
        }
      }
      final List<_CacheEntry> entries = <_CacheEntry>[];
      final Map<String, int> scannedSizes = <String, int>{};
      final Map<String, FileStat> temps = <String, FileStat>{};
      int deletedBytes = 0;
      await for (final FileSystemEntity entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String relative = path.relative(entity.path, from: root.path);
        if (relative == 'jobs' ||
            relative.startsWith('jobs${path.separator}')) {
          continue;
        }
        final bool isAtomicTemp = path.basename(entity.path).contains('.tmp.');
        try {
          final FileStat stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          // Fresh temps count toward the cap but cannot be evicted: they may
          // belong to another live writer. Stale ones were swept above.
          if (isAtomicTemp) {
            temps[entity.path] = stat;
          } else {
            scannedSizes[entity.path] = stat.size;
            entries.add(
              _CacheEntry(
                file: entity,
                size: stat.size,
                modified: stat.modified,
              ),
            );
          }
        } catch (_) {
          // A file that vanishes mid-scan is simply skipped.
        }
      }
      await onMaintenanceScan?.call();
      // Reconcile the temporary paths, not just their original byte sum. A
      // rename may have promoted a listed temp during this scan, including in
      // another store/process. Size+mtime identifies that promotion. This
      // synchronous reconciliation and the overlay below cannot interleave
      // with this isolate's completed-write accounting.
      int reconcileTemps() {
        int bytes = 0;
        for (final temp in temps.entries) {
          final FileStat current = FileStat.statSync(temp.key);
          if (current.type == FileSystemEntityType.file) {
            bytes += current.size;
          } else {
            final String target = temp.key.substring(
              0,
              temp.key.lastIndexOf('.tmp.'),
            );
            final FileStat promoted = FileStat.statSync(target);
            if (promoted.type == FileSystemEntityType.file &&
                promoted.size == temp.value.size &&
                promoted.modified == temp.value.modified &&
                !changes.containsKey(target)) {
              scannedSizes[target] = promoted.size;
            }
          }
        }
        return bytes;
      }

      int tempBytes = reconcileTemps();
      // Overlay writes completed during listing, including newly created keys.
      scannedSizes.addAll(changes);
      int totalBytes = tempBytes + scannedSizes.values.fold(0, (a, b) => a + b);
      if (totalBytes > maxBytes) {
        entries.sort(
          (_CacheEntry a, _CacheEntry b) => a.modified.compareTo(b.modified),
        );
        final int targetBytes = (maxBytes * 0.9).toInt();
        for (final _CacheEntry entry in entries) {
          if (totalBytes <= targetBytes) break;
          try {
            await _withFileGate(entry.file, () async {
              // Never delete a replacement written since this scan began.
              if (changes.containsKey(entry.file.path)) return;
              final FileStat current = await entry.file.stat();
              if (current.type != FileSystemEntityType.file ||
                  current.size != entry.size ||
                  current.modified != entry.modified) {
                return;
              }
              await entry.file.delete();
              totalBytes -= entry.size;
              deletedBytes += entry.size;
              _recordSize(entry.file.path, 0);
            });
          } catch (_) {
            // Best effort; a locked file is left for the next pass.
          }
        }
      }
      tempBytes = reconcileTemps();
      scannedSizes.addAll(changes);
      scannedSizes.removeWhere((_, size) => size == 0);
      _sizes
        ..clear()
        ..addAll(scannedSizes);
      _estimatedBytes = tempBytes + _sizes.values.fold(0, (a, b) => a + b);
      return deletedBytes;
    } finally {
      _scanChanges = null;
    }
  }

  Future<JobResumeState?> loadJobState(String jobKey) async {
    final File file = await _jobStateFile(jobKey);
    if (!await file.exists()) {
      return null;
    }
    final String raw = await file.readAsString();
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return JobResumeState.fromJson(decoded);
  }

  Future<void> saveJobState(JobResumeState state) async {
    final File file = await _jobStateFile(state.jobKey);
    await file.parent.create(recursive: true);
    await _sweepStaleTempFiles(file.parent);
    await writeFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    await _pruneOldJobStates();
  }

  /// Maximum retained per-job checkpoints, aligned with the 20-entry job
  /// history cap: a checkpoint whose job has scrolled out of history can no
  /// longer be resumed through the UI, so keeping more would let `jobs/`
  /// grow without bound.
  static const int _maxJobCheckpoints = 20;

  /// Deletes the oldest checkpoints beyond [_maxJobCheckpoints]. Best
  /// effort: checkpoint maintenance must never break a translation run. All
  /// recently active checkpoints (including the one just saved) are protected
  /// for five minutes, even when this temporarily exceeds the count cap.
  Future<void> _pruneOldJobStates() async {
    try {
      final Directory root = await _cacheRoot();
      await pruneJobCheckpointsForTest(
        Directory(path.join(root.path, 'jobs')),
        maxCheckpoints: _maxJobCheckpoints,
      );
    } catch (_) {
      // Best effort; a locked file is left for the next pass.
    }
  }

  /// Deletes the oldest checkpoint files in [jobsDir] beyond
  /// [maxCheckpoints] (oldest first by modification time).
  @visibleForTesting
  Future<void> pruneJobCheckpointsForTest(
    Directory jobsDir, {
    int maxCheckpoints = _maxJobCheckpoints,
  }) async {
    if (!await jobsDir.exists()) {
      return;
    }
    final List<({File file, DateTime modified})> entries =
        <({File file, DateTime modified})>[];
    await for (final FileSystemEntity entity in jobsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        entries.add((file: entity, modified: (await entity.stat()).modified));
      } catch (_) {
        // A file that vanishes mid-scan is simply skipped.
      }
    }
    if (entries.length <= maxCheckpoints) {
      return;
    }
    entries.sort(
      (
        ({File file, DateTime modified}) a,
        ({File file, DateTime modified}) b,
      ) => a.modified.compareTo(b.modified),
    );
    int remaining = entries.length;
    final DateTime activeSince = _now().subtract(const Duration(minutes: 5));
    for (final entry in entries) {
      if (remaining <= maxCheckpoints) break;
      if (!entry.modified.isBefore(activeSince)) continue;
      try {
        // A resume/save may have refreshed it since listing. Recheck before
        // deletion; active checkpoints may temporarily exceed the count cap.
        final FileStat current = await entry.file.stat();
        if (current.modified != entry.modified ||
            !current.modified.isBefore(activeSince)) {
          continue;
        }
        await entry.file.delete();
        remaining--;
      } catch (_) {
        // Best effort; a locked file is left for the next pass.
      }
    }
  }

  Future<void> clearJobState(String jobKey) async {
    final File file = await _jobStateFile(jobKey);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _blockCacheFile(String cacheKey) async {
    final Directory root = await _cacheRoot();
    return File(
      path.join(
        root.path,
        'blocks',
        cacheKey.substring(0, 2),
        '$cacheKey.html',
      ),
    );
  }

  Future<File> _jobStateFile(String jobKey) async {
    final Directory root = await _cacheRoot();
    return File(path.join(root.path, 'jobs', '$jobKey.json'));
  }

  Future<Directory> _cacheRoot() async {
    if (_rootOverride != null) return _rootOverride;
    return _rootFuture ??= (resolveCacheRoot ?? _resolveCacheRoot)();
  }

  Future<Directory> _resolveCacheRoot() async {
    final Directory appDirectory = Directory(
      await PlatformUtils.appDocumentsDirectory(),
    );
    return Directory(path.join(appDirectory.path, 'translation_cache'));
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.file,
    required this.size,
    required this.modified,
  });

  final File file;
  final int size;
  final DateTime modified;
}
