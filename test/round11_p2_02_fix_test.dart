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

InspectedChapter _chapter(String title) => InspectedChapter(
  path: 'chapter.xhtml',
  title: title,
  body: 'Source book text',
  originalHtml: '<p>Source book text</p>',
  blocks: const [
    ExtractedBlock(
      id: 'block-0',
      tagName: 'p',
      sourceHtml: 'Source book text',
      sourceText: 'Source book text',
    ),
  ],
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: true,
);

class _HeldRepository implements TranslationRepository {
  final result = Completer<TranslationRunResult>();
  final started = Completer<void>();
  TranslationProgressCallback? progressCallback;
  late TranslationJob runningJob;

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async => InspectionResult(
    job: TranslationJob(
      id: 'inspection-$inputPath',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      phase: TranslationJobPhase.inspection,
      progress: 1,
      totalBlocks: 1,
    ),
    chapters: [_chapter('Chapter of ${inputPath.split('/').last}')],
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
  }) {
    runningJob = TranslationJob(
      id: 'translation-$inputPath',
      inputPath: inputPath,
      outputPath: '$outputDirectory/translated.epub',
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.translation,
      progress: 0.5,
      totalBlocks: 1,
    );
    progressCallback = onProgress;
    onProgress?.call(runningJob, 'translation running');
    started.complete();
    return result.future;
  }

  TranslationRunResult terminalResult() => TranslationRunResult(
    job: runningJob.copyWith(
      status: TranslationJobStatus.completed,
      progress: 1,
      completedBlocks: 1,
    ),
    chapters: [
      _chapter('Translated chapter of ${runningJob.inputPath.split('/').last}'),
    ],
  );

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bookA = '/books/bookA.epub';
  const bookB = '/books/bookB.epub';
  late _HeldRepository repository;
  late TranslationDashboardController controller;
  late Completer<String?> pickerResult;
  late Completer<void> pickerOpened;
  Future<bool>? runA;

  setUp(() async {
    repository = _HeldRepository();
    pickerResult = Completer<String?>();
    pickerOpened = Completer<void>();
    runA = null;
    controller = TranslationDashboardController(
      repository: repository,
      epubPickerOverride: ({onWindowsNotice}) {
        pickerOpened.complete();
        return pickerResult.future;
      },
    );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath(bookA);
    controller.setOutputDirectory('/output');
    await controller.startInspection();
  });

  Future<void> startHeldRun({bool publishTerminal = true}) async {
    runA = controller.startTranslation();
    await repository.started.future;
    expect(controller.state.isRunActive, isTrue);
    if (publishTerminal) {
      // Export is complete; the future still waits for checkpoint persistence.
      repository.progressCallback!(
        repository.terminalResult().job,
        'exported; checkpoint persistence pending',
      );
      expect(controller.state.isRunActive, isFalse);
    }
  }

  tearDown(() async {
    if (repository.started.isCompleted && !repository.result.isCompleted) {
      repository.result.complete(repository.terminalResult());
    }
    if (runA != null) {
      await runA;
    }
    if (!pickerResult.isCompleted) {
      pickerResult.complete(null);
    }
    controller.dispose();
  });

  test(
    'P2-02 late terminal result preserves the new book inspection',
    () async {
      await startHeldRun();
      controller.setInputPath(bookB);
      await controller.startInspection();

      final before = controller.state;
      expect(before.inputPath, bookB);
      expect(before.job!.inputPath, bookB);
      expect(before.job!.phase, TranslationJobPhase.inspection);
      expect(before.inspectedChapters.single.title, 'Chapter of bookB.epub');

      repository.result.complete(repository.terminalResult());
      expect(await runA!, isTrue);

      expect(controller.state.inputPath, bookB);
      expect(controller.state.job!.inputPath, bookB);
      expect(controller.state.job!.phase, TranslationJobPhase.inspection);
      expect(controller.state.job, same(before.job));
      expect(
        controller.state.inspectedChapters,
        same(before.inspectedChapters),
      );
      expect(
        controller.state.inspectedChapters.single.title,
        'Chapter of bookB.epub',
      );
    },
  );

  test('P2-02 late terminal result preserves same-book reinspection', () async {
    await startHeldRun();
    await controller.startInspection();
    final before = controller.state;
    expect(before.job!.phase, TranslationJobPhase.inspection);

    repository.result.complete(repository.terminalResult());
    expect(await runA!, isTrue);

    expect(controller.state.inputPath, bookA);
    expect(controller.state.job!.inputPath, bookA);
    expect(controller.state.job!.phase, TranslationJobPhase.inspection);
    expect(controller.state.job, same(before.job));
    expect(controller.state.inspectedChapters, same(before.inspectedChapters));
    expect(
      controller.state.inspectedChapters.single.title,
      'Chapter of bookA.epub',
    );
  });

  test('P2-02 late progress preserves the new book inspection job', () async {
    await startHeldRun();
    controller.setInputPath(bookB);
    await controller.startInspection();
    final before = controller.state;

    repository.progressCallback!(
      repository.runningJob,
      'stale running progress',
    );

    expect(controller.state.job, same(before.job));
    expect(controller.state.job!.inputPath, bookB);
    expect(controller.state.job!.phase, TranslationJobPhase.inspection);
    expect(controller.state.inspectedChapters, same(before.inspectedChapters));
    expect(controller.state.logs, before.logs);
    expect(controller.state.isRunActive, isFalse);
  });

  test('P2-02 accepted EPUB import invalidates the finishing run', () async {
    await startHeldRun();
    expect(await controller.importDroppedEpubPath(bookB), isTrue);
    final before = controller.state;
    expect(before.inputPath, bookB);
    expect(before.job, isNull);

    repository.result.complete(repository.terminalResult());
    expect(await runA!, isTrue);

    expect(controller.state, same(before));
    expect(controller.state.inspectedChapters, isEmpty);
  });

  test(
    'P2-02 rejected path and inspection changes keep the run valid',
    () async {
      // The picker opened before the run; its result reaches _acceptInputPath
      // after the run starts, so the revision bumps but its final guard rejects.
      final picking = controller.pickInputPath();
      await pickerOpened.future;
      await startHeldRun(publishTerminal: false);
      controller.setInputPath(bookB);
      await controller.startInspection();
      pickerResult.complete(bookB);
      await picking;
      expect(controller.state.inputPath, bookA);

      repository.progressCallback!(
        repository.runningJob.copyWith(progress: 0.75),
        'current run progress',
      );
      expect(controller.state.job!.progress, 0.75);
      expect(controller.state.isRunActive, isTrue);

      final terminal = repository.terminalResult();
      repository.result.complete(terminal);
      expect(await runA!, isTrue);
      expect(controller.state.job!.status, TranslationJobStatus.completed);
      expect(controller.state.inspectedChapters, terminal.chapters);
    },
  );
}
