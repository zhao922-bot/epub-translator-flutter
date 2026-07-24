import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bool liveEnabled = Platform.environment['LIVE_TRANSLATION_E2E'] == '1';

  test(
    'confirmed style profile invalidates block and resume caches',
    () async {
      final String apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final String epubPath =
          Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'live_style_cache_invalidation_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl:
            Platform.environment['LIVE_TRANSLATION_API_BASE_URL'] ??
            'https://api.deepseek.com',
        apiKey: apiKey,
        model:
            Platform.environment['LIVE_TRANSLATION_MODEL'] ?? 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        outputSuffix: '_style_cache_test',
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
      );
      final List<InspectedChapter> candidates =
          inspection.chapters
              .where(
                (InspectedChapter chapter) =>
                    chapter.category == ChapterCategory.content &&
                    chapter.blocks.isNotEmpty,
              )
              .toList(growable: false)
            ..sort(
              (InspectedChapter left, InspectedChapter right) =>
                  left.blocks.length.compareTo(right.blocks.length),
            );
      expect(candidates, isNotEmpty);
      final InspectedChapter selected = candidates.first.copyWith(
        includeInTranslation: true,
      );
      final List<InspectedChapter> chapters = <InspectedChapter>[selected];
      final int totalBlocks = selected.blocks.length;

      const TranslationStyleProfile business = TranslationStyleProfile(
        primaryGenre: 'business nonfiction',
        tone: 'analytical and direct',
        confidence: TranslationStyleConfidence.high,
      );
      const TranslationStyleProfile literary = TranslationStyleProfile(
        primaryGenre: 'literary fiction',
        tone: 'lyrical and reflective',
        confidence: TranslationStyleConfidence.high,
      );

      final first = await repository.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: chapters,
        confirmedStyleProfile: business,
      );
      expect(first.job.completedBlocks, totalBlocks);
      expect(first.job.cachedBlocks, 0);

      final second = await repository.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: chapters,
        confirmedStyleProfile: business,
      );
      expect(second.job.completedBlocks, totalBlocks);
      expect(second.job.cachedBlocks, totalBlocks);
      expect(second.job.resumedBlocks, totalBlocks);

      final third = await repository.translateChapters(
        inputPath: epubPath,
        outputDirectory: tempDir.path,
        config: config,
        chapters: chapters,
        confirmedStyleProfile: literary,
      );
      expect(third.job.completedBlocks, totalBlocks);
      expect(third.job.cachedBlocks, 0);
      expect(third.job.resumedBlocks, 0);

      // ignore: avoid_print
      print(
        'style_cache_invalidation: blocks=$totalBlocks '
        'firstCached=${first.job.cachedBlocks} '
        'sameStyleCached=${second.job.cachedBlocks} '
        'changedStyleCached=${third.job.cachedBlocks}',
      );
    },
    skip: liveEnabled
        ? false
        : 'Set LIVE_TRANSLATION_E2E=1 plus API key and EPUB path.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
