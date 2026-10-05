import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for translated book titles in repacked EPUB metadata.
///
/// The finished book's OPF dc:title and NCX docTitle should show the
/// translated title so e-readers display the target-language title in the
/// library, instead of leaving the source-language title.
void main() {
  Map<String, List<int>> fakeArchive() {
    const String opfPath = 'OEBPS/content.opf';
    const String ncxPath = 'OEBPS/toc.ncx';
    final Map<String, List<int>> files = <String, List<int>>{
      'META-INF/container.xml': utf8.encode(
        '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="$opfPath" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
      opfPath: utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>The Gift of the Magi</dc:title>'
        '<dc:language>en</dc:language>'
        '</metadata>'
        '<manifest>'
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        '</manifest>'
        '<spine toc="ncx"></spine>'
        '</package>',
      ),
      ncxPath: utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<docTitle><text>The Gift of the Magi</text></docTitle>'
        '<navMap></navMap>'
        '</ncx>',
      ),
    };
    return files;
  }

  test('translated title updates OPF dc:title and NCX docTitle', () {
    final Map<String, String> result =
        EpubIsolateWorker.renderNavigationMetadata(
          archiveFiles: fakeArchive(),
          labelsByPath: const <String, String>{},
          languageTag: 'zh-CN',
          translatedTitle: '麦琪的礼物',
        );
    final String opf = result['OEBPS/content.opf']!;
    expect(opf, contains('<dc:title>麦琪的礼物</dc:title>'));
    expect(opf, isNot(contains('The Gift of the Magi')));
    final String ncx = result['OEBPS/toc.ncx']!;
    expect(ncx, contains('<text>麦琪的礼物</text>'));
  });

  test('null title leaves original metadata untouched', () {
    final Map<String, String> result =
        EpubIsolateWorker.renderNavigationMetadata(
          archiveFiles: fakeArchive(),
          labelsByPath: const <String, String>{},
          languageTag: 'zh-CN',
        );
    final String opf = result['OEBPS/content.opf']!;
    expect(opf, contains('The Gift of the Magi'));
    final String ncx = result['OEBPS/toc.ncx']!;
    expect(ncx, contains('<text>The Gift of the Magi</text>'));
  });
}
