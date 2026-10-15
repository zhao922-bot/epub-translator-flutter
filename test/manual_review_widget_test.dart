import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_manual_review_page.dart';

void main() {
  for (final inline in [false, true]) {
    testWidgets(
      'manual editor fits a narrow screen and preserves choices (inline=$inline)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ManualReviewSelection? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.push<ManualReviewSelection>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TranslationManualReviewPage(
                          blocks: [
                            {
                              'chapter': 'story.xhtml',
                              'id': 'p-1',
                              'key': 'story.xhtml\u0000p-1',
                              'sourceHtml': '<p>Tea was served.</p>',
                              'beforeHtml': inline
                                  ? '<p><em>晚饭</em>端上来了。</p>'
                                  : '<p>晚饭端上来了。</p>',
                            },
                          ],
                          edits: {},
                          reviewed: {},
                          isChinese: true,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tea was served.'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('修改此段'));
        await tester.tap(find.text('修改此段'));
        await tester.pumpAndSettle();
        if (inline) {
          await tester.enterText(
            find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == '原文字',
            ),
            '晚饭',
          );
          await tester.enterText(
            find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == '替换为',
            ),
            '茶点',
          );
        } else {
          await tester.enterText(find.byType(TextField).last, '茶点端上来了。');
        }
        await tester.tap(find.text('保存修改'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('保留选择'));
        await tester.pumpAndSettle();
        expect(result!.edits.values.single, contains('茶点'));
        if (inline) {
          expect(result!.edits.values.single, contains('<em>茶点</em>'));
        }
        expect(result!.reviewed, contains('story.xhtml\u0000p-1'));
      },
    );
  }
}
