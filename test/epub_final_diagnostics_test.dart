import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';

void main() {
  for (final bilingual in [false, true]) {
    test(
      'post-navigation content state preserves fallback history bilingual=$bilingual',
      () async {
        final dir = await Directory.systemTemp.createTemp('final-diagnostics-');
        addTearDown(() => dir.delete(recursive: true));
        const toc =
            '<html><head><title>Contents</title></head><body><p><a href="chapter.xhtml">The Road</a></p></body></html>';
        const chapter =
            '<html><body><h1>The Road</h1><h2>(The Journey)</h2><p>Walking.</p></body></html>';
        const extractor = EpubHtmlExtractor();
        final sourceToc = extractor.inspectChapterBytes(
          chapterPath: 'toc.xhtml',
          bytes: utf8.encode(toc),
        );
        final sourceChapter = extractor.inspectChapterBytes(
          chapterPath: 'chapter.xhtml',
          bytes: utf8.encode(chapter),
        );
        final chapters = [
          sourceToc.copyWith(
            includeInTranslation: true,
            blocks: [
              sourceToc.blocks.single.copyWith(
                translatedHtml: sourceToc.blocks.single.sourceHtml,
              ),
            ],
          ),
          sourceChapter.copyWith(
            includeInTranslation: true,
            blocks: [
              sourceChapter.blocks[0].copyWith(translatedHtml: '<h1>道路</h1>'),
              sourceChapter.blocks[1].copyWith(translatedHtml: '<h2>（旅途）</h2>'),
              sourceChapter.blocks[2].copyWith(translatedHtml: '<p>步行。</p>'),
            ],
          ),
        ];
        final archive = Archive();
        for (final entry in {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container><rootfile full-path="book.opf"/></container>',
          'book.opf':
              '<package><metadata/><manifest><item id="t" href="toc.xhtml" media-type="application/xhtml+xml"/><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="t"/><itemref idref="c"/></spine></package>',
          'toc.xhtml': toc,
          'chapter.xhtml': chapter,
        }.entries) {
          archive.addFile(ArchiveFile.string(entry.key, entry.value));
        }
        final input = File('${dir.path}/source.epub');
        await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
        final snapshots = <String, Object?>{};
        await EpubRepacker().writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: '${dir.path}/result.epub',
          config: TranslationConfig.defaults().copyWith(bilingual: bilingual),
          chapters: chapters,
          degradedBlockIds: {'toc.xhtml\u0000${sourceToc.blocks.single.id}'},
          reviewChapterPaths: {'toc.xhtml'},
          reviewSnapshots: snapshots,
        );
        final snapshot = snapshots['toc.xhtml'] as Map;
        expect(snapshot['translations'], {
          sourceToc.blocks.single.id: sourceToc.blocks.single.sourceHtml,
        });
        expect(snapshot['finalDegradedBlocks'], {
          sourceToc.blocks.single.id: 'modifiedNeedsReview',
        });
        final result = ZipDecoder().decodeBytes(
          await File('${dir.path}/result.epub').readAsBytes(),
        );
        expect(
          utf8.decode(result.findFile('toc.xhtml')!.content),
          contains('道路（旅途）'),
        );
      },
    );
  }
}
