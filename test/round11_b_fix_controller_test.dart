import 'dart:async';
import 'dart:math';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // P2-#7 / P2-#8: frozen estimate behavior after sources are released.
  // -------------------------------------------------------------------------
  group('P2-#7/P2-#8 frozen estimate', () {
    test('P2-#7 selection change after release keeps the frozen estimate',
        () async {
      final repository = _Round11Repository();
      final controller = _round11Controller(repository);
      await controller.startInspection();
      final frozen = controller.debugStaticEstimateCache!;
      expect(frozen.estimatedSourceChars, greaterThan(0));

      await controller.startTranslation();
      final released = controller.state.inspectedChapters.single;
      expect(
        released.blocks.every((block) => block.sourceText.isEmpty),
        isTrue,
      );

      controller.toggleChapterInclusion('chapter.xhtml', false);
      final estimate = controller.state.runEstimate!;
      expect(estimate.estimatedSourceChars, frozen.estimatedSourceChars);
      expect(estimate.estimatedInputTokens, frozen.estimatedInputTokens);
      expect(estimate.estimatedApiBatches, frozen.estimatedApiBatches);
      expect(estimate.totalBlocks, frozen.totalBlocks);
      expect(
        identical(controller.debugStaticEstimateCache, frozen),
        isTrue,
      );
    });

    test('P2-#8 chunkSize restored to the anchor recovers batch count',
        () async {
      final repository = _Round11Repository();
      final controller = _round11Controller(repository);
      controller.syncSettings(
        controller.state.config.copyWith(chunkSize: 100),
      );
      await controller.startInspection();
      final frozen = controller.debugStaticEstimateCache!;
      final originalBatches = frozen.estimatedApiBatches;
      expect(originalBatches, greaterThan(0));

      final entered = Completer<void>();
      final resume = Completer<void>();
      repository.afterSourcesReleased = () async {
        entered.complete();
        await resume.future;
      };
      final translating = controller.startTranslation();
      await entered.future;
      try {
        controller.syncSettings(
          controller.state.config.copyWith(chunkSize: 60),
        );
        final scaled = controller.debugStaticEstimateCache!;
        // Existing chained P2-#9 scaling is unchanged for other sizes.
        expect(
          scaled.estimatedApiBatches,
          max(1, (originalBatches * 100 / 60).ceil()),
        );
        controller.syncSettings(
          controller.state.config.copyWith(chunkSize: 100),
        );
        final restored = controller.debugStaticEstimateCache!;
        expect(restored.estimatedApiBatches, originalBatches);
        expect(restored.estimatedSourceChars, frozen.estimatedSourceChars);
      } finally {
        resume.complete();
        await translating;
      }
    });
  });

}

// ---------------------------------------------------------------------------
// Minimal controller harness (mirrors b_area_controller_fixes_test.dart).
// ---------------------------------------------------------------------------

class _Round11Repository implements TranslationRepository {
  Future<void> Function()? afterSourcesReleased;

  TranslationJob _job(String inputPath, String outputPath) => TranslationJob(
    id: 'book',
    inputPath: inputPath,
    outputPath: outputPath,
    status: TranslationJobStatus.inspected,
    progress: 1,
    totalBlocks: 60,
  );

  InspectedChapter _chapter() => InspectedChapter(
    path: 'chapter.xhtml',
    title: 'Chapter',
    body: '',
    originalHtml: '<p>Source book text</p>',
    blocks: List<ExtractedBlock>.generate(
      60,
      (index) => ExtractedBlock(
        id: 'block-$index',
        tagName: 'p',
        sourceHtml: 'source $index',
        sourceText: 'source $index',
      ),
    ),
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async => InspectionResult(
    job: _job(inputPath, outputDirectory),
    chapters: <InspectedChapter>[_chapter()],
  );

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    void Function(String chapterPath)? onChapterSourcesReleased,
  }) async {
    // The real worker spools each finished chapter's sources to disk and
    // drops its own copies: it fires onChapterSourcesReleased per chapter
    // and returns the released chapters.
    final released = <InspectedChapter>[
      for (final chapter in chapters)
        chapter.copyWith(
          originalHtml: '',
          blocks: <ExtractedBlock>[
            for (final block in chapter.blocks)
              block.copyWith(sourceHtml: '', sourceText: ''),
          ],
        ),
    ];
    for (final chapter in chapters) {
      onChapterSourcesReleased?.call(chapter.path);
    }
    await afterSourcesReleased?.call();
    final job = _job(inputPath, '$outputDirectory/book.epub').copyWith(
      status: TranslationJobStatus.completed,
      phase: TranslationJobPhase.translation,
      completedBlocks: 60,
    );
    return TranslationRunResult(job: job, chapters: released);
  }

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async => TranslationStyleProfile.empty;
}

TranslationDashboardController _round11Controller(
  _Round11Repository repository,
) {
  final controller = TranslationDashboardController(repository: repository);
  addTearDown(controller.dispose);
  controller.syncSettings(
    TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
  );
  controller.setInputPath('/books/old.epub');
  controller.setOutputDirectory('/output');
  return controller;
}
