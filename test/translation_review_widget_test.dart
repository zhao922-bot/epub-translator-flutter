import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_run_details.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_review_page.dart';

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
          'rendering': {},
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
}
