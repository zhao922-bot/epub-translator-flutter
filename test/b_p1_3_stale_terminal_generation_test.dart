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
  final inspectionChapters = [_chapter('Inspected chapter')];
  final results = List.generate(2, (_) => Completer<TranslationRunResult>());
  final started = List.generate(2, (_) => Completer<void>());
  final List<TranslationProgressCallback?> progressCallbacks = [];
  final List<TranslationJob> jobs = [];

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async => InspectionResult(
    job: TranslationJob(
      id: 'inspection',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      progress: 1,
      totalBlocks: 1,
    ),
    chapters: inspectionChapters,
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
    final index = jobs.length;
    final job = TranslationJob(
      id: 'repository-run-$index',
      inputPath: inputPath,
      outputPath: '$outputDirectory/run-$index.epub',
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.translation,
      progress: 0.5,
      totalBlocks: 1,
    );
    jobs.add(job);
    progressCallbacks.add(onProgress);
    onProgress?.call(job, 'run $index running');
    started[index].complete();
    return results[index].future;
  }

  TranslationRunResult terminalResult(int index) => TranslationRunResult(
    job: jobs[index].copyWith(
      status: TranslationJobStatus.completed,
      progress: 1,
      completedBlocks: 1,
    ),
    chapters: [_chapter('Terminal chapter from run $index')],
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

  late _HeldRepository repository;
  late TranslationDashboardController controller;
  late Future<bool> runA;
  late Future<bool> runB;

  setUp(() async {
    repository = _HeldRepository();
    controller = TranslationDashboardController(repository: repository);
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('/books/book.epub');
    controller.setOutputDirectory('/output');
    await controller.startInspection();

    runA = controller.startTranslation();
    await repository.started[0].future;
    // A has exported its output but its future is still held at persistence.
    // Terminal progress makes B eligible to start through the public API.
    repository.progressCallbacks[0]?.call(
      repository.terminalResult(0).job,
      'run A exported; checkpoint persistence pending',
    );
    expect(controller.state.isRunActive, isFalse);
    runB = controller.startTranslation();
    await repository.started[1].future;
    expect(controller.state.isRunActive, isTrue);
  });

  tearDown(() async {
    for (var index = 0; index < repository.results.length; index++) {
      if (!repository.results[index].isCompleted) {
        repository.results[index].complete(repository.terminalResult(index));
      }
    }
    await Future.wait([runA, runB]);
    controller.dispose();
  });

  test('B-P1-3 stale terminal result leaves the newer run untouched', () async {
    final before = controller.state;
    final staleResult = repository.terminalResult(0);
    expect(staleResult.job.outputPath, isNot(before.job!.outputPath));
    expect(
      staleResult.chapters.first.title,
      isNot(before.inspectedChapters.first.title),
    );

    repository.results[0].complete(staleResult);
    expect(await runA, isTrue);

    expect(controller.state.job!.id, before.job!.id);
    expect(controller.state.job, same(before.job));
    expect(controller.state.inspectedChapters, before.inspectedChapters);
    expect(controller.state.jobHistory.length, before.jobHistory.length);
    expect(controller.state.jobHistory, before.jobHistory);
    expect(controller.state.isRunActive, isTrue);
  });

  test('B-P1-3 stale failure leaves the newer run active', () async {
    final before = controller.state;
    repository.results[0].completeError(StateError('run A stale failure'));
    expect(await runA, isTrue);

    expect(controller.state.job!.id, before.job!.id);
    expect(controller.state.job, same(before.job));
    expect(controller.state.job!.status, TranslationJobStatus.running);
    expect(controller.state.job!.errorMessage, isNull);
    expect(controller.state.inspectedChapters, before.inspectedChapters);
    expect(controller.state.jobHistory, before.jobHistory);
    expect(controller.state.actionableError, before.actionableError);
    expect(controller.state.logs, before.logs);
    expect(controller.state.isRunActive, isTrue);
  });

  test('B-P1-3 newer run completes cleanly after stale terminal return', () async {
    final newerJob = controller.state.job!;
    final historyLength = controller.state.jobHistory.length;
    repository.results[0].complete(repository.terminalResult(0));
    expect(await runA, isTrue);
    expect(controller.state.job, same(newerJob));

    final resultB = repository.terminalResult(1);
    repository.results[1].complete(resultB);
    expect(await runB, isTrue);

    // The controller retains its history identity, not the repository job id.
    expect(controller.state.job!.id, newerJob.id);
    expect(controller.state.job!.runStartedAt, newerJob.runStartedAt);
    expect(
      controller.state.job!.recordRevision,
      greaterThan(newerJob.recordRevision),
    );
    expect(controller.state.job!.status, TranslationJobStatus.completed);
    expect(controller.state.job!.outputPath, resultB.job.outputPath);
    expect(controller.state.inspectedChapters, resultB.chapters);
    expect(controller.state.jobHistory.length, historyLength);
    expect(controller.state.jobHistory.first, same(controller.state.job));
    expect(controller.state.isRunActive, isFalse);
    expect(controller.state.actionableError, isNull);
  });
}
