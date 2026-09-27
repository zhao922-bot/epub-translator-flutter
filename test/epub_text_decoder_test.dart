import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_text_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// "中文" encoded in GBK: D6 D0 CE C4. Decoded as UTF-8 these bytes are
/// malformed, so without the encoding sniff they would silently become
/// U+FFFD confetti.
List<int> _gbkChapterBytes(String declaredEncoding) {
  return <int>[
    ...utf8.encode(
      '<?xml version="1.0" encoding="$declaredEncoding"?>\n'
      '<html><head><title>T</title></head><body><p>',
    ),
    0xD6, 0xD0, 0xCE, 0xC4,
    ...utf8.encode('</p></body></html>'),
  ];
}

void main() {
  const EpubHtmlExtractor extractor = EpubHtmlExtractor();

  group('decodeEpubText', () {
    test('GBK declaration fails loud with file path and encoding name', () {
      expect(
        () => decodeEpubText(
          bytes: _gbkChapterBytes('GBK'),
          filePath: 'OEBPS/chapter01.xhtml',
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            allOf(
              contains('OEBPS/chapter01.xhtml'),
              contains('GBK'),
            ),
          ),
        ),
      );
    });

    test('Shift_JIS declared via meta charset fails loud', () {
      final List<int> bytes = <int>[
        ...utf8.encode(
          '<html><head><meta charset="Shift_JIS"><title>T</title></head>'
          '<body><p>',
        ),
        0x82, 0xA0, // some Shift_JIS bytes
        ...utf8.encode('</p></body></html>'),
      ];
      expect(
        () => decodeEpubText(bytes: bytes, filePath: 'OEBPS/c2.xhtml'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            allOf(contains('OEBPS/c2.xhtml'), contains('Shift_JIS')),
          ),
        ),
      );
    });

    test('http-equiv content-type charset declaration is honored', () {
      final List<int> bytes = utf8.encode(
        '<html><head>'
        '<meta http-equiv="Content-Type" content="text/html; charset=Big5">'
        '<title>T</title></head><body><p>x</p></body></html>',
      );
      expect(
        () => decodeEpubText(bytes: bytes, filePath: 'OEBPS/c3.xhtml'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('Big5'),
          ),
        ),
      );
    });

    test('UTF-8 without declaration decodes as before', () {
      const String text = '<html><body><p>中文 English</p></body></html>';
      expect(
        decodeEpubText(
          bytes: utf8.encode(text),
          filePath: 'OEBPS/c4.xhtml',
        ),
        text,
      );
    });

    test('lowercase utf-8 declaration keeps lenient decoding', () {
      final List<int> bytes = utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><html><body><p>ok</p></body></html>',
      );
      expect(
        decodeEpubText(bytes: bytes, filePath: 'OEBPS/c5.xhtml'),
        contains('ok'),
      );
    });

    test('UTF8 spelling variant is accepted', () {
      final List<int> bytes = utf8.encode(
        '<?xml version="1.0" encoding="UTF8"?><html><body><p>ok</p></body></html>',
      );
      expect(
        decodeEpubText(bytes: bytes, filePath: 'OEBPS/c6.xhtml'),
        contains('ok'),
      );
    });

    test('malformed UTF-8 still replaced when not strict', () {
      final List<int> bytes = <int>[
        ...utf8.encode('<html><body><p>'),
        0xFF, // invalid UTF-8 byte
        ...utf8.encode('</p></body></html>'),
      ];
      final String decoded = decodeEpubText(
        bytes: bytes,
        filePath: 'OEBPS/c7.xhtml',
      );
      expect(decoded, contains('�'));
    });

    test('strict mode throws on malformed UTF-8 with file name', () {
      final List<int> bytes = <int>[
        ...utf8.encode('<package>'),
        0xFF,
        ...utf8.encode('</package>'),
      ];
      expect(
        () => decodeEpubText(
          bytes: bytes,
          filePath: 'OEBPS/content.opf',
          strict: true,
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('OEBPS/content.opf'),
          ),
        ),
      );
    });

    test('strict mode accepts valid UTF-8 metadata', () {
      const String xml = '<?xml version="1.0"?><package>ok</package>';
      expect(
        decodeEpubText(
          bytes: utf8.encode(xml),
          filePath: 'OEBPS/content.opf',
          strict: true,
        ),
        xml,
      );
    });
  });

  group('inspectChapterBytes encoding gate', () {
    test('meta charset after 2KB of head padding is still detected', () {
      // A-L1: <meta charset> may trail long <head> preambles; the HTML sniff
      // window is 8 KB, so a declaration at ~4 KB must still fail loud.
      final String padding = '<!-- ${'x' * 4096} -->';
      final List<int> bytes = utf8.encode(
        '<html><head>$padding<meta charset="GBK"><title>T</title></head>'
        '<body><p>hi</p></body></html>',
      );
      expect(bytes.length, greaterThan(2048));
      expect(
        () => decodeEpubText(bytes: bytes, filePath: 'OEBPS/late.xhtml'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('GBK'),
          ),
        ),
      );
    });

    test('GBK chapter is rejected instead of silently garbled', () {
      expect(
        () => extractor.inspectChapterBytes(
          chapterPath: 'OEBPS/gbk.xhtml',
          bytes: _gbkChapterBytes('GBK'),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            allOf(contains('OEBPS/gbk.xhtml'), contains('GBK')),
          ),
        ),
      );
    });

    test('UTF-8 chapter without declaration still inspects', () {
      final chapter = extractor.inspectChapterBytes(
        chapterPath: 'OEBPS/ok.xhtml',
        bytes: utf8.encode(
          '<html><head><title>T</title></head><body><p>Hello</p></body></html>',
        ),
      );
      expect(chapter.blocks, hasLength(1));
      expect(chapter.blocks.single.sourceText, 'Hello');
    });
  });
}
