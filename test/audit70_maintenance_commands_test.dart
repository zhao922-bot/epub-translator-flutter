import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import '../tool/rebuild_translated_epub.dart' as rebuild;
import '../tool/repair_epub_xhtml.dart' as repair;

void main() {
  for (final entry in {
    'repair': repair.main,
    'rebuild': rebuild.main,
  }.entries) {
    test(
      '${entry.key}: actual main creates a readable EPUB under Flutter VM',
      () async {
        final temp = await Directory.systemTemp.createTemp('audit-r32-tools-');
        addTearDown(() => temp.delete(recursive: true));
        final archive = Archive()
          ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
          ..addFile(
            ArchiveFile.string(
              'META-INF/container.xml',
              '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'OPS/book.opf',
              '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="uid"><metadata><dc:identifier id="uid">offline</dc:identifier><dc:title>本地书</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'OPS/c.xhtml',
              '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>章节</title></head><body><p>本地诊断 <strong>保留文字</strong></p></body></html>',
            ),
          );
        final input = await File(
          '${temp.path}/input.epub',
        ).writeAsBytes(ZipEncoder().encodeBytes(archive));
        final output = File('${temp.path}/output.epub');
        await entry.value([input.path, output.path]);
        final exported = ZipDecoder().decodeBytes(await output.readAsBytes());
        expect(
          utf8.decode(exported.findFile('OPS/c.xhtml')!.content as List<int>),
          allOf(contains('本地诊断'), contains('保留文字')),
        );
        expect(exported.findFile('OPS/book.opf'), isNotNull);
        final originalBytes = await output.readAsBytes();
        await expectLater(
          entry.value([input.path, output.path]),
          throwsArgumentError,
        );
        expect(await output.readAsBytes(), orderedEquals(originalBytes));
        await expectLater(
          entry.value([input.path, input.path]),
          throwsArgumentError,
        );
        debugPrint(
          'AUDIT ${entry.key}: actual production main exported ZIP and refused existing/same output; no API requests.',
        );
      },
    );
  }
}
