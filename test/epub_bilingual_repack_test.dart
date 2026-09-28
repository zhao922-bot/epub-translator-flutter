import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

InspectedChapter _chapter({
  required String path,
  required String originalHtml,
  required List<ExtractedBlock> blocks,
}) {
  return InspectedChapter(
    path: path,
    title: 'chapter',
    body: 'chapter',
    originalHtml: originalHtml,
    blocks: blocks,
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );
}

void main() {
  group('bilingual repack', () {
    test('table cell translation keeps its td wrapper', () {
      const String source =
          '<html><body><table><tr>'
          '<td class="line"><p>Cell one</p></td>'
          '</tr></table></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'td-1',
              tagName: 'td',
              sourceHtml: '<td class="line"><p>Cell one</p></td>',
              sourceText: 'Cell one',
              translatedHtml: '<p>单元格一</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      final List<dom.Element> rows = document.querySelectorAll('tr');
      expect(rows, hasLength(1));
      final dom.Element row = rows.first;
      // No bare translation text directly under <tr>: the translation must
      // live inside the original <td>, preserving the table grid.
      final Iterable<dom.Text> bareText = row.nodes.whereType<dom.Text>().where(
        (dom.Text node) => node.text.trim().isNotEmpty,
      );
      expect(bareText, isEmpty);
      final List<dom.Element> cells = row.querySelectorAll('td');
      expect(cells, hasLength(1));
      expect(cells[0].text, contains('Cell one'));
      final translation = cells[0].querySelector('[data-translation="true"]')!;
      expect(translation.text, contains('单元格一'));
    });

    test('table cell translation keeps td when the model returns one', () {
      const String source =
          '<html><body><table><tr>'
          '<td class="line"><p>Cell one</p></td>'
          '</tr></table></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'td-1',
              tagName: 'td',
              sourceHtml: '<td class="line"><p>Cell one</p></td>',
              sourceText: 'Cell one',
              translatedHtml: '<td><p>单元格一</p></td>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      final List<dom.Element> cells = document.querySelectorAll('tr td');
      expect(cells, hasLength(1));
      expect(
        cells.single.querySelector('[data-translation="true"]')!.text,
        contains('单元格一'),
      );
    });

    test('translation paragraphs are marked and visually distinguished', () {
      const String source = '<html><body><p>Hello world</p></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>Hello world</p>',
              sourceText: 'Hello world',
              translatedHtml: '<p>你好世界</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      final List<dom.Element> translations = document.querySelectorAll(
        '[data-translation="true"]',
      );
      expect(translations, isNotEmpty);
      expect(translations.first.text, contains('你好世界'));
      // The injected compatibility CSS must actually style the marker.
      expect(output, contains('[data-translation="true"]'));
    });

    test('bilingual mode does not relabel the root language', () {
      const String source =
          '<html lang="en" xml:lang="en"><body><p>Hello world</p></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>Hello world</p>',
              sourceText: 'Hello world',
              translatedHtml: '<p>你好世界</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      // Source keeps its original language...
      expect(document.documentElement?.attributes['lang'], 'en');
      // ...while translation blocks carry the target language.
      final List<dom.Element> translations = document.querySelectorAll(
        '[data-translation="true"]',
      );
      expect(translations, isNotEmpty);
      for (final dom.Element element in translations) {
        expect(element.attributes['lang'], 'zh-CN');
      }
    });

    test('non-bilingual mode still labels the root language', () {
      const String source = '<html><body><p>Hello world</p></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>Hello world</p>',
              sourceText: 'Hello world',
              translatedHtml: '<p>你好世界</p>',
            ),
          ],
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      expect(document.documentElement?.attributes['lang'], 'zh-CN');
    });

    test('bilingual mode never rewrites the source paragraph', () {
      final ProperNameBookState state = ProperNameNormalizer.bookState();
      const String source =
          '<html><body><p>Adam Smith wrote the book.</p></body></html>';

      String render(String translated) {
        return EpubRepacker().renderTranslatedChapter(
          chapter: _chapter(
            path: 'text/ch.xhtml',
            originalHtml: source,
            blocks: <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: '<p>Adam Smith wrote the book.</p>',
                sourceText: 'Adam Smith wrote the book.',
                translatedHtml: translated,
              ),
            ],
          ),
          bilingual: true,
          targetLanguage: 'Chinese',
          lockedGlossary: 'Adam Smith => 亚当·斯密',
          properNameState: state,
        );
      }

      final String output = render('<p>Adam Smith 写了这本书。</p>');
      // The source paragraph must stay byte-identical: the normalizer only
      // ever sees the translation.
      expect(output, contains('<p>Adam Smith wrote the book.</p>'));
      expect(output, isNot(contains('亚当·斯密（Adam Smith） wrote the book')));
      // The translation takes the first-occurrence gloss (the space
      // after the name comes from the model-supplied translation text).
      expect(output, contains('亚当·斯密（Adam Smith） 写了这本书'));

      // The book state advanced on the translation hit only, so a later
      // chapter renders the now-known name without a gloss.
      final String output2 = render('<p>Adam Smith 写了第二章。</p>');
      expect(output2, contains('亚当·斯密 写了第二章'));
      expect(output2, isNot(contains('亚当·斯密（Adam Smith） 写了第二章')));
    });

    test('illegal tr child keeps its translation in place', () {
      // `<p>` is not a legal child of `<tr>`; the HTML parser foster-parents
      // it, and the bilingual sanitize step must not displace the
      // translation fragment out of the document.
      const String source =
          '<html><body><table><tr>'
          '<p id="x">hello</p><td><p>Cell one</p></td>'
          '</tr></table></body></html>';
      final String output = EpubRepacker().renderTranslatedChapter(
        chapter: _chapter(
          path: 'text/ch.xhtml',
          originalHtml: source,
          blocks: <ExtractedBlock>[
            ExtractedBlock(
              id: 'td-1',
              tagName: 'td',
              sourceHtml: '<td><p>Cell one</p></td>',
              sourceText: 'Cell one',
              translatedHtml: '<p>单元格一</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'Chinese',
      );
      final dom.Document document = html_parser.parse(output);
      // The translation survived inside a td with the bilingual marker.
      final List<dom.Element> marked = document.querySelectorAll(
        '[data-translation="true"]',
      );
      expect(marked, isNotEmpty);
      expect(marked.map((dom.Element e) => e.text).join(), contains('单元格一'));
    });
  });
}
