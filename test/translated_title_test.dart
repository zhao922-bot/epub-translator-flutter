import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart' as xml;

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
    expect(opf, contains('<dc:title xml:lang="zh-CN">麦琪的礼物</dc:title>'));
    expect(opf, isNot(contains('The Gift of the Magi')));
    final String ncx = result['OEBPS/toc.ncx']!;
    expect(ncx, contains('<text xml:lang="zh-CN">麦琪的礼物</text>'));
  });

  test('translated title overrides local source-language declarations', () {
    final files = fakeArchive();
    files['OEBPS/content.opf'] = utf8.encode(
      utf8
          .decode(files['OEBPS/content.opf']!)
          .replaceFirst('<dc:title>', '<dc:title xml:lang="en">'),
    );
    files['OEBPS/toc.ncx'] = utf8.encode(
      utf8
          .decode(files['OEBPS/toc.ncx']!)
          .replaceFirst(
            '<docTitle><text>',
            '<docTitle xml:lang="en"><text xml:lang="en">',
          ),
    );
    final result = EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: files,
      labelsByPath: const {},
      languageTag: 'zh-TW',
      translatedTitle: '麥琪的禮物',
    );
    for (final entry in result.entries) {
      final document = xml.XmlDocument.parse(entry.value);
      for (final element
          in document.descendants.whereType<xml.XmlElement>().where(
            (e) => ['title', 'docTitle', 'text'].contains(e.name.local),
          )) {
        expect(element.getAttribute('xml:lang'), 'zh-TW');
      }
    }
  });

  test('ambiguous and mixed CJK titles still request translation', () {
    for (final pair in [
      ['夏の旅', 'Chinese'],
      ['中文书名', 'Korean'],
      ['龙与书', 'Traditional Chinese'],
      ['龍與書', 'Simplified Chinese'],
      ['東京', 'Chinese'],
      ['中文 English', 'Chinese'],
      ['日本語 English', 'Japanese'],
      ['한국어 中文', 'Korean'],
    ]) {
      expect(
        EpubChapterTranslator.titleAlreadyInTargetLanguage(pair[0], pair[1]),
        isFalse,
      );
    }
    expect(
      EpubChapterTranslator.titleAlreadyInTargetLanguage('夏の旅', 'Japanese'),
      isTrue,
    );
    expect(
      EpubChapterTranslator.titleAlreadyInTargetLanguage('한국의 책', 'Korean'),
      isTrue,
    );
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
