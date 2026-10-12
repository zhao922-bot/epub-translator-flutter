import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

/// C-30: style instruction building must normalize the target language once
/// and reuse the result, instead of each sub-builder normalizing
/// [TranslationConfig.targetLanguage] independently on every batch.
void main() {
  group('C-30 target language normalization reuse', () {
    TranslationConfig configFor(String targetLanguage) =>
        TranslationConfig.defaults().copyWith(targetLanguage: targetLanguage);

    test('fragment composes the three sub-builders unchanged', () {
      // styleProfileEnabled defaults to false in test configs, so the
      // profile part is empty; the fragment must equal gloss + second-person.
      final config = configFor('Chinese');
      final String fragment =
          EpubChapterTranslator.styleInstructionFragmentForTest(
            config: config,
          );
      final String expected =
          EpubChapterTranslator.terminologyGlossInstructionForTest(
            config: config,
          ) +
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
            config: config,
          );
      expect(fragment, expected);
      expect(fragment, isNotEmpty);
    });

    test('gating preserved per language', () {
      final String zh =
          EpubChapterTranslator.styleInstructionFragmentForTest(
            config: configFor('中文'),
          );
      // Terminology gloss (CJK) and second-person (Chinese-only) both apply.
      expect(zh, contains('assarting'));
      expect(zh, contains('您'));

      final String ja =
          EpubChapterTranslator.styleInstructionFragmentForTest(
            config: configFor('日本語'),
          );
      // Japanese is CJK: gloss applies, second-person does not.
      expect(ja, contains('assarting'));
      expect(ja, isNot(contains('您')));

      final String en =
          EpubChapterTranslator.styleInstructionFragmentForTest(
            config: configFor('English'),
          );
      expect(en, isEmpty);
    });

    test('builders honor the pre-normalized value instead of re-normalizing',
        () {
      // If the builders ignored the passed value and re-normalized
      // config.targetLanguage themselves, these would flip.
      final String glossWithEnOverride =
          EpubChapterTranslator.terminologyGlossInstructionForTest(
            config: configFor('Chinese'),
            normalizedTargetLanguage: 'en',
          );
      expect(
        glossWithEnOverride,
        isEmpty,
        reason: 'pre-normalized "en" must win over the Chinese config',
      );

      final String secondPersonWithZhOverride =
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
            config: configFor('English'),
            normalizedTargetLanguage: 'zh',
          );
      expect(
        secondPersonWithZhOverride,
        contains('您'),
        reason: 'pre-normalized "zh" must win over the English config',
      );
    });

    test('standalone builders still normalize when no override is given', () {
      // Backward compatibility for the existing test hook call shape.
      expect(
        EpubChapterTranslator.terminologyGlossInstructionForTest(
          config: configFor('Korean'),
        ),
        contains('assarting'),
      );
      expect(
        EpubChapterTranslator.terminologyGlossInstructionForTest(
          config: configFor('French'),
        ),
        isEmpty,
      );
    });
  });
}
