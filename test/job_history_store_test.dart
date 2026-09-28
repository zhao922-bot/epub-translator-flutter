import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saves and loads recent translation jobs', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'job_history_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final File historyFile = File('${temp.path}/job-history.json');
    final JobHistoryStore store = JobHistoryStore(
      historyFileProvider: () async => historyFile,
    );

    await store.save(const <TranslationJob>[
      TranslationJob(
        id: 'job-1',
        inputPath: 'C:\\Books\\book.epub',
        outputPath: 'C:\\Books\\book_translated.epub',
        status: TranslationJobStatus.completed,
        progress: 1,
        completedFiles: 2,
        totalFiles: 2,
        completedBlocks: 10,
        totalBlocks: 10,
      ),
    ]);

    final List<TranslationJob> loaded = await store.load();

    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'job-1');
    expect(loaded.single.status, TranslationJobStatus.completed);
    expect(loaded.single.outputPath, 'C:\\Books\\book_translated.epub');
    expect(loaded.single.completedBlocks, 10);
  });

  test('ignores malformed history files instead of crashing startup', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'job_history_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final File historyFile = File('${temp.path}/job-history.json');
    await historyFile.writeAsString('{not-json');
    final JobHistoryStore store = JobHistoryStore(
      historyFileProvider: () async => historyFile,
    );

    expect(await store.load(), isEmpty);
  });

  test('round-trips completed jobs with degraded-block warnings', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'job_history_warning_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final File historyFile = File('${temp.path}/job-history.json');
    final JobHistoryStore store = JobHistoryStore(
      historyFileProvider: () async => historyFile,
    );

    await store.save(const <TranslationJob>[
      TranslationJob(
        id: 'warning-job',
        inputPath: 'book.epub',
        outputPath: 'book_translated.epub',
        status: TranslationJobStatus.completedWithWarnings,
        phase: TranslationJobPhase.translation,
        progress: 1,
        completedBlocks: 5,
        totalBlocks: 5,
        degradedBlockCount: 2,
      ),
    ]);

    final List<TranslationJob> loaded = await store.load();

    expect(loaded.single.status, TranslationJobStatus.completedWithWarnings);
    expect(loaded.single.degradedBlockCount, 2);
  });

  group('clear tombstone', () {
    late Directory temp;
    late File historyFile;
    late JobHistoryStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('job_history_tombstone_');
      historyFile = File('${temp.path}/job-history.json');
      store = JobHistoryStore(historyFileProvider: () async => historyFile);
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    TranslationJob tombstoneJob(String id) => TranslationJob(
      id: id,
      inputPath: 'book.epub',
      outputPath: 'book_translated.epub',
      status: TranslationJobStatus.completed,
      progress: 1,
    );

    test('tombstone round-trips through save and load', () async {
      await store.save(<TranslationJob>[
        tombstoneJob('job-1'),
      ], clearedAtEpochMs: 123456789);

      final ({List<TranslationJob> jobs, int clearedAt}) loaded = await store
          .loadWithTombstone();

      expect(loaded.clearedAt, 123456789);
      expect(loaded.jobs, hasLength(1));
      expect(loaded.jobs.single.id, 'job-1');
      // load() keeps working and ignores the envelope.
      expect((await store.load()).single.id, 'job-1');
    });

    test('legacy bare-list files load with a zero tombstone', () async {
      await historyFile.writeAsString(
        jsonEncode(<Object?>[tombstoneJob('legacy-job').toJson()]),
      );

      final loaded = await store.loadWithTombstone();

      expect(loaded.clearedAt, 0);
      expect(loaded.jobs.single.id, 'legacy-job');
    });

    test('a clear writes an empty job list with a fresh tombstone', () async {
      await store.save(<TranslationJob>[
        tombstoneJob('job-1'),
      ], clearedAtEpochMs: 1000);
      final int clearedAt = DateTime.now().millisecondsSinceEpoch;
      await store.save(const <TranslationJob>[], clearedAtEpochMs: clearedAt);

      final loaded = await store.loadWithTombstone();

      expect(loaded.jobs, isEmpty);
      expect(loaded.clearedAt, clearedAt);
    });

    test('malformed files still degrade to an empty history', () async {
      await historyFile.writeAsString('{not-json');

      final loaded = await store.loadWithTombstone();

      expect(loaded.jobs, isEmpty);
      expect(loaded.clearedAt, 0);
    });
  });
}
