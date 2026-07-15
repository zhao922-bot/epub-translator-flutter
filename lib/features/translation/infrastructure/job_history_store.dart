import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../domain/models/translation_job.dart';

class JobHistoryStore {
  JobHistoryStore({this.historyFileProvider});

  final Future<File> Function()? historyFileProvider;

  Future<List<TranslationJob>> load() async {
    try {
      final File file = await _historyFile();
      if (!await file.exists()) {
        return const <TranslationJob>[];
      }
      final Object? decoded = jsonDecode(await file.readAsString());
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
    } catch (_) {
      return const <TranslationJob>[];
    }
  }

  Future<void> save(List<TranslationJob> jobs) async {
    final File file = await _historyFile();
    await file.parent.create(recursive: true);
    final List<Map<String, dynamic>> payload = jobs
        .take(20)
        .map((TranslationJob job) => job.toJson())
        .toList(growable: false);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
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
