import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_run_details.dart';
import 'package:epub_translator_flutter/app/routes.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_manual_review_page.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_review_page.dart';
import 'support/review_baseline_fixture.dart';

void main() {
  testWidgets(
    'review suggestions are unchecked, reversible, and fit a narrow scaled screen',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('review-widget-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/book.epub.quality.json');
      file.writeAsStringSync(
        jsonEncode({
          'version': 2,
          'outputPath': '${dir.path}/book.epub',
          'rendering': writeReviewBaselineFixture('${dir.path}/book.epub'),
          'corrections': [
            {
              'chapter': 'story.xhtml',
              'id': 'p-1',
              'sourceHtml': '<p>Alas, she cried.</p>',
              'beforeHtml': '<p>她喜极而泣。</p>',
              'afterHtml': '<p>她伤心地哭泣。</p>',
              'issues': ['情绪相反'],
              'accepted': false,
            },
          ],
          'unreviewed': [],
          'findings': [],
          'reviewedBlocks': 1,
        }),
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TranslationRunDetails(
                apiUsage: const {
                  'requests': 1,
                  'promptTokens': 100,
                  'completionTokens': 20,
                  'byKind': {'semanticReview': 1},
                },
                outputPath: '${dir.path}/book.epub',
                reportPath: file.path,
                isChinese: true,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看检查结果与修改建议'));
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TranslationReviewPage), findsOneWidget);
      expect(find.text('本地导出（已选 0 条）'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(CheckboxListTile),
        200,
        scrollable: find
            .descendant(
              of: find.byType(TranslationReviewPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('review routes recover when their extra is missing or invalid', (
    tester,
  ) async {
    appRouter.go(TranslationReviewRouteData.location);
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pumpAndSettle();
    expect(find.text('Translation review'), findsOneWidget);
    expect(
      find.text('Open a review from the translation results or job history.'),
      findsOneWidget,
    );

    appRouter.go(ManualReviewRouteData.location, extra: 'invalid');
    await tester.pumpAndSettle();
    expect(find.text('Manual review'), findsOneWidget);
    expect(
      find.text('Open a review from the translation results or job history.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('routed manual review debounces search and returns its choices', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('routed-review-widget-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final output = '${dir.path}/book.epub';
    final report = File('$output.quality.json');
    report.writeAsStringSync(
      jsonEncode({
        'version': 2,
        'outputPath': output,
        'rendering': writeReviewBaselineFixture(output)
          ..['completeSnapshot'] = true,
        'unreviewed': ['story.xhtml:p-1'],
        'corrections': [],
      }),
    );

    Future<void> waitFor(Finder target) async {
      for (
        var attempt = 0;
        attempt < 200 && target.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(target, findsOneWidget);
    }

    appRouter.go(
      TranslationReviewRouteData.location,
      extra: TranslationReviewRouteData(
        reportPath: report.path,
        outputPath: output,
        isChinese: false,
      ),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    final manualButton = find.text('Review any paragraph');
    await waitFor(manualButton);
    await tester.tap(manualButton);
    final paragraph = find.text('Alas, she cried.');
    await waitFor(paragraph);
    await tester.pumpAndSettle();
    expect(find.byType(TranslationManualReviewPage), findsOneWidget);

    final search = find.byType(TextField);
    await tester.enterText(search, 'no matching text');
    await tester.pump(const Duration(milliseconds: 249));
    expect(paragraph, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(paragraph, findsNothing);
    expect(find.text('No matching results.'), findsOneWidget);

    await tester.enterText(search, 'ALAS');
    await tester.pump(const Duration(milliseconds: 250));
    expect(paragraph, findsOneWidget);
    await tester.tap(paragraph);
    await tester.pumpAndSettle();
    final confirm = find.text('I checked this paragraph against the source');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pump();
    await tester.tap(find.text('Keep choices'));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationReviewPage), findsOneWidget);
    expect(
      find.text('Human-reviewed: 1; unresolved model failures: 0.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
