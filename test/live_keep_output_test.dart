import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/live_test_gate.dart';

/// Re-export a translated EPUB from warm block cache (no API cost).
/// Keeps the output file for manual inspection instead of deleting it.
///
/// Required env:
/// - LIVE_TRANSLATION_E2E=1
/// - LIVE_TRANSLATION_API_KEY (dummy ok when cache is warm; proxy still up)
/// - LIVE_TRANSLATION_EPUB_PATH
/// Optional: LIVE_TRANSLATION_API_BASE_URL, LIVE_TRANSLATION_MODEL
void main() {
  test(
    're-export translated EPUB from cache',
    () async {
      final String apiKey = Platform.environment['LIVE_TRANSLATION_API_KEY']!;
      final String epubPath = Platform.environment['LIVE_TRANSLATION_EPUB_PATH']!;
      final Directory outDir = Directory(
        '/home/hatch/workspace/book-test/live_run/output',
      );
      await outDir.create(recursive: true);

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl:
            Platform.environment['LIVE_TRANSLATION_API_BASE_URL'] ??
            'https://api.deepseek.com',
        apiKey: apiKey,
        model:
            Platform.environment['LIVE_TRANSLATION_MODEL'] ?? 'deepseek-chat',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
        residualQualityCheck: true,
        timeoutSeconds: 180,
        maxRetries: 2,
        chunkSize: 3000,
        maxConcurrent: 2,
        outputSuffix: '_live7step',
      );

      final EpubTranslationRepository repo = EpubTranslationRepository(
        cacheStore: TranslationCacheStore(),
      );

      final inspection = await repo.startJob(
        inputPath: epubPath,
        outputDirectory: outDir.path,
        config: config,
      );
      final List<InspectedChapter> selected = inspection.chapters
          .where((c) => c.includeInTranslation && c.blocks.isNotEmpty)
          .where((c) {
            final String path = c.path.toLowerCase();
            return !path.contains('ind_') &&
                !path.contains('toc_') &&
                !path.contains('ata_');
          })
          .toList(growable: false);
      expect(selected, isNotEmpty);

      final TranslationStyleProfile profile =
          await repo.generateStyleProfile(
            config: config,
            chapters: inspection.chapters,
          );
      expect(profile.isEmpty, isFalse);

      final TranslationRunResult result = await repo.translateChapters(
        inputPath: epubPath,
        outputDirectory: outDir.path,
        config: config,
        chapters: selected,
        confirmedStyleProfile: profile,
      );
      expect(result.job.status, TranslationJobStatus.completed);
      expect(result.job.completedBlocks, result.job.totalBlocks);

      final File produced = File(result.job.outputPath);
      expect(produced.existsSync(), isTrue);
      final File kept = File(p.join(outDir.path, 'yellow-wallpaper-live7step.epub'));
      await produced.copy(kept.path);
      // ignore: avoid_print
      print('KEPT_OUTPUT=${kept.path} bytes=${await kept.length()} '
          'cached=${result.job.cachedBlocks}/${result.job.totalBlocks}');
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: liveTestSkipReason(),
  );
}
