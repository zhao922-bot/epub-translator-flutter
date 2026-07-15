import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('repack cancellation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_repack_cancel_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'cancelled token refuses commit and preserves existing output',
      () async {
        final File input = File(path.join(tempDir.path, 'book.epub'));
        final File output = File(path.join(tempDir.path, 'book_out.epub'));
        await _writeMinimalEpub(input, body: 'source');
        const String previous = 'PREVIOUS_OUTPUT_MARKER';
        await output.writeAsString(previous, flush: true);

        final CancelToken token = CancelToken()..cancel('pre-cancelled');
        final EpubRepacker repacker = EpubRepacker();

        await expectLater(
          repacker.writeTranslatedEpub(
            inputPath: input.path,
            outputFilePath: output.path,
            config: TranslationConfig.defaults(),
            chapters: <InspectedChapter>[
              InspectedChapter(
                path: 'OEBPS/chapter.xhtml',
                title: 'Chapter',
                body: 'source',
                originalHtml:
                    '<?xml version="1.0"?><html><body><p>source</p></body></html>',
                blocks: const <ExtractedBlock>[
                  ExtractedBlock(
                    id: 'b1',
                    tagName: 'p',
                    sourceHtml: '<p>source</p>',
                    sourceText: 'source',
                    translatedHtml: '<p>translated-new</p>',
                  ),
                ],
                category: ChapterCategory.content,
                recommendedForTranslation: true,
                includeInTranslation: true,
              ),
            ],
            cancelToken: token,
          ),
          throwsA(isA<TranslationCancelledException>()),
        );

        expect(await output.readAsString(), previous);
        final List<FileSystemEntity> leftovers = tempDir
            .listSync()
            .where(
              (FileSystemEntity entity) =>
                  entity.path.contains('.tmp.') ||
                  entity.path.contains('.bak.'),
            )
            .toList();
        expect(leftovers, isEmpty);
      },
    );

    test('isCancelled callback after isolate prep blocks final commit', () async {
      final File input = File(path.join(tempDir.path, 'book.epub'));
      final File output = File(path.join(tempDir.path, 'book_out.epub'));
      await _writeMinimalEpub(input, body: 'source');
      const String previous = 'KEEP_ME';
      await output.writeAsString(previous, flush: true);

      bool cancelled = false;
      final EpubRepacker repacker = EpubRepacker();

      // Flip cancel during shouldCommit by cancelling before the async write
      // returns: start with not cancelled, then cancel immediately via token
      // after a microtask so rendering starts then commit is refused.
      final CancelToken token = CancelToken();
      final Future<void> write = repacker.writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: output.path,
        config: TranslationConfig.defaults(),
        chapters: <InspectedChapter>[
          InspectedChapter(
            path: 'OEBPS/chapter.xhtml',
            title: 'Chapter',
            body: 'source',
            originalHtml:
                '<?xml version="1.0"?><html><body><p>source</p></body></html>',
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'b1',
                tagName: 'p',
                sourceHtml: '<p>source</p>',
                sourceText: 'source',
                translatedHtml: '<p>translated-new</p>',
              ),
            ],
            category: ChapterCategory.content,
            recommendedForTranslation: true,
            includeInTranslation: true,
          ),
        ],
        cancelToken: token,
        isCancelled: () => cancelled,
      );

      // Cancel while isolate is (or will be) running so shouldCommit is false.
      cancelled = true;
      token.cancel('mid-repack');

      await expectLater(write, throwsA(isA<TranslationCancelledException>()));
      expect(await output.readAsString(), previous);
    });
  });
}

Future<void> _writeMinimalEpub(File file, {required String body}) async {
  final Archive archive = Archive();
  final List<int> mimetype = 'application/epub+zip'.codeUnits;
  archive.add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));
  final String container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.add(ArchiveFile.bytes('META-INF/container.xml', container.codeUnits));
  final String opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test</dc:title>
    <dc:identifier id="id">test-id</dc:identifier>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>''';
  archive.add(ArchiveFile.bytes('OEBPS/content.opf', opf.codeUnits));
  final String chapter =
      '<?xml version="1.0"?><html><body><p>$body</p></body></html>';
  archive.add(ArchiveFile.bytes('OEBPS/chapter.xhtml', chapter.codeUnits));
  final List<int> bytes = ZipEncoder().encodeBytes(archive);
  await file.writeAsBytes(bytes, flush: true);
}
