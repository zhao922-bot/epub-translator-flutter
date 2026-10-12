import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/chapter_source_restorer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Map<String, List<int>> _metadata() => <String, List<int>>{
  'mimetype': utf8.encode('application/epub+zip'),
  'META-INF/container.xml': utf8.encode(
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>'
    '</rootfiles></container>',
  ),
  'OPS/content.opf': utf8.encode(
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Restore Test</dc:title>'
    '<dc:identifier id="id">restore-test</dc:identifier><dc:language>en</dc:language></metadata>'
    '<manifest><item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>'
    '<spine toc="ncx"><itemref idref="c0"/></spine></package>',
  ),
  'OPS/toc.ncx': utf8.encode(
    '<ncx><docTitle><text>Restore Test</text></docTitle><navMap><navPoint>'
    '<navLabel><text>Ch</text></navLabel><content src="c0.xhtml"/>'
    '</navPoint></navMap></ncx>',
  ),
};

File _book(Directory dir) {
  final files = _metadata();
  files['OPS/c0.xhtml'] = utf8.encode(
    '<html><body><p>Hello world, this is a test chapter.</p>'
    '<p>Second paragraph for good measure.</p></body></html>',
  );
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return File(path.join(dir.path, 'source.epub'))
    ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

/// Simulates exactly what the dashboard's onChapterSourcesReleased handler
/// does: drop originalHtml and per-block sources, keep the preview excerpt.
InspectedChapter _releaseUiSources(InspectedChapter chapter) =>
    chapter.copyWith(
      originalHtml: '',
      blocks: <ExtractedBlock>[
        for (final block in chapter.blocks)
          block.copyWith(sourceHtml: '', sourceText: ''),
      ],
    );

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('restorer_a1_');
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'A-1: restore recovers released originalHtml from the source archive',
    () async {
      final book = _book(dir);
      final inspected = await EpubInspector().inspect(
        inputPath: book.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      expect(inspected.job.status, TranslationJobStatus.inspected);
      expect(inspected.chapters, hasLength(1));
      final chapter = inspected.chapters.single;
      expect(chapter.sourceIdentity, isNotNull);
      expect(chapter.blocks, isNotEmpty);

      // Simulate a cancelled run: the worker spooled sources and the
      // dashboard dropped its UI-side copies.
      final released = _releaseUiSources(chapter);
      expect(released.originalHtml, isEmpty);
      expect(
        released.blocks.every((b) => b.sourceHtml.isEmpty),
        isTrue,
      );

      // Before the fix this threw FormatException('Source block order
      // changed'): utf8.encode('') yields zero blocks.
      final restored = await ChapterSourceRestorer.restore(
        chapters: [released],
        isCancelled: () => false,
      );
      expect(restored, hasLength(1));
      final back = restored.single;
      expect(back.originalHtml, isNotEmpty);
      expect(
        back.blocks.every((b) => b.sourceHtml.isNotEmpty),
        isTrue,
        reason: 'block sources must be re-parsed from the archive',
      );
      expect(back.blocks.length, chapter.blocks.length);
      expect(
        back.blocks.map((b) => b.id),
        orderedEquals(chapter.blocks.map((b) => b.id)),
      );
    },
  );

  test(
    'A-1: restore without sourceIdentity fails loudly instead of silently',
    () async {
      final book = _book(dir);
      final inspected = await EpubInspector().inspect(
        inputPath: book.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      final chapter = inspected.chapters.single;
      // Strip the identity too: nothing recoverable remains. copyWith
      // cannot null it out (?? this.sourceIdentity), so rebuild directly.
      final stripped = _releaseUiSources(chapter);
      final released = InspectedChapter(
        path: stripped.path,
        title: stripped.title,
        body: stripped.body,
        originalHtml: stripped.originalHtml,
        blocks: stripped.blocks,
        category: stripped.category,
        recommendedForTranslation: stripped.recommendedForTranslation,
        includeInTranslation: stripped.includeInTranslation,
        sourceIdentity: null,
      );

      await expectLater(
        ChapterSourceRestorer.restore(
          chapters: [released],
          isCancelled: () => false,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no recoverable source'),
          ),
        ),
      );
    },
  );

  test(
    'A-1: chapters that never lost originalHtml skip the archive reload',
    () async {
      final book = _book(dir);
      final inspected = await EpubInspector().inspect(
        inputPath: book.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      final chapter = inspected.chapters.single;
      // Only block sources released (legacy shape): no archive hit needed.
      final released = chapter.copyWith(
        blocks: <ExtractedBlock>[
          for (final block in chapter.blocks)
            block.copyWith(sourceHtml: '', sourceText: ''),
        ],
      );

      final restored = await ChapterSourceRestorer.restore(
        chapters: [released],
        isCancelled: () => false,
      );
      expect(restored.single.blocks.every((b) => b.sourceHtml.isNotEmpty), isTrue);
    },
  );
}
