import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

class CountingCheckpointStore extends TranslationCacheStore {
  int cumulativeBytes = 0;
  int finalBytes = 0;
  int writes = 0;
  int historyBytes = 0;
  @override
  Future<void> saveMemoryCheckpoint(
    JobResumeState state, {
    String? chunkHash,
    String? chunk,
  }) async {
    final headBytes = utf8.encode(jsonEncode(state.toJson())).length;
    final chunkBytes = chunk == null ? 0 : utf8.encode(chunk).length;
    historyBytes += chunkBytes;
    finalBytes = headBytes + historyBytes;
    cumulativeBytes += headBytes + chunkBytes;
    writes++;
  }
}

void main() {
  test('synthetic EPUB inspection and export without paid API', () async {
    final temp = await Directory.systemTemp.createTemp('epub_audit_perf_');
    addTearDown(() => temp.delete(recursive: true));
    for (final count in [20, 100, 300]) {
      final archive = Archive();
      archive.add(
        ArchiveFile.string('mimetype', 'application/epub+zip')
          ..compression = CompressionType.none,
      );
      archive.add(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        ),
      );
      final manifest = StringBuffer();
      final spine = StringBuffer();
      for (var chapter = 0; chapter < count; chapter++) {
        manifest.write(
          '<item id="c$chapter" href="c$chapter.xhtml" media-type="application/xhtml+xml"/>',
        );
        spine.write('<itemref idref="c$chapter"/>');
        archive.add(
          ArchiveFile.string(
            'OPS/c$chapter.xhtml',
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $chapter</title></head><body>'
                '<h1 id="heading">Chapter $chapter</h1>'
                '${List.generate(100, (p) => '<p id="p$p">Paragraph $p in chapter $chapter contains ordinary source prose for a controlled offline performance measurement.</p>').join()}'
                '</body></html>',
          ),
        );
      }
      archive.add(
        ArchiveFile.string(
          'OPS/book.opf',
          '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<metadata><dc:title>Benchmark</dc:title><dc:language>en</dc:language></metadata>'
              '<manifest>$manifest</manifest><spine>$spine</spine></package>',
        ),
      );
      final input = File('${temp.path}/book-$count.epub');
      await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final rssBefore = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();
      final inspection = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      final inspectMs = watch.elapsedMilliseconds;
      final rssAfterInspect = ProcessInfo.currentRss;
      final List<InspectedChapter> translated = [
        for (final chapter in inspection.chapters)
          chapter.copyWith(
            blocks: [
              for (final block in chapter.blocks)
                block.copyWith(
                  translatedHtml: block.sourceHtml
                      .replaceAll('Paragraph', 'Paragraphe')
                      .replaceAll('Chapter', 'Chapitre'),
                ),
            ],
          ),
      ];
      final output = File('${temp.path}/out-$count.epub');
      watch.reset();
      await EpubRepacker().writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: output.path,
        config: TranslationConfig.defaults().copyWith(targetLanguage: 'French'),
        chapters: translated,
      );
      final repackMs = watch.elapsedMilliseconds;
      final rssAfterExport = ProcessInfo.currentRss;
      final exported = ZipDecoder().decodeBytes(await output.readAsBytes());
      expect(inspection.chapters, hasLength(count));
      expect(
        XmlDocument.parse(
          utf8.decode(exported.find('OPS/c0.xhtml')!.content),
        ).rootElement.namespaceUri,
        'http://www.w3.org/1999/xhtml',
      );
      stdout.writeln(
        'PERF chapters=$count blocks=${inspection.job.totalBlocks} '
        'zipBytes=${await input.length()} inspectMs=$inspectMs repackMs=$repackMs '
        'rssBefore=$rssBefore rssAfterInspect=$rssAfterInspect rssAfterExport=$rssAfterExport',
      );
    }
  });

  test('measure actual checkpoint payload amplification', () async {
    for (final count in [100, 300, 600]) {
      final store = CountingCheckpointStore();
      final writer =
          await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
            cacheStore: store,
            jobKey: 'audit-memory',
            chunkSize: 3000,
          );
      final timeline = <({String path, Map<String, Object?> memory})>[];
      for (var i = 0; i < count; i++) {
        timeline.add((
          path: 'OPS/c$i.xhtml',
          memory: {
            'bookSummary': 'A compact summary of the earlier chapters. ' * 10,
            'glossary': List.generate(
              10,
              (t) => {'source': 'Name $t', 'target': '译名$t'},
            ),
          },
        ));
        await writer(timeline);
      }
      stdout.writeln(
        'CHECKPOINT chapters=$count writes=${store.writes} '
        'finalBytes=${store.finalBytes} cumulativeBytes=${store.cumulativeBytes} '
        'amplification=${(store.cumulativeBytes / store.finalBytes).toStringAsFixed(1)}',
      );
      expect(store.writes, count);
    }
  });
}
