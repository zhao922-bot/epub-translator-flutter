import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chineseSecondPersonInstruction', () {
    test('Chinese target gets the judgment-based instruction', () {
      final String instruction =
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
            config: TranslationConfig.defaults().copyWith(
              targetLanguage: 'Chinese',
            ),
          );
      // Judgment-based, not a blanket rule: both forms must be mentioned with
      // guidance on when to use each.
      expect(instruction, contains('您'));
      expect(instruction, contains('你'));
      expect(instruction, contains('strangers'));
      expect(instruction, contains('family'));
      // Must not be the old blanket rule.
      expect(instruction, isNot(contains('never 你')));
      expect(instruction, isNot(contains('always use 您')));
    });

    test('non-Chinese targets get no instruction', () {
      for (final String language in <String>['English', 'Japanese', 'French']) {
        final String instruction =
            EpubChapterTranslator.chineseSecondPersonInstructionForTest(
              config: TranslationConfig.defaults().copyWith(
                targetLanguage: language,
              ),
            );
        expect(instruction, isEmpty, reason: language);
      }
    });

    test('Traditional Chinese variants also get the instruction', () {
      final String instruction =
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
            config: TranslationConfig.defaults().copyWith(targetLanguage: '中文'),
          );
      expect(instruction, isNotEmpty);
      expect(instruction, contains('您'));
    });
  });

  group('idiomaticTranslationInstruction', () {
    test('instructs meaning-based translation, not word-for-word', () {
      final String instruction =
          EpubChapterTranslator.idiomaticTranslationInstructionForTest();
      expect(instruction, contains('Translate meaning, not words'));
      expect(instruction, contains('idioms'));
      expect(instruction, contains('Never translate them word for word'));
    });
  });
}
