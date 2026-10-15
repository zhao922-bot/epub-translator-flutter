import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Readers decide whether spaces collapse using the book's CSS. Repacking
/// cannot remove them safely: external or inherited styles may preserve them.
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

  test('ASCII and non-breaking spaces survive for reader CSS processing', () {
    final String output = EpubRepacker().renderTranslatedChapter(
      chapter: singleBlockChapter('<p>限制。     您可以&#160;&#160;继续。</p>'),
      bilingual: false,
    );
    expect(output, contains('限制。     您可以'));
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
