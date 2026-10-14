import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void _expectQuality(String source, String translated, bool residual) {
  expect(
    TranslationQuality.hasSuspiciousSourceResidual(
      sourceText: source,
      translatedText: translated,
      targetLanguage: 'Chinese',
    ),
    residual,
  );
  expect(
    TranslationQuality.findSuspiciousHtmlResidual(
      sourceHtml: '<p>$source</p>',
      translatedHtml: '<p>$translated</p>',
      targetLanguage: 'Chinese',
    )?.kind,
    residual ? TranslationResidualKind.longSourceText : null,
  );
}

void main() {
  test('P2-02 装饰线边界样本的新旧判定一致性验证', () {
    const decoration = '・・・・・・・・';
    // The former range-only matcher counts punctuation as kana evidence.
    expect(
      RegExp(r'[\u3040-\u30FF]{8,}', unicode: true).hasMatch(decoration),
      isTrue,
    );
    _expectQuality(
      'He paused. $decoration Then he continued.',
      '他停了下来。$decoration随后继续。',
      false,
    );
  });

  test('P2-02 标点、符号及组合标记边界样本一致性验证', () {
    for (final character in [
      '・',
      '゠',
      '゛',
      '゜',
      '\u3099',
      '\u309A',
      '\u3000',
    ]) {
      expect(RegExp(r'\p{L}', unicode: true).hasMatch(character), isFalse);
      final decoration = character * 8;
      _expectQuality(
        'He paused. $decoration Then he continued.',
        '他停了下来。$decoration随后继续。',
        false,
      );
    }
    _expectQuality('あいうえおかき・', 'あいうえおかき・', false);
  });

  test('P2-02 连续假名正文边界样本一致性验证', () {
    const source = 'これはまだほんやくされていない文章です。';
    _expectQuality(source, source, true);
    _expectQuality('あいうえおかきく', 'あいうえおかきく', true);
  });
}
