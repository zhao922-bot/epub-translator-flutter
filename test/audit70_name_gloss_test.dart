import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';

void main() {
  for (final mode in [
    'bare-control',
    'canonical',
    'half-width',
    'reverse',
    'formatted-half-width',
    'split-source',
    'encoded-split-source',
    'empty-link-marker',
    'encoded-space-link-marker',
    'reverse-formatted-target',
    'reverse-split-source',
    'reverse-encoded-source',
  ]) {
    test('real EPUB export retains only the first name gloss: $mode', () async {
      final temp = await Directory.systemTemp.createTemp('audit-r23-gloss-');
      addTearDown(() => temp.delete(recursive: true));
      const source =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body><p>Adam Smith wrote about economics.</p></body></html>';
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfile full-path="OPS/book.opf"/></container>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/book.opf',
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Names</dc:title></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
          ),
        )
        ..addFile(ArchiveFile.string('OPS/c1.xhtml', source))
        ..addFile(ArchiveFile.string('OPS/c2.xhtml', source));
      final input = await File(
        '${temp.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final inspected = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      expect(inspected.chapters, hasLength(2));
      final later = switch (mode) {
        'canonical' => '<p>后来，亚当·斯密（Adam Smith）继续写作。</p>',
        'half-width' => '<p>后来，亚当·斯密 (Adam Smith) 继续写作。</p>',
        'reverse' => '<p>后来，Adam Smith（亚当·斯密）继续写作。</p>',
        'formatted-half-width' => '<p>后来，<em>亚当·斯密</em> (Adam Smith) 继续写作。</p>',
        'split-source' => '<p>后来，亚当·斯密（Ad<em>am Smith</em>）继续写作。</p>',
        'encoded-split-source' =>
          '<p>后来，亚当·斯密&#40;Ad<em>am&#160;Smith</em>&#41;继续写作。</p>',
        'empty-link-marker' =>
          '<p>后来，亚当·斯密（Ad<a id="page-marker"></a>am Smith）继续写作。</p>',
        'encoded-space-link-marker' =>
          '<p>后来，亚当·斯密（Adam<a id="page-marker">&#32;</a>Smith）继续写作。</p>',
        'reverse-formatted-target' =>
          '<p>后来，Adam Smith（亚当<em id="name-style">·斯密</em>）继续写作。</p>',
        'reverse-split-source' =>
          '<p>后来，Ad<em id="name-style">am Smith（亚当·斯密</em>）继续写作。</p>',
        'reverse-encoded-source' =>
          '<p>后来，&#65;dam Sm<em id="name-style">ith&#40;亚当·斯密</em>&#41;继续写作。</p>',
        _ => '<p>后来，Adam Smith继续写作。</p>',
      };
      final chapters = [
        for (var i = 0; i < inspected.chapters.length; i++)
          inspected.chapters[i].copyWith(
            blocks: [
              for (final block in inspected.chapters[i].blocks)
                block.copyWith(
                  translatedHtml: i == 0 ? '<p>最初，Adam Smith写作。</p>' : later,
                ),
            ],
          ),
      ];
      final output = '${temp.path}/out.epub';
      await EpubRepacker().writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: output,
        config: TranslationConfig.defaults().copyWith(
          lockedGlossary: 'Adam Smith => 亚当·斯密',
        ),
        chapters: chapters,
      );
      final exported = ZipDecoder().decodeBytes(
        await File(output).readAsBytes(),
      );
      String chapterText(int n) =>
          XmlDocument.parse(
                utf8.decode(
                  exported.findFile('OPS/c$n.xhtml')!.content as List<int>,
                ),
              ).descendants
              .whereType<XmlElement>()
              .singleWhere((e) => e.name.local == 'body')
              .innerText;
      final first = chapterText(1), second = chapterText(2);
      debugPrint('AUDIT name gloss mode=$mode first=$first second=$second');
      expect(first, contains('亚当·斯密（Adam Smith）'));
      expect(second, contains('亚当·斯密'));
      if (mode == 'formatted-half-width' ||
          mode == 'split-source' ||
          mode == 'encoded-split-source' ||
          mode.startsWith('reverse-')) {
        final doc = XmlDocument.parse(
          utf8.decode(exported.findFile('OPS/c2.xhtml')!.content as List<int>),
        );
        expect(
          doc.descendants.whereType<XmlElement>().where(
            (e) => e.name.local == 'em',
          ),
          hasLength(1),
        );
      }
      expect(
        second,
        isNot(contains('Adam Smith')),
        reason:
            'The settings promise only the first book occurrence retains its Latin gloss.',
      );
    });
  }
}
