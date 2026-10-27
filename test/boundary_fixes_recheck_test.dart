import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'additional_audit_regression_test.dart' as audit;
import 'real_book_fix_regression_test.dart' as fixture;

void main() {
  test('ordinary void elements still export as valid XHTML', () {
    const source =
        '<div>Before<br/>after<hr/><img src="cover.png" alt="cover"/></div>';
    final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
      XhtmlHtmlCompatibility.parseFragment(source).outerHtml,
    );
    final root = XmlDocument.parse(output).rootElement;
    expect(root.childElements.map((e) => e.name.local), ['br', 'hr', 'img']);
    expect(root.childElements.every((e) => e.children.isEmpty), isTrue);
    expect(root.innerText, 'Beforeafter');
  });
  test(
    'prefixed foreign elements with void-like names retain their children',
    () {
      const source =
          '<root xmlns:f="urn:fixture"><f:source>keep</f:source><f:br>text</f:br></root>';
      final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(source);
      expect(output, source);
      expect(XmlDocument.parse(output).rootElement.innerText, 'keeptext');
    },
  );
  test('markup-shaped text in comments and CDATA is not rewritten', () {
    const source =
        '<root><!-- <x:br></x:br> --><![CDATA[<x:br></x:br>]]></root>';
    expect(XhtmlHtmlCompatibility.normalizeForXhtmlOutput(source), source);
  });
  for (final tag in [
    'br',
    'hr',
    'img',
    'wbr',
    'input',
    'source',
    'meta',
    'link',
  ]) {
    test('prefixed $tag survives parse and XHTML serialization', () {
      final source =
          '<x:div xmlns:x="http://www.w3.org/1999/xhtml">before<x:$tag title="a &gt; b"/>after</x:div>';
      final dom = XhtmlHtmlCompatibility.parseFragment(source);
      final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
        dom.outerHtml,
      );
      final xml = XmlDocument.parse(output);
      expect(xml.rootElement.innerText, 'beforeafter');
      final element = xml.rootElement.childElements.single;
      expect(element.name.qualified, 'x:$tag');
      expect(element.children, isEmpty);
      expect(element.getAttribute('title'), 'a > b');
      expect(
        XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
          XhtmlHtmlCompatibility.parseFragment(output).outerHtml,
        ),
        output,
      );
    });
  }
  test('prefixed h4 with a line break keeps chapter and anchor titles', () {
    const source =
        '<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:head><x:title>Book</x:title></x:head><x:body><x:h4 id="main">The Art<x:br/>of War</x:h4><x:p>Body.</x:p><x:h2 id="later">Later</x:h2></x:body></x:html>';
    final c = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'c.xhtml',
      bytes: utf8.encode(source),
    );
    final labels = EpubRepacker().debugNavigationLabels([
      c.copyWith(
        includeInTranslation: true,
        blocks: [
          for (final b in c.blocks) b.copyWith(translatedHtml: b.sourceHtml),
        ],
      ),
    ]);
    expect(labels['c.xhtml'], 'The Art of War');
    expect(labels['c.xhtml#main'], 'The Art of War');
    expect(labels['c.xhtml#later'], 'Later');
  });
  test(
    'navigation replacement is idempotent with a break and protected marker',
    () {
      final anchor = XhtmlHtmlCompatibility.parseFragment(
        '<a href="c.xhtml">Old<br/>Title<span role="doc-pagebreak">12</span></a>',
      ).children.single;
      expect(
        replaceNavigationAnchorLabel(anchor, 'New Title', languageTag: 'en'),
        isTrue,
      );
      expect(navigationLabelText(anchor), 'New Title');
      final first = anchor.outerHtml;
      expect(
        replaceNavigationAnchorLabel(anchor, 'New Title', languageTag: 'en'),
        isTrue,
      );
      expect(anchor.outerHtml, first);
      expect(anchor.querySelector('[role="doc-pagebreak"]')!.text, '12');
    },
  );

  test(
    'sparse footnote review uses neighbours from the correct source chapter',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
      final translator = EpubChapterTranslator(cacheStore: f.repo.cacheStore);
      final config = f.config.copyWith(autoApplyVerifiedCorrections: true);
      final dio = const TranslationApiClient().buildDio(config);
      addTearDown(() => dio.close(force: true));
      final chapters = [
        for (final name in ['Amber', 'Beryl'])
          const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: '$name.xhtml',
            bytes: utf8.encode(
              '<html><head><title>Notes</title></head><body><p>$name is the person mentioned next.</p><p>First she screamed with joy; then alas she burst into distress and tears.</p><p>$name later recovered.</p></body></html>',
            ),
          ),
      ];
      final references = [
        for (var i = 0; i < chapters.length; i++)
          FootnoteBlockReference(
            chapterIndex: i,
            chapter: chapters[i],
            block: chapters[i].blocks[1],
          ),
      ];
      final translated = await translator.translateFootnoteBatchForTest(
        dio: dio,
        config: config,
        references: references,
      );
      expect(translated, hasLength(2));
      final requests = f.requests
          .map(audit.payload)
          .whereType<Map<String, dynamic>>();
      for (final kind in [
        'semanticSourceAnalysis',
        'semanticReview',
        'semanticVerification',
      ]) {
        final matching = requests.where((p) => p['kind'] == kind).toList();
        expect(matching, hasLength(2));
        for (var i = 0; i < 2; i++) {
          final name = ['Amber', 'Beryl'][i];
          final row = (matching[i]['blocks'] as List).single;
          expect(row['adjacentSource'], {
            'before': '$name is the person mentioned next.',
            'after': '$name later recovered.',
          });
          expect(jsonEncode(row), isNot(contains(['Beryl', 'Amber'][i])));
        }
      }
    },
  );

  // Reuse actual export fixtures, then re-inspect and repack a chapter with
  // prefixed void elements. Fixed translations here are synthetic test data.
  for (final epub3 in [false, true]) {
    for (final bilingual in [false, true]) {
      test(
        'prefixed breaks survive complete EPUB ${epub3 ? 3 : 2} export, bilingual=$bilingual',
        () async {
          final dir = await Directory.systemTemp.createTemp(
            'prefix-roundtrip-',
          );
          addTearDown(() => dir.delete(recursive: true));
          const ns = 'http://www.w3.org/1999/xhtml';
          const chapter =
              '<x:html xmlns:x="$ns"><x:head><x:title>Story</x:title><x:meta name="fixture" content="before &gt; after"/></x:head><x:body>'
              '<x:h4 id="main">The Art<x:br/>of War</x:h4><x:p>Not<x:br/>blue.</x:p><x:hr/>'
              '<x:h6 id="later">Later</x:h6><x:p>Tail.</x:p></x:body></x:html>';
          const link = '<a href="chapter.xhtml">Old title</a>';
          const toc =
              '<html xmlns="$ns"><head><title>Contents</title></head><body><h1>Contents</h1><ol><li>$link</li></ol></body></html>';
          const nav =
              '<html xmlns="$ns" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol><li>$link</li></ol></nav></body></html>';
          const uid = 'urn:uuid:0c3a0187-516f-4219-a3da-7698e748b885';
          const ncx =
              '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="$uid"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>Story</text></docTitle><navMap><navPoint id="n" playOrder="1"><navLabel><text>Old title</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>';
          final files = {
            'mimetype': 'application/epub+zip',
            'META-INF/container.xml':
                '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
            'OPS/book.opf':
                '<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">$uid</dc:identifier><dc:title>Story</dc:title><dc:language>en</dc:language>${epub3 ? '<meta property="dcterms:modified">2026-10-27T00:00:00Z</meta>' : ''}</metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="t" href="toc.xhtml" media-type="application/xhtml+xml"/><item id="n" href="toc.ncx" media-type="application/x-dtbncx+xml"/>${epub3 ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : ''}</manifest><spine toc="n"><itemref idref="t"/><itemref idref="c"/></spine></package>',
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
                                .replaceAll('The Art', '战争')
                                .replaceAll('of War', '艺术')
                                .replaceAll('Not', '不是')
                                .replaceAll('blue.', '蓝色。')
                                .replaceAll('Later', '后续')
                                .replaceAll('Tail.', '尾段。'),
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
          final result = ZipDecoder().decodeBytes(
            await File(output).readAsBytes(),
          );
          XmlDocument read(String name) => XmlDocument.parse(
            utf8.decode(result.findFile('OPS/$name')!.content),
          );
          final body = read('chapter.xhtml');
          final breaks = body.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'br')
              .toList();
          expect(breaks, hasLength(bilingual ? 4 : 2));
          expect(
            breaks.every((e) => e.children.isEmpty && e.namespaceUri == ns),
            isTrue,
          );
          expect(body.rootElement.innerText, contains('尾段。'));
          expect(
            body.descendants.whereType<XmlElement>().where(
              (e) => e.name.local == 'hr',
            ),
            hasLength(1),
          );
          expect(
            read('toc.ncx').descendants
                .whereType<XmlElement>()
                .singleWhere((e) => e.name.local == 'navLabel')
                .innerText,
            '战争 艺术',
          );
          expect(
            read('toc.xhtml').descendants
                .whereType<XmlElement>()
                .singleWhere((e) => e.name.local == 'a')
                .innerText,
            '战争 艺术',
          );
          if (epub3) {
            expect(
              read('nav.xhtml').descendants
                  .whereType<XmlElement>()
                  .singleWhere((e) => e.name.local == 'a')
                  .innerText,
              '战争 艺术',
            );
          }
          final reloaded = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'OPS/chapter.xhtml',
            bytes: result.findFile('OPS/chapter.xhtml')!.content,
          );
          expect(
            reloaded.blocks.any((b) => b.sourceText.contains('尾段。')),
            isTrue,
          );
          final destination = Platform.environment['EPUBCHECK_OUTPUT_DIR'];
          if (destination != null) {
            await Directory(destination).create(recursive: true);
            await File(output).copy(
              '$destination/prefix-${epub3 ? 3 : 2}-${bilingual ? 'bilingual' : 'chinese'}.epub',
            );
          }
        },
      );
    }
  }
}
