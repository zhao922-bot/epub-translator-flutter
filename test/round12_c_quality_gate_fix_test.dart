import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

const _kana = 'これはまだほんやくされていない文章です。';
const _hangul = '이 문장은 번역되지않고그대로남아있습니다.';
const _han = '東京都立中央図書館';
const _supplementaryHan = '𠀀𠀁𠀂𠀃𠀄𠀅𠀆𠀇';

const _cjkTargets = <String, List<String>>{
  'zh': ['zh', 'zh-CN', 'zh_Hant', 'Chinese (Simplified)', '中文', '汉语', '漢語'],
  'ja': ['ja', 'ja-JP', 'ja_JP', ' JAPANESE (Japan) ', '日本語', '日语', '日語'],
  'ko': ['ko', 'ko-KR', 'ko_KR', 'Korean (Korea)', '한국어', '韩语', '韓語'],
};

void _expectResidual(
  String source,
  String translated,
  String target,
  bool expected,
) {
  expect(
    TranslationQuality.hasSuspiciousSourceResidual(
      sourceText: source,
      translatedText: translated,
      targetLanguage: target,
    ),
    expected,
    reason: '$target: $translated',
  );
  expect(
    TranslationQuality.findSuspiciousFragmentResidual(
      sourceFragment: html.parseFragment('<p>$source</p>'),
      translatedFragment: html.parseFragment('<p>$translated</p>'),
      targetLanguage: target,
    )?.kind,
    expected ? TranslationResidualKind.longSourceText : null,
    reason: '$target: $translated',
  );
}

// Echo the first batch reply, then supply a translation on the individual
// fallback. This exercises the citation early return in the real validator.
class _CitationReplyApi extends TranslationApiClient {
  _CitationReplyApi(this.translatedHtml);

  final String translatedHtml;
  int calls = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    final user = (data['messages'] as List).last['content'] as String;
    final String reply;
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      reply = jsonEncode({
        'blocks': [
          for (final block in payload['blocks'] as List)
            {'id': block['id'], 'html': block['html']},
        ],
      });
    } else {
      reply = translatedHtml;
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': reply},
          },
        ],
      },
    );
  }
}

// Frozen pre-cache implementation: string equality below protects parsing,
// replacement order, Unicode matching and the exact replacement whitespace.
String _legacyStripLockedTerms(String text, String glossary) {
  if (glossary.trim().isEmpty) return text;
  final terms = <String>{};
  for (final line in glossary.split('\n')) {
    final separator = RegExp(r'=>|=').firstMatch(line);
    if (separator == null) continue;
    final source = line.substring(0, separator.start).trim();
    final target = line.substring(separator.end).trim();
    if (source.isNotEmpty && target.isNotEmpty) terms.add(source);
  }
  final ordered = terms.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final term in ordered) {
    text = text.replaceAll(
      RegExp(
        '(?<![A-Za-z0-9_\u00C0-\u02AF\u0300-\u036F])'
        '${RegExp.escape(term)}'
        '(?![A-Za-z0-9_\u00C0-\u02AF\u0300-\u036F])',
        unicode: true,
      ),
      ' ',
    );
  }
  return text;
}

void main() {
  group('P2-03 script-specific CJK residuals', () {
    for (final entry in _cjkTargets.entries) {
      test('cross-script residuals for ${entry.key} target variants', () {
        for (final target in entry.value) {
          _expectResidual(_kana, _kana, target, entry.key != 'ja');
          _expectResidual(_hangul, _hangul, target, entry.key != 'ko');
        }
      });
    }

    test('shared Han stays exempt for every CJK target variant', () {
      for (final target in _cjkTargets.values.expand((values) => values)) {
        _expectResidual(_han, _han, target, false);
        _expectResidual(_supplementaryHan, _supplementaryHan, target, false);
      }
    });

    test('script runs retain the eight-character threshold', () {
      for (final text in ['あいうえおかき', '가나다라마바사']) {
        _expectResidual(text, text, 'Chinese', false);
      }
      for (final text in ['あいうえおかきく', '가나다라마바사아']) {
        _expectResidual(text, text, 'Chinese', true);
      }
    });

    test('a translated match must also occur verbatim in the source', () {
      _expectResidual(_han, _kana, 'Chinese', false);
      _expectResidual(_han, _hangul, 'Japanese', false);
      _expectResidual(_kana, '已经完整翻译这段日语。', 'Chinese', false);
      _expectResidual(_hangul, 'ほんやくがかんりょうしました。', 'Japanese', false);
    });

    test('non-CJK targets keep the original combined-script matching', () {
      // No individual script reaches eight characters; the original union
      // does. Splitting the regex for non-CJK targets would change this.
      const mixed = '中文あい한국漢字';
      for (final target in [
        'English',
        'Spanish',
        'Russian',
        'Arabic',
        'Javanese',
        'Konkani',
        'nonjapanese',
        'nonkorean',
      ]) {
        for (final text in [_kana, _hangul, _han, _supplementaryHan, mixed]) {
          _expectResidual(text, text, target, true);
        }
      }
      _expectResidual(mixed, mixed, 'Chinese', false);
      _expectResidual(_kana, _kana, '', false);
    });
  });

  group('P2-04 non-Latin citation bodies', () {
    test(
      'letters without ASCII words are not affirmative metadata evidence',
      () {
        for (final text in [
          'Этот обычный текст должен быть переведен полностью.',
          '14. Этот обычный текст должен быть переведен полностью.',
          'هذه جملة عادية يجب ترجمتها بالكامل.',
          _kana,
          _hangul,
          _han,
          'Αυτό είναι ένα συνηθισμένο κείμενο.',
          'éàö',
          '𐐀𐐁𐐂',
        ]) {
          expect(
            TranslationQuality.isPureCitationMetadata(text),
            isFalse,
            reason: text,
          );
        }
      },
    );

    test('bare locators and established citation metadata remain exempt', () {
      for (final text in [
        '',
        '14',
        '14.',
        '（１４）',
        '١٤',
        '— …',
        'Ibid.',
        '21. Ibid.',
        '17. Fiorentini and Peltzman, op. cit., p. 15.',
        'YARDENI',
        'Yardeni, op. cit.',
        'Smith, John (1999)',
        'Leonardo da Vinci, 318',
      ]) {
        expect(
          TranslationQuality.isPureCitationMetadata(text),
          isTrue,
          reason: text,
        );
      }
    });

    for (final cssClass in ['endnotes1', 'bibliography']) {
      test(
        'Russian $cssClass prose reaches the production quality gate',
        () async {
          const source =
              '14. Этот обычный текст должен быть переведен полностью.';
          final sourceHtml = '<p class="$cssClass">$source</p>';
          final translatedHtml =
              '<p class="$cssClass">14. This ordinary note must be translated fully.</p>';
          final sourceFragment = html.parseFragment(sourceHtml);
          expect(
            TranslationQuality.findSuspiciousFragmentResidual(
              sourceFragment: sourceFragment,
              translatedFragment: html.parseFragment(sourceHtml),
              targetLanguage: 'English',
              allowBibliographicRetention: true,
            )?.kind,
            TranslationResidualKind.longSourceText,
          );
          expect(sourceFragment.text, source);

          final api = _CitationReplyApi(translatedHtml);
          final translator = EpubChapterTranslator(apiClient: api);
          final dio = Dio();
          addTearDown(() => dio.close(force: true));
          final validated = <String>[];
          final result = await translator.translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              targetLanguage: 'English',
              residualQualityCheck: true,
              styleProfileEnabled: false,
              maxRetries: 1,
            ),
            blocks: [
              ExtractedBlock(
                id: 'note-14',
                tagName: 'p',
                sourceHtml: sourceHtml,
                sourceText: source,
              ),
            ],
            onValidated: (id, value) async => validated.add(value),
          );
          expect(api.calls, 2);
          expect(result.single, translatedHtml);
          expect(validated, result);
          expect(translator.getDegradedBlockIdsForTest(), isEmpty);
        },
      );
    }
  });

  group('P3-01 cached locked glossary rules', () {
    test('cached stripping exactly matches the pre-cache implementation', () {
      const glossary = '''
machine learning => 机器学习
learning=学习
entitlement=>权利
entitlement=另一译法
C++=>语言
a.b=点号
[tag]=标签
école=学校
Cafe\u0301=咖啡馆
𠀀术语=>术语
a-b=甲
b-c=>乙
key=target=extra
free text grants no exemption
=>empty source
missing target=>
''';
      const texts = [
        'machine learning and learning entitlement概念',
        'entitlements _entitlement entitlement2 éentitlement entitlement\u0301',
        'entitlementX Xentitlement 权利 -entitlement- entitlement한글',
        'C++ C++++ a.b xa.by [tag] école Cafe\u0301 𠀀术语',
        'a-b-c key free text missing target',
        '  entitlement\n\tentitlement  ',
        '\uD800entitlement\uDC00',
      ];
      for (final rules in [glossary, '', ' \n\t', 'entitlement=>', '=>权利']) {
        for (final text in texts) {
          expect(
            TranslationQuality.stripLockedTermsForTest(text, rules),
            _legacyStripLockedTerms(text, rules),
            reason: '$rules: $text',
          );
        }
      }
      expect(
        TranslationQuality.stripLockedTermsForTest('entitlement概念', glossary),
        ' 概念',
      );
      expect(
        TranslationQuality.stripLockedTermsForTest('entitlements', glossary),
        'entitlements',
      );
    });

    test(
      'equal glossary content reuses compiled rules and edits use a new key',
      () {
        const glossary = 'cache-key-term=>甲\ncache-key-term=乙';
        final rules = TranslationQuality.lockedTermRulesForTest(glossary);
        expect(rules, hasLength(1));
        expect(rules.single.isUnicode, isTrue);
        expect(
          TranslationQuality.lockedTermRulesForTest(
            ['cache-key-term=>甲', 'cache-key-term=乙'].join('\n'),
          ),
          same(rules),
        );
        expect(
          TranslationQuality.lockedTermRulesForTest('cache-key-term=>丙'),
          isNot(same(rules)),
        );
        expect(
          TranslationQuality.stripLockedTermsForTest('other概念', 'other=>别的'),
          ' 概念',
        );
        expect(
          TranslationQuality.stripLockedTermsForTest('other概念', glossary),
          'other概念',
        );
      },
    );

    test(
      'eight newer glossary entries evict the oldest without changing output',
      () {
        const oldest = 'eviction-anchor=>甲';
        final oldestRules = TranslationQuality.lockedTermRulesForTest(oldest);
        var newest = oldest;
        var newestRules = oldestRules;
        for (var index = 0; index < 8; index++) {
          newest = 'eviction-term-$index=>术语';
          newestRules = TranslationQuality.lockedTermRulesForTest(newest);
        }
        expect(
          TranslationQuality.lockedTermRulesForTest(oldest),
          isNot(same(oldestRules)),
        );
        expect(
          TranslationQuality.lockedTermRulesForTest(newest),
          same(newestRules),
        );
        expect(
          TranslationQuality.stripLockedTermsForTest(
            'eviction-anchor概念',
            oldest,
          ),
          _legacyStripLockedTerms('eviction-anchor概念', oldest),
        );
      },
    );

    test('50 terms across 200 nodes and five rounds preserve exact output', () {
      final glossary = [
        for (var index = 0; index < 50; index++) 'locked-term$index=>词$index',
      ].join('\n');
      final nodes = [
        for (var index = 0; index < 200; index++)
          'locked-term${index % 50} / locked-term${(index + 1) % 50} / 正文',
      ];
      final rules = TranslationQuality.lockedTermRulesForTest(glossary);
      // Warm up both paths. Timing is informational; cache identity is the
      // deterministic assertion that repeated preparation has been removed.
      _legacyStripLockedTerms(nodes.first, glossary);
      TranslationQuality.stripLockedTermsForTest(nodes.first, glossary);
      final legacyMicros = <int>[];
      final cachedMicros = <int>[];
      for (var round = 0; round < 5; round++) {
        final legacyTimer = Stopwatch()..start();
        final expected = [
          for (final node in nodes) _legacyStripLockedTerms(node, glossary),
        ];
        legacyTimer.stop();
        legacyMicros.add(legacyTimer.elapsedMicroseconds);
        final cachedTimer = Stopwatch()..start();
        final actual = [
          for (final node in nodes)
            TranslationQuality.stripLockedTermsForTest(node, glossary),
        ];
        cachedTimer.stop();
        cachedMicros.add(cachedTimer.elapsedMicroseconds);
        expect(actual, expected);
        expect(
          TranslationQuality.lockedTermRulesForTest(glossary),
          same(rules),
        );
      }
      expect(
        Duration(microseconds: cachedMicros.reduce((a, b) => a + b)),
        lessThan(const Duration(seconds: 10)),
      );
      legacyMicros.sort();
      cachedMicros.sort();
      debugPrint(
        'P3-01 median: legacy ${legacyMicros[2] / 1000} ms, '
        'cached ${cachedMicros[2] / 1000} ms (50 terms, 200 nodes).',
      );

      final source = html.parseFragment(
        '<p>${[for (final node in nodes) '<span>$node</span>'].join(' ')}</p>',
      );
      final translated = source.clone(true);
      final original = source.outerHtml;
      expect(
        TranslationQuality.findSuspiciousFragmentResidual(
          sourceFragment: source,
          translatedFragment: translated,
          targetLanguage: 'Chinese',
          lockedGlossary: glossary,
        ),
        isNull,
      );
      expect(TranslationQuality.lockedTermRulesForTest(glossary), same(rules));
      expect(source.outerHtml, original);
      expect(translated.outerHtml, original);
    });
  });
}
