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
}
