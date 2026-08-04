import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranslationStyleProfile prompt sanitization', () {
    const TranslationStyleProfile profile = TranslationStyleProfile(
      primaryGenre: 'business nonfiction',
      tone: 'analytical',
      translationConstraints: <String>[
        'Keep all embedded English quotations in English with Chinese attribution',
        'Preserve proper nouns exactly',
        'Translate quoted epigraphs faithfully; preserve the original English when a quote is short and well-known',
      ],
      avoid: <String>[
        'Avoid softening the polemical edge',
        'Keep dialogue in English when it sounds better',
      ],
      confidence: TranslationStyleConfidence.high,
    );

    test('strips English-quote retention rules for Chinese targets', () {
      final String instruction = profile.toConfirmedPromptInstruction(
        targetLanguage: 'Chinese',
      );

      expect(instruction, isNotEmpty);
      expect(instruction, contains('Genre: business nonfiction'));
      expect(instruction, contains('Preserve proper nouns exactly'));
      expect(instruction, isNot(contains('Keep all embedded English quotations')));
      expect(instruction, isNot(contains('preserve the original English')));
      expect(instruction, isNot(contains('Keep dialogue in English')));
      expect(
        instruction,
        contains(
          'Quoted prose, dialogue, and epigraphs must be translated into Chinese',
        ),
      );
      expect(
        instruction,
        contains(
          'keep only proper names, work titles, URLs, and short technical terms',
        ),
      );
    });

    test('keeps English-quote rules only for English targets', () {
      final String instruction = profile.toConfirmedPromptInstruction(
        targetLanguage: 'English',
      );

      expect(instruction, contains('Keep all embedded English quotations'));
      expect(
        instruction,
        isNot(
          contains(
            'Quoted prose, dialogue, and epigraphs must be translated into English',
          ),
        ),
      );
    });

    test('sanitizes stored constraints without rewriting the profile object', () {
      final TranslationStyleProfile sanitized = profile.forTargetLanguage(
        '中文',
      );

      expect(
        sanitized.translationConstraints,
        <String>[
          'Quoted prose, dialogue, and epigraphs must be translated into 中文; keep only proper names, work titles, URLs, and short technical terms in the source language',
          'Preserve proper nouns exactly',
        ],
      );
      expect(
        sanitized.avoid,
        <String>['Avoid softening the polemical edge'],
      );
      expect(profile.translationConstraints, hasLength(3));
    });
  });
}
