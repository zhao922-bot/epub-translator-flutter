import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('atomic EPUB write', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_atomic_write_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'writes via temp file and replaces without corrupting existing output',
      () async {
        final File input = File(path.join(tempDir.path, 'book.epub'));
        final File output = File(path.join(tempDir.path, 'book_out.epub'));
        await _writeMinimalEpub(input, body: 'original');
        await output.writeAsString('EXISTING_OUTPUT_MARKER', flush: true);

        final bool committed = await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: const <String, String>{
            'OEBPS/chapter.xhtml':
                '<?xml version="1.0"?><html><body><p>translated</p></body></html>',
          },
        );

        expect(committed, isTrue);
        expect(await output.exists(), isTrue);
        final List<int> bytes = await output.readAsBytes();
        expect(
          String.fromCharCodes(bytes),
          isNot(contains('EXISTING_OUTPUT_MARKER')),
        );
        // No leftover temp files in the output directory.
        final List<FileSystemEntity> leftovers = tempDir
            .listSync()
            .where(
              (FileSystemEntity entity) =>
                  entity.path.contains('.tmp.') ||
                  entity.path.contains('.bak.'),
            )
            .toList();
        expect(leftovers, isEmpty);

        final Map<String, List<int>> files =
            await EpubIsolateWorker.loadArchiveFiles(output.path);
        expect(utf8Body(files['OEBPS/chapter.xhtml']!), contains('translated'));
      },
    );

    test(
      'refusing commit deletes temp and leaves existing final file intact',
      () async {
        final File input = File(path.join(tempDir.path, 'book.epub'));
        final File output = File(path.join(tempDir.path, 'book_out.epub'));
        await _writeMinimalEpub(input, body: 'original');
        const String existing = 'PREVIOUS_GOOD_EPUB_BYTES';
        await output.writeAsString(existing, flush: true);

        final bool committed = await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: const <String, String>{
            'OEBPS/chapter.xhtml':
                '<?xml version="1.0"?><html><body><p>new</p></body></html>',
          },
          shouldCommit: () => false,
        );

        expect(committed, isFalse);
        expect(await output.readAsString(), existing);
        final List<FileSystemEntity> leftovers = tempDir
            .listSync()
            .where((FileSystemEntity entity) => entity.path.contains('.tmp.'))
            .toList();
        expect(leftovers, isEmpty);
      },
    );

    test(
      'commitTempFileSync restores backup if promotion fails path is isolated',
      () {
        final File finalFile = File(path.join(tempDir.path, 'final.epub'));
        final File tempFile = File(path.join(tempDir.path, 'final.epub.tmp.1'));
        finalFile.writeAsStringSync('OLD');
        tempFile.writeAsStringSync('NEW');

        EpubIsolateWorker.commitTempFileSyncForTest(tempFile, finalFile);

        expect(finalFile.readAsStringSync(), 'NEW');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'abort after backup move restores old final and cleans temp/bak',
      () async {
        final File finalFile = File(path.join(tempDir.path, 'final.epub'));
        final File tempFile = File(
          path.join(tempDir.path, 'final.epub.tmp.race'),
        );
        const String oldContent = 'OLD_FINAL_CONTENT';
        await finalFile.writeAsString(oldContent, flush: true);
        await tempFile.writeAsString('NEW_TEMP_CONTENT', flush: true);

        // 1st check (before backup): true
        // 2nd check (after backup, before promote): false
        int checks = 0;
        final bool committed = await EpubIsolateWorker.commitTempFile(
          tempFile,
          finalFile,
          shouldCommit: () {
            checks += 1;
            return checks <= 1;
          },
        );

        expect(committed, isFalse);
        expect(checks, 2);
        expect(await finalFile.readAsString(), oldContent);
        expect(await tempFile.exists(), isFalse);
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

    test(
      'writeTranslatedEpub aborts after backup when later shouldCommit is false',
      () async {
        final File input = File(path.join(tempDir.path, 'book.epub'));
        final File output = File(path.join(tempDir.path, 'book_out.epub'));
        await _writeMinimalEpub(input, body: 'original');
        const String existing = 'PREVIOUS_GOOD_BYTES';
        await output.writeAsString(existing, flush: true);

        // Outer pre-check true, before-backup true, after-backup false.
        int checks = 0;
        final bool committed = await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: const <String, String>{
            'OEBPS/chapter.xhtml':
                '<?xml version="1.0"?><html><body><p>new</p></body></html>',
          },
          shouldCommit: () {
            checks += 1;
            return checks <= 2;
          },
        );

        expect(committed, isFalse);
        expect(checks, 3);
        expect(await output.readAsString(), existing);
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
  });
}

String utf8Body(List<int> bytes) => String.fromCharCodes(bytes);

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
