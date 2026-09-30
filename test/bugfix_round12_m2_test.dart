import 'dart:async';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake repository whose style-profile generation mirrors the real one: it
/// blocks on [styleRelease], then returns *normally* (no exception) when the
/// controller's `isCancelled` reports a cancel. That quiet return is exactly
/// what used to let a cancel during the style phase slip through
/// startInspection and into an unwanted startTranslation in _retryJob.
class _StyleCancelAwareRepository implements TranslationRepository {
  final Completer<void> styleStarted = Completer<void>();
  final Completer<TranslationStyleProfile> styleRelease =
      Completer<TranslationStyleProfile>();

  int translateChaptersCalls = 0;

  static final List<InspectedChapter> chapters = <InspectedChapter>[
    InspectedChapter(
      path: 'ch1.xhtml',
      title: 'Chapter 1',
      body: 'Hello world',
      originalHtml: '<p>Hello world</p>',
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

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return InspectionResult(
      job: const TranslationJob(
        id: 'inspect-1',
        inputPath: 'book.epub',
        outputPath: 'out',
        status: TranslationJobStatus.inspected,
        phase: TranslationJobPhase.inspection,
        progress: 1,
      ),
      chapters: chapters,
    );
  }

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    if (!styleStarted.isCompleted) {
      styleStarted.complete();
    }
    final TranslationStyleProfile profile = await styleRelease.future;
    if (isCancelled?.call() == true) {
      // Real implementation returns normally here instead of throwing.
      return TranslationStyleProfile.empty;
    }
    return profile;
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
  }) async {
    translateChaptersCalls += 1;
    return TranslationRunResult(
      job: const TranslationJob(
        id: 'run-1',
        inputPath: 'book.epub',
        outputPath: 'out',
        status: TranslationJobStatus.completed,
        phase: TranslationJobPhase.translation,
        progress: 1,
      ),
      chapters: chapters,
    );
  }

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<String> testConnection({required TranslationConfig config}) =>
      throw StateError('Unexpected repository call: testConnection');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call: ${invocation.memberName}');
}

class _TestController extends TranslationDashboardController {
  _TestController(_StyleCancelAwareRepository repository)
    : super(
        repository: repository,
        settingsReady: () async {},
        defaultOutputDirectoryResolver: (_) async => 'out',
      ) {
    state = TranslationDashboardState.initial().copyWith(
      inputPath: 'book.epub',
      outputDirectory: 'out',
      config: TranslationConfig.defaults().copyWith(styleProfileEnabled: true),
      // A failed translation run awaiting retry: a non-empty chapter
      // selection means the retry regenerates the style profile (the phase
      // where M2 lives), and no confirmed profile is preserved.
      jobHistory: const <TranslationJob>[
        TranslationJob(
          id: 'failed-1',
          inputPath: 'book.epub',
          outputPath: 'out',
          status: TranslationJobStatus.failed,
          phase: TranslationJobPhase.translation,
          progress: 0.35,
          selectedChapterPaths: <String>['ch1.xhtml'],
        ),
      ],
    );
  }
}

Future<void> _waitForStyleGeneration(_TestController controller) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!controller.state.isGeneratingStyleProfile) {
    if (DateTime.now().isAfter(deadline)) {
      fail('style generation never started');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('bugfix round12 M2: cancel during style-profile generation', () {
    test(
      'retry cancelled during the style phase never starts translation',
      () async {
        final _StyleCancelAwareRepository repository =
            _StyleCancelAwareRepository();
        final _TestController controller = _TestController(repository);

        final Future<void> retry = controller.retryJob('failed-1');
        await _waitForStyleGeneration(controller);
        await controller.requestCancel();
        // The profile coroutine observes the cancel and returns normally
        // (no exception) — the pre-fix code then marched into
        // startTranslation and burned API tokens on a run the user cancelled.
        repository.styleRelease.complete(TranslationStyleProfile.empty);
        await retry;

        expect(
          repository.translateChaptersCalls,
          0,
          reason:
              'a cancel during the retry style phase must not start a new '
              'translation run',
        );
        expect(
          controller.state.job?.status,
          TranslationJobStatus.cancelled,
          reason: 'the cancelled retry must wind down as cancelled',
        );
        expect(
          controller.state.isGeneratingStyleProfile,
          isFalse,
          reason: 'the style spinner must be cleared',
        );
      },
    );

    test('retry without cancel still translates normally', () async {
      final _StyleCancelAwareRepository repository =
          _StyleCancelAwareRepository();
      final _TestController controller = _TestController(repository);

      final Future<void> retry = controller.retryJob('failed-1');
      await _waitForStyleGeneration(controller);
      repository.styleRelease.complete(TranslationStyleProfile.empty);
      await retry;

      // Control: the recheck must not disturb the happy path.
      expect(repository.translateChaptersCalls, 1);
      expect(
        controller.state.job?.status,
        TranslationJobStatus.completed,
        reason: 'uncancelled retry must still translate',
      );
      expect(controller.state.isGeneratingStyleProfile, isFalse);
    });

    test('inspection without cancel still completes normally', () async {
      final _StyleCancelAwareRepository repository =
          _StyleCancelAwareRepository();
      final _TestController controller = _TestController(repository);

      final Future<void> inspection = controller.startInspection(
        generateStyle: true,
      );
      await _waitForStyleGeneration(controller);
      repository.styleRelease.complete(TranslationStyleProfile.empty);
      await inspection;

      expect(
        controller.state.job?.status,
        TranslationJobStatus.inspected,
        reason: 'uncancelled inspection must still finish',
      );
      expect(controller.state.isGeneratingStyleProfile, isFalse);
    });

    test('cancel during inspection-time style generation leaves the '
        'inspected job untouched', () async {
      final _StyleCancelAwareRepository repository =
          _StyleCancelAwareRepository();
      final _TestController controller = _TestController(repository);

      final Future<void> inspection = controller.startInspection(
        generateStyle: true,
      );
      await _waitForStyleGeneration(controller);
      await controller.requestCancel();
      repository.styleRelease.complete(TranslationStyleProfile.empty);
      await inspection;

      // Mirrors the pre-existing contract (see
      // translation_dashboard_controller_test.dart): the profile coroutine
      // handles the cancel itself, so startInspection must not re-mark the
      // finished job — only _retryJob winds the retry down.
      expect(
        controller.state.job?.status,
        TranslationJobStatus.inspected,
        reason:
            'cancelling style generation during a plain inspection must '
            'leave the inspected job alone',
      );
      expect(controller.state.isGeneratingStyleProfile, isFalse);
    });
  });

  // Note on the two display-level fixes in the same round:
  // - The resume-hint sites now use `_confirmedProgressBlocks(job)`
  //   (phase-aware: cachedBlocks during cacheRestoration), the same helper
  //   `_handleCancellation` already used for its resume-hint log line. It is
  //   a private top-level function, so it cannot be imported here; the
  //   convention is covered indirectly by the cancellation path above and by
  //   the translator's cache-restoration tests, which verify that the real
  //   resume position always comes from the cache scan, never the hint.
  // - The mounted guards in exportTranslatedEpub/openJobOutput mirror
  //   saveTranslatedEpubToDownloads and only change behavior after the
  //   provider is disposed; that path is not reachable in a unit test.
}
