import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// B-05 regression: inspection job ids must carry the `-seq` suffix
/// (`<ms>-<seq>`), mirroring the dashboard controller's `_newJobId`, so two
/// inspections started within the same millisecond cannot collide. The
/// controller also parses the id prefix (`job.id.split('-').first`) for the
/// history-clear watermark, so the ms prefix must stay parseable.
void main() {
  group('B-05 inspection job id -seq suffix', () {
    test('rapid ids are distinct and match <ms>-<seq>', () {
      final ids = <String>{
        for (int i = 0; i < 200; i++) EpubInspector.newJobIdForTest(),
      };
      expect(ids, hasLength(200));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^\d+-\d+$')));
        // The controller's watermark parser reads the ms prefix.
        expect(int.tryParse(id.split('-').first), isNotNull);
      }
    });

    test('two inspections in the same millisecond get different ids',
        () async {
      final dir = await Directory.systemTemp.createTemp('b05_jobid_');
      addTearDown(() => dir.delete(recursive: true));
      final first = await EpubInspector().inspect(
        inputPath: _minimalBook(dir).path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      final second = await EpubInspector().inspect(
        inputPath: _minimalBook(dir).path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      expect(first.job.id, matches(RegExp(r'^\d+-\d+$')));
      expect(second.job.id, matches(RegExp(r'^\d+-\d+$')));
      expect(second.job.id, isNot(first.job.id));
    });
  });
}

File _minimalBook(Directory dir) {
  final archive = Archive();
  final files = <String, List<int>>{
    'META-INF/container.xml': utf8.encode(
      '<container><rootfile full-path="OPS/book.opf"/></container>',
    ),
    'OPS/book.opf': utf8.encode(
      '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>t</dc:title><dc:language>en</dc:language></metadata>
<manifest><item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="c0"/></spine></package>''',
    ),
    'OPS/c0.xhtml': utf8.encode('<html><body><p>Hi.</p></body></html>'),
  };
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  final file = File(path.join(dir.path, 'source.epub'));
  file.writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  return file;
}
