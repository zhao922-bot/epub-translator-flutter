import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  group('repack keeps table cell wrappers', () {
    test('wraps model output that drops the td element back in a td', () {
      const String source =
          '<html><body><table><tr>'
          '<td class="line"><p>Cell one</p></td>'
          '</tr></table></body></html>';
      final EpubRepacker repacker = EpubRepacker();
      final String output = repacker.renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'text/ch.xhtml',
          title: 'chapter',
          body: 'cell',
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
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
      );
      final cell = html.parse(output).querySelectorAll('td').single;
      expect(cell.attributes['class'], 'line');
      expect(cell.querySelector('p')!.text, '单元格一');
      expect(cell.attributes['lang'], 'zh-CN');
    });

    test('keeps td when the model returns a full td already', () {
      const String source =
          '<html><body><table><tr>'
          '<td class="line"><p>Cell one</p></td>'
          '</tr></table></body></html>';
      final EpubRepacker repacker = EpubRepacker();
      final String output = repacker.renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'text/ch.xhtml',
          title: 'chapter',
          body: 'cell',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'td-1',
              tagName: 'td',
              sourceHtml: '<td class="line"><p>Cell one</p></td>',
              sourceText: 'Cell one',
              translatedHtml: '<td class="line"><p>单元格一</p></td>',
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
      );
      final cell = html.parse(output).querySelectorAll('td').single;
      expect(cell.attributes['class'], 'line');
      expect(cell.querySelector('p')!.text, '单元格一');
      expect(cell.attributes['lang'], 'zh-CN');
    });

    test('wraps th cell output without duplicating the wrapper', () {
      const String source =
          '<html><body><table><tr><th>Header</th></tr></table></body></html>';
      final EpubRepacker repacker = EpubRepacker();
      final String output = repacker.renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'text/ch.xhtml',
          title: 'chapter',
          body: 'header',
          originalHtml: source,
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'th-1',
              tagName: 'th',
              sourceHtml: '<th>Header</th>',
              sourceText: 'Header',
              translatedHtml: '表头',
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
      );
      final cell = html.parse(output).querySelectorAll('th').single;
      expect(cell.text, '表头');
      expect(cell.attributes['lang'], 'zh-CN');
    });
  });
}
