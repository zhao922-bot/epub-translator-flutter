import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';

void main() {
  final translator = EpubChapterTranslator();
  const emoji = '\u{1f642}';
  for (final offset in [-1, 0, 1]) {
    test('preview HTML cutoff handles surrogate boundary offset $offset', () {
      const limit = 4000;
      final html = '<p>${'a' * (limit * 8 - 4 + offset)}${emoji}tail</p>';
      final result = translator.previewBodyFromBlocksForTest([
        ExtractedBlock(
          id: 'p-1',
          tagName: 'p',
          sourceHtml: html,
          sourceText: 'source',
          translatedHtml: html,
        ),
      ], fallback: 'fallback');
      expect(result, 'a' * limit);
    });
  }
  test('preview text cutoff keeps Unicode scalar intact', () {
    final html = '<p>${'a' * 3999}${emoji}tail</p>';
    final result = translator.plainTextFromHtmlForTest(html, maxChars: 4000)!;
    expect(utf8.decode(utf8.encode(result)), result);
  });
  test('supplementary CJK text is safe at both preview boundaries', () {
    for (final count in [3998, 3999, 4000]) {
      final result = translator.plainTextFromHtmlForTest(
        '<p>${'a' * count}\u{20000}tail</p>',
        maxChars: 4000,
      )!;
      expect(result.length, lessThanOrEqualTo(4000));
      expect(utf8.decode(utf8.encode(result)), result);
    }
  });
  test(
    'preview errors fall back while direct XML validation remains strict',
    () {
      const invalid = '<p>invalid\u0001</p>';
      expect(
        () => translator.plainTextFromHtmlForTest(invalid),
        throwsFormatException,
      );
      expect(
        translator.previewBodyFromBlocksForTest([
          const ExtractedBlock(
            id: 'p-1',
            tagName: 'p',
            sourceHtml: '<p>source</p>',
            sourceText: 'source',
            translatedHtml: invalid,
          ),
        ], fallback: 'source preview'),
        'source preview',
      );
    },
  );
}
