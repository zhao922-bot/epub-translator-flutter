import 'dart:convert';
import 'dart:io';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/book_source_index.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

void main() {
  test('titled secondary names survive a crowded source index', () {
    final words = [
      for (var i = 0; i < 40; i++)
        'Market${String.fromCharCode(97 + i ~/ 26)}${String.fromCharCode(97 + i % 26)}',
    ];
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'crowded.xhtml',
      bytes: utf8.encode(
        '<html><body>${List.generate(6, (i) => '<p>They saw ${words.join(' and ')}.${i < 3 ? ' Mrs. Holden returned.' : ''}</p>').join()}</body></html>',
      ),
    );
    final names = (BookSourceIndex.build([chapter])['recurringNames'] as List)
        .cast<Map>();
    expect(names, hasLength(32));
    expect(names.first['source'], 'Holden');
  });
  test(
    'stable entity aliases have a separate bounded capacity from rolling vocabulary',
    () {
      final memory = {
        'glossary': [
          for (var i = 0; i < 40; i++)
            {'source': 'Person$i', 'target': '人名$i', 'canonical': 'true'},
        ],
      };
      final chapter = {
        'glossary': [
          for (var i = 0; i < 40; i++) {'source': 'Term$i', 'target': '术语$i'},
        ],
      };
      final result = EpubChapterTranslator.mergeBookMemoryForTest(
        memory,
        chapter,
        trustedMemoryLocks: true,
      );
      final glossary = (result['glossary'] as List).cast<Map>();
      expect(glossary.where((e) => e['canonical'] == 'true'), hasLength(40));
      expect(glossary.where((e) => e['canonical'] != 'true'), hasLength(32));
      final bounded = EpubChapterTranslator.mergeBookMemoryForTest(
        {
          'glossary': [
            for (var i = 0; i < 70; i++)
              {'source': 'Alias$i', 'target': '名称$i', 'canonical': 'true'},
          ],
        },
        {},
        trustedMemoryLocks: true,
      );
      expect(bounded['glossary'], hasLength(64));
    },
  );
  test(
    'failed entity coverage retains valid initial memory and warm coverage warnings',
    () async {
      final f = fixture.Fixture();
      await f.init(blocks: 3, sourcePrefix: 'She spoke to Ada. ');
      addTearDown(f.dispose);
      f.malformedEntityMemory = true;
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      for (var attempt = 0; attempt < 2; attempt++) {
        final r = await helpers.run(f, config: config);
        final q =
            jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
        expect(q['missingEntityTerms'], contains('Ada'));
        if (attempt == 1) expect(r.apiUsage['requests'], 0);
      }
      final contents = f.requests
          .map((r) => (r['messages'] as List).last['content'] as String)
          .toList();
      expect(
        contents.where((s) => s.contains('"kind":"entityGlossary"')),
        hasLength(1),
      );
      expect(
        contents
            .where((s) => s.contains('"blocks"') && s.contains('"bookMemory"'))
            .any((s) => s.contains('德拉')),
        isTrue,
      );
    },
  );
  for (final recovery in [false, true]) {
    test(
      'missing source entity coverage is recovered and invented aliases discarded (summary failed=$recovery)',
      () async {
        final f = fixture.Fixture();
        await f.init(blocks: 3, sourcePrefix: 'She spoke to Ada. ');
        addTearDown(f.dispose);
        f.malformedInitialMemory = recovery;
        f.entityTerms = [
          {'source': 'Ada', 'target': '艾达'},
          {'source': 'UnrequestedEntity', 'target': '虚构人物'},
        ];
        final result = await helpers.run(
          f,
          config: f.config.copyWith(autoApplyVerifiedCorrections: true),
        );
        final requests = f.requests
            .where(
              (r) => ((r['messages'] as List).last['content'] as String)
                  .trimLeft()
                  .startsWith('{'),
            )
            .map(
              (r) =>
                  jsonDecode((r['messages'] as List).last['content'] as String),
            )
            .whereType<Map>()
            .toList();
        final entity = requests.singleWhere(
          (r) => r['kind'] == 'entityGlossary',
        );
        expect(
          (entity['entities'] as List).any(
            (e) =>
                e['source'] == 'Ada' &&
                (e['evidence'] as String).contains('Ada'),
          ),
          isTrue,
        );
        final withMemory = requests
            .where(
              (r) =>
                  r['blocks'] is List &&
                  r['context'] is Map &&
                  (r['context'] as Map)['bookMemory'] != null,
            )
            .toList();
        expect(withMemory, isNotEmpty);
        expect(jsonEncode(withMemory), contains('艾达'));
        expect(jsonEncode(withMemory), isNot(contains('UnrequestedEntity')));
        final report =
            jsonDecode(File(result.qualityReportPath!).readAsStringSync())
                as Map;
        expect(report['missingEntityTerms'], isNot(contains('Ada')));
      },
    );
  }
  test('new number gate allows written-number and ordinal equivalence', () {
    Set<String> added(String source, String before, String after) =>
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: source,
          beforeHtml: before,
          afterHtml: after,
        );
    expect(added('Four hundred years passed.', '许多年过去了。', '四百年过去了。'), isEmpty);
    expect(added('On the second morning.', '第三天早晨。', '第二天早晨。'), isEmpty);
    expect(added('She cried.', '她哭了。', '她哭了九百八十七次。'), {'987'});
  });
  test(
    'canonical entity survives model drift while ordinary terms can evolve',
    () {
      final memory = {
        'glossary': [
          {'source': 'Ada', 'target': '艾达', 'canonical': 'true'},
          {'source': 'bridge', 'target': '桥'},
        ],
      };
      final chapter = {
        'glossary': [
          {'source': 'Ada', 'target': '阿达'},
          {'source': 'bridge', 'target': '桥梁'},
        ],
      };
      List<Map> terms(Map<String, Object?> result) =>
          (result['glossary'] as List).cast<Map>();
      final merged = terms(
        EpubChapterTranslator.mergeBookMemoryForTest(
          memory,
          chapter,
          trustedMemoryLocks: true,
        ),
      );
      expect(merged.singleWhere((v) => v['source'] == 'Ada')['target'], '艾达');
      expect(
        merged.singleWhere((v) => v['source'] == 'bridge')['target'],
        '桥梁',
      );
      final untrusted = terms(
        EpubChapterTranslator.mergeBookMemoryForTest(
          memory,
          chapter,
          trustedMemoryLocks: false,
        ),
      );
      expect(
        untrusted.singleWhere((v) => v['source'] == 'Ada')['target'],
        '阿达',
      );
      final userOverride = terms(
        EpubChapterTranslator.mergeBookMemoryForTest(
          memory,
          {
            'glossary': [
              {'source': 'Ada', 'target': '用户译名', 'locked': 'true'},
            ],
          },
          trustedMemoryLocks: true,
          trustedChapterLocks: true,
        ),
      );
      expect(
        userOverride.singleWhere((v) => v['source'] == 'Ada')['target'],
        '用户译名',
      );
    },
  );

  test('source index discovers short secondary names with source evidence', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'new-story.xhtml',
      bytes: utf8.encode(
        '<html><body>'
        '<p>We saw Ada with Mrs. Holden.</p>'
        '<p>She asked Ada and Mrs. Holden to wait.</p>'
        '<p>They thanked Ada and Mrs. Holden.</p>'
        '</body></html>',
      ),
    );
    final names = (BookSourceIndex.build([chapter])['recurringNames'] as List)
        .cast<Map>();
    expect(names.map((n) => n['source']), containsAll(['Ada', 'Holden']));
    expect(
      names.every(
        (n) => (n['evidence'] as String).contains(n['source'] as String),
      ),
      isTrue,
    );
    expect(names.map((n) => n['source']), isNot(contains('They')));
  });

  test('auto mode is opt-in and survives settings serialization', () {
    final c = TranslationConfig.defaults();
    expect(c.autoApplyVerifiedCorrections, isFalse);
    final enabled = c.copyWith(autoApplyVerifiedCorrections: true);
    expect(
      TranslationConfig.fromJson(enabled.toJson()).autoApplyVerifiedCorrections,
      isTrue,
    );
    expect(
      TranslationConfig.fromJson({}).autoApplyVerifiedCorrections,
      isFalse,
    );
  });

  test(
    'independent verification applies corrections, preserves report identity and restores audit on warm cache',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 12);
      addTearDown(f.dispose);
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      for (var attempt = 0; attempt < 2; attempt++) {
        final r = await helpers.run(f, config: config);
        expect(helpers.story(r.job.outputPath), contains('伤心'));
        expect(helpers.story(r.job.outputPath), isNot(contains('喜极而泣')));
        final report = await const TranslationReviewStore().load(
          r.qualityReportPath!,
          expectedOutputPath: r.job.outputPath,
        );
        expect(report['corrections'], isEmpty);
        final automatic = (report['automaticCorrections'] as List).cast<Map>();
        expect(automatic, hasLength(2));
        expect(
          automatic.every(
            (a) => a['verified'] == true && a['beforeHtml'] != a['afterHtml'],
          ),
          isTrue,
        );
        final same = await const TranslationReviewStore().export(
          reportPath: r.qualityReportPath!,
          baseOutputPath: r.job.outputPath,
          accepted: {},
        );
        expect(helpers.story(same), helpers.story(r.job.outputPath));
        if (attempt == 1) expect(r.apiUsage['requests'], 0);
      }
      expect(
        f.requests.where(
          (r) => (r['messages'] as List).last['content'].contains(
            'semanticVerification',
          ),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'quoted evidence reaches independent verification and warm audit intact',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 12);
      addTearDown(f.dispose);
      f.reviewQuoteOverride = '“alas”';
      f.verificationItemsOverride = (items) => [
        for (final item in items)
          {
            ...item,
            'sourceQuotes': ['"alas"'],
          },
      ];
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      for (var attempt = 0; attempt < 2; attempt++) {
        final r = await helpers.run(f, config: config);
        final report =
            jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
        expect(r.job.unreviewedBlockCount, 0);
        expect(report['automaticCorrections'], hasLength(2));
        expect(report['corrections'], isEmpty);
        expect(helpers.story(r.job.outputPath), contains('伤心'));
        if (attempt == 1) expect(r.apiUsage['requests'], 0);
      }
    },
  );

  for (final evidenceMode in [
    'actualMarkup',
    'forgedReviewMarkup',
    'forgedVerifierMarkup',
  ]) {
    test('source HTML quotation gate: $evidenceMode', () async {
      final f = fixture.Fixture();
      await f.init(blocks: 1, reviewLimit: 12);
      addTearDown(f.dispose);
      const actual =
          '<p>First she screamed with joy; then alas she burst into distress and tears. Scene 0.</p>';
      final forged = actual.replaceAll('<p>', '<b>').replaceAll('</p>', '</b>');
      f.reviewQuoteOverride = evidenceMode == 'forgedReviewMarkup'
          ? forged
          : actual;
      f.verificationItemsOverride = (items) => [
        for (final item in items)
          {
            ...item,
            'sourceQuotes': [
              evidenceMode == 'forgedVerifierMarkup' ? forged : actual,
            ],
          },
      ];
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      final r = await helpers.run(f, config: config);
      final report =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      if (evidenceMode == 'actualMarkup') {
        expect(report['automaticCorrections'], hasLength(1));
        expect(report['corrections'], isEmpty);
        expect(r.job.unreviewedBlockCount, 0);
        final warm = await helpers.run(f, config: config);
        expect(warm.apiUsage['requests'], 0);
        expect(
          helpers.story(warm.job.outputPath),
          helpers.story(r.job.outputPath),
        );
      } else {
        expect(report['automaticCorrections'], isEmpty);
        expect(helpers.story(r.job.outputPath), contains('喜极而泣'));
        if (evidenceMode == 'forgedReviewMarkup') {
          expect(r.job.unreviewedBlockCount, 1);
        } else {
          expect(
            (report['corrections'] as List).single['autoApplication'],
            'notVerified',
          );
        }
      }
    });
  }

  for (final outcome in [
    'reject',
    'uncertain',
    'fabricatedEvidence',
    'duplicate',
    'omitted',
  ]) {
    test('verifier $outcome cannot mutate a draft', () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.verificationItemsOverride = (items) => switch (outcome) {
        'reject' => [
          for (final i in items) {...i, 'approve': false},
        ],
        'uncertain' => [
          for (final i in items) {...i, 'confidence': 'low'},
        ],
        'fabricatedEvidence' => [
          for (final i in items)
            {
              ...i,
              'sourceQuotes': ['an unsupported fictional quotation'],
            },
        ],
        'duplicate' => [...items, ...items],
        _ => [],
      };
      final result = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final report =
          jsonDecode(File(result.qualityReportPath!).readAsStringSync()) as Map;
      expect(report['automaticCorrections'], isEmpty);
      expect(report['corrections'], hasLength(2));
      expect(helpers.story(result.job.outputPath), contains('喜极而泣'));
      final warm = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final restored =
          jsonDecode(File(warm.qualityReportPath!).readAsStringSync()) as Map;
      expect(warm.apiUsage['requests'], 0);
      expect(
        (restored['corrections'] as List).every(
          (s) => s['autoApplication'] == 'notVerified',
        ),
        isTrue,
      );
    });
  }
  test(
    'verification shares the review budget; exhaustion leaves proposals intact',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 1);
      addTearDown(f.dispose);
      final r = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final report =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(report['requests'], 1);
      expect(report['automaticCorrections'], isEmpty);
      expect(
        (report['corrections'] as List).every(
          (s) => s['autoApplication'] == 'verificationBudgetLimit',
        ),
        isTrue,
      );
      expect(helpers.story(r.job.outputPath), contains('喜极而泣'));
    },
  );
  test(
    'candidate that introduces an unsupported number is held before verification',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        for (final i in items) {...i, 'html': '<p>她先欢喜，接着伤心地哭了 987 次。</p>'},
      ];
      final result = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final report =
          jsonDecode(File(result.qualityReportPath!).readAsStringSync()) as Map;
      expect(report['automaticCorrections'], isEmpty);
      expect(
        (report['corrections'] as List).every(
          (s) => s['autoApplication'] == 'newConsistencyRisk',
        ),
        isTrue,
      );
      expect(
        f.requests.where(
          (r) => (r['messages'] as List).last['content'].contains(
            'semanticVerification',
          ),
        ),
        isEmpty,
      );
      expect(helpers.story(result.job.outputPath), contains('喜极而泣'));
    },
  );

  test(
    'automatic audit cannot be rebound to a different final translation or source',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final result = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final file = File(result.qualityReportPath!);
      final original = file.readAsStringSync();
      for (final field in ['afterHtml', 'sourceHtml']) {
        final report = jsonDecode(original) as Map;
        (report['automaticCorrections'] as List).first[field] =
            '<p>Unrelated altered text.</p>';
        await file.writeAsString(jsonEncode(report));
        await expectLater(
          const TranslationReviewStore().load(
            file.path,
            expectedOutputPath: result.job.outputPath,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      await file.writeAsString(original);
    },
  );
  test(
    'switching automatic mode does not reuse manually-reviewable drafts as corrected output',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 12);
      addTearDown(f.dispose);
      final manual = await helpers.run(f);
      expect(helpers.story(manual.job.outputPath), contains('喜极而泣'));
      final auto = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      expect(auto.job.cachedBlocks, 0);
      expect(helpers.story(auto.job.outputPath), contains('伤心'));
    },
  );
  test(
    'generic ordinal and written-initial checks are not tied to either book',
    () {
      const c = TranslationConsistencyChecker();
      final config = TranslationConfig.defaults();
      List<String?> codes(String a, String b) => c
          .check(
            sourceHtml: '<p>$a</p>',
            translatedHtml: '<p>$b</p>',
            config: config,
          )
          .map((f) => f['code'])
          .toList();
      expect(
        codes('The label changed to Q.', '标记改成了丘。'),
        contains('literalLetter'),
      );
      expect(
        codes('The label changed to Q.', '标记改成了Q。'),
        isNot(contains('literalLetter')),
      );
      expect(
        codes(
          'The fourth time, on the fourth morning; the fifth morning followed.',
          '第四次，在第五个早晨；随后是第五个早晨。',
        ),
        contains('ordinal'),
      );
      expect(
        codes(
          'The fourth time, on the fourth morning; the fifth morning followed.',
          '第四次，在第四个早晨；随后是第五个早晨。',
        ),
        isNot(contains('ordinal')),
      );
      expect(
        c.riskScore('<p>They walked up to the station.</p>', []),
        greaterThan(0),
      );
      expect(c.riskScore('<p>The sky was blue.</p>', []), 0);
    },
  );
}
