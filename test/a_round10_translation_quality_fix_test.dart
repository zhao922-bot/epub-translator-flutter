import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

TranslationResidualFinding? check(
  String source,
  String translated, {
  String target = 'Chinese',
  String lockedGlossary = '',
}) => TranslationQuality.findSuspiciousHtmlResidual(
  sourceHtml: '<p>$source</p>',
  translatedHtml: '<p>$translated</p>',
  targetLanguage: target,
  lockedGlossary: lockedGlossary,
);

void main() {
  test('A-P2-17 five-word lowercase leak cannot use low source coverage', () {
    expect(
      check(
        'At dawn the workers returned home before the storm reached town.',
        '黎明时分 the workers returned home before 暴风雨抵达。',
      )?.kind,
      TranslationResidualKind.longSourceText,
    );
  });

  test('A-P2-17 four-word technical phrase and explicit gloss stay valid', () {
    expect(
      check(
        'The system improves large language model inference.',
        '系统改进了 large language model inference。',
      ),
      isNull,
    );
    expect(
      check(
        'They studied the mean time between system failures today.',
        '他们研究了系统平均故障间隔（mean time between system failures）。',
      ),
      isNull,
    );
  });

  for (final phrase in [
    'do not enter',
    'please wait here',
    'we are ready',
    'stop now！',
  ]) {
    test('A-P2-18 sentence before lowercase-term exemption: $phrase', () {
      expect(
        check(phrase, phrase)?.kind,
        TranslationResidualKind.longSourceText,
      );
    });
  }

  test('A-P2-18 genuine lowercase transliteration stays valid', () {
    expect(check('chum yum', 'chum yum'), isNull);
  });

  test('A-P2-19 Title Case heading is not citation metadata', () {
    expect(
      TranslationQuality.isPureCitationMetadata('The Future of Human Society'),
      isFalse,
    );
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<li>The Future of Human Society</li>',
        translatedHtml: '<li>The Future of Human Society</li>',
        targetLanguage: 'Chinese',
        allowBibliographicRetention: true,
      ),
      isNotNull,
    );
  });

  test(
    'A-P2-19 author/year, locators and cross-references remain metadata',
    () {
      for (final value in [
        'Smith, John (1999)',
        'Leonardo da Vinci, 318',
        'Journal of History, vol. 2',
        'YARDENI',
        'Ibid.',
        'Yardeni, op. cit.',
      ]) {
        expect(
          TranslationQuality.isPureCitationMetadata(value),
          isTrue,
          reason: value,
        );
      }
    },
  );

  test('A-P2-20 language codes do not match inside ordinary words', () {
    for (final value in [
      'Norwegian',
      'Javanese',
      'Konkani',
      'Aromanian',
      'sugar',
      'nonchinese',
    ]) {
      expect(
        TranslationQuality.shouldCheckResidual(value),
        isFalse,
        reason: value,
      );
    }
  });

  test('A-P2-20 language names and locale codes remain supported', () {
    for (final value in [
      'Chinese (Simplified)',
      '中文',
      '日本語',
      '한국어',
      'zh_Hans',
      'ja-JP',
      'ko_KR',
      'ru-RU',
      'ar_SA',
      'Russian',
      'Arabic',
    ]) {
      expect(
        TranslationQuality.shouldCheckResidual(value),
        isTrue,
        reason: value,
      );
    }
  });

  test(
    'A-P2-21 Chinese source retained in English is detected in text and HTML',
    () {
      const source = '这是一段应该完整翻译的中文原文';
      expect(
        TranslationQuality.hasSuspiciousSourceResidual(
          sourceText: source,
          translatedText: 'Translated: $source',
          targetLanguage: 'English',
        ),
        isTrue,
      );
      expect(
        check(source, 'Translated: $source', target: 'English')?.kind,
        TranslationResidualKind.longSourceText,
      );
    },
  );

  test(
    'A-P2-21 translated content, short names and shared Han are not leaks',
    () {
      expect(
        check(
          '这是一段应该完整翻译的中文原文',
          'This paragraph is fully translated.',
          target: 'English',
        ),
        isNull,
      );
      expect(
        check('北京是中国的首都', '北京 is the capital.', target: 'English'),
        isNull,
      );
      expect(check('这是已经完成翻译的中文段落', '这是已经完成翻译的中文段落'), isNull);
      expect(check('東京都立中央図書館', '東京都立中央図書館', target: 'Japanese'), isNull);
    },
  );

  test('A-P2-21 source-owned non-prose remains exempt for English target', () {
    expect(
      check(
        '<code>这是一段应该完整保留的中文代码</code>',
        '<code>这是一段应该完整保留的中文代码</code>',
        target: 'English',
      ),
      isNull,
    );
  });

  test('A-P2-22 config lock exempts retained source term', () {
    final config = TranslationConfig.defaults().copyWith(
      lockedGlossary: 'entitlement => 权利',
    );
    const source = 'The concept of entitlement changes.';
    const translated = 'entitlement概念改变。';
    expect(check(source, translated), isNotNull);
    expect(
      check(source, translated, lockedGlossary: config.lockedGlossary),
      isNull,
    );
  });

  test('A-P2-22 fragment checks accept locks without mutating caller DOM', () {
    final source = html.parseFragment(
      '<p>The concept of entitlement changes.</p>',
    );
    final translated = html.parseFragment('<p>entitlement概念改变。</p>');
    expect(
      TranslationQuality.findSuspiciousFragmentResidual(
        sourceFragment: source,
        translatedFragment: translated,
        targetLanguage: 'Chinese',
        lockedGlossary: 'entitlement=权利',
      ),
      isNull,
    );
    expect(translated.text, contains('entitlement'));
    expect(source.text, contains('entitlement'));
  });

  test('A-P2-22 locks preserve boundaries and do not exempt other leaks', () {
    expect(
      check(
        'The entitlements change.',
        'entitlements改变。',
        lockedGlossary: 'entitlement => 权利',
      ),
      isNotNull,
    );
    expect(
      check(
        'The entitlement remains important.',
        'entitlement仍然important。',
        lockedGlossary: 'entitlement => 权利',
      )?.token,
      'important',
    );
    expect(
      check(
        'The entitlement changes.',
        'entitlement改变。',
        lockedGlossary: 'entitlement =>',
      ),
      isNotNull,
    );
  });

  test(
    'A-PERF-3 rune adjacency handles supplementary and malformed UTF-16',
    () {
      expect(
        check('The entitlement changes.', 'entitlement𠀀')?.token,
        'entitlement',
      );
      expect(
        check('The entitlement changes.', '𠀀entitlement')?.token,
        'entitlement',
      );
      expect(check('The entitlement changes.', 'entitlement\uD800'), isNull);
      expect(check('The entitlement changes.', 'entitlement'), isNull);
    },
  );

  test('A-PERF-4 repeated open quotes with CJK complete quickly', () {
    final text = '${'“中' * 20000}agoric';
    final timer = Stopwatch()..start();
    expect(TranslationQuality.glossedTermTokenStartsForTest(text), isEmpty);
    timer.stop();
    expect(timer.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('A-PERF-4 normal quoted glosses retain exact token offsets', () {
    const text = '所谓“agoric开放系统”和「中文assarting」';
    expect(TranslationQuality.glossedTermTokenStartsForTest(text), {
      text.indexOf('agoric'),
      text.indexOf('assarting'),
    });
    expect(
      check('They described agoric systems.', '他们描述“agoric开放系统”。'),
      isNull,
    );
  });

  test('A-PERF-5 multiple titles and nested wrappers retain local context', () {
    expect(
      check(
        'Read <span><i>A Brief History of Time</i></span> and '
            'the book <i>The Shape of Things Yet to Come</i>.',
        '阅读<span><i>A Brief History of Time</i></span>以及'
            '<i>The Shape of Things Yet to Come</i>。',
      ),
      isNull,
    );
  });

  test(
    'A-PERF-5 title context does not exempt an instruction in the block',
    () {
      expect(
        check(
          'Read <i>A Brief History of Time</i>. <em>Please Read This</em>',
          '阅读<i>A Brief History of Time</i>。<em>Please Read This</em>',
        ),
        isNotNull,
      );
    },
  );
}
