import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  for (final prefixed in [false, true]) {
    for (final bilingual in [false, true]) {
      test(
        'three name fixes survive EPUB export: prefixed=$prefixed bilingual=$bilingual',
        () async {
          final dir = await Directory.systemTemp.createTemp(
            'proper-name-export-',
          );
          addTearDown(() => dir.delete(recursive: true));
          String markup(String input) => prefixed
              ? input
                    .replaceAllMapped(
                      RegExp(
                        r'<(/?)(html|head|title|body|p|em|a|sup|span)(?=[\s>])',
                      ),
                      (m) => '<${m[1]}x:${m[2]}',
                    )
                    .replaceFirst(
                      'xmlns="http://www.w3.org/1999/xhtml"',
                      'xmlns:x="http://www.w3.org/1999/xhtml"',
                    )
              : input;
          final archive = Archive();
          void add(String name, String text) {
            final file = ArchiveFile.string(name, text);
            if (name == 'mimetype') file.compression = CompressionType.none;
            archive.add(file);
          }

          add('mimetype', 'application/epub+zip');
          add(
            'META-INF/container.xml',
            '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
          );
          add(
            'OPS/book.opf',
            '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:c4d15694-ed74-4b78-8e7d-67f68d456233</dc:identifier><dc:title>Proper Names</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-18T00:00:00Z</meta></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/><item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine></package>''',
          );
          add(
            'OPS/nav.xhtml',
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">One</a></li><li><a href="c2.xhtml">Two</a></li><li><a href="c3.xhtml">Three</a></li></ol></nav></body></html>',
          );
          const firstSource =
              '<p id="p1">René wrote <a href="#note51"><sup>LI</sup></a> about <em id="style" class="name-style">Smith</em>.</p>';
          for (var n = 1; n <= 3; n++) {
            final body = n == 1
                ? '$firstSource<span id="note51"></span>'
                : '<p id="p$n">Smith, Li and Ren wrote.</p>';
            add(
              'OPS/c$n.xhtml',
              markup(
                '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>Chapter $n</title></head><body>$body</body></html>',
              ),
            );
          }
          final input = await File(
            '${dir.path}/source.epub',
          ).writeAsBytes(ZipEncoder().encodeBytes(archive));
          final inspected = await EpubInspector().inspect(
            inputPath: input.path,
            outputDirectory: dir.path,
            cancelToken: CancelToken(),
          );
          const translations = [
            '<p id="p1">René（雷内）介绍<a href="#note51"><sup>LI</sup></a>和<em id="style" class="name-style">Smith（斯</em>密）。</p>',
            '<p id="p2">Smith（斯密）继续，Li和Ren也来了。</p>',
            '<p id="p3">Smith、Li和Ren继续。</p>',
          ];
          final chapters = [
            for (final chapter in inspected.chapters)
              chapter.copyWith(
                blocks: [
                  for (final block in chapter.blocks)
                    block.copyWith(
                      translatedHtml: markup(
                        translations[int.parse(chapter.path.substring(5, 6)) -
                            1],
                      ),
                    ),
                ],
              ),
          ];
          final output = '${dir.path}/export.epub';
          await EpubRepacker().writeTranslatedEpub(
            inputPath: input.path,
            outputFilePath: output,
            config: TranslationConfig.defaults().copyWith(
              bilingual: bilingual,
              lockedGlossary: 'Smith => 斯密\nLi => 李\nRen => 任',
            ),
            chapters: chapters,
          );
          final exported = ZipDecoder().decodeBytes(
            await File(output).readAsBytes(),
          );
          final texts = <String>[];
          for (var n = 1; n <= 3; n++) {
            final doc = XmlDocument.parse(
              utf8.decode(
                exported.findFile('OPS/c$n.xhtml')!.content as List<int>,
              ),
            );
            final elements = doc.descendants.whereType<XmlElement>().toList();
            final ids = elements
                .map((e) => e.getAttribute('id'))
                .whereType<String>()
                .toList();
            expect(ids.toSet(), hasLength(ids.length));
            final paragraph = elements
                .where(
                  (e) =>
                      e.name.local == 'p' &&
                      (!bilingual ||
                          e.getAttribute('data-translation') == 'true'),
                )
                .single;
            texts.add(paragraph.innerText);
            if (n == 1) {
              final descendants = paragraph.descendants.whereType<XmlElement>();
              expect(
                descendants.where((e) => e.name.local == 'a').single.innerText,
                'LI',
              );
              expect(
                descendants
                    .where((e) => e.getAttribute('class') == 'name-style')
                    .map((e) => e.innerText)
                    .join(),
                '斯（Smith',
              );
              if (bilingual) {
                expect(
                  elements
                      .where((e) => e.getAttribute('id') == 'style')
                      .single
                      .innerText,
                  'Smith',
                );
              }
            }
          }
          expect(texts, [
            'René（雷内）介绍LI和斯密（Smith）。',
            '斯密继续，李（Li）和任（Ren）也来了。',
            '斯密、李和任继续。',
          ]);
          final destination = Platform.environment['PROPER_NAME_EXPORT_DIR'];
          if (destination != null) {
            await Directory(destination).create(recursive: true);
            await File(
              output,
            ).copy('$destination/names-$prefixed-$bilingual.epub');
          }
        },
      );
    }
  }
}
