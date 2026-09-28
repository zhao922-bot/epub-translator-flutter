import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/platform/platform_utils.dart';
import '../domain/models/translation_job.dart';

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
      final Object? decoded = jsonDecode(await file.readAsString());
      final Object? jobsNode = decoded is Map<String, dynamic>
          ? decoded['jobs']
          : decoded;
      final int clearedAt = decoded is Map<String, dynamic>
          ? _readClearedAt(decoded)
          : 0;
      return (jobs: _parseJobs(jobsNode), clearedAt: clearedAt);
    } catch (_) {
      return (jobs: const <TranslationJob>[], clearedAt: 0);
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
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    final File file = await _historyFile();
    await file.parent.create(recursive: true);
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
