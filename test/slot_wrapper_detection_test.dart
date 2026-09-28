import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the protected-slot wrapper detector: a comparison
/// like "a < b > c" is plain text, not markup, and must not be flagged —
/// flagging it threw a retryable FormatException that the nested retry
/// layers amplified into maxRetries² paid retries.
void main() {
  group('slotTranslationHasWrapperTag', () {
    test('ignores comparisons with spaces around angle brackets', () {
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('a < b > c'),
        isFalse,
      );
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('5 < 10'),
        isFalse,
      );
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('见第三章 < 附录'),
        isFalse,
      );
    });

    test('still detects real tag opens', () {
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('<p>译文</p>'),
        isTrue,
      );
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('</p>'),
        isTrue,
      );
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('x<br/>y'),
        isTrue,
      );
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('<!DOCTYPE html>'),
        isTrue,
      );
    });

    test('ignores a bare less-than without a tag shape', () {
      expect(
        EpubChapterTranslator.slotTranslationHasWrapperTag('a<b'),
        isFalse,
      );
      expect(EpubChapterTranslator.slotTranslationHasWrapperTag('<3'), isFalse);
    });
  });
}
