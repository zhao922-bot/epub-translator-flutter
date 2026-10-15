import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';

void main() {
  late Directory dir;
  late File file;
  late JobHistoryStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history-worker-');
    file = File('${dir.path}/history.json');
    store = JobHistoryStore(historyFileProvider: () async => file);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  const job = TranslationJob(
    id: 'j',
    inputPath: 'b.epub',
    outputPath: 'o.epub',
    status: TranslationJobStatus.completed,
    progress: 1,
  );
  test(
    'UTF-8, escaped strings and values spanning input chunks remain intact',
    () async {
      final title = '${'a' * 65460}中文😀"\\end';
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'jobs': [job.copyWith(currentChapter: title).toJson()],
          'clearedAt': 17,
        }),
      );
      final loaded = await store.loadWithTombstone();
      expect(loaded.jobs.single.currentChapter, title);
      expect(loaded.clearedAt, 17);
    },
  );
  test(
    'tail is validated and duplicate envelope fields use the last value',
    () async {
      final first = jsonEncode([job.copyWith(id: 'first').toJson()]);
      final last = jsonEncode([job.copyWith(id: 'last').toJson()]);
      await file.writeAsString(
        '{"jobs":$first,"clearedAt":1,"jobs":$last,"clearedAt":9}',
      );
      final loaded = await store.loadWithTombstone();
      expect(loaded.jobs.single.id, 'last');
      expect(loaded.clearedAt, 9);
      await file.writeAsString(
        '{"jobs":${jsonEncode([for (var i = 0; i < 25; i++) job.toJson()])},"broken": [}',
      );
      expect(await store.load(), isEmpty);
      expect(await file.exists(), isFalse);
      expect(await dir.list().where((e) => e.path.contains('.bad-')).length, 1);
    },
  );
  test(
    'incomplete UTF-8 tail is backed up, not silently ignored after 20 jobs',
    () async {
      await file.writeAsBytes([
        ...utf8.encode(jsonEncode([for (var i = 0; i < 25; i++) job.toJson()])),
        0xe4,
        0xb8,
      ]);
      expect(await store.load(), isEmpty);
      expect(await file.exists(), isFalse);
    },
  );
}
