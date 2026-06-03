import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../domain/models/job_resume_state.dart';

final translationCacheStoreProvider = Provider<TranslationCacheStore>(
  (ref) => TranslationCacheStore(),
);

class TranslationCacheStore {
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
    await file.writeAsString(translatedHtml);
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
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
      flush: true,
    );
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
