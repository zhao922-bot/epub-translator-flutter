import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const chapter =
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Story</title></head>'
    '<body><section id="section"><a id="before"></a><h1 id="start"><span id="inside">The Road</span></h1>'
    '<h2 id="subtitle">(The Journey)</h2><p>Walking.</p><h2 id="later">Later</h2></section></body></html>';
const targets = {
  'The Road': '道路',
  '(The Journey)': '（旅途）',
  'Walking.': '步行。',
  'Later': '后续',
};
const labels = {
  '': '道路（旅途）',
  '#section': '道路（旅途）',
  '#before': '道路（旅途）',
  '#start': '道路（旅途）',
  '#inside': '道路（旅途）',
  '#subtitle': '（旅途）',
  '#later': '后续',
};

void main() {
  for (final signal in ['class', 'type', 'role', 'hgroup', 'independent']) {
    test('plain subtitle needs structural evidence: $signal', () {
      final marker = switch (signal) {
        'class' => 'class="chapter-subtitle"',
        'type' => 'epub:type="subtitle"',
        'role' => 'role="doc-subtitle"',
        _ => '',
      };
      final headings =
          '<h1 id="start">The Road</h1><h2 $marker>The Journey</h2>';
      final source =
          '<html xmlns:epub="http://www.idpf.org/2007/ops"><body>'
          '${signal == 'hgroup' ? '<hgroup>$headings</hgroup>' : headings}<p>Body.</p></body></html>';
      final c = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'c.xhtml',
        bytes: utf8.encode(source),
      );
      final result = EpubRepacker().debugNavigationLabels([
        c.copyWith(
          includeInTranslation: true,
          blocks: [
            for (final b in c.blocks)
              b.copyWith(
                translatedHtml: b.sourceHtml
                    .replaceAll('The Road', '道路')
                    .replaceAll('The Journey', '旅途'),
              ),
          ],
        ),
      ]);
      expect(
        result['c.xhtml#start'],
        signal == 'independent' ? '道路' : '道路: 旅途',
      );
    });
  }
  for (final prefixed in [false, true]) {
    test(
      'opening title aliases preserve subtitle; other headings stay local: prefix=$prefixed',
      () {
        var source = chapter.replaceFirst(
          '<a id="before">',
          '<a name="before">',
        );
        if (prefixed) {
          source = source
              .replaceAllMapped(
                RegExp(r'<(/?)(html|head|title|body|section|a|h1|span|h2|p)\b'),
                (m) => '<${m[1]}x:${m[2]}',
              )
              .replaceFirst('xmlns=', 'xmlns:x=');
        }
        final c = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'OPS/chapter.xhtml',
          bytes: utf8.encode(source),
        );
        final translated = c.copyWith(
          includeInTranslation: true,
          blocks: [
            for (final b in c.blocks)
              b.copyWith(
                translatedHtml: targets.entries.fold<String>(
                  b.sourceHtml,
                  (String s, e) => s.replaceAll(e.key, e.value),
                ),
              ),
          ],
        );
        final result = EpubRepacker().debugNavigationLabels([translated]);
        for (final e in labels.entries) {
          expect(result['OPS/chapter.xhtml${e.key}'], e.value);
        }
        expect(
          EpubRepacker().debugNavigationLabels([
            translated.copyWith(includeInTranslation: false),
          ]),
          isEmpty,
        );
      },
    );
  }

  for (final epub3 in [false, true]) {
    for (final bilingual in [false, true]) {
      for (final (adjacent, level) in [
        for (final adjacent in [false, true])
          for (final level in [1, 4, 5, 6]) (adjacent, level),
      ]) {
        test(
          'subtitle survives complete legacy TOC/nav/NCX export: epub3=$epub3 bilingual=$bilingual adjacent=$adjacent h$level',
          () async {
            final dir = await Directory.systemTemp.createTemp('nav-subtitle-');
            addTearDown(() => dir.delete(recursive: true));
            final tocLinks = [
              for (final fragment in labels.keys)
                '<li><a href="chapter.xhtml$fragment">The Road (The Journey)</a></li>',
            ].join();
            final toc =
                '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title></head>'
                '<body><h1>Contents</h1><ol>$tocLinks</ol></body></html>';
            final nav =
                '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
                '<head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>$tocLinks</ol></nav>'
                '<nav epub:type="page-list" id="pages"><ol><li><a href="chapter.xhtml#start">4</a></li></ol></nav></body></html>';
            final ncx =
                '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
                '<head><meta name="dtb:uid" content="urn:uuid:0c3a0187-516f-4219-a3da-7698e748b885"/>'
                '<meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>'
                '<docTitle><text>Story</text></docTitle><navMap>${[for (var i = 0; i < labels.length; i++) '<navPoint id="n$i" playOrder="${i + 1}"><navLabel><text>The Road (The Journey)</text></navLabel>'
                      '<content src="chapter.xhtml${labels.keys.elementAt(i)}"/></navPoint>'].join()}</navMap></ncx>';
            final sourceChapter =
                (adjacent
                        ? chapter.replaceFirst(
                            '<p>Walking.</p><h2 id="later">Later</h2>',
                            '<h2 id="later">Later</h2><p>Walking.</p>',
                          )
                        : chapter)
                    .replaceFirst('<h1 ', '<h$level ')
                    .replaceFirst('</h1>', '</h$level>');
            final files = {
              'mimetype': 'application/epub+zip',
              'META-INF/container.xml':
                  '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                  '<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
              'OPS/book.opf':
                  '<package xmlns="http://www.idpf.org/2007/opf" version="${epub3 ? '3.0' : '2.0'}" unique-identifier="uid">'
                  '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:0c3a0187-516f-4219-a3da-7698e748b885</dc:identifier>'
                  '<dc:title>Story</dc:title><dc:language>en</dc:language>'
                  '${epub3 ? '<meta property="dcterms:modified">2026-10-27T00:00:00Z</meta>' : ''}</metadata><manifest>'
                  '<item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
                  '<item id="t" href="toc.xhtml" media-type="application/xhtml+xml"/>'
                  '<item id="n" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
                  '${epub3 ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : ''}'
                  '</manifest><spine toc="n"><itemref idref="t"/><itemref idref="c"/></spine></package>',
              'OPS/chapter.xhtml': epub3
                  ? sourceChapter
                  : sourceChapter
                        .replaceAll('<section', '<div')
                        .replaceAll('</section', '</div'),
              'OPS/toc.xhtml': toc,
              'OPS/toc.ncx': ncx,
              if (epub3) 'OPS/nav.xhtml': nav,
            };
            final archive = Archive();
            for (final e in files.entries) {
              final f = ArchiveFile.string(e.key, e.value);
              if (e.key == 'mimetype') f.compression = CompressionType.none;
              archive.addFile(f);
            }
            final input = File('${dir.path}/source.epub');
            await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
            const extractor = EpubHtmlExtractor();
            final chapters =
                [
                      for (final e in files.entries.where(
                        (e) => e.key.endsWith('.xhtml'),
                      ))
                        extractor.inspectChapterBytes(
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
                              translatedHtml: targets.entries.fold<String>(
                                b.sourceHtml,
                                (String s, e) => s.replaceAll(e.key, e.value),
                              ),
                            ),
                        ],
                      ),
                    )
                    .toList();
            final output = '${dir.path}/translated.epub';
            await EpubRepacker().writeTranslatedEpub(
              inputPath: input.path,
              outputFilePath: output,
              config: TranslationConfig.defaults().copyWith(
                bilingual: bilingual,
              ),
              chapters: chapters,
            );
            final rendered = ZipDecoder().decodeBytes(
              await File(output).readAsBytes(),
            );
            XmlDocument read(String name) => XmlDocument.parse(
              utf8.decode(rendered.findFile('OPS/$name')!.content),
            );
            final tocAnchors = read('toc.xhtml').descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'a')
                .toList();
            final translatedNodes = read('chapter.xhtml').descendants
                .whereType<XmlElement>()
                .where(
                  (e) => epub3
                      ? e.getAttribute('data-translation') == 'true'
                      : (e.getAttribute('class') ?? '')
                            .split(' ')
                            .contains('epub-translator-translation'),
                )
                .toList();
            expect(translatedNodes, hasLength(bilingual ? 4 : 0));
            if (!epub3) {
              expect(
                read('chapter.xhtml').descendants.whereType<XmlElement>().any(
                  (e) => e.getAttribute('data-translation') != null,
                ),
                isFalse,
              );
            }
            expect(tocAnchors.map((a) => a.innerText), labels.values);
            for (final a in tocAnchors) {
              expect(
                labels.keys.map((k) => 'chapter.xhtml$k'),
                contains(a.getAttribute('href')),
              );
            }
            final navPoints = read('toc.ncx').descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'navLabel')
                .toList();
            expect(navPoints.map((e) => e.innerText), labels.values);
            if (epub3) {
              final sections = read('nav.xhtml').descendants
                  .whereType<XmlElement>()
                  .where((e) => e.name.local == 'nav')
                  .toList();
              expect(
                sections.first.descendants
                    .whereType<XmlElement>()
                    .where((e) => e.name.local == 'a')
                    .map((e) => e.innerText),
                labels.values,
              );
              expect(
                sections.last.descendants
                    .whereType<XmlElement>()
                    .singleWhere((e) => e.name.local == 'a')
                    .innerText,
                '4',
              );
            }
            final destination = Platform.environment['EPUBCHECK_OUTPUT_DIR'];
            if (destination != null) {
              await Directory(destination).create(recursive: true);
              await File(output).copy(
                '$destination/subtitle-${epub3 ? 3 : 2}-${bilingual ? 'bilingual' : 'chinese'}${adjacent ? '-adjacent' : ''}-h$level.epub',
              );
            }
          },
        );
      }
    }
  }
}
