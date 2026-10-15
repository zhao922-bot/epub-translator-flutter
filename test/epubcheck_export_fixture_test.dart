import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Produces standards-check fixtures for pinned EPUBCheck in CI, without API.
void main() {
  final destination = Platform.environment['EPUBCHECK_OUTPUT_DIR'];
  test(
    'export EPUB3/NCX with tables, inline SVG, MathML, image and emphasis',
    () async {
      final out = Directory(destination!)..createSync(recursive: true);
      final source = File('${out.path}/source.epub');
      final files = <String, List<int>>{};
      void add(String name, String text) => files[name] = utf8.encode(text);
      add('mimetype', 'application/epub+zip');
      add(
        'META-INF/container.xml',
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      );
      add('OPS/package.opf', '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:9fe1ec30-3caf-43a5-a771-7590a9b4ac04</dc:identifier><dc:title>A Story</dc:title><dc:creator>Fixture Author</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-15T00:00:00Z</meta></metadata>
<manifest><item id="story" href="story.xhtml" media-type="application/xhtml+xml" properties="svg mathml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="image" href="pixel.png" media-type="image/png"/><item id="css" href="style.css" media-type="text/css"/></manifest>
<spine toc="ncx"><itemref idref="story"/></spine></package>''');
      add(
        'OPS/story.xhtml',
        '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>Story</title><link href="style.css" rel="stylesheet" type="text/css"/></head><body><h1 id="chapter">Story</h1><p>A short story with <em>emphasis</em> and a <a href="#table">table</a>.</p><figure><img src="pixel.png" alt="Pixel"/><figcaption>A figure</figcaption></figure><table id="table"><caption>Values</caption><tbody><tr><th>Item</th><th>Value</th></tr><tr><td>One</td><td>1</td></tr></tbody></table><p>Formula: <math xmlns="http://www.w3.org/1998/Math/MathML" display="inline"><mi>x</mi><mo>+</mo><mn>1</mn></math>.</p><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 30"><title>A diagram</title><rect x="0" y="0" width="90" height="20"/><text x="3" y="15">English SVG text</text></svg></body></html>''',
      );
      add(
        'OPS/nav.xhtml',
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="story.xhtml#chapter">Story</a></li></ol></nav></body></html>',
      );
      add(
        'OPS/toc.ncx',
        '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:uuid:9fe1ec30-3caf-43a5-a771-7590a9b4ac04"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>A Story</text></docTitle><navMap><navPoint id="c1" playOrder="1"><navLabel><text>Story</text></navLabel><content src="story.xhtml#chapter"/></navPoint></navMap></ncx>',
      );
      add(
        'OPS/style.css',
        'p { line-height: 1.6; } table { border-collapse: collapse; }',
      );
      files['OPS/pixel.png'] = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      final archive = Archive();
      for (final e in files.entries) {
        final f = ArchiveFile(e.key, e.value.length, e.value);
        if (e.key == 'mimetype') f.compression = CompressionType.none;
        archive.addFile(f);
      }
      await source.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final config = TranslationConfig.defaults();
      final inspection = await EpubTranslationRepository().startJob(
        inputPath: source.path,
        outputDirectory: out.path,
        config: config,
      );
      final chapters = [
        for (final c in inspection.chapters)
          c.copyWith(
            blocks: [
              for (final block in c.blocks)
                block.copyWith(
                  translatedHtml: block.sourceHtml
                      .replaceFirst('A short story with', '一个简短故事，含有')
                      .replaceFirst('Story', '故事')
                      .replaceFirst('A figure', '插图')
                      .replaceFirst('Values', '数值'),
                ),
            ],
          ),
      ];
      for (final bilingual in [false, true]) {
        final path = '${out.path}/${bilingual ? 'bilingual' : 'chinese'}.epub';
        final snapshots = <String, Object?>{};
        await EpubRepacker().writeTranslatedEpub(
          reviewChapterPaths: {'OPS/story.xhtml'},
          reviewSnapshots: snapshots,
          inputPath: source.path,
          outputFilePath: path,
          config: config.copyWith(bilingual: bilingual),
          chapters: chapters,
          translatedTitle: '故事',
        );
        expect(await File(path).exists(), isTrue);
        final story = chapters.singleWhere((c) => c.path == 'OPS/story.xhtml');
        final suggestions = [
          for (final block in story.blocks)
            if (block.tagName == 'h1' ||
                (block.tagName == 'td' && block.sourceText == 'One'))
              {
                'chapter': story.path,
                'id': block.id,
                'sourceHtml': block.sourceHtml,
                'beforeHtml': block.translatedHtml,
                'afterHtml': block.translatedHtml!
                    .replaceFirst('故事', '短篇故事')
                    .replaceFirst('One', '一'),
                'issues': ['Fixture semantic correction'],
                'accepted': false,
              },
        ];
        final reportPath = '$path.quality.json';
        await File(reportPath).writeAsString(
          jsonEncode({
            'version': 2,
            'outputPath': path,
            'corrections': suggestions,
            'rendering': {
              'bilingual': bilingual,
              'targetLanguage': 'Chinese',
              'lockedGlossary': '',
              'chapters': snapshots,
            },
          }),
        );
        final reviewed = await const TranslationReviewStore().export(
          reportPath: reportPath,
          baseOutputPath: path,
          accepted: suggestions
              .map(TranslationReviewStore.suggestionKey)
              .toSet(),
        );
        final zip = ZipDecoder().decodeBytes(
          await File(reviewed).readAsBytes(),
        );
        expect(
          utf8.decode(zip.findFile('OPS/nav.xhtml')!.content as List<int>),
          contains('短篇故事'),
        );
        expect(
          utf8.decode(zip.findFile('OPS/story.xhtml')!.content as List<int>),
          contains('>一<'),
        );
        await File(reviewed).copy(
          '${out.path}/${bilingual ? 'bilingual' : 'chinese'}-reviewed.epub',
        );
      }
    },
    skip: destination == null
        ? 'Set EPUBCHECK_OUTPUT_DIR to generate CI validation fixtures.'
        : false,
  );
}
