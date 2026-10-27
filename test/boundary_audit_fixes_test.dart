import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/semantic_source_analysis.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

import 'additional_audit_regression_test.dart' as audit;
import 'further_audit_fixes_test.dart' as fixes;
import 'real_book_fix_regression_test.dart' as fixture;
import 'translation_quality_optimization_test.dart' as helpers;

const _middle1 = 'Rhea alone held the bronze appointment letter.';
const _middle2 = 'Cedric handled the sapphire bookstore application.';

void _unchangedPeers(fixture.Fixture f, Set<String> proposed) {
  f.reviewQuoteOverride = 'finally';
  f.reviewItemsOverride = (items) => [
    for (final item in items)
      if (proposed.contains(item['id']))
        item
      else
        ({
          ...item,
          'unchanged': true,
          'coverage': [
            for (final c in item['coverage'] as List)
              {...c as Map, 'verdict': 'equivalent'},
          ],
        }..remove('html')),
  ];
}

void main() {
  for (final tag in ['br', 'hr', 'img', 'wbr']) {
    test('prefixed self-closing $tag does not consume later source text', () {
      final source =
          '<x:p xmlns:x="http://www.w3.org/1999/xhtml">before<x:$tag/>after</x:p>';
      final fragment = XhtmlHtmlCompatibility.parseFragment(source);
      final root = fragment.children.single;
      expect(root.children.single.nodes, isEmpty);
      expect(root.text, 'beforeafter');
      expect(
        const EpubHtmlExtractor().elementText(root),
        tag == 'br' || tag == 'hr' ? 'before after' : 'beforeafter',
      );
      expect(
        TranslationConsistencyChecker.text(source),
        tag == 'br' || tag == 'hr' ? 'before after' : 'beforeafter',
      );
    });
  }
  for (final (markup, expected) in [
    ('<p>The sky was not<br/>blue.</p>', 'The sky was not blue.'),
    ('<p>The sky was not<br>blue.</p>', 'The sky was not blue.'),
    ('<div><p>The sky was not</p><p>blue.</p></div>', 'The sky was not blue.'),
    ('<x:p>The sky was not<x:br/>blue.</x:p>', 'The sky was not blue.'),
    (
      '<p>The mission al<em>most</em> succeeded.</p>',
      'The mission almost succeeded.',
    ),
    (
      '<p>The mission al<wbr/>most succeeded.</p>',
      'The mission almost succeeded.',
    ),
    ('<p>The sky was n<!-- separator -->ot blue.</p>', 'The sky was not blue.'),
  ]) {
    test('review text preserves structural and inline boundaries: $markup', () {
      expect(TranslationConsistencyChecker.text(markup), expected);
      expect(
        const TranslationConsistencyChecker().riskScore(markup, []),
        greaterThan(0),
      );
      final units = SemanticSourceAnalysis.units(markup);
      expect(units.single['source'], expected);
      expect(
        units.single['focus'],
        contains(expected.contains('almost') ? 'outcome' : 'scope'),
      );
    });
  }
  test('protected review text stays excluded without mutating markup', () {
    const source =
        '<p>The sky was not<br/>blue.<sup>99</sup><code>ignored</code><span translate="no">hidden</span></p>';
    expect(TranslationConsistencyChecker.text(source), 'The sky was not blue.');
  });
  for (final (markup, expected) in [
    ('<h1>The Art<br/>of War</h1>', 'The Art of War'),
    ('<x:h1>The Art<x:br/>of War</x:h1>', 'The Art of War'),
    ('<div><h1>The Art</h1><p>of War</p></div>', 'The Art of War'),
    ('<h1>Ex<em>ample</em></h1>', 'Example'),
    (
      '<h1>The Art<span role="doc-pagebreak">12<br/>ignored</span><br/>of War</h1>',
      'The Art of War',
    ),
  ]) {
    test('navigation text preserves boundaries and markers: $markup', () {
      final node = XhtmlHtmlCompatibility.parseFragment(markup);
      final original = node.outerHtml;
      expect(navigationLabelText(node), expected);
      expect(node.outerHtml, original);
    });
  }

  for (final level in [1, 2, 3, 4, 5, 6]) {
    test(
      'h$level chapter title handles path, fragment, subtitle and later section',
      () {
        for (final suffix in [
          '',
          '<p>Body.</p><h2 id="later">Later</h2>',
          '<h6 class="subtitle" id="sub">(Subtitle)</h6><p>Body.</p><h2 id="later">Later</h2>',
        ]) {
          final c = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'c.xhtml',
            bytes: utf8.encode(
              '<html><body><h$level id="main">Main</h$level>$suffix</body></html>',
            ),
          );
          final labels = EpubRepacker().debugNavigationLabels([
            c.copyWith(
              includeInTranslation: true,
              blocks: [
                for (final b in c.blocks)
                  b.copyWith(
                    translatedHtml: b.sourceHtml
                        .replaceAll('Main', '主标题')
                        .replaceAll('(Subtitle)', '（副标题）')
                        .replaceAll('Later', '后续小节'),
                  ),
              ],
            ),
          ]);
          final title = suffix.contains('Subtitle') ? '主标题（副标题）' : '主标题';
          expect(labels['c.xhtml'], title);
          expect(labels['c.xhtml#main'], title);
          if (suffix.contains('Later')) expect(labels['c.xhtml#later'], '后续小节');
          if (suffix.contains('Subtitle')) {
            expect(labels['c.xhtml#sub'], '（副标题）');
          }
        }
      },
    );
  }
  test('lower-level title stops at the next structural container', () {
    final c = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'c.xhtml',
      bytes: utf8.encode(
        '<html><body><section><h4 id="main">Main</h4></section><section><h2 id="later">Later</h2></section></body></html>',
      ),
    );
    final labels = EpubRepacker().debugNavigationLabels([
      c.copyWith(
        includeInTranslation: true,
        blocks: [
          for (final b in c.blocks) b.copyWith(translatedHtml: b.sourceHtml),
        ],
      ),
    ]);
    expect(labels['c.xhtml'], 'Main');
    expect(labels['c.xhtml#later'], 'Later');
  });

  test('sparse batches use bounded original neighbours in source order', () {
    final long = '${List.filled(479, 'a').join()}😀tail';
    final c = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'c.xhtml',
      bytes: utf8.encode(
        '<html><body><p>One.</p><p>$long</p><p>Three.</p><p>Four.</p></body></html>',
      ),
    );
    final batches = const TranslationBatchPlanner().plan(
      pendingBlocks: [c.blocks.last, c.blocks.first],
      chapterBlocks: c.blocks,
      chapterTitle: 'Chapter',
      chunkSize: 5000,
    );
    final batch = batches.single;
    expect(batch.sourceNeighbours(c.blocks.last), {'before': 'Three.'});
    final after = batch.sourceNeighbours(c.blocks.first)['after']!;
    expect(after, List.filled(479, 'a').join());
    expect(after.codeUnits.any((u) => u >= 0xD800 && u <= 0xDFFF), isFalse);
    expect(
      batch.sourceNeighbours(c.blocks.first).containsKey('before'),
      isFalse,
    );
  });

  for (final retry in [false, true]) {
    test(
      'verification receives and accepts adjacent source on initial or sparse retry: $retry',
      () async {
        final f = fixture.Fixture();
        await f.init(blocks: 4, chunkSize: 5000);
        addTearDown(f.dispose);
        fixes.replaceStory(
          f,
          '<p>She finally agreed.</p><p>$_middle1</p><p>$_middle2</p><p>He finally refused.</p>',
        );
        _unchangedPeers(f, {'p-1', 'p-4'});
        List<dynamic> approve(List<Map<String, Object?>> items) => [
          for (final i in items)
            {
              ...i,
              'sourceQuotes': [i['id'] == 'p-1' ? _middle1 : _middle2],
            },
        ];
        f.verificationItemsOverride = retry ? (_) => [] : approve;
        final config = f.config.copyWith(
          autoApplyVerifiedCorrections: true,
          semanticReviewScope: SemanticReviewScope.all,
        );
        var result = await helpers.run(f, config: config);
        var requests = f.requests;
        if (retry) {
          expect(result.job.unreviewedBlockCount, 2);
          audit.restart(f);
          final before = f.requests.length;
          f.verificationItemsOverride = approve;
          result = await helpers.run(
            f,
            config: config.copyWith(retryIncompleteReviews: true),
          );
          requests = f.requests.skip(before).toList();
          expect(requests.map((r) => audit.payload(r)?['kind']), [
            'semanticVerification',
          ]);
        }
        final payload = requests
            .map(audit.payload)
            .whereType<Map<String, dynamic>>()
            .singleWhere((p) => p['kind'] == 'semanticVerification');
        expect(payload['relatedSourcePassages'], isEmpty);
        final rows = {for (final b in payload['blocks'] as List) b['id']: b};
        expect(rows.keys, unorderedEquals(['p-1', 'p-4']));
        expect(rows['p-1']['adjacentSource'], {'after': _middle1});
        expect(rows['p-4']['adjacentSource'], {'before': _middle2});
        expect(result.job.unreviewedBlockCount, 0);
        expect(audit.report(result)['automaticCorrections'], hasLength(2));
        await audit.checkReportBinding(result);
        audit.restart(f);
        final warm = await helpers.run(f, config: config);
        expect(warm.apiUsage['requests'], 0);
        expect(audit.report(warm)['automaticCorrections'], hasLength(2));
      },
    );
  }

  test(
    'verifier cannot approve using an unsent peer from the same batch',
    () async {
      final f = fixture.Fixture();
      await f.init(blocks: 4, chunkSize: 5000);
      addTearDown(f.dispose);
      fixes.replaceStory(
        f,
        '<p>She finally agreed.</p><p>$_middle1</p><p>$_middle2</p><p>A distant bird sang.</p>',
      );
      _unchangedPeers(f, {'p-1'});
      f.verificationItemsOverride = (items) => [
        for (final i in items)
          {
            ...i,
            'sourceQuotes': [_middle2],
          },
      ];
      final result = await helpers.run(
        f,
        config: f.config.copyWith(
          autoApplyVerifiedCorrections: true,
          semanticReviewScope: SemanticReviewScope.all,
        ),
      );
      final payload = f.requests
          .map(audit.payload)
          .whereType<Map<String, dynamic>>()
          .singleWhere((p) => p['kind'] == 'semanticVerification');
      expect(jsonEncode(payload), isNot(contains(_middle2)));
      expect(audit.report(result)['automaticCorrections'], isEmpty);
      final correction = (audit.report(result)['corrections'] as List).single;
      expect(correction['verificationFailure'], 'unsupportedEvidence');
      expect(result.job.unreviewedBlockCount, 1);
    },
  );
}
