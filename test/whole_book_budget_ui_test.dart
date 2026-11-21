import 'dart:async';

import 'package:epub_translator_flutter/features/jobs/presentation/pages/jobs_page.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_dashboard_page.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_overview.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_job_history_store.dart';
import 'helpers/memory_session_path_store.dart';

const _chapters = [
  InspectedChapter(
    path: 'chapter.xhtml',
    title: 'Chapter',
    body: 'One. Two.',
    originalHtml: '<p>One.</p><p>Two.</p>',
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
    blocks: [
      ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml: '<p>One.</p>',
        sourceText: 'One.',
      ),
      ExtractedBlock(
        id: 'p-2',
        tagName: 'p',
        sourceHtml: '<p>Two.</p>',
        sourceText: 'Two.',
      ),
    ],
  ),
];

const _job = TranslationJob(
  id: 'budget-job',
  inputPath: 'book.epub',
  outputPath: '',
  outputDirectory: 'output',
  status: TranslationJobStatus.inspected,
  progress: 0,
  totalBlocks: 2,
  totalFiles: 1,
  selectedChapterPaths: ['chapter.xhtml'],
);

const _usage = <String, Object>{
  'requests': 2,
  'usageReportedRequests': 1,
  'promptTokens': 50,
  'completionTokens': 20,
  'chargedTokensEstimate': 145,
  'estimatedUnreportedTokens': 75,
  'reasoningTokens': 10,
  'cachedPromptTokens': 25,
  'promptCacheReportedRequests': 1,
  'byKind': {'translation': 2},
  'chargedTokensEstimateByKind': {'translation': 145},
  'promptTokensByKind': {'translation': 50},
  'completionTokensByKind': {'translation': 20},
  'maxBookTokens': 200,
  'nextRequestEstimatedTokens': 100,
};

class _Settings extends SettingsStore {
  _Settings(int budget, {bool styleEnabled = false})
    : saved = TranslationConfig.defaults().copyWith(
        apiKey: 'fixture-key',
        styleProfileEnabled: styleEnabled,
        maxBookTokens: budget,
      );

  TranslationConfig saved;

  @override
  Future<TranslationConfig> load() async => saved;

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    saved = TranslationConfig.fromJson(
      config.toJson(),
    ).copyWith(apiKey: config.apiKey);
  }
}

class _Repository implements TranslationRepository {
  final configs = <TranslationConfig>[];
  final first = Completer<TranslationRunResult>();
  int styleAttempts = 0;

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    styleAttempts++;
    if (config.maxBookTokens == 200) {
      throw const TranslationBudgetPausedException(_usage);
    }
    return TranslationStyleProfile.empty;
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async => InspectionResult(job: _job, chapters: _chapters);

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
    configs.add(config);
    if (configs.length == 1 && config.maxBookTokens == 200) {
      onProgress?.call(
        _job.copyWith(
          status: TranslationJobStatus.running,
          phase: TranslationJobPhase.translation,
          progress: 0.5,
          completedBlocks: 1,
          apiUsage: _usage,
        ),
        '',
      );
      return first.future;
    }
    return TranslationRunResult(
      job: _job.copyWith(
        status: TranslationJobStatus.completed,
        phase: TranslationJobPhase.translation,
        progress: 1,
        completedBlocks: 2,
        resumedBlocks: 1,
        cachedBlocks: 1,
        outputPath: 'book_translated.epub',
        apiUsage: {
          ..._usage,
          'priorChargedTokensEstimate': 145,
          'maxBookTokens': config.maxBookTokens,
        },
      ),
      chapters: chapters,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(
  _Settings settings,
  _Repository repository, {
  List<TranslationJob> jobs = const [],
}) {
  final history = MemoryJobHistoryStore()..save(jobs);
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      translationRepositoryProvider.overrideWithValue(repository),
      jobHistoryStoreProvider.overrideWithValue(history),
      sessionPathStoreProvider.overrideWithValue(MemorySessionPathStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  Widget page,
) async {
  await container.read(settingsProvider.notifier).ready;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: page)),
    ),
  );
  await tester.pumpAndSettle();
}

TranslationJob _paused() => _job.copyWith(
  phase: TranslationJobPhase.translation,
  status: TranslationJobStatus.budgetPaused,
  progress: 0.5,
  completedBlocks: 1,
  apiUsage: _usage,
);

void main() {
  test(
    'legacy budgets default to unlimited and paused jobs persist without export',
    () {
      expect(TranslationConfig.fromJson({}).maxBookTokens, 0);
      final restored = TranslationConfig.fromJson(
        TranslationConfig.defaults().copyWith(maxBookTokens: 300).toJson(),
      );
      expect(restored.maxBookTokens, 300);
      final paused = TranslationJob.fromJson(
        _paused().copyWith(completedBlocks: 0).toJson(),
      );
      expect(paused.canResumeTranslation, isTrue);
      expect(paused.hasExportableEpub, isFalse);
      expect(paused.apiUsage['chargedTokensEstimate'], 145);
    },
  );

  testWidgets(
    'whole-book budget input persists a cap and blank restores unlimited',
    (tester) async {
      final store = _Settings(0);
      final container = _container(store, _Repository());
      await _mount(tester, container, const SettingsPage());
      final field = find.byKey(const ValueKey('settings-max-book-tokens'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.saved.maxBookTokens, 123456);
      expect(
        container.read(translationDashboardProvider).config.maxBookTokens,
        123456,
      );
      await tester.enterText(field, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.saved.maxBookTokens, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dashboard shows live usage, pauses without export, and continues after a saved cap change',
    (tester) async {
      final store = _Settings(200);
      final repository = _Repository();
      final container = _container(store, repository);
      final controller = container.read(translationDashboardProvider.notifier);
      await container.read(settingsProvider.notifier).ready;
      await tester.runAsync(() async {
        controller.setInputPath('book.epub');
        controller.setOutputDirectory('output');
        await controller.startInspection(generateStyle: false);
      });
      await _mount(tester, container, const TranslationDashboardPage());
      expect(find.textContaining('Estimated book total'), findsOneWidget);
      final strings = container.read(appStringsProvider);
      final translate = find.widgetWithText(
        FilledButton,
        strings.translateSelected,
      );
      await tester.ensureVisible(translate);
      await tester.tap(translate);
      await tester.pumpAndSettle();
      expect(repository.configs, hasLength(1));
      expect(
        find.textContaining('145 tokens counted toward budget'),
        findsOneWidget,
      );
      expect(
        container
            .read(translationDashboardProvider)
            .runEstimate
            ?.hasObservedBookUsage,
        isTrue,
      );

      repository.first.complete(
        TranslationRunResult(job: _paused(), chapters: _chapters),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(TranslationOverview),
          matching: find.text('Paused at token budget'),
        ),
        findsOneWidget,
      );
      expect(find.text('Open EPUB'), findsNothing);
      final pauseLogs = container.read(translationDashboardProvider).logs;
      expect(pauseLogs, contains('Paused at token budget'));
      expect(pauseLogs, isNot(contains(strings.logTranslationCompleteDesktop)));
      final resume = find.text('Adjust budget and resume');
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pumpAndSettle();
      expect(find.textContaining('at least 245 tokens'), findsOneWidget);
      final field = find.byKey(const ValueKey('book-token-budget-field'));
      await tester.enterText(field, '300');
      await tester.tap(find.text('Save budget and resume'));
      await tester.pumpAndSettle();
      expect(store.saved.maxBookTokens, 300);
      expect(repository.configs.map((c) => c.maxBookTokens), [200, 300]);
      expect(
        container.read(translationDashboardProvider).job?.hasExportableEpub,
        isTrue,
      );
      expect(
        container
            .read(translationDashboardProvider)
            .job
            ?.apiUsage['priorChargedTokensEstimate'],
        145,
      );
    },
  );

  testWidgets('style budget pause resumes to an inspected, translatable job', (
    tester,
  ) async {
    final store = _Settings(200, styleEnabled: true);
    final repository = _Repository();
    final container = _container(store, repository);
    final controller = container.read(translationDashboardProvider.notifier);
    await container.read(settingsProvider.notifier).ready;
    controller.setInputPath('book.epub');
    controller.setOutputDirectory('output');
    await controller.startInspection();
    final paused = container.read(translationDashboardProvider).job!;
    expect(paused.status, TranslationJobStatus.budgetPaused);
    expect(paused.phase, TranslationJobPhase.inspection);
    expect(repository.styleAttempts, 1);
    await _mount(tester, container, const TranslationDashboardPage());
    final resume = find.text('Adjust budget and resume');
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('book-token-budget-field')),
      '0',
    );
    await tester.tap(find.text('Save budget and resume'));
    await tester.pumpAndSettle();
    final state = container.read(translationDashboardProvider);
    expect(state.job?.status, TranslationJobStatus.inspected);
    expect(state.job!.runStartedAt, greaterThan(paused.runStartedAt));
    expect(state.job?.apiUsage['maxBookTokens'], 0);
    expect(state.job?.apiUsage['chargedTokensEstimate'], 145);
    expect(state.styleProfileConfirmed, isTrue);
    expect(repository.styleAttempts, 2);
    expect(
      find.widgetWithText(
        FilledButton,
        container.read(appStringsProvider).translateSelected,
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Jobs offers the same budget adjustment for a saved pause', (
    tester,
  ) async {
    final repository = _Repository();
    final store = _Settings(200);
    final container = _container(store, repository, jobs: [_paused()]);
    await _mount(tester, container, const JobsPage());
    final button = find.byTooltip('Adjust budget and resume');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('book-token-budget-field')),
      '300',
    );
    await tester.tap(find.text('Save budget and resume'));
    await tester.pumpAndSettle();
    expect(store.saved.maxBookTokens, 300);
    expect(repository.configs.single.maxBookTokens, 300);
  });
}
