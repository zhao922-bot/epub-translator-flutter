import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/review_text_patch.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/semantic_source_analysis.dart';
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

void main() {
  test('word sense analysis must address the requested expression', () {
    final units = SemanticSourceAnalysis.units(
      '<p>The manager opened the office.</p>',
    );
    final base = {
      'id': 'u0',
      'meaning': 'A staff supervisor opened the workplace.',
    };
    expect(
      () => SemanticSourceAnalysis.validatePlan([
        {
          ...base,
          'sense': 'The scene takes place at the beginning of a working day.',
        },
      ], units),
      throwsFormatException,
    );
    expect(
      SemanticSourceAnalysis.validatePlan([
        {
          ...base,
          'sense':
              'The manager is a staff supervisor; office is the workplace.',
        },
      ], units),
      hasLength(1),
    );
  });
  for (final approve in [true, false]) {
    test(
      'patch-only repair keeps incomplete coverage and requires verification: $approve',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        f.reviewItemsOverride = (items) => [
          for (final item in items)
            {'id': item['id'], 'unchanged': true, 'coverage': []},
        ];
        f.repairItemsOverride = (items) => [
          for (final item in items)
            Map<String, Object?>.from(item)..remove('coverage'),
        ];
        if (!approve) {
          f.verificationItemsOverride = (items) => [
            for (final item in items) {...item, 'approve': false},
          ];
        }
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        for (var pass = 0; pass < 2; pass++) {
          final r = await helpers.run(f, config: config);
          final q =
              jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
          expect(q['automaticCorrections'], hasLength(approve ? 2 : 0));
          expect(q['corrections'], hasLength(approve ? 0 : 2));
          expect(q['unreviewed'], hasLength(2));
          expect(q['reviewedBlocks'], 0);
          expect(q['complete'], isFalse);
          if (pass == 1) expect(r.apiUsage['requests'], 0);
        }
      },
    );
  }
  for (final noOp in [false, true]) {
    test(
      'an initially false equivalence triggers bounded repair; no-op=$noOp',
      () async {
        final f = fixture.Fixture();
        await f.init();
        addTearDown(f.dispose);
        f.reviewItemsOverride = (items) => [
          for (final item in items)
            {
              'id': item['id'],
              'unchanged': true,
              'coverage': [
                for (final c in item['coverage'] as List)
                  {...c as Map, 'verdict': 'equivalent'},
              ],
            },
        ];
        f.equivalenceItemsOverride = (items) => [
          for (final item in items)
            {
              ...item,
              'sourceImpliesDraft': false,
              'reason': 'Distress and continued happiness are incompatible.',
            },
        ];
        if (noOp) {
          f.repairItemsOverride = (items) => [
            for (final item in items)
              {
                ...item,
                'html': null,
                'edits': [
                  {'node': 'n0', 'before': '她', 'after': '她'},
                ],
              },
          ];
        }
        final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
        for (var pass = 0; pass < 2; pass++) {
          final r = await helpers.run(f, config: config);
          final q =
              jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
          expect(q['automaticCorrections'], hasLength(noOp ? 0 : 2));
          expect(q['unreviewed'], hasLength(noOp ? 2 : 0));
          if (pass == 1) expect(r.apiUsage['requests'], 0);
        }
        final payloads = f.requests
            .map((r) => (r['messages'] as List).last['content'] as String)
            .where((s) => s.startsWith('{'))
            .map(jsonDecode)
            .whereType<Map>()
            .toList();
        expect(
          payloads.where((p) => p['kind'] == 'semanticReviewRepair'),
          hasLength(1),
        );
        final independent = payloads.singleWhere(
          (p) => p['kind'] == 'semanticEquivalence',
        );
        expect(jsonEncode(independent), isNot(contains('equivalent')));
        expect(jsonEncode(independent), isNot(contains('unchanged')));
        expect(jsonEncode(independent), isNot(contains('喜极而泣')));
      },
    );
  }
  test(
    'an unchanged decision without equivalence budget stays unreviewed',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 3);
      addTearDown(f.dispose);
      f.reviewUnchanged = true;
      final r = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final q =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(q['requests'], 3);
      expect(q['unreviewed'], hasLength(2));
      expect(q['reviewedBlocks'], 0);
    },
  );
  test(
    'valid local corrections survive incomplete coverage without claiming full review',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        {...items.first, 'coverage': []},
        ...items.skip(1),
      ];
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      final r = await helpers.run(f, config: config);
      final q =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(q['automaticCorrections'], hasLength(2));
      expect(q['unreviewed'], hasLength(1));
      expect(q['reviewedBlocks'], 1);
      expect(q['requests'], 4);
      final repairs = f.requests
          .map((r) => (r['messages'] as List).last['content'] as String)
          .where((s) => s.startsWith('{'))
          .map(jsonDecode)
          .whereType<Map>()
          .where((p) => p['kind'] == 'semanticReviewRepair');
      expect(repairs, isEmpty);
      final warm = await helpers.run(f, config: config);
      expect(warm.apiUsage['requests'], 0);
      expect(warm.job.unreviewedBlockCount, 1);
      final warmReport =
          jsonDecode(File(warm.qualityReportPath!).readAsStringSync()) as Map;
      expect(warmReport['automaticCorrections'], hasLength(2));
    },
  );
  test(
    'missing blind draft reading never certifies the original draft',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.draftAnalysisItemsOverride = (items) => items.skip(1).toList();
      final r = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final q =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(q['automaticCorrections'], hasLength(1));
      expect(q['unreviewed'], hasLength(1));
      expect(q['reviewedBlocks'], 1);
    },
  );
  test('source units keep title and initials with their complete sentence', () {
    const source = 'Dr. Alice M. Wells arrived. J. R. Hill waved; she replied.';
    final units = SemanticSourceAnalysis.units('<p>$source</p>');
    expect(units.map((u) => u['source']).toList(), [
      'Dr. Alice M. Wells arrived.',
      'J. R. Hill waved;',
      'she replied.',
    ]);
    expect(units.map((u) => u['source']).join(' '), source);
  });
  test(
    'a review split retains neighbours from original paragraph order',
    () async {
      final f = fixture.Fixture();
      await f.init(blocks: 9, chunkSize: 12000, reviewLimit: 12);
      addTearDown(f.dispose);
      final r = await helpers.run(
        f,
        config: f.config.copyWith(
          autoApplyVerifiedCorrections: true,
          maxSemanticReviewTokens: 256000,
        ),
      );
      expect(r.job.unreviewedBlockCount, 0);
      final payloads = f.requests
          .map((r) => (r['messages'] as List).last['content'] as String)
          .where((s) => s.startsWith('{'))
          .map((s) => jsonDecode(s))
          .whereType<Map>();
      final requests = payloads
          .where((p) => p['kind'] == 'semanticSourceAnalysis')
          .toList();
      expect(requests, hasLength(2));
      final last = (requests.last['blocks'] as List).single as Map;
      expect(last['id'], 'p-9');
      expect((last['adjacentSource'] as Map)['before'], contains('Scene 7.'));
      expect((last['adjacentSource'] as Map).containsKey('after'), isFalse);
    },
  );
  test(
    'focused analysis cannot copy source or certify plural wording as singular',
    () {
      final units = SemanticSourceAnalysis.units('<p>They waited outside.</p>');
      expect(
        () => SemanticSourceAnalysis.validatePlan([
          {
            'id': 'u0',
            'meaning': 'They waited outside.',
            'reference': 'They waited outside.',
            'referenceNumber': 'singular',
          },
        ], units),
        throwsFormatException,
      );
      final plan = SemanticSourceAnalysis.validatePlan([
        {
          'id': 'u0',
          'meaning': 'The previously identified visitor waited outside.',
          'reference': 'They refers to the one visitor established in context.',
          'referenceNumber': 'singular',
        },
      ], units);
      final row = {
        'id': 'u0',
        'verdict': 'equivalent',
        'targetQuote': '他们在外面等候。',
        'reason': 'The visitor waited outside.',
        'backMeaning': 'Several people waited outside.',
        'referenceQuote': '他们',
        'referenceNumber': 'plural',
      };
      expect(
        () => SemanticSourceAnalysis.validateCoverage(
          [row],
          plan,
          '<p>他们在外面等候。</p>',
          unchanged: true,
        ),
        throwsFormatException,
      );
      expect(
        () => SemanticSourceAnalysis.validateCoverage(
          [
            {...row, 'referenceNumber': 'singular'},
          ],
          plan,
          '<p>他们在外面等候。</p>',
          unchanged: true,
        ),
        throwsFormatException,
      );
      expect(
        () => SemanticSourceAnalysis.validateCoverage(
          [
            {...row, 'referenceNumber': 'singular', 'referenceQuote': '他'},
          ],
          plan,
          '<p>他们在外面等候。</p>',
          unchanged: true,
        ),
        throwsFormatException,
      );
      expect(
        SemanticSourceAnalysis.validateCoverage(
          [
            {...row, 'verdict': 'mismatch'},
          ],
          plan,
          '<p>他们在外面等候。</p>',
          unchanged: false,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'node-scoped edits disambiguate repetition without touching protected markup',
    () {
      const draft =
          '<p><a href="/link">同词</a><i>同词</i><sup>注</sup><code>同词</code></p>';
      expect(ReviewTextPatch.segments(draft), [
        {'node': 'n0', 'text': '同词'},
        {'node': 'n1', 'text': '同词'},
      ]);
      expect(
        ReviewTextPatch.apply(draft, [
          {'node': 'n1', 'before': '同词', 'after': '新词'},
        ]),
        '<p><a href="/link">同词</a><i>新词</i><sup>注</sup><code>同词</code></p>',
      );
      expect(
        () => ReviewTextPatch.apply(draft, [
          {'before': '同词', 'after': '新词'},
        ]),
        throwsFormatException,
      );
      for (final id in ['n2', 'n-1', 'n01', 'href']) {
        expect(
          () => ReviewTextPatch.apply(draft, [
            {'node': id, 'before': '同词', 'after': '新词'},
          ]),
          throwsFormatException,
        );
      }
      expect(
        () => ReviewTextPatch.apply('<p>同词和同词</p>', [
          {'node': 'n0', 'before': '同词', 'after': '新词'},
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'source units retain inline clauses and bound long paragraphs without dropping text',
    () {
      final source =
          '<p>She tried <i>to open</i> the door; it remained shut. Her friend, joking, asked why.</p>';
      final units = SemanticSourceAnalysis.units(source);
      expect(units, hasLength(3));
      expect(
        units.map((u) => u['source']).join(' '),
        'She tried to open the door; it remained shut. Her friend, joking, asked why.',
      );
      final long = List.generate(40, (i) => 'Sentence $i.').join(' ');
      final bounded = SemanticSourceAnalysis.units('<p>$long</p>');
      expect(bounded, hasLength(16));
      expect(bounded.map((u) => u['source']).join(' '), long);
    },
  );

  test(
    'complete plans and real target evidence are required to accept unchanged',
    () {
      final units = SemanticSourceAnalysis.units(
        '<p>One visitor arrived. Nobody else came.</p>',
      );
      final plan = SemanticSourceAnalysis.validatePlan([
        {'id': 'u0', 'meaning': 'Exactly one visitor arrived.'},
        {
          'id': 'u1',
          'meaning': 'No additional person came.',
          'scope': 'The statement excludes every additional arrival.',
        },
      ], units);
      final coverage = [
        {
          'id': 'u0',
          'verdict': 'equivalent',
          'targetQuote': '一位访客来了。',
          'reason': 'Preserves the singular visitor.',
        },
        {
          'id': 'u1',
          'verdict': 'equivalent',
          'targetQuote': '没有其他人来。',
          'reason': 'Preserves exclusion of others.',
          'backMeaning': 'There was no additional arrival.',
        },
      ];
      expect(
        SemanticSourceAnalysis.validateCoverage(
          coverage,
          plan,
          '<p>一位访客来了。没有其他人来。</p>',
          unchanged: true,
        ),
        hasLength(2),
      );
      for (final bad in [
        [],
        [coverage.first, coverage.first],
        [
          coverage.first,
          {...coverage.last, 'targetQuote': '伪造的内容'},
        ],
        [
          coverage.first,
          {...coverage.last, 'targetQuote': ''},
        ],
        [
          coverage.first,
          {...coverage.last, 'verdict': 'missing'},
        ],
      ]) {
        expect(
          () => SemanticSourceAnalysis.validateCoverage(
            bad,
            plan,
            '<p>一位访客来了。没有其他人来。</p>',
            unchanged: true,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => SemanticSourceAnalysis.validatePlan([
          {'id': 'u0', 'meaning': 'Only first'},
        ], units),
        throwsFormatException,
      );
    },
  );

  test(
    'grounded review preserves separate source-only calls and bound audit on warm cache',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 12);
      addTearDown(f.dispose);
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      for (var pass = 0; pass < 2; pass++) {
        final r = await helpers.run(f, config: config);
        final q =
            jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
        expect(q['automaticCorrections'], hasLength(2));
        expect(q['meaningAssessments'], hasLength(2));
        expect(r.job.unreviewedBlockCount, 0);
        if (pass == 1) expect(r.apiUsage['requests'], 0);
      }
      final payloads = f.requests
          .map((r) {
            final content = (r['messages'] as List).last['content'] as String;
            return content.startsWith('{') ? jsonDecode(content) : null;
          })
          .whereType<Map>()
          .toList();
      final analysis = payloads.singleWhere(
        (p) => p['kind'] == 'semanticSourceAnalysis',
      );
      expect(jsonEncode(analysis), isNot(contains('draft')));
      expect(jsonEncode(analysis), isNot(contains('喜极而泣')));
      final review = payloads.singleWhere((p) => p['kind'] == 'semanticReview');
      final blind = payloads.singleWhere(
        (p) => p['kind'] == 'semanticDraftAnalysis',
      );
      expect(jsonEncode(blind), isNot(contains('alas')));
      expect(jsonEncode(blind), isNot(contains('source')));
      expect(jsonEncode(blind), contains('喜极而泣'));
      expect(
        (review['blocks'] as List).every(
          (b) =>
              b['sourceAnalysis'] is List &&
              b['draftAnalysis'] is String &&
              b['draftSegments'] is List &&
              !b.containsKey('draftHtml'),
        ),
        isTrue,
      );
    },
  );

  test(
    'an unsupported unchanged response never becomes a reviewed block',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.reviewItemsOverride = (items) => [
        for (final i in items)
          {'id': i['id'], 'unchanged': true, 'coverage': []},
      ];
      f.repairItemsOverride = f.reviewItemsOverride;
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      for (var pass = 0; pass < 2; pass++) {
        final r = await helpers.run(f, config: config);
        final q =
            jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
        expect(q['reviewedBlocks'], 0);
        expect(q['complete'], isFalse);
        expect(r.job.unreviewedBlockCount, 2);
        expect(q['automaticCorrections'], isEmpty);
        expect((q['unreviewedReasons'] as Map).values.toSet(), {
          'invalidResponse',
        });
        expect(
          (q['unreviewedDetails'] as Map).values.every(
            (v) => v is String && v.isNotEmpty,
          ),
          isTrue,
        );
        expect(q['unreviewedDetails'], hasLength(2));
        if (pass == 1) expect(r.apiUsage['requests'], 0);
      }
    },
  );

  test(
    'missing source analysis isolates one block and cannot retry outside the review budget',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      f.sourceAnalysisItemsOverride = (items) => items.skip(1).toList();
      final r = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final q =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(r.job.unreviewedBlockCount, 1);
      expect(q['automaticCorrections'], hasLength(1));
      expect(
        q['requests'],
        4,
      ); // source, blind draft, surviving review, verifier
    },
  );

  test(
    'a single-call budget cannot claim review after source analysis alone',
    () async {
      final f = fixture.Fixture();
      await f.init(reviewLimit: 1);
      addTearDown(f.dispose);
      final r = await helpers.run(
        f,
        config: f.config.copyWith(autoApplyVerifiedCorrections: true),
      );
      final q =
          jsonDecode(File(r.qualityReportPath!).readAsStringSync()) as Map;
      expect(q['requests'], 1);
      expect(q['reviewedBlocks'], 0);
      expect(r.job.unreviewedBlockCount, 2);
      expect(q['corrections'], isEmpty);
      expect(q['automaticCorrections'], isEmpty);
    },
  );
}
