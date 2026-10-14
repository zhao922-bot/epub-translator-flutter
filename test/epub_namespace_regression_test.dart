import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const ns = 'http://www.w3.org/1999/xhtml';
const extractor = EpubHtmlExtractor();

InspectedChapter translatedChapter(String source, String from, String to) {
  final chapter = extractor.inspectChapterBytes(
    chapterPath: 'OPS/chapter.xhtml',
    bytes: utf8.encode(source),
  );
  return chapter.copyWith(
    includeInTranslation: true,
    blocks: [
      for (final b in chapter.blocks)
        b.copyWith(translatedHtml: b.sourceHtml.replaceAll(from, to)),
    ],
  );
}

String prefixed(String body) =>
    '<x:html xmlns:x="$ns"><x:head><x:title>Book</x:title></x:head>'
    '<x:body>$body</x:body></x:html>';

void main() {
  test('R01 correct prefixed code retention must pass residual quality', () {
    const literal = 'print the original value and then return the result';
    for (final p in ['', 'x:']) {
      final source =
          '<${p}p>Hello world. <${p}code>$literal</${p}code></${p}p>';
      final translation = '<${p}p>你好，世界。 <${p}code>$literal</${p}code></${p}p>';
      expect(
        TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml: source,
          translatedHtml: translation,
          targetLanguage: 'Chinese',
        ),
        isNull,
        reason: 'Protected code must be exempt for prefix $p',
      );
    }
  });

  test('R02 prefixed code whitespace and classes survive repack', () {
    const body =
        '<x:p>Hello world. <x:code class="dropcap-code">a  b\n  c</x:code></x:p>';
    final chapter = translatedChapter(prefixed(body), 'Hello world.', '你好，世界。');
    final rendered = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
      targetLanguage: 'Chinese',
    );
    final code = XmlDocument.parse(rendered).descendants
        .whereType<XmlElement>()
        .singleWhere((e) => e.name.local == 'code');
    expect(code.innerText, 'a  b\n  c');
    expect(code.getAttribute('class'), 'dropcap-code');
  });

  test(
    'R03 prefixed heading fragments produce translated navigation labels',
    () {
      final chapter = translatedChapter(
        prefixed('<x:h1 id="section">Original heading</x:h1><x:p>Text.</x:p>'),
        'Original heading',
        '译文标题',
      );
      final labels = EpubRepacker().debugNavigationLabels([chapter]);
      expect(labels['OPS/chapter.xhtml'], '译文标题');
      expect(labels['OPS/chapter.xhtml#section'], '译文标题');
    },
  );

  test('R04 prefixed EPUB3 navigation synchronizes labels', () {
    final markup =
        '<x:html xmlns:x="$ns" xmlns:epub="http://www.idpf.org/2007/ops">'
        '<x:head><x:title>Contents</x:title></x:head><x:body>'
        '<x:nav epub:type="toc"><x:ol><x:li><x:a href="chapter.xhtml#section">'
        'Original heading</x:a></x:li></x:ol></x:nav></x:body></x:html>';
    final output = synchronizeEpub3Navigation(
      markup: markup,
      documentPath: 'OPS/nav.xhtml',
      labelsByPath: {'OPS/chapter.xhtml#section': '译文标题'},
      languageTag: 'zh-CN',
    );
    expect(output, contains('译文标题'));
    expect(output, isNot(contains('Original heading')));
    final document = XmlDocument.parse(output);
    expect(document.rootElement.name.qualified, 'x:html');
    expect(
      document.descendants.whereType<XmlElement>().every(
        (element) => element.namespaceUri == ns,
      ),
      isTrue,
    );
  });

  test('R05 bilingual prefixed anchors retain only one legacy name', () {
    final chapter = translatedChapter(
      prefixed('<x:p><x:a name="legacy"></x:a>Hello world.</x:p>'),
      'Hello world.',
      'Bonjour le monde.',
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: true,
      targetLanguage: 'French',
    );
    final named = XmlDocument.parse(output).descendants
        .whereType<XmlElement>()
        .where((e) => e.getAttribute('name') == 'legacy')
        .toList();
    expect(named, hasLength(1));
  });

  test('R06 generated wrappers in prefixed XHTML retain XHTML namespace', () {
    final chapter = translatedChapter(
      prefixed('<x:div>Hello unwrapped prose.</x:div>'),
      'Hello unwrapped prose.',
      'Bonjour texte.',
    );
    expect(chapter.blocks, hasLength(1));
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
      targetLanguage: 'French',
    );
    final spans = XmlDocument.parse(output).descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'span')
        .toList();
    expect(spans, isNotEmpty);
    expect(spans.map((e) => e.namespaceUri), everyElement(ns));
  });

  test('control plain XHTML keeps protected code and heading navigation', () {
    final chapter = translatedChapter(
      '<html xmlns="$ns"><head><title>Book</title></head><body>'
          '<h1 id="section">Heading</h1><p>Hello. <code>a  b\n  c</code></p>'
          '</body></html>',
      'Hello.',
      '你好。',
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
      targetLanguage: 'Chinese',
    );
    final code = XmlDocument.parse(output).descendants
        .whereType<XmlElement>()
        .singleWhere((e) => e.name.local == 'code');
    expect(code.innerText, 'a  b\n  c');
    expect(
      EpubRepacker().debugNavigationLabels([
        chapter,
      ])['OPS/chapter.xhtml#section'],
      'Heading',
    );
  });

  test('R10 glossary must not rewrite source-owned prefixed code', () {
    const source = '<x:p>中文说明 <x:code>Adam Smith</x:code></x:p>';
    final result = ProperNameNormalizer.normalizeHtml(
      source,
      [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
      targetLanguage: 'Chinese',
      state: ProperNameNormalizer.bookState(),
    );
    expect(result, contains('<x:code>Adam Smith</x:code>'));
  });

  test('prefixed TOC preserves page-list labels and protected page markers', () {
    final markup = prefixed(
      '<x:nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc">'
      '<x:a href="chapter.xhtml">Original<x:span role="doc-pagebreak">12</x:span></x:a>'
      '</x:nav><x:nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="page-list">'
      '<x:a href="chapter.xhtml">Page twelve</x:a></x:nav>',
    );
    final output = synchronizeEpub3Navigation(
      markup: markup,
      documentPath: 'OPS/nav.xhtml',
      labelsByPath: {'OPS/chapter.xhtml': '译文标题'},
      languageTag: 'zh-CN',
    );
    expect(output, contains('Page twelve'));
    final document = XmlDocument.parse(output);
    final marker = document.descendants.whereType<XmlElement>().singleWhere(
      (e) => e.getAttribute('role') == 'doc-pagebreak',
    );
    expect(marker.innerText, '12');
    expect(
      document.descendants.whereType<XmlElement>().every(
        (e) => e.namespaceUri == ns,
      ),
      isTrue,
    );
  });

  test(
    'ordinary navigation keeps embedded prefixed XHTML without replacing its root',
    () {
      final markup =
          '<html xmlns="$ns" xmlns:x="$ns" xmlns:epub="http://www.idpf.org/2007/ops">'
          '<body><nav epub:type="toc"><a href="chapter.xhtml">Original</a></nav>'
          '<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><x:html><x:body>Embedded</x:body></x:html></foreignObject></svg>'
          '</body></html>';
      final output = synchronizeEpub3Navigation(
        markup: markup,
        documentPath: 'OPS/nav.xhtml',
        labelsByPath: {'OPS/chapter.xhtml': '译文标题'},
        languageTag: 'zh-CN',
      );
      final document = XmlDocument.parse(output);
      expect(document.rootElement.name.prefix, isNull);
      expect(document.rootElement.namespaceUri, ns);
      expect(output, contains('译文标题'));
      expect(output, contains('Embedded'));
    },
  );

  test(
    'R11 glossary must preserve quoted attributes containing greater-than',
    () {
      const source = '<p title="Value > Adam Smith">中文说明 Adam Smith 的观点。</p>';
      final result = ProperNameNormalizer.normalizeHtml(
        source,
        [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
        targetLanguage: 'Chinese',
        state: ProperNameNormalizer.bookState(),
      );
      final document = XmlDocument.parse(result);
      expect(document.rootElement.getAttribute('title'), 'Value > Adam Smith');
      expect(document.rootElement.innerText, contains('亚当·斯密（Adam Smith）'));
    },
  );
}
