import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// Stress-tests isolate ZIP open + inspect + repack with a large synthetic EPUB.
///
/// Sized to be multi-MB so isolate I/O is meaningful, but still CI-friendly.
void main() {
  // ~3–5MB uncompressed HTML so isolate ZIP I/O is meaningful after compression.
  const int chapterCount = 120;
  const int paragraphsPerChapter = 60;
  const int wordsPerParagraph = 50;

  test(
    'isolate load + inspect + repack scales on a large synthetic EPUB',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_isolate_stress_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final File epubFile = File(path.join(temp.path, 'large_book.epub'));
      final Stopwatch buildWatch = Stopwatch()..start();
      await _writeLargeSyntheticEpub(
        epubFile,
        chapterCount: chapterCount,
        paragraphsPerChapter: paragraphsPerChapter,
        wordsPerParagraph: wordsPerParagraph,
      );
      buildWatch.stop();
      final int epubBytes = await epubFile.length();
      // Compressed size varies; require a solid multi-hundred-KB package.
      expect(epubBytes, greaterThan(500 * 1024));

      final Stopwatch openWatch = Stopwatch()..start();
      final Map<String, List<int>> files = await EpubInspector.openArchiveFiles(
        epubFile.path,
      );
      openWatch.stop();
      expect(files.length, greaterThan(chapterCount));
      expect(files.containsKey('META-INF/container.xml'), isTrue);

      final EpubInspector inspector = EpubInspector();
      final Stopwatch inspectWatch = Stopwatch()..start();
      final inspection = await inspector.inspect(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      inspectWatch.stop();

      expect(inspection.chapters.length, chapterCount);
      final int totalBlocks = inspection.chapters.fold<int>(
        0,
        (int sum, InspectedChapter c) => sum + c.blocks.length,
      );
      expect(
        totalBlocks,
        greaterThanOrEqualTo(chapterCount * paragraphsPerChapter),
      );

      final List<InspectedChapter> withTranslations = inspection.chapters
          .map((InspectedChapter chapter) {
            final List<ExtractedBlock> blocks = chapter.blocks
                .map(
                  (ExtractedBlock block) => block.copyWith(
                    translatedHtml:
                        '<${block.tagName}>译:${block.sourceText}</${block.tagName}>',
                  ),
                )
                .toList(growable: false);
            return chapter.copyWith(includeInTranslation: true, blocks: blocks);
          })
          .toList(growable: false);

      final String outputPath = path.join(temp.path, 'large_book_out.epub');
      final EpubRepacker repacker = EpubRepacker();
      final Stopwatch repackWatch = Stopwatch()..start();
      await repacker.writeTranslatedEpub(
        inputPath: epubFile.path,
        outputFilePath: outputPath,
        config: TranslationConfig.defaults(),
        chapters: withTranslations,
      );
      repackWatch.stop();

      final File outFile = File(outputPath);
      expect(await outFile.exists(), isTrue);
      // Output stays large (translated text is longer); compress size varies.
      expect(await outFile.length(), greaterThan(400 * 1024));

      final Map<String, dynamic> outFiles =
          await EpubIsolateWorker.loadArchiveFiles(outputPath);
      expect(outFiles.length, greaterThan(chapterCount));

      // Soft budgets — catch extreme regressions only.
      expect(openWatch.elapsed, lessThan(const Duration(seconds: 30)));
      expect(inspectWatch.elapsed, lessThan(const Duration(seconds: 60)));
      expect(repackWatch.elapsed, lessThan(const Duration(seconds: 45)));

      // ignore: avoid_print
      print(
        'isolate stress: epub=${epubBytes ~/ 1024}KB chapters=$chapterCount '
        'blocks=$totalBlocks build=${buildWatch.elapsedMilliseconds}ms '
        'open=${openWatch.elapsedMilliseconds}ms '
        'inspect=${inspectWatch.elapsedMilliseconds}ms '
        'repack=${repackWatch.elapsedMilliseconds}ms',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _writeLargeSyntheticEpub(
  File epubFile, {
  required int chapterCount,
  required int paragraphsPerChapter,
  required int wordsPerParagraph,
}) async {
  final Archive archive = Archive();
  archive.addFile(
    ArchiveFile.string('mimetype', 'application/epub+zip')
      ..compression = CompressionType.none,
  );
  archive.addFile(
    ArchiveFile.string(
      'META-INF/container.xml',
      '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
    ),
  );

  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  final Random random = Random(42);

  for (int i = 1; i <= chapterCount; i += 1) {
    final String id = 'ch$i';
    final String href = 'Text/chapter_$i.xhtml';
    manifest.writeln(
      '    <item id="$id" href="$href" media-type="application/xhtml+xml"/>',
    );
    spine.writeln('    <itemref idref="$id"/>');

    final StringBuffer body = StringBuffer();
    body.writeln('<!doctype html>');
    body.writeln(
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $i</title></head><body>',
    );
    for (int p = 0; p < paragraphsPerChapter; p += 1) {
      final String text = List<String>.generate(
        wordsPerParagraph,
        (int w) => 'w${random.nextInt(10000)}',
      ).join(' ');
      body.writeln('<p>$text</p>');
    }
    body.writeln('</body></html>');
    archive.addFile(ArchiveFile.string('OPS/$href', body.toString()));
  }

  archive.addFile(
    ArchiveFile.string(
      'OPS/content.opf',
      '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Large Stress Book</dc:title>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine>
$spine  </spine>
</package>''',
    ),
  );

  final List<int> encoded = ZipEncoder().encodeBytes(archive);
  await epubFile.parent.create(recursive: true);
  await epubFile.writeAsBytes(encoded, flush: true);
}
