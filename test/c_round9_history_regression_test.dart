import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late File file;
  late JobHistoryStore store;

  const TranslationJob sampleJob = TranslationJob(
    id: 'repaired-job',
    inputPath: 'book.epub',
    outputPath: 'book_translated.epub',
    status: TranslationJobStatus.completed,
    progress: 1,
  );
  const TranslationJob sampleJob2 = TranslationJob(
    id: 'stale-job',
    inputPath: 'other.epub',
    outputPath: 'other_translated.epub',
    status: TranslationJobStatus.completed,
    progress: 1,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('c_round9_history_');
    file = File('${temp.path}/job-history.json');
    store = JobHistoryStore(historyFileProvider: () async => file);
    await file.writeAsString('NOT-JSON{{{');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<List<FileSystemEntity>> backups() => temp
      .list()
      .where(
        (FileSystemEntity entity) =>
            entity is File &&
            // Compare by basename: on Windows, file.path may use '/'
            // (from '${temp.path}/job-history.json') while path.join
            // produces '\', breaking a full-path startsWith.
            p.basename(entity.path).startsWith('job-history.json.bad-'),
      )
      .toList();

  test('T1: concurrent repair and clear tombstone survive corrupt load', () async {
    final String repaired = jsonEncode(<String, Object?>{
      'version': 2,
      'clearedAt': 12345,
      'jobs': <Object?>[sampleJob.toJson()],
    });
    store.onBeforeCorruptBackupForTest = () async {
      await file.writeAsString(repaired);
    };

    expect(await store.load(), isEmpty);
    expect(await backups(), isEmpty);
    expect(await file.readAsString(), repaired);

    final loaded = await store.loadWithTombstone();
    expect(loaded.clearedAt, 12345);
    expect(loaded.jobs, hasLength(1));
    expect(loaded.jobs.single.id, sampleJob.id);
  });

  test('T2: unchanged corrupt history is still backed up', () async {
    expect(await store.load(), isEmpty);

    expect(await file.exists(), isFalse);
    final List<FileSystemEntity> corruptBackups = await backups();
    expect(corruptBackups, hasLength(1));
    expect(await (corruptBackups.single as File).readAsString(), 'NOT-JSON{{{');
  });

  test('T3: save fails closed when corrupt history is concurrently repaired', () async {
    final String repaired = jsonEncode(<String, Object?>{
      'version': 2,
      'clearedAt': 999,
      'jobs': <Object?>[],
    });
    store.onBeforeCorruptBackupForTest = () async {
      await file.writeAsString(repaired);
    };

    await expectLater(store.save(<TranslationJob>[sampleJob2]), throwsFormatException);

    expect(await backups(), isEmpty);
    expect(await file.readAsString(), repaired);
    final loaded = await store.loadWithTombstone();
    expect(loaded.clearedAt, 999);
    expect(loaded.jobs, isEmpty);
  });
}
