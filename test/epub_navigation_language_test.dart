import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty navigation labels still rewrite the OPF language tag', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'epub_nav_language_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final File input = File('${tempDir.path}/book.epub');
    await _writeMinimalEpub(input);

    // No chapter produced a navigation label (e.g. a book with no h1-h3
    // headings), but the target language is known: the OPF
    // <dc:language> must still be rewritten.
    final String
    tempPath = await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
      inputPath: input.path,
      outputFilePath: '${tempDir.path}/book-zh.epub',
      translatedHtmlByPath: const <String, String>{
        'OEBPS/chapter.xhtml':
            '<?xml version="1.0"?><html><body><p>translated</p></body></html>',
      },
      navigationLabelsByPath: const <String, String>{},
      navigationLanguageTag: 'zh-CN',
    );

    final Map<String, List<int>> files =
        await EpubIsolateWorker.loadArchiveFiles(tempPath);
    final String opf = String.fromCharCodes(files['OEBPS/content.opf']!);
    expect(opf, contains('<dc:language>zh-CN</dc:language>'));
    expect(opf, isNot(contains('<dc:language>en</dc:language>')));
  });
}

Future<void> _writeMinimalEpub(File file) async {
  final Archive archive = Archive();
  final List<int> mimetype = 'application/epub+zip'.codeUnits;
  archive.add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));
  const String container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.add(ArchiveFile.bytes('META-INF/container.xml', container.codeUnits));
  const String opf = '''<?xml version="1.0"?>
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
  const String chapter =
      '<?xml version="1.0"?><html><body><p>source</p></body></html>';
  archive.add(ArchiveFile.bytes('OEBPS/chapter.xhtml', chapter.codeUnits));
  final List<int> bytes = ZipEncoder().encodeBytes(archive);
  await file.writeAsBytes(bytes, flush: true);
}
