import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for redundant-whitespace collapsing in translated HTML.
///
/// Found during the 2026-10-05 live test (SiliconFlow DeepSeek-V4-Flash,
/// Project Gutenberg "The Yellow Wallpaper"): the model emitted runs of
/// multiple spaces (e.g. "限制。     您可以"), which renderers collapse
/// visually but which litter the EPUB source. The repack step now collapses
/// ASCII whitespace runs to a single space, leaving `<pre>` and non-breaking
/// spaces untouched.
void main() {
  InspectedChapter singleBlockChapter(String translatedHtml) {
    return InspectedChapter(
      path: 'OEBPS/test.html',
      title: 'Test',
      body: '',
      originalHtml: '<html><body><p>Original.</p></body></html>',
      blocks: <ExtractedBlock>[
        ExtractedBlock(
          id: 'p-1',
          tagName: 'p',
          sourceHtml: '<p>Original.</p>',
          sourceText: 'Original.',
          translatedHtml: translatedHtml,
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );
  }

  test('multiple spaces collapse to one in translated text', () {
    final String output = EpubRepacker().renderTranslatedChapter(
      chapter: singleBlockChapter('<p>限制。     您可以&#160;&#160;继续。</p>'),
      bilingual: false,
    );
    // ASCII runs collapse; the two non-breaking spaces survive.
    expect(output, contains('限制。 您可以'));
    expect(output.contains('限制。     您可以'), isFalse);
    expect(output, contains('&#160;&#160;'));
  });

  test('whitespace inside pre is preserved', () {
    final String output = EpubRepacker().renderTranslatedChapter(
      chapter: singleBlockChapter('<pre>line1\nline2    indented</pre>'),
      bilingual: false,
    );
    expect(output, contains('line2    indented'));
  });
}
