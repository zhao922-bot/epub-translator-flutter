import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/review_text_patch.dart';

// Synthetic prose only: exercise the real patch, validation and export code.
void main() {
  for (final epub3 in [false, true]) {
    for (final prefix in ['', 'x:']) {
      for (final bilingual in [false, true]) {
        test(
          'patched table exports EPUB ${epub3 ? 3 : 2}, prefix=$prefix, bilingual=$bilingual',
          () async {
            final dir = await Directory.systemTemp.createTemp(
              'review-table-export-',
            );
            addTearDown(() => dir.delete(recursive: true));
            const ns = 'http://www.w3.org/1999/xhtml';
            const uid = 'urn:uuid:4bc178c5-9949-4b1b-9f56-990cc8db6b12';
            String cell(String tag) =>
                '<$prefix$tag id="$tag">The sky was <${prefix}em>blue</${prefix}em>.</$prefix$tag>';
            final chapter =
                '<html xmlns="$ns" xmlns:x="$ns"><head><title>Colours</title></head><body><h1 id="main">Colours</h1><${prefix}table id="table">${cell('caption')}<${prefix}tr>${cell('th')}${cell('td')}</${prefix}tr></${prefix}table></body></html>';
            const ncx =
                '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="$uid"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>Colours</text></docTitle><navMap><navPoint id="n" playOrder="1"><navLabel><text>Colours</text></navLabel><content src="chapter.xhtml#main"/></navPoint></navMap></ncx>';
            final files = {
              'mimetype': 'application/epub+zip',
              'META-INF/container.xml':
                  '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
              'OPS/book.opf':
                  '<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">$uid</dc:identifier><dc:title>Colours</dc:title><dc:language>en</dc:language>${epub3 ? '<meta property="dcterms:modified">2026-10-27T00:00:00Z</meta>' : ''}</metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="n" href="toc.ncx" media-type="application/x-dtbncx+xml"/>${epub3 ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : ''}</manifest><spine toc="n"><itemref idref="c"/></spine></package>',
              'OPS/chapter.xhtml': chapter,
              'OPS/toc.ncx': ncx,
              if (epub3)
                'OPS/nav.xhtml':
                    '<html xmlns="$ns" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="chapter.xhtml#main">Colours</a></li></ol></nav></body></html>',
            };
            final zip = Archive();
            for (final e in files.entries) {
              final f = ArchiveFile.string(e.key, e.value);
              if (e.key == 'mimetype') f.compression = CompressionType.none;
              zip.addFile(f);
            }
            final input = File('${dir.path}/source.epub');
            await input.writeAsBytes(ZipEncoder().encodeBytes(zip));
            final config = TranslationConfig.defaults().copyWith(
              bilingual: bilingual,
            );
            final inspected = const EpubHtmlExtractor().inspectChapterBytes(
              chapterPath: 'OPS/chapter.xhtml',
              bytes: utf8.encode(chapter),
            );
            final translated = inspected.copyWith(
              includeInTranslation: true,
              blocks: [
                for (final block in inspected.blocks)
                  block.copyWith(
                    translatedHtml: block.tagName == 'h1'
                        ? block.sourceHtml.replaceFirst('Colours', '颜色')
                        : EpubChapterTranslator.validateReviewSuggestion(
                            config: config,
                            block: block,
                            translatedHtml: ReviewTextPatch.apply(
                              block.sourceHtml
                                  .replaceFirst('The sky was ', '天空是')
                                  .replaceFirst('blue', '红色'),
                              [
                                {'before': '红色', 'after': '蓝色'},
                              ],
                            ),
                          ),
                  ),
              ],
            );
            final output = '${dir.path}/translated.epub';
            await EpubRepacker().writeTranslatedEpub(
              inputPath: input.path,
              outputFilePath: output,
              config: config,
              chapters: [translated],
              translatedTitle: '颜色',
            );
            final archive = ZipDecoder().decodeBytes(
              await File(output).readAsBytes(),
            );
            final xml = XmlDocument.parse(
              utf8.decode(
                archive.findFile('OPS/chapter.xhtml')!.content as List<int>,
              ),
            );
            final elements = xml.descendants.whereType<XmlElement>();
            for (final tag in ['td', 'th', 'caption']) {
              final cell = elements.singleWhere((e) => e.name.local == tag);
              expect(cell.getAttribute('id'), tag);
              expect(cell.namespaceUri, ns);
              expect(cell.innerText, contains('蓝色'));
              expect(cell.innerText, isNot(contains('红色')));
              expect(cell.innerText.contains('blue'), bilingual);
              if (tag == 'caption' && bilingual) {
                expect(
                  cell.childElements.any((e) => e.name.local == 'div'),
                  isFalse,
                );
                expect(
                  cell.childElements.any(
                    (e) => e.name.local == 'span' && e.innerText.contains('蓝色'),
                  ),
                  isTrue,
                );
              }
            }
            final ids = elements
                .map((e) => e.getAttribute('id'))
                .whereType<String>()
                .toList();
            expect(ids.toSet().length, ids.length);
            final readBack = const EpubHtmlExtractor().inspectChapterBytes(
              chapterPath: 'OPS/chapter.xhtml',
              bytes:
                  archive.findFile('OPS/chapter.xhtml')!.content as List<int>,
            );
            expect(readBack.body, contains('蓝色'));
            final destination = Platform.environment['EPUBCHECK_OUTPUT_DIR'];
            if (destination != null) {
              await Directory(destination).create(recursive: true);
              await File(output).copy(
                '$destination/review-${epub3 ? 3 : 2}-${prefix.isEmpty ? 'plain' : 'prefix'}-${bilingual ? 'bilingual' : 'chinese'}.epub',
              );
            }
          },
        );
      }
    }
  }
}
