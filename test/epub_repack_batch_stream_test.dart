import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

class _SingleNavigationExtraction extends EpubHtmlExtractor {
  final _paths = <String>{};

  @override
  List<ExtractedBlock> extractBlocks(
    dom.Document document, {
    required String chapterPath,
    bool detectAuthorSignatures = false,
  }) {
    if (!_paths.add(chapterPath)) {
      throw StateError('Navigation labels recalculated for $chapterPath');
    }
    return super.extractBlocks(
      document,
      chapterPath: chapterPath,
      detectAuthorSignatures: detectAuthorSignatures,
    );
  }
}

InspectedChapter _chapter(String name, String html, {bool selected = true}) {
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: name,
    bytes: utf8.encode(html),
  );
  return chapter.copyWith(includeInTranslation: selected);
}

Archive _book() => Archive()
  ..add(ArchiveFile.string('mimetype', 'application/epub+zip\n'))
  ..add(
    ArchiveFile.string('META-INF/container.xml', '''
<container><rootfile full-path="OPS/book.opf"/></container>'''),
  )
  ..add(
    ArchiveFile.string('OPS/book.opf', '''
<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:language>en</dc:language></metadata>
<manifest>
<item id="nav" href="nav%20doc.xhtml#toc" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
</manifest><spine toc="ncx"/></package>'''),
  )
  ..add(
    ArchiveFile.string('OPS/nav doc.xhtml', '''
<html xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><a href="chapter.xhtml#heading">Source</a></nav>
<nav epub:type="page-list"><a href="chapter.xhtml#heading">12</a></nav>
</body></html>'''),
  )
  ..add(
    ArchiveFile.string('OPS/toc.ncx', '''
<ncx><navMap><navPoint><navLabel><text>Source</text></navLabel>
<content src="chapter.xhtml#heading"/></navPoint></navMap></ncx>'''),
  )
  ..add(
    ArchiveFile.string('OPS/contents.xhtml', '''
<html><body><a href="chapter.xhtml#heading">Source</a></body></html>'''),
  )
  ..add(
    ArchiveFile.string('OPS/chapter.xhtml', '''
<html><body><h1 id="heading">Source</h1></body></html>'''),
  )
  ..add(ArchiveFile.string('OPS/media.bin', 'asset data ' * 500))
  ..add(ArchiveFile.noCompress('OPS/stored.bin', 4, [0, 1, 2, 255]));

List<int> _compressed(ArchiveFile file) =>
    file.rawContent!.getStream(decompress: false).toUint8List();

void main() {
  for (final bilingual in [false, true]) {
    test(
      'batch siblings preserve order and boundaries (bilingual=$bilingual)',
      () {
        final source = StringBuffer('<html><body><section>');
        for (var i = 0; i < 120; i++) {
          source.write('<p id="p$i">Source $i</p>\n<!--gap$i-->');
        }
        source.write(
          '</section><aside><p>Other parent</p></aside></body></html>',
        );
        var chapter = _chapter('OPS/chapter.xhtml', source.toString());
        chapter = chapter.copyWith(
          blocks: [
            for (var i = 0; i < chapter.blocks.length; i++)
              chapter.blocks[i].copyWith(
                translatedHtml: i == 60
                    ? null
                    : '<p>Translation $i A</p><p>Translation $i B</p>',
              ),
          ],
        );
        final output = EpubRepacker().renderTranslatedChapter(
          chapter: chapter,
          bilingual: bilingual,
          targetLanguage: 'French',
          degradedBlockIds: {
            EpubRepacker.degradedKeyForBlock(
              chapterPath: chapter.path,
              blockId: chapter.blocks[61].id,
            ),
          },
        );
        final document = html_parser.parse(output);
        final section = document.querySelector('section')!;
        final expected = <String>[];
        for (var i = 0; i < 120; i++) {
          if (bilingual || i == 60) expected.add('Source $i');
          if (i != 60) {
            expected.addAll(['Translation $i A', 'Translation $i B']);
          }
        }
        expect(section.children.map((node) => node.text), expected);
        expect(
          section.nodes.whereType<dom.Comment>().map((node) => node.data),
          [
            for (var i = 0; i < 120; i++) ...[
              if (i == 61) ' UNTRANSLATED ',
              'gap$i',
            ],
          ],
        );
        expect(
          document.querySelector('aside')!.text,
          contains('Translation 120 B'),
        );
        expect(document.querySelectorAll('#p60'), hasLength(1));
        if (bilingual) {
          expect(section.querySelectorAll('[id]'), hasLength(120));
          expect(
            section.querySelectorAll('[data-translation="true"]'),
            hasLength(238),
          );
        }
      },
    );
  }

  test(
    'one label preparation synchronizes legacy TOC, EPUB3 nav and NCX',
    () async {
      final temp = await Directory.systemTemp.createTemp('epub_labels_once_');
      addTearDown(() => temp.delete(recursive: true));
      final book = _book();
      final input = File('${temp.path}/input.epub')
        ..writeAsBytesSync(ZipEncoder().encodeBytes(book));
      var chapter = _chapter(
        'OPS/chapter.xhtml',
        utf8.decode(book.find('OPS/chapter.xhtml')!.content),
      );
      chapter = chapter.copyWith(
        blocks: [
          chapter.blocks.single.copyWith(
            translatedHtml: '<h1 id="heading">Translated heading</h1>',
          ),
        ],
      );
      final toc = _chapter(
        'OPS/contents.xhtml',
        utf8.decode(book.find('OPS/contents.xhtml')!.content),
        selected: false,
      );
      final output = File('${temp.path}/output.epub');
      await EpubRepacker(
        extractor: _SingleNavigationExtraction(),
      ).writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: output.path,
        config: TranslationConfig.defaults().copyWith(targetLanguage: 'French'),
        chapters: [chapter, toc],
      );
      final result = ZipDecoder().decodeBytes(output.readAsBytesSync());
      for (final name in [
        'OPS/contents.xhtml',
        'OPS/nav doc.xhtml',
        'OPS/toc.ncx',
      ]) {
        expect(
          utf8.decode(result.find(name)!.content),
          contains('Translated heading'),
          reason: name,
        );
      }
      final nav = html_parser.parse(
        utf8.decode(result.find('OPS/nav doc.xhtml')!.content),
      );
      expect(nav.querySelectorAll('nav')[1].text.trim(), '12');
    },
  );

  test(
    'streamed repack preserves compressed bytes including read-only container',
    () async {
      final temp = await Directory.systemTemp.createTemp('epub_stream_');
      addTearDown(() => temp.delete(recursive: true));
      final bytes = ZipEncoder().encodeBytes(_book(), level: 9);
      final source = ZipDecoder().decodeBytes(bytes);
      final input = File('${temp.path}/input.epub')..writeAsBytesSync(bytes);
      final output = File('${temp.path}/output.epub')..writeAsStringSync('OLD');
      final tempPath = await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
        inputPath: input.path,
        outputFilePath: output.path,
        translatedHtmlByPath: {
          'OPS/chapter.xhtml': '<html><body>Changed</body></html>',
        },
        navigationLanguageTag: 'fr',
        navigationLabelsByPath: {'OPS/chapter.xhtml#heading': 'Translated'},
      );
      expect(output.readAsStringSync(), 'OLD');
      final result = ZipDecoder().decodeBytes(File(tempPath).readAsBytesSync());
      expect(result.first.name, 'mimetype');
      expect(result.first.compression, CompressionType.none);
      expect(utf8.decode(result.first.content), 'application/epub+zip');
      for (final name in [
        'META-INF/container.xml',
        'OPS/media.bin',
        'OPS/stored.bin',
        'OPS/contents.xhtml',
      ]) {
        final original = source.find(name)!;
        final copied = result.find(name)!;
        expect(_compressed(copied), _compressed(original), reason: name);
        expect(copied.crc32, original.crc32, reason: name);
        expect(copied.mode, original.mode);
        expect(copied.content, original.content);
      }
      expect(
        utf8.decode(result.find('OPS/chapter.xhtml')!.content),
        contains('Changed'),
      );
      expect(
        utf8.decode(result.find('OPS/book.opf')!.content),
        contains('<dc:language>fr</dc:language>'),
      );
      expect(
        await EpubIsolateWorker.commitTempFile(
          File(tempPath),
          output,
          shouldCommit: () => false,
        ),
        isFalse,
      );
      expect(output.readAsStringSync(), 'OLD');
      expect(File(tempPath).existsSync(), isFalse);
    },
  );

  test(
    'lazy navigation skips unrelated and already-rendered corrupt payloads',
    () async {
      final temp = await Directory.systemTemp.createTemp('epub_lazy_repack_');
      addTearDown(() => temp.delete(recursive: true));
      final bytes = ZipEncoder().encodeBytes(_book());
      final data = ByteData.sublistView(bytes);
      final corruptNames = {'OPS/media.bin', 'OPS/nav doc.xhtml'};
      final corrupted = <String>{};
      for (var i = 0; i + 46 <= bytes.length; i++) {
        if (data.getUint32(i, Endian.little) != 0x02014b50) continue;
        final length = data.getUint16(i + 28, Endian.little);
        final name = utf8.decode(bytes.sublist(i + 46, i + 46 + length));
        if (!corruptNames.contains(name)) continue;
        final local = data.getUint32(i + 42, Endian.little);
        final payload =
            local +
            30 +
            data.getUint16(local + 26, Endian.little) +
            data.getUint16(local + 28, Endian.little);
        bytes[payload] = 0x07; // Reserved DEFLATE block type.
        corrupted.add(name);
      }
      expect(corrupted, corruptNames);
      final input = File('${temp.path}/input.epub')..writeAsBytesSync(bytes);
      await expectLater(
        EpubIsolateWorker.loadArchiveFiles(input.path),
        throwsA(anything),
      );
      final output = File('${temp.path}/output.epub');
      expect(
        await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: {
            'OPS/nav doc.xhtml':
                '<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="chapter.xhtml#heading">Rendered</a></nav><p>Translated prose</p></body></html>',
          },
          navigationLanguageTag: 'fr',
          navigationLabelsByPath: {
            'OPS/chapter.xhtml#heading': 'Translated heading',
          },
        ),
        isTrue,
      );
      final source = ZipDecoder().decodeBytes(bytes);
      final result = ZipDecoder().decodeBytes(output.readAsBytesSync());
      expect(
        _compressed(result.find('OPS/media.bin')!),
        _compressed(source.find('OPS/media.bin')!),
      );
      final nav = utf8.decode(result.find('OPS/nav doc.xhtml')!.content);
      expect(nav, contains('Translated heading'));
      expect(nav, contains('Translated prose'));
      expect(
        temp.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty,
      );
    },
  );
}
