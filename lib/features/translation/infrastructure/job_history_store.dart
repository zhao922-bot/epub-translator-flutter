import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/io/strip_bom.dart';
import '../../../shared/logging/app_logger.dart';
import '../../../shared/platform/platform_utils.dart';
import '../domain/models/translation_job.dart';

/// Thrown by [JobHistoryStore.save] when the file's clear tombstone is newer
/// than the caller's: another app instance cleared the history after this
/// instance last read it. Writing would resurrect the cleared entries and
/// move the tombstone backwards, so the write is refused; the caller should
/// re-read (its clear-guard will then see the newer tombstone and drop the
/// stale in-memory entries).
class HistoryWriteConflict implements Exception {
  HistoryWriteConflict(this.currentClearedAt);

  /// The newer tombstone found in the file.
  final int currentClearedAt;

  @override
  String toString() =>
      'HistoryWriteConflict: file cleared at $currentClearedAt '
      'after this instance last read it';
}

/// Thrown by [JobHistoryStore.saveMerged] when the cross-process history
/// lock cannot be acquired within [_historyLockTimeout]: another app
/// instance is holding it without making progress (debugger-paused, wedged
/// event loop). The write is abandoned, not retried forever — the caller's
/// next persist will try again, and `clearJobHistory` surfaces the failure
/// instead of hanging the UI.
class HistoryLockTimeout implements Exception {
  HistoryLockTimeout(this.timeout);

  final Duration timeout;

  @override
  String toString() =>
      'HistoryLockTimeout: history lock not acquired within $timeout';
}

/// How long `saveMerged` waits for the cross-process history lock before
/// giving up with [HistoryLockTimeout].
const Duration _historyLockTimeout = Duration(seconds: 10);

/// Acquires an exclusive lock on [lockHandle], failing fast instead of
/// blocking forever: a non-blocking attempt throws [FileSystemException]
/// immediately when another *process* holds the lock, so retry every 100ms
/// until [timeout] and then throw [HistoryLockTimeout].
///
/// (Same-process handles never contend on POSIX — verified by test — which
/// is why the in-process mutex in `saveMerged` serializes same-isolate
/// callers separately.)
Future<void> _lockWithTimeout(
  RandomAccessFile lockHandle, {
  Duration timeout = _historyLockTimeout,
}) async {
  // P2-#40: measure the deadline with a monotonic Stopwatch, not the wall
  // clock. A system clock rollback during the wait must not stretch the
  // timeout (a ~1-hour rollback would otherwise extend a 10-second wait to
  // ~1 hour).
  final Stopwatch waitClock = Stopwatch()..start();
  for (;;) {
    try {
      await lockHandle.lock(FileLock.exclusive);
      return;
    } on FileSystemException {
      if (waitClock.elapsed >= timeout) {
        throw HistoryLockTimeout(timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class JobHistoryStore {
  JobHistoryStore({this.historyFileProvider});

  final Future<File> Function()? historyFileProvider;

  @visibleForTesting
  Future<void> Function()? onBeforeCorruptBackupForTest;

  @visibleForTesting
  Future<void> Function()? onBeforeCorruptRenameForTest;

  /// Fingerprint of the file's raw bytes. P2-#34: this must be computed on
  /// the bytes, never on the (possibly lossy) decoded string — two different
  /// byte sequences can decode to the same string once undecodable bytes
  /// become U+FFFD, and a concurrently repaired file would then be mistaken
  /// for unchanged and moved aside.
  String _fingerprint(List<int> bytes) => sha256.convert(bytes).toString();

  Future<List<TranslationJob>> load() async => (await loadWithTombstone()).jobs;

  /// Loads the history together with the clear tombstone: the
  /// milliseconds-since-epoch of the last `clearJobHistory`, or 0 when the
  /// history was never cleared (including the legacy bare-list format).
  ///
  /// The tombstone lets a second app instance detect that another instance
  /// cleared the history after its last read, so its periodic persistence
  /// does not resurrect the cleared entries (see
  /// `TranslationDashboardController._persistJobHistory`).
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async {
    try {
      final File file = await _historyFile();
      if (!await file.exists()) {
        return (jobs: const <TranslationJob>[], clearedAt: 0);
      }
      // Windows Notepad writes UTF-8 with BOM; without stripping, a
      // hand-edited job-history.json parses as corrupt, the load returns
      // empty, and the next persist silently wipes the whole history.
      //
      // P2-#25: decode strictly first. `allowMalformed` would replace
      // undecodable bytes inside a JSON string with U+FFFD, and the result
      // still parses — but the decoded text is not the file's true content,
      // and a later save would overwrite the original bytes with the
      // substituted text and no backup. Undecodable bytes are untrusted:
      // they take the corrupt-backup path instead.
      //
      // Perf-#54: strict-decode exactly once; the lossy decode runs only
      // when the bytes are genuinely undecodable.
      final List<int> bytes = await file.readAsBytes();
      final String raw;
      try {
        raw = utf8.decode(bytes);
      } on FormatException {
        // P2-#33: the corrupt file may still carry a valid clear tombstone;
        // preserve it so a concurrent instance's saveMerged cannot resurrect
        // cleared entries.
        final int preservedClearedAt = await _backupCorruptHistoryFile(
          expectedFingerprint: _fingerprint(bytes),
        );
        AppLogger.error(
          'Failed to decode job-history.json as UTF-8; moved aside and '
          'starting fresh.',
          tag: 'history',
        );
        return (
          jobs: const <TranslationJob>[],
          clearedAt: preservedClearedAt,
        );
      }
      try {
        final Object? decoded = jsonDecode(stripLeadingBom(raw));
        // P2-#34: valid JSON with the wrong structure (e.g. "jobs" is a
        // map instead of a list) must take the corrupt-backup path like
        // unparseable JSON. The old code silently parsed it as empty
        // history, and a later saveMerged would then overwrite the file
        // with no evidence preserved.
        if (!_isValidHistoryStructure(decoded)) {
          throw const FormatException(
            'job-history.json has an invalid structure',
          );
        }
        final Object? jobsNode = decoded is Map<String, dynamic>
            ? decoded['jobs']
            : decoded;
        final int clearedAt = decoded is Map<String, dynamic>
            ? _readClearedAt(decoded)
            : 0;
        return (jobs: _parseJobs(jobsNode), clearedAt: clearedAt);
      } catch (parseError) {
        // Preserve genuinely unparseable history, unless another writer has
        // changed it since this read (including repairing its clear tombstone).
        // P2-#33: preserve the tombstone so saveMerged applies it.
        final int preservedClearedAt = await _backupCorruptHistoryFile(
          expectedFingerprint: _fingerprint(bytes),
        );
        AppLogger.error(
          'Failed to parse job-history.json; moved aside and starting fresh.',
          tag: 'history',
          error: parseError,
        );
        return (
          jobs: const <TranslationJob>[],
          clearedAt: preservedClearedAt,
        );
      }
    } on FileSystemException catch (error) {
      // Transient IO failure (an antivirus/indexer lock on Windows, a
      // disappearing network drive): the file is not corrupt, only
      // unreadable right now. Do NOT rename it aside — the next load will
      // retry and the history is preserved.
      AppLogger.error(
        'Failed to read job-history.json (transient IO error); '
        'will retry on next load.',
        tag: 'history',
        error: error,
      );
      return (jobs: const <TranslationJob>[], clearedAt: 0);
    }
  }

  /// P2-#34: the only shapes this store ever writes are a bare job list
  /// (legacy) and the version-2 envelope whose "jobs" is a list. Anything
  /// else that parses — a map without a list "jobs", a bare string, `null`
  /// — is a structural error and must be backed up, never silently treated
  /// as empty history.
  static bool _isValidHistoryStructure(Object? decoded) =>
      decoded is List<dynamic> ||
      (decoded is Map<String, dynamic> && decoded['jobs'] is List<dynamic>);

  /// Renames an unparseable history file aside (best effort) so the next
  /// [save] cannot silently destroy it with no recovery path.
  ///
  /// Returns the clear tombstone preserved from the corrupt file (P2-#33),
  /// or 0 when none could be recovered. A corrupt file may still carry a
  /// valid tombstone; dropping it would let another instance's [saveMerged]
  /// resurrect already-cleared entries because it can no longer see the
  /// tombstone.
  Future<int> _backupCorruptHistoryFile({
    String? expectedFingerprint,
    bool lockHeld = false,
  }) async {
    try {
      await onBeforeCorruptBackupForTest?.call();
      final File file = await _historyFile();
      if (!await file.exists()) return 0;
      final List<int> bytes = await file.readAsBytes();
      final String fingerprint = _fingerprint(bytes);
      if (expectedFingerprint != null && expectedFingerprint != fingerprint) {
        return 0;
      }
      // Best-effort tombstone recovery before the rename: the JSON may be
      // torn but still contain a readable clearedAt.
      final int preservedClearedAt = _extractTombstoneBestEffort(bytes);
      final String backupPath = path.join(
        file.parent.path,
        'job-history.json.bad-${DateTime.now().microsecondsSinceEpoch}',
      );
      await onBeforeCorruptRenameForTest?.call();
      final File backup = await file.rename(backupPath);
      final List<int> movedBytes = await backup.readAsBytes();
      if (expectedFingerprint != null &&
          expectedFingerprint != _fingerprint(movedBytes)) {
        // A writer replaced the history after the precheck. Preserve the
        // moved contents, without restoring over a newer write or pruning.
        // If no new active file exists, move it back so a repaired history
        // isn't lost from view (P1-#2: the rename must not silently drop a
        // just-fixed history).
        //
        // P1-#3: the exists() check and the rename must be atomic with
        // respect to concurrent writers: another instance committing a new
        // history in between would have its fresh file overwritten by this
        // stale backup. Re-verify under the cross-process history lock; if
        // the file appeared, the newer history wins and the backup stays in
        // place as evidence.
        await _restoreBackupIfStillAbsent(
          file,
          backup,
          lockHeld: lockHeld,
        );
        return 0;
      }
      await _pruneCorruptBackups(file.parent);
      return preservedClearedAt;
    } catch (_) {
      // Best effort only: a failed backup must not break startup.
      return 0;
    }
  }

  /// Best-effort recovery of the clear tombstone from a corrupt history
  /// file's raw bytes (P2-#33). Tries a full JSON parse first, then falls
  /// back to scanning for the clearedAt field in case the file is torn.
  /// Never throws.
  static int _extractTombstoneBestEffort(List<int> bytes) {
    try {
      final String raw = utf8.decode(bytes, allowMalformed: true);
      try {
        final Object? decoded = jsonDecode(stripLeadingBom(raw));
        if (decoded is Map<String, dynamic>) {
          return _readClearedAt(decoded);
        }
      } catch (_) {
        // Torn JSON: fall through to the field scan.
      }
      final RegExpMatch? match = RegExp(
        r'"clearedAt"\s*:\s*(\d+)',
      ).firstMatch(raw);
      if (match != null) {
        return int.tryParse(match.group(1) ?? '') ?? 0;
      }
    } catch (_) {
      // Best effort only.
    }
    return 0;
  }

  /// Restores [backup] to [file]'s path only if [file] is still absent,
  /// re-checking under the cross-process history lock so a concurrent
  /// writer cannot slip a new history in between the check and the rename
  /// (P1-#3). When the file appeared, the newer history is kept and the
  /// backup is left in place.
  ///
  /// [lockHeld] must be true when the caller already holds the history
  /// lock ([saveMerged]): the in-process mutex is not re-entrant, and no
  /// cooperating writer can interleave inside that critical section anyway,
  /// so a plain re-check suffices there.
  Future<void> _restoreBackupIfStillAbsent(
    File file,
    File backup, {
    required bool lockHeld,
  }) async {
    Future<void> restoreIfAbsent() async {
      if (await file.exists()) return;
      await backup.rename(file.path);
    }

    if (lockHeld) {
      await restoreIfAbsent();
      return;
    }
    final File lockFile = File('${file.path}.lock');
    await _withInProcessMutex(lockFile.path, () async {
      final RandomAccessFile lockHandle = await lockFile.open(
        mode: FileMode.write,
      );
      try {
        await _lockWithTimeout(lockHandle);
        await restoreIfAbsent();
      } finally {
        try {
          await lockHandle.unlock();
        } catch (_) {
          // Best effort: the close below releases the lock anyway.
        }
        await lockHandle.close();
      }
    });
  }

  /// How many corrupt-history backups to keep. Every genuinely corrupt file
  /// leaves one `job-history.json.bad-<microseconds>` behind; without a
  /// bound they accumulate forever.
  static const int _maxCorruptBackups = 5;

  /// Deletes `job-history.json.bad-*` backups beyond [_maxCorruptBackups],
  /// oldest first (the microseconds-since-epoch suffix sorts
  /// chronologically).
  Future<void> _pruneCorruptBackups(Directory directory) async {
    try {
      final List<File> backups = await directory
          .list()
          .where(
            (FileSystemEntity entity) =>
                entity is File &&
                path.basename(entity.path).startsWith('job-history.json.bad-'),
          )
          .cast<File>()
          .toList();
      backups.sort((File a, File b) => a.path.compareTo(b.path));
      for (int i = 0; i + _maxCorruptBackups < backups.length; i++) {
        try {
          await backups[i].delete();
        } catch (_) {
          // Best effort: leave whatever cannot be deleted.
        }
      }
    } catch (_) {
      // Best effort: a listing failure must not break startup.
    }
  }

  static int _readClearedAt(Map<String, dynamic> envelope) {
    final Object? value = envelope['clearedAt'];
    return value is int ? value : 0;
  }

  List<TranslationJob> _parseJobs(Object? decoded) {
    if (decoded is! List<dynamic>) {
      return const <TranslationJob>[];
    }
    final List<TranslationJob> jobs = <TranslationJob>[];
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      try {
        jobs.add(TranslationJob.fromJson(item));
        if (jobs.length == 20) break;
      } catch (_) {
        // A single corrupt entry should not prevent the app from opening.
      }
    }
    return jobs.toList(growable: false);
  }

  /// Saves the history. [clearedAtEpochMs] preserves the clear tombstone so
  /// a concurrent app instance's `clearJobHistory` is not silently undone by
  /// this write (see `TranslationDashboardController._persistJobHistory`).
  ///
  /// Throws [HistoryWriteConflict] when the file on disk carries a *newer*
  /// tombstone than [clearedAtEpochMs]: another instance cleared after this
  /// instance's last read, and writing would resurrect the cleared entries.
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    final File file = await _historyFile();
    await file.parent.create(recursive: true);
    int preservedClearedAt = 0;
    if (await file.exists()) {
      final List<int> bytes = await file.readAsBytes();
      final String raw = utf8.decode(bytes, allowMalformed: true);
      try {
        final Object? decoded = jsonDecode(stripLeadingBom(raw));
        if (decoded is Map<String, dynamic> &&
            _readClearedAt(decoded) > clearedAtEpochMs) {
          throw HistoryWriteConflict(_readClearedAt(decoded));
        }
      } on HistoryWriteConflict {
        rethrow;
      } on FormatException {
        // P2-#33: preserve the tombstone so this write does not resurrect
        // cleared entries.
        preservedClearedAt = await _backupCorruptHistoryFile(
          expectedFingerprint: _fingerprint(bytes),
        );
        if (await file.exists()) rethrow;
      }
    }
    // P2-#33: never move the tombstone backwards; the preserved tombstone
    // from a corrupt file wins over an older caller value.
    final int tombstone = preservedClearedAt > clearedAtEpochMs
        ? preservedClearedAt
        : clearedAtEpochMs;
    final Map<String, Object?> payload = <String, Object?>{
      'version': 2,
      'clearedAt': tombstone,
      'jobs': jobs
          .take(20)
          .map((TranslationJob job) => job.toJson())
          .toList(growable: false),
    };
    await writeFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  /// Atomically reads the history file, merges, and writes it back under a
  /// cross-process exclusive lock (a sidecar `job-history.json.lock` file).
  ///
  /// The read, the clear-tombstone check, the [merge], and the write all
  /// happen inside the lock, so two app instances can no longer interleave
  /// their read-modify-write cycles: the loser re-reads the winner's write
  /// instead of silently discarding the entries it added.
  ///
  /// [merge] receives the jobs currently in the file (and its clear
  /// tombstone) and returns the jobs to write. It runs inside the critical
  /// section, so it must be synchronous and fast — snapshot everything it
  /// needs beforehand.
  ///
  /// Returns `written: false` (and does not write) when the file carries a
  /// *newer* clear tombstone than [clearedAtEpochMs]: another instance
  /// cleared after this instance's last read, and writing would resurrect
  /// the cleared entries. The caller should then adopt [fileClearedAt] and
  /// drop its stale in-memory entries (same semantics as the old
  /// [HistoryWriteConflict], without the exception).
  ///
  /// The written tombstone is `max(clearedAtEpochMs, fileClearedAt)` so a
  /// merge can never move the tombstone backwards.
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(
      List<TranslationJob> fileJobs,
      int fileClearedAt,
    )
    merge,
    required int clearedAtEpochMs,
  }) async {
    final File file = await _historyFile();
    await file.parent.create(recursive: true);
    final File lockFile = File('${file.path}.lock');
    // In-process mutex outside, OS lock inside: the mutex serializes
    // same-isolate callers (which the OS lock cannot see on POSIX), the OS
    // lock serializes separate processes. The OS lock is acquired as late
    // as possible so it is never held while waiting on the Dart mutex.
    return _withInProcessMutex(lockFile.path, () async {
      final RandomAccessFile lockHandle = await lockFile.open(
        mode: FileMode.write,
      );
      try {
        // Timed exclusive: the second instance retries here instead of
        // racing, but gives up after [_historyLockTimeout] rather than
        // blocking forever when the peer is wedged. Mandatory on Windows,
        // advisory (flock) on Linux/Android — both instances use this same
        // path, so either is sufficient.
        await _lockWithTimeout(lockHandle);
        int fileClearedAt = 0;
        List<TranslationJob> fileJobs = const <TranslationJob>[];
        if (await file.exists()) {
          final List<int> bytes = await file.readAsBytes();
          // P2-#34: fingerprint the raw bytes, not the decoded string.
          final String fingerprint = _fingerprint(bytes);
          try {
            // Strict decode inside the try: undecodable bytes take the
            // corrupt-backup path like unparseable JSON.
            final String raw = utf8.decode(bytes);
            final Object? decoded = jsonDecode(stripLeadingBom(raw));
            final int clearedAt = decoded is Map<String, dynamic>
                ? _readClearedAt(decoded)
                : 0;
            if (clearedAt > clearedAtEpochMs) {
              return (written: false, fileClearedAt: clearedAt);
            }
            fileClearedAt = clearedAt;
            // P2-#34: like the load path, structurally invalid JSON must be
            // backed up, not silently merged as empty (which would let this
            // write overwrite the file with no evidence preserved).
            if (!_isValidHistoryStructure(decoded)) {
              throw const FormatException(
                'job-history.json has an invalid structure',
              );
            }
            final Object? jobsNode = decoded is Map<String, dynamic>
                ? decoded['jobs']
                : decoded;
            fileJobs = _parseJobs(jobsNode);
          } on FormatException {
            // Only parse failures can start fresh, after preserving evidence.
            // IO failures must propagate: an unreadable file is not empty.
            // P2-#33: the corrupt file's tombstone is preserved and applied
            // to the merge below, so cleared entries cannot be resurrected.
            fileClearedAt = await _backupCorruptHistoryFile(
              expectedFingerprint: fingerprint,
              // This method already holds the cross-process history lock
              // (P1-#3: the lock is not re-entrant).
              lockHeld: true,
            );
            if (await file.exists()) rethrow;
          }
        }
        final List<TranslationJob> toSave = merge(fileJobs, fileClearedAt);
        final int tombstone = fileClearedAt > clearedAtEpochMs
            ? fileClearedAt
            : clearedAtEpochMs;
        final Map<String, Object?> payload = <String, Object?>{
          'version': 2,
          'clearedAt': tombstone,
          'jobs': toSave
              .take(20)
              .map((TranslationJob job) => job.toJson())
              .toList(growable: false),
        };
        await writeFileAtomically(
          file,
          const JsonEncoder.withIndent('  ').convert(payload),
        );
        return (written: true, fileClearedAt: fileClearedAt);
      } finally {
        try {
          await lockHandle.unlock();
        } catch (_) {
          // Best effort: the close below releases the lock anyway.
        }
        await lockHandle.close();
        // Keep a stable sidecar identity. On POSIX a waiting process may
        // already have opened this inode; unlinking it would let another
        // writer create a different file and acquire an independent lock.
      }
    });
  }

  /// In-isolate mutual exclusion, keyed by lock-file path. The OS file lock
  /// below serializes *processes*, but on Linux/macOS two handles opened by
  /// the same process do not block each other (flock is per open-file
  /// description and a process never deadlocks against itself), so two
  /// concurrent `saveMerged` calls in one isolate would still interleave
  /// their read-modify-write cycles. This chain serializes them; the OS
  /// lock still covers the true multi-process case (two app instances are
  /// two processes, where flock/LockFileEx do conflict).
  static final Map<String, Future<void>> _inProcessLockChains =
      <String, Future<void>>{};

  static Future<T> _withInProcessMutex<T>(
    String key,
    Future<T> Function() body,
  ) async {
    final Future<void> previous =
        _inProcessLockChains[key] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _inProcessLockChains[key] = gate.future;
    await previous;
    try {
      return await body();
    } finally {
      if (identical(_inProcessLockChains[key], gate.future)) {
        _inProcessLockChains.remove(key);
      }
      gate.complete();
    }
  }

  Future<File> _historyFile() async {
    final Future<File> Function()? provider = historyFileProvider;
    if (provider != null) {
      return provider();
    }
    final Directory appDirectory = Directory(
      await PlatformUtils.appDocumentsDirectory(),
    );
    return File(path.join(appDirectory.path, 'job-history.json'));
  }
}
