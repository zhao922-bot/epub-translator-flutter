import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_xml_characters.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_text_decoder.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';

void main() {
  for (final invalid in [
    '\u0000',
    '\u0001',
    '\u000b',
    '\ufffe',
    '\uffff',
    '\ud800',
    '\udfff',
  ]) {
    test(
      'XML 1.0 rejects scalar ${invalid.codeUnitAt(0).toRadixString(16)} before parsing',
      () {
        expect(
          () => XhtmlHtmlCompatibility.parseFragment('<p>Hello$invalid</p>'),
          throwsFormatException,
        );
      },
    );
  }
  test('valid supplementary characters and XML whitespace survive', () {
    const text = '中😀\t\n\r\u0085';
    expect(() => validateEpubXmlCharacters(text), returnsNormally);
    expect(
      () => XhtmlHtmlCompatibility.parseFragment('<p>$text</p>'),
      returnsNormally,
    );
  });
  test('surrogate boundaries distinguish valid pairs from isolated halves', () {
    for (final text in [
      '\u{10000}',
      '\u{10ffff}',
      '\ud800\udc00',
      '\udbff\udfff',
    ]) {
      expect(() => validateEpubXmlCharacters(text), returnsNormally);
    }
    for (final text in [
      '\ud800x',
      'x\udfff',
      '\ud800\ud800\udc00',
      '\udfff\udbff\udfff',
    ]) {
      expect(() => validateEpubXmlCharacters(text), throwsFormatException);
    }
  });
  test(
    'invalid references are rejected; literal examples in CDATA/comments are allowed',
    () {
      for (final markup in [
        '<p>&#1;</p>',
        '<p a="&#xD800;">x</p>',
        '<p>&#x0;</p>',
        '<p>&#1114112;</p>',
        '<p>&#1</p>',
        '<p a="&#x1">x</p>',
      ]) {
        expect(
          () => XhtmlHtmlCompatibility.parseFragment(markup),
          throwsFormatException,
        );
      }
      expect(
        () => validateEpubXmlMarkup('<p><![CDATA[&#1;]]><!-- &#x0; --></p>'),
        returnsNormally,
      );
      expect(
        XhtmlHtmlCompatibility.parseFragment('<p>&amp;#1;</p>').text,
        '&#1;',
      );
    },
  );
  test('invalid input content fails before any translation', () {
    expect(
      () => decodeEpubText(
        bytes: utf8.encode('<p>Bad\u0001</p>'),
        filePath: 'c.xhtml',
      ),
      throwsFormatException,
    );
  });
  test(
    'old invalid cache is rejected while valid paid translations remain reusable',
    () async {
      final dir = await Directory.systemTemp.createTemp('xml-cache-');
      final cache = TranslationCacheStore(cacheRoot: dir);
      try {
        await cache.putBlockTranslation('valid', '<p>保留😀</p>');
        await cache.putBlockTranslation('invalid', '<p>坏\u0001</p>');
        expect(await cache.getBlockTranslation('valid'), '<p>保留😀</p>');
        await expectLater(
          cache.getBlockTranslation('invalid'),
          throwsFormatException,
        );
        await cache.putBlockTranslation('invalid-ref', '<p>&#1</p>');
        await expectLater(
          cache.getBlockTranslation('invalid-ref'),
          throwsFormatException,
        );
      } finally {
        await cache.waitForMaintenanceForTest();
        await dir.delete(recursive: true);
      }
    },
  );
}
