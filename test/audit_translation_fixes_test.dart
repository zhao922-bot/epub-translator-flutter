import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_manual_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ConfigProbe extends TranslationRepository {
  TranslationConfig? received;
  final chapters = const [
    InspectedChapter(
      path: 'story.xhtml',
      title: 'Story',
      body: 'Hello.',
      originalHtml: '<p>Hello.</p>',
      blocks: [
        ExtractedBlock(
          id: 'p1',
          tagName: 'p',
          sourceHtml: '<p>Hello.</p>',
          sourceText: 'Hello.',
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
  }) async => InspectionResult(
    job: TranslationJob(
      id: 'probe',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      progress: 1,
    ),
    chapters: chapters,
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
    void Function(String)? onChapterSourcesReleased,
  }) async {
    received = config;
    return TranslationRunResult(
      job: TranslationJob(
        id: 'probe',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.completed,
        phase: TranslationJobPhase.translation,
        progress: 1,
        completedBlocks: 1,
        totalBlocks: 1,
      ),
      chapters: chapters,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'review retry preference reaches a real controller translation call',
    () async {
      final repository = _ConfigProbe();
      final controller = TranslationDashboardController(
        repository: repository,
        settingsReady: () async {},
        windowsPathObserverOverride: (_) async {},
      );
      addTearDown(controller.dispose);
      controller.setInputPath('book.epub');
      controller.setOutputDirectory('output');
      for (final retry in [true, false, true]) {
        controller.syncSettings(
          TranslationConfig.defaults().copyWith(
            retryIncompleteReviews: retry,
            styleProfileEnabled: false,
          ),
        );
        await controller.startInspection(generateStyle: false);
        expect(await controller.startTranslation(), isTrue);
        expect(repository.received, isNotNull);
        expect(repository.received!.retryIncompleteReviews, retry);
      }
    },
  );

  for (final sample in [
    (
      'suggestion',
      '<p>Source passage.</p>',
      '<p>Old draft.</p>',
      '<p>New accepted wording.</p>',
      'new accepted',
    ),
    (
      'source entities',
      '<p>Tea &amp; <em>biscuits</em>.</p>',
      '<p>Draft.</p>',
      null,
      'tea & biscuits',
    ),
    (
      'translation entities',
      '<p>Source.</p>',
      '<p>Draft.</p>',
      '<p>Tea &amp; <em>biscuits</em>.</p>',
      'tea & biscuits',
    ),
  ]) {
    testWidgets('manual search matches visible ${sample.$1}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationManualReviewPage(
            blocks: [
              {
                'key': 'story.xhtml\u0000p1',
                'chapter': 'story.xhtml',
                'id': 'p1',
                'sourceHtml': sample.$2,
                'beforeHtml': sample.$3,
                if (sample.$4 != null) 'proposedHtml': sample.$4!,
              },
            ],
            edits: const {},
            reviewed: const {},
            isChinese: false,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), sample.$5);
      await tester.pump();
      expect(find.byType(ExpansionTile), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'absent phrase');
      await tester.pump();
      expect(find.byType(ExpansionTile), findsNothing);
    });
  }

  testWidgets(
    'search index follows edits and undo instead of stale suggestions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationManualReviewPage(
            blocks: const [
              {
                'key': 'story.xhtml\u0000p1',
                'chapter': 'story.xhtml',
                'id': 'p1',
                'sourceHtml': '<p>Source.</p>',
                'beforeHtml': '<p>Old draft.</p>',
                'proposedHtml': '<p>Accepted wording.</p>',
              },
            ],
            edits: const {},
            reviewed: const {},
            isChinese: false,
          ),
        ),
      );
      final search = find.byType(TextField).first;
      await tester.enterText(search, 'accepted wording');
      await tester.pump();
      expect(find.byType(ExpansionTile), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit paragraph'));
      await tester.tap(find.text('Edit paragraph'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'Fresh edit & biscuits.',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.enterText(search, 'fresh edit & biscuits');
      await tester.pump();
      expect(find.byType(ExpansionTile), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Undo manual edit'));
      await tester.tap(find.text('Undo manual edit'));
      await tester.pump();
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.enterText(search, 'accepted wording');
      await tester.pump();
      expect(find.byType(ExpansionTile), findsOneWidget);
    },
  );

  for (final sample in [
    ('中（foo bar）', true),
    ('foo bar（中文）', true),
    ('foo bar（中文', false),
    ('中（foo bar', false),
    ('中（其他foo bar其他）', true),
    ('中（different foo bar）', false),
    ('😀中（foo bar）', true),
    ('foo bar\u00a0（中文）', true),
    ('foo bar（English only）', false),
    ('foo bar（中文)', true),
  ]) {
    test('indexed gloss preserves the boundary rule for ${sample.$1}', () {
      expect(
        TranslationQuality.isParenthesizedTermGlossForTest(
          sample.$1,
          'foo bar',
        ),
        sample.$2,
      );
    });
  }

  test(
    'public residual check bounds repeated unclosed gloss work',
    () {
      const repeats = 800;
      final source = '<p>${'foo bar ' * repeats}additional source words.</p>';
      final target = '<p>${'foo bar（中' * repeats}。</p>';
      final watch = Stopwatch()..start();
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: source,
        translatedHtml: target,
        targetLanguage: 'zh',
      );
      watch.stop();
      expect(finding?.kind, TranslationResidualKind.longSourceText);
      // Generous ceiling: the old nested scans take about 9 seconds for 7KB.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
