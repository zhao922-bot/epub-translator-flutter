import 'dart:async';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

// Drive the public inspection/translation flow, as in the existing controller
// harness, rather than mutating StateNotifier.state or duplicating catch logic.
class _Repository implements TranslationRepository {
  _Repository({
    this.phase = TranslationJobPhase.cacheRestoration,
    this.cachedBlocks = 10,
    this.terminalStatus,
  });

  final TranslationJobPhase phase;
  final int cachedBlocks;
  final TranslationJobStatus? terminalStatus;

  TranslationJob _job(String inputPath, String outputPath) => TranslationJob(
    id: 'book',
    inputPath: inputPath,
    outputPath: outputPath,
    status: TranslationJobStatus.inspected,
    progress: 1,
    totalBlocks: 60,
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
    chapters: <InspectedChapter>[
      InspectedChapter(
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
      ),
    ],
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
    final job = _job(inputPath, '$outputDirectory/book_translated.epub')
        .copyWith(
          status: TranslationJobStatus.running,
          phase: phase,
          completedBlocks: 50,
          cachedBlocks: cachedBlocks,
        );
    onProgress?.call(job, 'Cache scan in progress');
    if (terminalStatus == null) throw StateError('Cache scan failed');
    return TranslationRunResult(
      job: job.copyWith(status: terminalStatus),
      chapters: chapters,
    );
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

class _RecordingPathStore extends SessionPathStore {
  final saves = <({String inputPath, String outputDirectory})>[];

  @override
  Future<SessionPathResult> load() async => const SessionPathResult();

  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {
    saves.add((inputPath: inputPath, outputDirectory: outputDirectory));
  }
}

// Pause before the real store's locked read so a second store can write a new
// run. This exercises the controller's actual merge closure against disk.
class _PausedClearStore extends JobHistoryStore {
  _PausedClearStore(File file) : super(historyFileProvider: () async => file);

  final entered = Completer<int>();
  final release = Completer<void>();
  final candidates = <int>[];

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    candidates.add(clearedAtEpochMs);
    if (!entered.isCompleted) {
      entered.complete(clearedAtEpochMs);
      await release.future;
    }
    return super.saveMerged(merge: merge, clearedAtEpochMs: clearedAtEpochMs);
  }
}

TranslationDashboardController _controller({_Repository? repository}) {
  final controller = TranslationDashboardController(
    repository: repository ?? _Repository(),
  );
  addTearDown(controller.dispose);
  controller.syncSettings(
    TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
  );
  controller.setInputPath('/books/old.epub');
  controller.setOutputDirectory('/output');
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('directory picker persists the new session destination', () async {
    final store = _RecordingPathStore();
    final controller = TranslationDashboardController(
      repository: _Repository(),
      pathStore: store,
      // Keep the nullable future type of native pickers: timeout's null
      // cancellation result must also be valid for the override's future.
      directoryPickerOverride: ({onWindowsNotice}) =>
          Future<String?>.value('/new-output'),
    );
    addTearDown(controller.dispose);
    controller.setInputPath('/books/book.epub');
    await Future<void>.delayed(Duration.zero);
    await controller.pickOutputDirectory();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.outputDirectory, '/new-output');
    expect(store.saves.last, (
      inputPath: '/books/book.epub',
      outputDirectory: '/new-output',
    ));
  });

  for (final cached in <int>[10, 0]) {
    test('restoration failure logs only $cached verified blocks', () async {
      final controller = _controller(
        repository: _Repository(cachedBlocks: cached),
      );
      await controller.startInspection();
      expect(await controller.startTranslation(), isTrue);
      final job = controller.state.job!;
      final strings = AppStrings(controller.state.config.uiLanguage);
      expect(job.status, TranslationJobStatus.failed);
      expect(job.phase, TranslationJobPhase.cacheRestoration);
      expect(job.completedBlocks, 50);
      expect(job.cachedBlocks, cached);
      expect(
        controller.state.logs,
        isNot(contains(strings.logCheckpointed(50))),
      );
      expect(
        controller.state.logs.contains(strings.logCheckpointed(cached)),
        cached > 0,
      );
    });
  }

  test('translation failure still logs confirmed completed blocks', () async {
    final controller = _controller(
      repository: _Repository(phase: TranslationJobPhase.translation),
    );
    await controller.startInspection();
    await controller.startTranslation();
    expect(controller.state.job!.phase, TranslationJobPhase.translation);
    expect(
      controller.state.logs,
      contains(
        AppStrings(controller.state.config.uiLanguage).logCheckpointed(50),
      ),
    );
  });

  for (final status in <TranslationJobStatus>[
    TranslationJobStatus.completed,
    TranslationJobStatus.failed,
  ]) {
    test('cache-only terminal $status preserves restoration phase', () async {
      final controller = _controller(
        repository: _Repository(terminalStatus: status),
      );
      await controller.startInspection();
      await controller.startTranslation();
      expect(controller.state.job!.status, status);
      expect(controller.state.job!.phase, TranslationJobPhase.cacheRestoration);
    });
  }

  for (final inputMethod in <String>['manual', 'drop', 'picker']) {
    test('$inputMethod input releases the previous static estimate', () async {
      final controller = TranslationDashboardController(
        repository: _Repository(),
        epubPickerOverride:
            ({void Function(WindowsPathNotice notice)? onWindowsNotice}) =>
                Future<String?>.value('/books/new.epub'),
      );
      addTearDown(controller.dispose);
      controller.setInputPath('/books/old.epub');
      controller.setOutputDirectory('/output');
      await controller.startInspection();
      expect(controller.debugStaticEstimateCache, isNotNull);
      switch (inputMethod) {
        case 'manual':
          controller.setInputPath('/books/new.epub');
        case 'drop':
          expect(
            await controller.importDroppedEpubPath('/books/new.epub'),
            isTrue,
          );
        case 'picker':
          await controller.pickInputPath();
      }
      expect(controller.state.inputPath, '/books/new.epub');
      expect(controller.state.inspectedChapters, isEmpty);
      expect(controller.debugStaticEstimateCache, isNull);
      await controller.startInspection();
      expect(controller.debugStaticEstimateCache, isNotNull);
    });
  }

  for (final rebase in <bool>[false, true]) {
    test('clear preserves late runs with tombstone rebase=$rebase', () async {
      final directory = await Directory.systemTemp.createTemp(
        'b-area-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/history.json');
      final otherStore = JobHistoryStore(historyFileProvider: () async => file);
      TranslationJob job(String id, int startedAt) => TranslationJob(
        id: id,
        inputPath: '/books/$id.epub',
        outputPath: '/output',
        status: TranslationJobStatus.failed,
        progress: 0,
        runStartedAt: startedAt,
      );
      final old = job('A', 1);
      final legacy = job('legacy', 0);
      await otherStore.save(<TranslationJob>[old, legacy]);
      final store = _PausedClearStore(file);
      final controller = TranslationDashboardController(
        repository: _Repository(),
        historyStore: store,
      );
      addTearDown(controller.dispose);
      // Wait for initial hydration without triggering any history write.
      while (controller.state.jobHistory.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final clearing = controller.clearJobHistory();
      final clearMs = await store.entered.future;
      final boundary = job('boundary', clearMs * 1000);
      // clearMs is millisecond-truncated while the deletion watermark uses the
      // true microsecond instant inside that millisecond, so +1us is NOT
      // reliably after the clear. Use a margin safely beyond the whole
      // millisecond to construct a genuinely late run.
      final late = job('B', clearMs * 1000 + 10000);
      await otherStore.save(<TranslationJob>[
        late,
        boundary,
        old,
        legacy,
      ], clearedAtEpochMs: rebase ? clearMs + 100 : 0);
      store.release.complete();
      expect(await clearing, isTrue);
      final result = await otherStore.loadWithTombstone();
      expect(result.jobs.map((entry) => entry.id), <String>['B']);
      expect(result.clearedAt, rebase ? clearMs + 101 : clearMs);
      expect(store.candidates.length, rebase ? 2 : 1);
    });
  }
}
