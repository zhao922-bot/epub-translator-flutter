import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_artifact_cache.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:xml/xml.dart';

const ns = 'http://www.w3.org/1999/xhtml';

Future<void> runProbe({
  required String source,
  required String draft,
  required String before,
  required String after,
  required String quote,
  String tag = 'p',
  bool risksOnly = false,
  bool verify = true,
  bool verifierApproves = true,
  bool applied = true,
  bool oldReview = false,
}) async {
  final dir = await Directory.systemTemp.createTemp('offline-audit-');
  addTearDown(() => dir.delete(recursive: true));
  final calls = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final user = (data['messages'] as List).last['content'] as String;
    final payload = jsonDecode(user) as Map;
    final kind = payload['kind'] as String? ?? 'translation';
    calls.add(kind);
    final blocks = payload['blocks'] as List;
    final output = {
      'blocks': [
        for (final b in blocks)
          switch (kind) {
            'semanticSourceAnalysis' => {
              'id': b['id'],
              'units': [
                for (final u in b['units'])
                  {
                    'id': u['id'],
                    'meaning':
                        'The source explicitly states the described situation.',
                    for (final key
                        in (u['focus'] as String)
                            .split(',')
                            .where((s) => s.isNotEmpty))
                      key: key == 'sense'
                          ? 'Functional meaning of ${u['senseTerms']} in context.'
                          : 'The source explicitly establishes the $key meaning.',
                    'referenceNumber': 'singular',
                  },
              ],
            },
            'semanticDraftAnalysis' => {
              'id': b['id'],
              'meaning': 'The draft expresses the opposite condition.',
            },
            'semanticReview' || 'semanticReviewRepair' => {
              'id': b['id'],
              'edits': [
                {'before': before, 'after': after},
              ],
              'category': 'accuracy',
              'confidence': 'high',
              'sourceQuotes': [quote],
              'issues': [
                'Correct the condition explicitly described by the source.',
              ],
              'coverage': [
                for (final u in b['sourceAnalysis'])
                  {
                    'id': u['id'],
                    'verdict': 'mismatch',
                    'targetQuote': b['draftText'],
                    'reason':
                        'The source and target assert different conditions.',
                    'backMeaning':
                        'The draft expresses the opposite condition.',
                    'referenceNumber': 'singular',
                    'referenceQuote': '她',
                  },
              ],
            },
            'semanticVerification' => {
              'id': b['id'],
              'approve': verifierApproves,
              'confidence': 'high',
              'sourceQuotes': [quote],
              'reason': 'The correction restores the condition in the source.',
            },
            'semanticEquivalence' => {
              'id': b['id'],
              'sourceImpliesDraft': false,
              'draftImpliesSource': false,
              'reason': 'The conditions contradict each other.',
            },
            _ => {'id': b['id'], 'html': draft},
          },
      ],
    };
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': jsonEncode(output)},
          },
        ],
      }),
    );
    await request.response.close();
  });
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'http://127.0.0.1:${server.port}/v1',
    apiKey: 'offline-fixture-only',
    model: 'offline-fixture',
    targetLanguage: 'Chinese',
    maxConcurrent: 1,
    maxRetries: 0,
    residualQualityCheck: false,
    semanticQualityCheck: true,
    autoApplyVerifiedCorrections: true,
    semanticReviewScope: risksOnly
        ? SemanticReviewScope.risksOnly
        : SemanticReviewScope.all,
    maxSemanticReviewRequests: 8,
    maxSemanticReviewTokens: 200000,
    styleProfileEnabled: false,
  );
  final dio = const TranslationApiClient().buildDio(config);
  addTearDown(() => dio.close(force: true));
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'c.xhtml',
    bytes: utf8.encode(
      '<html xmlns="$ns"><head><title>Book</title></head><body>${tag == 'p' ? source : '<table>${tag == 'caption' ? source : '<tr>$source</tr>'}</table>'}</body></html>',
    ),
  );
  final cache = TranslationCacheStore(
    cacheRoot: Directory('${dir.path}/cache'),
  );
  final translator = EpubChapterTranslator(cacheStore: cache);
  if (oldReview) {
    final block = chapter.blocks.single;
    final artifact = TranslationArtifactCache(cache);
    // Mimic an existing paid draft plus a v12 failure. Updating the review
    // protocol must re-audit it without re-translating the source.
    await artifact.write(
      TranslationArtifactCache.key(config, 'semantic-draft-v4', [
        '',
        chapter.path,
        block.id,
        block.sourceHtml,
        null,
        true,
      ]),
      {'html': draft},
    );
    await artifact.write(
      TranslationArtifactCache.key(config, 'semantic-suggestions-v12', [
        '',
        chapter.path,
        block.id,
        block.sourceHtml,
        draft,
        config.semanticReviewScope.name,
        true,
      ]),
      {'status': 'needsAttention', 'reason': 'invalidHtml'},
    );
  }
  final result = await translator.translateBlockBatchForTest(
    dio: dio,
    config: config,
    blocks: chapter.blocks,
    chapterPath: chapter.path,
  );
  expect(result.single, applied ? contains(after) : contains(before));
  expect(
    calls.where((k) => k == 'semanticVerification'),
    hasLength(verify ? 1 : 0),
  );
  if (oldReview) expect(calls, isNot(contains('translation')));
  final callsBefore = calls.length;
  final warm = await EpubChapterTranslator(cacheStore: cache)
      .translateBlockBatchForTest(
        dio: dio,
        config: config,
        blocks: chapter.blocks,
        chapterPath: chapter.path,
      );
  expect(warm, result);
  expect(
    calls.length,
    callsBefore,
    reason:
        'Validated drafts and review states must survive restart without another request.',
  );
  for (final bilingual in [false, true]) {
    final rendered = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        includeInTranslation: true,
        blocks: [chapter.blocks.single.copyWith(translatedHtml: result.single)],
      ),
      bilingual: bilingual,
    );
    final xml = XmlDocument.parse(rendered);
    expect(xml.rootElement.namespaceUri, ns);
    expect(xml.rootElement.innerText, contains(applied ? after : before));
    if (tag != 'p') {
      final structural = xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == tag,
      );
      expect(
        structural,
        hasLength(1),
        reason:
            'Bilingual translation must not add another table cell or caption.',
      );
      expect(structural.single.getAttribute('id'), 'cell');
    }
  }
}

void main() {
  for (final prefix in ['', 'x:']) {
    test(
      'risks-only review treats prefix $prefix equivalently',
      () => runProbe(
        risksOnly: true,
        source:
            '<${prefix}p xmlns:x="$ns">The sky was <${prefix}em>blue</${prefix}em>.</${prefix}p>',
        draft:
            '<${prefix}p xmlns:x="$ns">天空是<${prefix}em>红色</${prefix}em>的。</${prefix}p>',
        before: '红色',
        after: '蓝色',
        quote: 'blue',
      ),
    );
  }
  for (final tag in ['p', 'td', 'th', 'caption']) {
    test(
      'end-to-end $tag inline correction reaches verifier',
      () => runProbe(
        tag: tag,
        source: '<$tag id="cell">The sky was <em>blue</em>.</$tag>',
        draft: '<$tag id="cell">天空是<em>红色</em>的。</$tag>',
        before: '红色',
        after: '蓝色',
        quote: 'blue',
      ),
    );
  }
  for (final adverb in ['非常', '十分']) {
    test(
      'end-to-end degree adverb $adverb is not a numerical claim',
      () => runProbe(
        source: '<p>She was very happy.</p>',
        draft: '<p>她不开心。</p>',
        before: '不开心',
        after: '$adverb开心',
        quote: 'very happy',
      ),
    );
  }
  test(
    'old failed table review reuses draft and retries only review',
    () => runProbe(
      tag: 'td',
      oldReview: true,
      source: '<td id="cell">The sky was <em>blue</em>.</td>',
      draft: '<td id="cell">天空是<em>红色</em>的。</td>',
      before: '红色',
      after: '蓝色',
      quote: 'blue',
    ),
  );
  test(
    'ambiguous numeral wording still requires verifier approval',
    () => runProbe(
      source: '<p>She was very happy.</p>',
      draft: '<p>她不开心。</p>',
      before: '不开心',
      after: '十分开心',
      quote: 'very happy',
      verifierApproves: false,
      applied: false,
    ),
  );
  for (final amount in ['987', '九百八十七']) {
    test(
      'unsupported quantity $amount cannot bypass the numeric gate',
      () => runProbe(
        source: '<p>She was very happy.</p>',
        draft: '<p>她不开心。</p>',
        before: '不开心',
        after: '开心地笑了$amount次',
        quote: 'very happy',
        verify: false,
        applied: false,
      ),
    );
  }
  test('namespaced emphasis has the same risk score as plain emphasis', () {
    const c = TranslationConsistencyChecker();
    final ordinary = c.riskScore('<p>The sky was <em>blue</em>.</p>', []);
    final prefixed = c.riskScore(
      '<x:p xmlns:x="$ns">The sky was <x:em>blue</x:em>.</x:p>',
      [],
    );
    expect(prefixed, ordinary);
  });
  for (final sample in [
    ('<p>She agreed with him.</p>', '<p>她不同意。</p>', '<p>她与他意见一致。</p>'),
    ('<p>Just in case it rains.</p>', '<p>等下雨。</p>', '<p>以防万一下雨。</p>'),
  ]) {
    test('idiomatic numbers are not newly introduced claims: ${sample.$3}', () {
      final introduced = TranslationConsistencyChecker.introducedNumbers(
        sourceHtml: sample.$1,
        beforeHtml: sample.$2,
        afterHtml: sample.$3,
      );
      expect(introduced, isEmpty);
    });
  }
}
