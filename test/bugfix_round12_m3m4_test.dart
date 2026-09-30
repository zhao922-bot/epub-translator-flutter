import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_text_decoder.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Round-12 regression tests: M3 (spine media-type parameters), M4 (`ad_`
/// left-boundary anchoring), the decoder's absolute replacement-count
/// threshold, and planner budgeting of bookMemory / snippet context.
void main() {
  group('M3: spine media-type with parameters is accepted', () {
    test('chapter declared as application/xhtml+xml; charset=utf-8 is '
        'inspected', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'bugfix_round12_m3_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File epubFile = File('${temp.path}/charset_param.epub');
      await epubFile.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(
              ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
            )
            ..addFile(
              ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    <item id="chapter-1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml; charset=utf-8"/>
  </manifest>
  <spine>
    <itemref idref="chapter-1"/>
  </spine>
</package>
'''),
            )
            ..addFile(
              ArchiveFile.string('OPS/Text/chapter1.xhtml', '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body><p>Hello world.</p></body>
</html>
'''),
            ),
        ),
        flush: true,
      );

      final result = await EpubTranslationRepository().startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: TranslationConfig.defaults(),
      );

      expect(result.chapters, hasLength(1));
      expect(result.chapters.single.path, 'OPS/Text/chapter1.xhtml');
      expect(result.chapters.single.blocks.single.sourceText, 'Hello world.');
    });
  });

  group('M4: ad_ requires a left token boundary', () {
    const EpubHtmlExtractor extractor = EpubHtmlExtractor();

    test('dead_end.xhtml is not classified as ancillary', () {
      expect(
        extractor.categorizeChapter('OEBPS/dead_end.xhtml', 'Dead End'),
        isNot(ChapterCategory.ancillary),
      );
    });

    test('read_along.xhtml is not classified as ancillary', () {
      expect(
        extractor.categorizeChapter('OEBPS/read_along.xhtml', 'Read Along'),
        isNot(ChapterCategory.ancillary),
      );
    });

    test('instead_of.xhtml is not classified as ancillary', () {
      expect(
        extractor.categorizeChapter('OEBPS/instead_of.xhtml', 'Instead Of'),
        isNot(ChapterCategory.ancillary),
      );
    });

    test('chapter_ad_2.xhtml is still classified as ancillary', () {
      expect(
        extractor.categorizeChapter('OEBPS/chapter_ad_2.xhtml', 'Chapter 2'),
        ChapterCategory.ancillary,
      );
    });

    test('other delimiter markers keep plain mid-token matching', () {
      expect(
        extractor.categorizeChapter('OEBPS/book_cvi_r1.htm', 'Example'),
        ChapterCategory.ancillary,
      );
      expect(
        extractor.categorizeChapter('OEBPS/book_cop_r1.htm', 'Example'),
        ChapterCategory.ancillary,
      );
    });
  });

  group('decoder: absolute replacement-count threshold', () {
    test('200 replacements in a 50k-char file now fail loudly', () {
      // 200 destroyed chars at 0.4% used to slip through the 1% ratio
      // clause; the absolute-count clause (100+) catches it.
      final List<int> bytes = <int>[
        ...List<int>.filled(50000, 0x61),
        ...List<int>.filled(200, 0xFF),
      ];
      expect(
        () => decodeEpubText(bytes: bytes, filePath: 'OEBPS/ch1.xhtml'),
        throwsFormatException,
      );
    });

    test('a few stray bytes in a large file still pass', () {
      final List<int> bytes = <int>[
        ...List<int>.filled(50000, 0x61),
        ...List<int>.filled(50, 0xFF),
      ];
      expect(
        decodeEpubText(bytes: bytes, filePath: 'OEBPS/ch1.xhtml'),
        hasLength(50050),
      );
    });
  });

  group('planner: context overhead counts toward the budget', () {
    ExtractedBlock block(String id, String char) => ExtractedBlock(
      id: id,
      tagName: 'p',
      sourceHtml: '<p>${char * 100}</p>',
      sourceText: char * 100,
    );

    test('a large bookMemory forces an extra batch split', () {
      // Each block: not tiny (100 > 80) -> budget = max(107, 100) + 96.
      final List<ExtractedBlock> blocks = <ExtractedBlock>[
        block('b0', 'x'),
        block('b1', 'y'),
      ];
      final List<TranslationBlockBatch> plain = const TranslationBatchPlanner()
          .plan(pendingBlocks: blocks, chunkSize: 500, chapterBlocks: blocks);
      expect(plain, hasLength(1));

      final List<TranslationBlockBatch> withMemory =
          const TranslationBatchPlanner().plan(
            pendingBlocks: blocks,
            chunkSize: 500,
            chapterBlocks: blocks,
            bookMemory: <String, Object?>{'summary': 'z' * 300},
          );
      // 406 block budget + ~314 serialized bookMemory > 500.
      expect(withMemory, hasLength(2));
    });

    test('before/after snippet context counts toward the budget', () {
      final List<ExtractedBlock> chapters = <ExtractedBlock>[
        block('b0', 'a'),
        block('b1', 'b'),
        block('b2', 'c'),
        block('b3', 'd'),
      ];
      final List<ExtractedBlock> pending = <ExtractedBlock>[
        chapters[1],
        chapters[2],
      ];
      // Block budgets alone (203 + 203 = 406 < 450) would merge; the batch
      // [b1, b2] also carries before=[b0] and after=[b3] snippets
      // (2 x (100 + id + framing) = 252 chars), which pushes it over.
      final List<TranslationBlockBatch> plan = const TranslationBatchPlanner()
          .plan(
            pendingBlocks: pending,
            chunkSize: 450,
            chapterBlocks: chapters,
          );
      expect(plan, hasLength(2));
    });
  });
}
