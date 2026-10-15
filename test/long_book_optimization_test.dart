import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/book_source_index.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

void main() {
  const checker = TranslationConsistencyChecker();
  final config = TranslationConfig.defaults();
  List<Map<String, String>> check(String source, String target) =>
      checker.check(
        sourceHtml: '<p>$source</p>',
        translatedHtml: '<p>$target</p>',
        config: config,
      );

  test(
    'numbers distinguish pronouns, line wraps, centuries, clocks and decimals',
    () {
      expect(
        check('No one knew; I never told any one.', '无人知道，我对谁都没说。'),
        isEmpty,
      );
      expect(check('three\nhundred years', '三百年'), isEmpty);
      expect(check('three centuries', '三百年'), isEmpty);
      expect(check('three centuries', '三个世纪'), isEmpty);
      expect(check('eleven oclock', '十一点一刻'), isEmpty);
      expect(check('11.1 dollars', '十一点一美元'), isEmpty);
      expect(check('three centuries', '三年'), isNotEmpty);
      expect(check('one apple', '没有苹果'), isNotEmpty);
      expect(check('11.1 dollars', '十一点二美元'), isNotEmpty);
    },
  );

  test(
    'soft glossary tolerates modifiers while explicit locks remain exact',
    () {
      const terms = {'the American Minister': '美国公使'};
      final okay = checker.check(
        sourceHtml: 'the American Minister',
        translatedHtml: '美国驻圣詹姆斯宫（英国宫廷）公使',
        config: config,
        knownTerms: terms,
      );
      expect(okay, isEmpty);
      expect(
        checker.check(
          sourceHtml: 'Miss Virginia E. Otis',
          translatedHtml: '弗吉尼亚·E·奥蒂斯小姐',
          config: config,
          knownTerms: {'Miss Virginia': '弗吉尼亚小姐'},
        ),
        isEmpty,
      );
      final wrong = checker.check(
        sourceHtml: 'the American Minister',
        translatedHtml: '英国公使',
        config: config,
        knownTerms: terms,
      );
      expect(wrong, isNotEmpty);
      expect(
        checker.check(
          sourceHtml: 'the American Minister',
          translatedHtml: '美国驻伦敦公使',
          config: config.copyWith(
            lockedGlossary: 'the American Minister => 美国公使',
          ),
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'whole-selection index retains repeated brands and sibling evidence from later sections',
    () {
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'novel.xhtml',
        bytes: utf8.encode(
          '<html><title>Novel</title><body><h2>I</h2><p>She used Paragon Detergent.</p><h2>II</h2><p>After Virginia came the twins.</p><p>He returned with Paragon Detergent.</p></body></html>',
        ),
      );
      final index = BookSourceIndex.build([chapter]);
      expect(
        (index['recurringTerms'] as List).cast<Map>().any(
          (t) => t['source'] == 'Paragon Detergent',
        ),
        isTrue,
      );
      expect(
        (index['relationshipEvidence'] as List).join(),
        contains('After Virginia came the twins'),
      );
    },
  );

  test('evidence returns the following explanation of a distant reference', () {
    final index = ReviewEvidenceIndex();
    index.add(
      'Have you read the prophecy on the library window?',
      after: 'There are only six lines: When a golden girl can win.',
    );
    index.add('A man looked at the empty garden.');
    expect(
      index.retrieve('They engraved the verse from the library window.').join(),
      contains('six lines'),
    );
  });

  test(
    'rejected reviews persist reasons and retry only when explicitly selected',
    () async {
      final f = fixture.Fixture();
      await f.init(sourcePrefix: 'Della waited. ');
      addTearDown(f.dispose);
      f.reviewConfidence = 'uncertain';
      final first = await helpers.run(f);
      final report = await const TranslationReviewStore().load(
        first.qualityReportPath!,
      );
      expect(
        (report['unreviewedReasons'] as Map).values,
        everyElement('unsupportedRewrite'),
      );
      expect(report['findings'], isNotEmpty);
      final requests = f.requests.length;
      final cached = await helpers.run(f);
      expect(f.requests.length, requests);
      expect(cached.apiUsage['requests'], 0);
      expect(cached.job.unreviewedBlockCount, 2);
      final restored = await const TranslationReviewStore().load(
        cached.qualityReportPath!,
      );
      expect(restored['findings'], report['findings']);
      f.reviewConfidence = 'high';
      final retryLogs = <String>[];
      final retried = await helpers.run(
        f,
        config: f.config.copyWith(retryIncompleteReviews: true),
        onProgress: (_, message) => retryLogs.add(message),
      );
      expect(retried.job.unreviewedBlockCount, 0);
      expect(retried.apiUsage['byKind'], {'semanticReview': 1});
      expect(retryLogs, contains(contains('0 个新块的 API 用时')));
      expect(
        TranslationConfig.fromJson(
          f.config.copyWith(retryIncompleteReviews: true).toJson(),
        ).retryIncompleteReviews,
        isTrue,
      );
    },
  );

  for (final mode in ['missing', 'duplicate', 'malformed']) {
    test('partial review preserves valid neighbours ($mode)', () async {
      final f = fixture.Fixture();
      await f.init(blocks: 3);
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        items[0],
        if (mode == 'duplicate') ...[items[1], items[1]],
        if (mode == 'malformed') {...items[1], 'issues': null},
        items[2],
        {...items[0], 'id': 'unknown'},
      ];
      final first = await helpers.run(f);
      expect(first.job.reviewSuggestionCount, 2);
      expect(first.job.unreviewedBlockCount, 1);
      final cached = await helpers.run(f);
      expect(cached.apiUsage['requests'], 0);
      expect(cached.job.reviewSuggestionCount, 2);
      expect(cached.job.unreviewedBlockCount, 1);
    });
  }

  test('source evidence comparison tolerates HTML line wrapping', () async {
    final f = fixture.Fixture();
    await f.init(sourcePrefix: 'He waited three\nhundred years. ');
    addTearDown(f.dispose);
    f.reviewQuoteOverride = 'three hundred years';
    final result = await helpers.run(f);
    expect(result.job.reviewSuggestionCount, 2);
    expect(result.job.unreviewedBlockCount, 0);
  });

  test(
    'local format conversion works without suggestions or any API calls',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewUnchanged = true;
      final result = await helpers.run(f);
      final paid = f.requests.length;
      const store = TranslationReviewStore();
      final report = await store.load(result.qualityReportPath!);
      expect(report['corrections'], isEmpty);
      expect((report['rendering'] as Map)['completeSnapshot'], isTrue);
      final converted = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
        bilingual: true,
      );
      expect(helpers.story(converted), contains('First she screamed'));
      expect(helpers.story(converted), contains('喜极而泣'));
      final mono = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
        bilingual: false,
      );
      expect(helpers.story(mono), helpers.story(result.job.outputPath));
      expect(f.requests.length, paid);
    },
  );

  test(
    'custom suggestion text escapes markup, persists and can be undone',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final result = await helpers.run(f);
      const store = TranslationReviewStore();
      final report = await store.load(result.qualityReportPath!);
      final item = (report['corrections'] as List).first as Map;
      final key = TranslationReviewStore.suggestionKey(item);
      final custom = TranslationReviewStore.editText(
        item['afterHtml'] as String,
        '她先欢喜，随后悲伤。<这些是普通文字>',
      );
      final output = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {key},
        editedSuggestions: {key: custom},
      );
      expect(helpers.story(output), contains('&lt;这些是普通文字&gt;'));
      final saved = await store.load(result.qualityReportPath!);
      expect(
        ((saved['corrections'] as List).first as Map)['customHtml'],
        custom,
      );
      final undo = await store.export(
        reportPath: result.qualityReportPath!,
        baseOutputPath: result.job.outputPath,
        accepted: {},
        editedSuggestions: {key: custom},
      );
      expect(helpers.story(undo), helpers.story(result.job.outputPath));
      expect(
        TranslationReviewStore.editableText('<p>Keep <em>format</em></p>'),
        isNull,
      );
      expect(await File(result.job.outputPath).exists(), isTrue);
    },
  );
}
