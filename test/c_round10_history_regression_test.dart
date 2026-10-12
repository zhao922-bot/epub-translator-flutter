import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final List<int> invalidUtf8 = <int>[
    0xff,
    0xfe,
    ...utf8.encode('{"version":2,"jobs":['),
  ];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('c_round10_history_');
    file = File('${temp.path}/job-history.json');
    store = JobHistoryStore(historyFileProvider: () async => file);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<List<File>> backups() => temp
      .list()
      .where(
        (FileSystemEntity entity) =>
            entity is File && entity.path.startsWith('${file.path}.bad-'),
      )
      .cast<File>()
      .toList();

  test('P1-#2: repair after precheck is restored to the active path', () async {
    await file.writeAsString('NOT-JSON{{{');
    final String repaired = jsonEncode(<String, Object?>{
      'version': 2,
      'clearedAt': 12345,
      'jobs': <Object?>[sampleJob.toJson()],
    });
    bool renameHookCalled = false;
    store.onBeforeCorruptRenameForTest = () async {
      renameHookCalled = true;
      await file.writeAsString(repaired);
    };

    expect((await store.loadWithTombstone()).jobs, isEmpty);

    expect(renameHookCalled, isTrue);
    // The repaired file was moved aside, then detected as non-corrupt and
    // restored to the active path (no new active file was created meanwhile).
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), repaired);
    final loaded = await store.loadWithTombstone();
    expect(loaded.clearedAt, 12345);
    expect(loaded.jobs.single.id, sampleJob.id);
  });

  test(
    'P2-#7: invalid UTF-8 loads empty and preserves original bytes',
    () async {
      await file.writeAsBytes(invalidUtf8);

      final loaded = await store.loadWithTombstone();

      expect(loaded.jobs, isEmpty);
      expect(loaded.clearedAt, 0);
      expect(await file.exists(), isFalse);
      final List<File> corruptBackups = await backups();
      expect(corruptBackups, hasLength(1));
      expect(await corruptBackups.single.readAsBytes(), invalidUtf8);
    },
  );

  test('P2-#7: save backs up invalid UTF-8 before writing history', () async {
    await file.writeAsBytes(invalidUtf8);

    await store.save(<TranslationJob>[sampleJob]);

    final List<File> corruptBackups = await backups();
    expect(corruptBackups, hasLength(1));
    expect(await corruptBackups.single.readAsBytes(), invalidUtf8);
    expect((await store.load()).single.id, sampleJob.id);
  });

  test(
    'P2-#7: save fails closed if invalid UTF-8 is concurrently repaired',
    () async {
      await file.writeAsBytes(invalidUtf8);
      final String repaired = jsonEncode(<String, Object?>{
        'version': 2,
        'clearedAt': 999,
        'jobs': <Object?>[],
      });
      store.onBeforeCorruptBackupForTest = () async {
        await file.writeAsString(repaired);
      };

      await expectLater(
        store.save(<TranslationJob>[sampleJob]),
        throwsFormatException,
      );

      expect(await backups(), isEmpty);
      expect(await file.readAsString(), repaired);
    },
  );

  test('performance-#19: 5000 jobs return the first 20 in order', () async {
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 2,
        'jobs': List<Map<String, dynamic>>.generate(
          5000,
          (int index) => sampleJob.copyWith(id: 'job-$index').toJson(),
        ),
      }),
    );

    final List<TranslationJob> loaded = await store.load();

    expect(loaded, hasLength(20));
    expect(
      loaded.map((TranslationJob job) => job.id),
      List<String>.generate(20, (int index) => 'job-$index'),
    );
    expect(() => loaded.add(sampleJob), throwsUnsupportedError);
  });

  test(
    'performance-#19: skipped entries do not count toward the limit',
    () async {
      await file.writeAsString(
        jsonEncode(<Object?>[
          null,
          'not a job',
          <String, Object?>{'id': ''},
          for (int index = 0; index < 25; index++)
            sampleJob.copyWith(id: 'job-$index').toJson(),
        ]),
      );

      final List<TranslationJob> loaded = await store.load();

      expect(loaded, hasLength(20));
      expect(
        loaded.map((TranslationJob job) => job.id),
        List<String>.generate(20, (int index) => 'job-$index'),
      );
    },
  );
}
