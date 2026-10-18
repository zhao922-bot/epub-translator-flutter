import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_review_page.dart';
import 'support/review_baseline_fixture.dart';

Map<String, dynamic> _minimal(String output) => {
  'version': 2,
  'outputPath': output,
  'corrections': [],
  'rendering': writeReviewBaselineFixture(output),
  'findings': [],
  'unreviewed': ['story.xhtml:p-1'],
};
Future<void> _open(WidgetTester tester, File report, String output) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TranslationReviewPage(
        reportPath: report.path,
        outputPath: output,
        isChinese: false,
      ),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pump();
}

void main() {
  for (final mode in ['valid', 'wrongReasons', 'wrongLastBilingual']) {
    testWidgets(
      'malformed optional report fields recover without build exception: $mode',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync('audit-r28-field-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final output = '${temp.path}/book.epub';
        final report = File('$output.quality.json');
        final data = _minimal(output)
          ..['unreviewedReasons'] = mode == 'wrongReasons'
              ? ['budgetLimit']
              : {'story.xhtml:p-1': 'budgetLimit'};
        if (mode == 'wrongLastBilingual') data['lastExportBilingual'] = 'false';
        report.writeAsStringSync(jsonEncode(data));
        await _open(tester, report, output);
        final error = tester.takeException();
        debugPrint(
          'AUDIT report fields mode=$mode frameworkError=${error.runtimeType} error=$error recoveryMessage=${find.textContaining("Could not read the review report").evaluate().length}',
        );
        final recoveryCount = find
            .textContaining('Could not read the review report')
            .evaluate()
            .length;
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          error,
          isNull,
          reason:
              'A malformed report must stay inside the readable error path, not throw during ListView build.',
        );
        expect(recoveryCount, mode == 'valid' ? 0 : 1);
      },
    );
  }
  testWidgets('restored large manual-review choices do not block a UI frame', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('audit-r28-ui-cost-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final timings = <int, int>{};
    for (final count in [1000, 4000]) {
      final source =
          '<html><body>${List.generate(count, (i) => '<p>She considered the story and continued walking through the quiet village. Scene $i.</p>').join()}</body></html>';
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'story.xhtml',
        bytes: utf8.encode(source),
      );
      expect(chapter.blocks.length, count);
      final output = '${temp.path}/book$count.epub',
          report = File('${temp.path}/book$count.quality.json');
      final data = _minimal(output)
        ..['rendering'] = {
          'completeSnapshot': true,
          'bilingual': false,
          'targetLanguage': 'Chinese',
          'lockedGlossary': '',
          'chapters': {
            'story.xhtml': {
              'originalHtml': source,
              'translations': {
                for (final b in chapter.blocks)
                  b.id: '<p>她考虑着故事，继续走过寂静的村庄。</p>',
              },
              'countedNames': [],
              'degraded': [],
            },
          },
        }
        ..['unreviewed'] = [
          for (final b in chapter.blocks) 'story.xhtml:${b.id}',
        ]
        ..['unreviewedReasons'] = {
          for (final b in chapter.blocks) 'story.xhtml:${b.id}': 'budgetLimit',
        }
        ..['manuallyReviewed'] = [
          for (final b in chapter.blocks) 'story.xhtml\u0000${b.id}',
        ];
      final archive = Archive()
        ..add(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfile full-path="book.opf"/></container>',
          ),
        )
        ..add(
          ArchiveFile.string(
            'book.opf',
            '<package><manifest><item id="s" href="story.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="s"/></spine></package>',
          ),
        )
        ..add(ArchiveFile.string('story.xhtml', source));
      File(output).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      (((data['rendering'] as Map)['chapters'] as Map)['story.xhtml']
          as Map)['baseHtmlSha256'] = sha256
          .convert(utf8.encode(source))
          .toString();
      report.writeAsStringSync(jsonEncode(data));
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationReviewPage(
            reportPath: report.path,
            outputPath: output,
            isChinese: false,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      final watch = Stopwatch()..start();
      await tester.pump();
      watch.stop();
      timings[count] = watch.elapsedMilliseconds;
      expect(
        find.text('Human-reviewed: $count; unresolved model failures: 0.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'AUDIT review UI count=$count reportBytes=${report.lengthSync()} firstLoadedBuildMs=${watch.elapsedMilliseconds}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugPrint('AUDIT review UI timing curve=$timings');
    expect(
      timings[4000]!,
      lessThan(500),
      reason:
          'Restoring review marks for a long book should not block the UI frame for half a second.',
    );
  });
}
