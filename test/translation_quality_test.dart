import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enables residual checks for CJK and similar targets', () {
    expect(TranslationQuality.shouldCheckResidual('Chinese'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('日本語'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('Korean'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('English'), isFalse);
  });

  test('flags long English residuals in Chinese translations', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'Once upon a time there was a long English sentence that should be translated carefully.',
        translatedText:
            'Once upon a time there was a long English sentence that should be translated carefully.',
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });

  test('allows Chinese labels followed by preserved English proper names', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'Book design by Ralph Fowler. Graphics by Rodrigo Corral Design. Illustrations by Matt Buck. Cover design by Michael Nagin.',
        translatedText:
            '书籍设计：Ralph Fowler；图形设计：Rodrigo Corral Design；插图：Matt Buck；封面设计：Michael Nagin。',
        targetLanguage: 'Chinese',
      ),
      isFalse,
    );
  });

  test('still flags a long English sentence after a short Chinese prefix', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'This entire sentence should have been translated into Chinese but was left in English.',
        translatedText:
            '译文：This entire sentence should have been translated into Chinese but was left in English.',
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });
}
