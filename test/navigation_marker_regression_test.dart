import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

Map<String, String> labels(String source) {
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'chapter.xhtml',
    bytes: utf8.encode(source),
  );
  return EpubRepacker().debugNavigationLabels([
    chapter.copyWith(
      includeInTranslation: true,
      blocks: [
        for (final b in chapter.blocks)
          b.copyWith(
            translatedHtml: b.sourceHtml
                .replaceAll('Main', '主标题')
                .replaceAll('(Subtitle)', '（副标题）'),
          ),
      ],
    ),
  ]);
}

void main() {
  const markers = [
    '<a epub:type="noteref" href="#note">[1]</a>',
    '<a e:type="noteref" href="#note">[1]</a>',
    '<a role="doc-noteref" href="#note">[1]</a>',
    '<a epub:type="backlink" href="#note">[1]</a>',
    '<span epub:type="pagebreak">12</span>',
    '<span role="doc-pagebreak">12</span>',
    '<span class="pagenum">12</span>',
    '<a class="footnote_ref" href="#note">[1]</a>',
    '<a href="#note"><sup class="footnote_num">[1]</sup></a>',
    '<svg xmlns="http://www.w3.org/2000/svg"><title>Decoration</title></svg>',
  ];
  for (final marker in markers) {
    test('title and subtitle labels exclude protected marker: $marker', () {
      final source =
          '<html xmlns:epub="http://www.idpf.org/2007/ops" xmlns:e="http://www.idpf.org/2007/ops">'
          '<body><h1 id="main">Main$marker</h1><h2 id="sub">(Subtitle)$marker</h2><p>Body.</p></body></html>';
      final result = labels(source);
      expect(result['chapter.xhtml'], '主标题（副标题）');
      expect(result['chapter.xhtml#main'], '主标题（副标题）');
      expect(result['chapter.xhtml#sub'], '（副标题）');
      // Nested anchors are not valid HTML; use a span to check the same marker
      // semantics without allowing the HTML parser to relocate the marker.
      final safe = marker
          .replaceAll('<a ', '<span ')
          .replaceAll('</a>', '</span>');
      final anchor = html
          .parse(
            '<html xmlns:epub="http://www.idpf.org/2007/ops" xmlns:e="http://www.idpf.org/2007/ops"><body><a href="chapter.xhtml">Old$safe</a></body></html>',
          )
          .querySelector('a')!;
      final protectedBefore = anchor.children.single.outerHtml;
      expect(
        replaceNavigationAnchorLabel(anchor, '新标题', languageTag: 'zh'),
        isTrue,
      );
      expect(anchor.outerHtml, contains(protectedBefore));
      expect(navigationLabelText(anchor), '新标题');
    });
  }

  test('unmarked title numbers and ordinary links remain visible', () {
    expect(
      labels(
        '<html><body><h1 id="main">Main 12 <a href="#guide">Guide</a></h1></body></html>',
      )['chapter.xhtml#main'],
      '主标题 12 Guide',
    );
  });
  test('foreign namespace binding survives detached title fragments', () {
    expect(
      labels(
        '<html xmlns:epub="urn:foreign"><body><h1 id="main">Main<span epub:type="pagebreak">12</span></h1></body></html>',
      )['chapter.xhtml#main'],
      '主标题12',
    );
  });
  test('prefixed XHTML headings use the same marker boundary', () {
    final result = labels(
      '<x:html xmlns:x="http://www.w3.org/1999/xhtml" xmlns:e="http://www.idpf.org/2007/ops"><x:body>'
      '<x:h1 id="main">Main<x:span e:type="pagebreak">12</x:span></x:h1>'
      '<x:h2>(Subtitle)<x:a role="doc-noteref" href="#note">[1]</x:a></x:h2><x:p>Body.</x:p></x:body></x:html>',
    );
    expect(result['chapter.xhtml#main'], '主标题（副标题）');
  });
  test('marker-only heading and navigation link have no replaceable label', () {
    expect(
      labels(
        '<html xmlns:epub="http://www.idpf.org/2007/ops"><body><h1 id="main"><span epub:type="pagebreak">12</span></h1></body></html>',
      ),
      isEmpty,
    );
    final anchor = html
        .parseFragment(
          '<a href="#page"><span role="doc-pagebreak">12</span></a>',
        )
        .children
        .single;
    final original = anchor.outerHtml;
    expect(replaceNavigationAnchorLabel(anchor, 'Title'), isFalse);
    expect(anchor.outerHtml, original);
  });

  for (final epub3 in [false, true]) {
    for (final bilingual in [false, true]) {
      test('marker-safe complete export EPUB ${epub3 ? 3 : 2}, bilingual=$bilingual', () async {
        final dir = await Directory.systemTemp.createTemp(
          'navigation-markers-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final ns = epub3 ? ' xmlns:epub="http://www.idpf.org/2007/ops"' : '';
        String page(int n) => epub3
            ? '<span epub:type="pagebreak" id="page$n">$n</span>'
            : '<span class="pagenum" id="page$n">$n</span>';
        final note = epub3
            ? '<a epub:type="noteref" href="#note">[1]</a>'
            : '<a class="footnote_ref" href="#note">[1]</a>';
        final chapter =
            '<html xmlns="http://www.w3.org/1999/xhtml"$ns><head><title>Story</title></head><body>'
            '<h1 id="main">Road$note${page(12)}</h1><h2 id="sub">(Journey)${page(13)}</h2><p>Walking.</p>'
            '${epub3 ? '<aside epub:type="footnote" id="note">' : '<div id="note">'}<p>Note.</p>${epub3 ? '</aside>' : '</div>'}</body></html>';
        const link =
            '<a href="chapter.xhtml#main">Road (Journey)<span class="pagenum">12</span></a>';
        const toc =
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title></head><body><h1>Contents</h1><ol><li>$link</li></ol></body></html>';
        const nav =
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>'
            '<nav epub:type="toc" id="toc"><h1>Contents</h1><ol><li>$link</li></ol></nav>'
            '<nav epub:type="page-list"><ol><li><a href="chapter.xhtml#page12">12</a></li><li><a href="chapter.xhtml#page13">13</a></li></ol></nav></body></html>';
        const ncx =
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head>'
            '<meta name="dtb:uid" content="urn:uuid:0c3a0187-516f-4219-a3da-7698e748b885"/><meta name="dtb:depth" content="1"/>'
            '<meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>Story</text></docTitle>'
            '<navMap><navPoint id="n" playOrder="1"><navLabel><text>Road (Journey)</text></navLabel><content src="chapter.xhtml#main"/></navPoint></navMap></ncx>';
        final files = {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
          'OPS/book.opf':
              '<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}" unique-identifier="uid">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:0c3a0187-516f-4219-a3da-7698e748b885</dc:identifier><dc:title>Story</dc:title><dc:language>en</dc:language>'
              '${epub3 ? '<meta property="dcterms:modified">2026-10-27T00:00:00Z</meta>' : ''}</metadata><manifest>'
              '<item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="t" href="toc.xhtml" media-type="application/xhtml+xml"/><item id="n" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
              '${epub3 ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : ''}</manifest><spine toc="n"><itemref idref="t"/><itemref idref="c"/></spine></package>',
          'OPS/chapter.xhtml': chapter,
          'OPS/toc.xhtml': toc,
          'OPS/toc.ncx': ncx,
          if (epub3) 'OPS/nav.xhtml': nav,
        };
        final archive = Archive();
        for (final e in files.entries) {
          final file = ArchiveFile.string(e.key, e.value);
          if (e.key == 'mimetype') file.compression = CompressionType.none;
          archive.addFile(file);
        }
        final input = File('${dir.path}/source.epub');
        await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
        final chapters =
            [
                  for (final e in files.entries.where(
                    (e) => e.key.endsWith('.xhtml'),
                  ))
                    const EpubHtmlExtractor().inspectChapterBytes(
                      chapterPath: e.key,
                      bytes: utf8.encode(e.value),
                    ),
                ]
                .map(
                  (c) => c.copyWith(
                    includeInTranslation: c.path.endsWith('chapter.xhtml'),
                    blocks: [
                      for (final b in c.blocks)
                        b.copyWith(
                          translatedHtml: b.sourceHtml
                              .replaceAll('Road', '道路')
                              .replaceAll('(Journey)', '（旅途）')
                              .replaceAll('Walking.', '步行。')
                              .replaceAll('Note.', '注释。'),
                        ),
                    ],
                  ),
                )
                .toList();
        final output = '${dir.path}/translated.epub';
        await EpubRepacker().writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output,
          config: TranslationConfig.defaults().copyWith(bilingual: bilingual),
          chapters: chapters,
        );
        final rendered = ZipDecoder().decodeBytes(
          await File(output).readAsBytes(),
        );
        XmlDocument read(String name) => XmlDocument.parse(
          utf8.decode(rendered.findFile('OPS/$name')!.content),
        );
        expect(
          read('toc.xhtml').descendants
              .whereType<XmlElement>()
              .singleWhere((e) => e.name.local == 'a')
              .innerText,
          '道路（旅途）12',
        );
        expect(
          read('toc.ncx').descendants
              .whereType<XmlElement>()
              .singleWhere((e) => e.name.local == 'navLabel')
              .innerText,
          '道路（旅途）',
        );
        final body = read('chapter.xhtml');
        expect(
          body.descendants.whereType<XmlElement>().where(
            (e) => e.name.local == 'a' && e.getAttribute('href') == '#note',
          ),
          hasLength(bilingual ? 2 : 1),
        );
        expect(
          body.descendants.whereType<XmlElement>().where(
            (e) => e.getAttribute('id') == 'note',
          ),
          hasLength(1),
        );
        if (epub3) {
          final navs = read('nav.xhtml').descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'nav')
              .toList();
          expect(
            navs.first.descendants
                .whereType<XmlElement>()
                .singleWhere((e) => e.name.local == 'a')
                .innerText,
            '道路（旅途）12',
          );
          expect(
            navs.last.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'a')
                .map((e) => e.innerText),
            ['12', '13'],
          );
        } else {
          expect(
            body.descendants.whereType<XmlElement>().any(
              (e) => e.getAttribute('data-translation') != null,
            ),
            isFalse,
          );
        }
        final destination = Platform.environment['EPUBCHECK_OUTPUT_DIR'];
        if (destination != null) {
          await Directory(destination).create(recursive: true);
          await File(output).copy(
            '$destination/markers-${epub3 ? 3 : 2}-${bilingual ? 'bilingual' : 'chinese'}.epub',
          );
        }
      });
    }
  }
}
