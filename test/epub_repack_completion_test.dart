import 'dart:io';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _CommittedRepacker extends EpubRepacker {
  _CommittedRepacker(this.onCommitted);

  final void Function() onCommitted;

  @override
  Future<void> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const <String>{},
    String? translatedTitle,
  }) async {
    await File(outputFilePath).writeAsString('committed');
    onCommitted();
  }
}

class _TerminalSaveFailureCacheStore extends TranslationCacheStore {
  @override
  Future<String?> getBlockTranslation(String cacheKey) async =>
      '<p>translated from cache</p>';

  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => null;

  @override
  Future<void> saveJobState(JobResumeState state) async {
    if (state.status == TranslationJobStatus.completed.name) {
      throw const FileSystemException('Checkpoint write failed');
    }
  }
}

void main() {
  test('zero-block translation stays completed after output commit', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'epub_repack_completion_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    bool cancelled = false;
    final EpubChapterTranslator translator = EpubChapterTranslator(
      repacker: _CommittedRepacker(() => cancelled = true),
    );

    final result = await translator.translateChapters(
      inputPath: '${tempDir.path}/book.epub',
      outputDirectory: tempDir.path,
      config: TranslationConfig.defaults(),
      chapters: const <InspectedChapter>[
        InspectedChapter(
          path: 'empty.xhtml',
          title: 'Empty',
          body: '',
          originalHtml: '<html><body></body></html>',
          blocks: <ExtractedBlock>[],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
      ],
      cancelToken: CancelToken(),
      isCancelled: () => cancelled,
    );

    expect(result.job.status, TranslationJobStatus.completed);
    expect(await File(result.job.outputPath).readAsString(), 'committed');
  });

  test(
    'committed EPUB remains completed when final checkpoint save fails',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'epub_repack_checkpoint_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File input = File('${tempDir.path}/book.epub');
      await input.writeAsString('source');
      bool cancelled = false;
      final EpubChapterTranslator translator = EpubChapterTranslator(
        cacheStore: _TerminalSaveFailureCacheStore(),
        repacker: _CommittedRepacker(() => cancelled = true),
      );

      final result = await translator.translateChapters(
        inputPath: input.path,
        outputDirectory: tempDir.path,
        config: TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://example.invalid/v1',
          apiKey: 'test-key',
          model: 'test-model',
          styleProfileEnabled: false,
        ),
        chapters: const <InspectedChapter>[
          InspectedChapter(
            path: 'chapter.xhtml',
            title: 'Chapter',
            body: 'source',
            originalHtml: '<html><body><p>source</p></body></html>',
            blocks: <ExtractedBlock>[
              ExtractedBlock(
                id: 'block-1',
                tagName: 'p',
                sourceHtml: '<p>source</p>',
                sourceText: 'source',
              ),
            ],
            category: ChapterCategory.content,
            recommendedForTranslation: true,
            includeInTranslation: true,
          ),
        ],
        cancelToken: CancelToken(),
        isCancelled: () => cancelled,
      );

      expect(result.job.status, TranslationJobStatus.completed);
      expect(await File(result.job.outputPath).readAsString(), 'committed');
    },
  );
}
