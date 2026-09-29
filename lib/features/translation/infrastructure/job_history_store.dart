import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class JobHistoryStore {
  JobHistoryStore({this.historyFileProvider});

  final Future<File> Function()? historyFileProvider;

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
      final Object? decoded = jsonDecode(
        stripLeadingBom(await file.readAsString()),
      );
      final Object? jobsNode = decoded is Map<String, dynamic>
          ? decoded['jobs']
          : decoded;
      final int clearedAt = decoded is Map<String, dynamic>
          ? _readClearedAt(decoded)
          : 0;
      return (jobs: _parseJobs(jobsNode), clearedAt: clearedAt);
    } catch (error) {
      // A genuinely unparseable history file would otherwise be silently
      // overwritten by the next persist with no recovery path; rename it
      // aside (best effort) like the settings store does.
      await _backupCorruptHistoryFile();
      AppLogger.error(
        'Failed to parse job-history.json; moved aside and starting fresh.',
        tag: 'history',
        error: error,
      );
      return (jobs: const <TranslationJob>[], clearedAt: 0);
    }
  }

  /// Renames an unparseable history file aside (best effort) so the next
  /// [save] cannot silently destroy it with no recovery path.
  Future<void> _backupCorruptHistoryFile() async {
    try {
      final File file = await _historyFile();
      if (!await file.exists()) return;
      final String backupPath = path.join(
        file.parent.path,
        'job-history.json.bad-${DateTime.now().microsecondsSinceEpoch}',
      );
      await file.rename(backupPath);
    } catch (_) {
      // Best effort only: a failed backup must not break startup.
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
      } catch (_) {
        // A single corrupt entry should not prevent the app from opening.
      }
    }
    return jobs.take(20).toList(growable: false);
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
    if (await file.exists()) {
      try {
        final Object? decoded = jsonDecode(
          stripLeadingBom(await file.readAsString()),
        );
        if (decoded is Map<String, dynamic> &&
            _readClearedAt(decoded) > clearedAtEpochMs) {
          throw HistoryWriteConflict(_readClearedAt(decoded));
        }
      } on HistoryWriteConflict {
        rethrow;
      } catch (_) {
        // Unparseable file: fall through and overwrite. (A corrupt file
        // would already have been backed aside by loadWithTombstone.)
      }
    }
    final Map<String, Object?> payload = <String, Object?>{
      'version': 2,
      'clearedAt': clearedAtEpochMs,
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
        // Blocking exclusive: the second instance waits here instead of
        // racing. Mandatory on Windows, advisory (flock) on Linux/Android —
        // both instances use this same path, so either is sufficient.
        await lockHandle.lock(FileLock.blockingExclusive);
        int fileClearedAt = 0;
        List<TranslationJob> fileJobs = const <TranslationJob>[];
        if (await file.exists()) {
          try {
            final Object? decoded = jsonDecode(
              stripLeadingBom(await file.readAsString()),
            );
            final int clearedAt = decoded is Map<String, dynamic>
                ? _readClearedAt(decoded)
                : 0;
            if (clearedAt > clearedAtEpochMs) {
              return (written: false, fileClearedAt: clearedAt);
            }
            fileClearedAt = clearedAt;
            final Object? jobsNode = decoded is Map<String, dynamic>
                ? decoded['jobs']
                : decoded;
            fileJobs = _parseJobs(jobsNode);
          } catch (_) {
            // Unparseable file: merge over empty. (A corrupt file would
            // already have been backed aside by loadWithTombstone.)
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
