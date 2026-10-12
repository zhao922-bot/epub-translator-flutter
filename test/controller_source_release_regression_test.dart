import 'dart:io';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake repository that fires [onChapterSourcesReleased] mid-translation,
/// mirroring the worker spooling a finished chapter's sources to disk.
/// The terminal [TranslationRunResult] mirrors the real translator:
/// `originalHtml`+`body` restored for repack/preview, block sources stay
/// released on disk.
class _ReleasingRepository implements TranslationRepository {
  void Function(String chapterPath)? capturedRelease;

  /// Set by the test after the controller exists; read synchronously right
  /// after the release callback fires to observe the mid-run state.
  TranslationDashboardState Function()? readState;

  /// Controller's chapter copy observed right after the release callback ran.
  InspectedChapter? chapterAtReleaseTime;

  static List<InspectedChapter> chapters() => <InspectedChapter>[
    InspectedChapter(
      path: 'chapter.xhtml',
      title: 'Chapter',
      body: 'preview excerpt',
      originalHtml: '<html><body><p>Hello world</p></body></html>',
      blocks: const <ExtractedBlock>[
        ExtractedBlock(
          id: 'b1',
          tagName: 'p',
          sourceHtml: '<p>Hello world</p>',
          sourceText: 'Hello world',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    ),
  ];

  TranslationJob _inspectedJob(String inputPath, String outputDirectory) =>
      TranslationJob(
        id: 'job-1',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.inspected,
        progress: 1,
        completedFiles: 1,
        totalFiles: 1,
        completedBlocks: 1,
        totalBlocks: 1,
      );

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final TranslationJob job = _inspectedJob(inputPath, outputDirectory);
    onProgress?.call(job, 'Inspection complete.');
    return InspectionResult(job: job, chapters: chapters());
  }

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
    capturedRelease = onChapterSourcesReleased;
    // Simulate the worker spooling the finished chapter's sources mid-run.
    // The callback is synchronous, so the controller state observed right
    // after reflects the mid-run clearing.
    onChapterSourcesReleased?.call('chapter.xhtml');
    chapterAtReleaseTime = readState!().inspectedChapters.singleWhere(
      (InspectedChapter c) => c.path == 'chapter.xhtml',
    );
    final TranslationJob job = TranslationJob(
      id: 'run-1',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.completed,
      phase: TranslationJobPhase.translation,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: 1,
      totalBlocks: 1,
    );
    onProgress?.call(job, 'Translation complete.');
    // Mirror the real translator's terminal chapters: originalHtml+body
    // restored for repack/preview, block sources stay released on disk.
    return TranslationRunResult(
      job: job,
      chapters: <InspectedChapter>[
        for (final InspectedChapter c in chapters)
          c.copyWith(
            blocks: <ExtractedBlock>[
              for (final ExtractedBlock b in c.blocks)
                b.copyWith(sourceHtml: '', sourceText: ''),
            ],
          ),
      ],
    );
  }

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async => TranslationStyleProfile.empty;

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<void> cancelJob(String jobId) async {}
}

void main() {
  test(
    '#42 UI drops spooled chapter sources but keeps the preview excerpt',
    () async {
      final temp = await Directory.systemTemp.createTemp('source_release_');
      addTearDown(() => temp.delete(recursive: true));
      final repository = _ReleasingRepository();
      final controller = TranslationDashboardController(
        repository: repository,
      );
      addTearDown(controller.debugDispose);
      repository.readState = () => controller.state;
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath('${temp.path}/book.epub');
      await controller.startInspection();
      await controller.startTranslation();

      expect(
        repository.capturedRelease,
        isNotNull,
        reason: 'controller must pass onChapterSourcesReleased to the repo',
      );
      final InspectedChapter released = repository.chapterAtReleaseTime!;
      expect(
        released.originalHtml,
        isEmpty,
        reason: 'spooled originalHtml must be dropped from UI state mid-run',
      );
      expect(
        released.blocks.single.sourceHtml,
        isEmpty,
        reason: 'spooled block sourceHtml must be dropped from UI state',
      );
      expect(
        released.blocks.single.sourceText,
        isEmpty,
        reason: 'spooled block sourceText must be dropped from UI state',
      );
      expect(
        released.body,
        'preview excerpt',
        reason:
            'the <=6K preview excerpt stays: preview has no recovery path '
            'for finished chapters',
      );
      // Terminal state mirrors the real translator: repack restores
      // originalHtml+body, block sources stay released.
      final InspectedChapter terminal = controller.state.inspectedChapters
          .singleWhere((c) => c.path == 'chapter.xhtml');
      expect(terminal.originalHtml, isNotEmpty);
      expect(terminal.body, 'preview excerpt');
      expect(terminal.blocks.single.sourceHtml, isEmpty);
    },
  );

  test(
    '#42 release callback for an unknown path leaves state untouched',
    () async {
      final temp = await Directory.systemTemp.createTemp('source_release_');
      addTearDown(() => temp.delete(recursive: true));
      final repository = _ReleasingRepository();
      final controller = TranslationDashboardController(
        repository: repository,
      );
      addTearDown(controller.debugDispose);
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath('${temp.path}/book.epub');
      await controller.startInspection();
      await controller.startTranslation();
      final int before = controller.state.inspectedChapters.length;
      final String bodyBefore = controller.state.inspectedChapters.single.body;

      // Fire the captured callback with a path the controller never saw.
      repository.capturedRelease!('no-such-chapter.xhtml');

      expect(
        controller.state.inspectedChapters,
        hasLength(before),
        reason: 'unknown release paths must not mutate inspected chapters',
      );
      expect(
        controller.state.inspectedChapters.single.body,
        bodyBefore,
        reason: 'unknown release paths must not touch existing chapters',
      );
    },
  );
}
