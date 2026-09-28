import 'dart:convert';
import 'dart:io';

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

  /// Size check runs at most every [_pruneCheckInterval] writes so a large
  /// book does not stat the cache directory per block.
  static const int _pruneCheckInterval = 64;
  int _writesSincePruneCheck = 0;
  bool _pruning = false;

  Future<void> _sweepStaleTempFiles(Directory directory) async {
    if (!_sweptTempDirs.add(directory.path)) {
      return;
    }
    await cleanStaleAtomicTempFiles(directory);
  }

  Future<String?> getBlockTranslation(String cacheKey) async {
    final File file = await _blockCacheFile(cacheKey);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
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
    await writeFileAtomically(file, translatedHtml);
    await _pruneIfNeeded();
  }

  /// Evicts the oldest cache entries when the cache grows past
  /// [_maxCacheBytes]. Purely defensive: any failure is swallowed so cache
  /// maintenance can never break a translation run.
  Future<void> _pruneIfNeeded() async {
    _writesSincePruneCheck += 1;
    if (_writesSincePruneCheck < _pruneCheckInterval || _pruning) {
      return;
    }
    _writesSincePruneCheck = 0;
    _pruning = true;
    try {
      final Directory root = await _cacheRoot();
      if (!await root.exists()) {
        return;
      }
      await pruneCacheDirectoryForTest(root);
    } catch (_) {
      // Cache maintenance must never break translation.
    } finally {
      _pruning = false;
    }
  }

  /// Scans [root] and evicts the oldest entries under `blocks/` until the
  /// total is back under [maxBytes] (default [_maxCacheBytes]).
  ///
  /// Job checkpoints under `jobs/` are never evicted and their bytes are
  /// not counted: they are tiny, and losing one to eviction would discard
  /// already-paid translation progress after a process crash. Leftover
  /// `.tmp.*` files count toward the cap (they occupy real disk space) but
  /// are never evicted here: they may belong to an in-flight write in
  /// another isolate or process, and stale ones are reclaimed by
  /// `cleanStaleAtomicTempFiles` on write sweeps.
  Future<void> pruneCacheDirectoryForTest(
    Directory root, {
    int maxBytes = _maxCacheBytes,
  }) async {
    final List<_CacheEntry> entries = <_CacheEntry>[];
    int totalBytes = 0;
    await for (final FileSystemEntity entity in root.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final String relative = path.relative(entity.path, from: root.path);
      if (relative == 'jobs' || relative.startsWith('jobs${path.separator}')) {
        continue;
      }
      final String name = path.basename(entity.path);
      final bool isAtomicTemp = name.contains('.tmp.');
      try {
        final FileStat stat = await entity.stat();
        totalBytes += stat.size;
        // Leftover `.tmp.*` files count toward the cap but are never
        // evicted here: a temp file may belong to an in-flight write in
        // another isolate or process, and stale ones are reclaimed by
        // `cleanStaleAtomicTempFiles` on write sweeps.
        if (!isAtomicTemp) {
          entries.add(
            _CacheEntry(file: entity, size: stat.size, modified: stat.modified),
          );
        }
      } catch (_) {
        // A file that vanishes mid-scan is simply skipped.
      }
    }
    if (totalBytes <= maxBytes) {
      return;
    }
    entries.sort(
      (_CacheEntry a, _CacheEntry b) => a.modified.compareTo(b.modified),
    );
    final int targetBytes = (maxBytes * 0.9).toInt();
    for (final _CacheEntry entry in entries) {
      if (totalBytes <= targetBytes) {
        break;
      }
      try {
        await entry.file.delete();
        totalBytes -= entry.size;
      } catch (_) {
        // Best effort; a locked file is left for the next pass.
      }
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
  /// effort: checkpoint maintenance must never break a translation run. The
  /// checkpoint just written is always the newest, so it can never be pruned
  /// by its own save.
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
    for (int i = 0; i < entries.length - maxCheckpoints; i++) {
      try {
        await entries[i].file.delete();
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
