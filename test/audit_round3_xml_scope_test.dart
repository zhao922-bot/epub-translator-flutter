import 'dart:convert';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_dom.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'audit_round3_content_regression_test.dart' as content;

void main() {
  test('legacy named entities retain namespace discovery on the XML path', () {
    final source =
        '<_x:html xmlns:_x="${content.xhtml}"><_x:head><_x:title>Book</_x:title></_x:head><_x:body><_x:p>Hello world.&nbsp;&copy;</_x:p></_x:body></_x:html>';
    final output = XmlDocument.parse(content.render(source));
    expect(output.rootElement.name.qualified, '_x:html');
    expect(output.rootElement.getAttribute('lang'), 'fr');
    expect(
      output.descendants
          .whereType<XmlElement>()
          .singleWhere((e) => e.name.local == 'p')
          .innerText,
      'Bonjour monde.\u00a0\u00a9',
    );
  });
  for (final prefix in ['_X', '图', '\u{20000}', 'a图', 'a·b', 'a\u0301']) {
    for (final bilingual in [false, true]) {
      test(
        'legal prefix $prefix retains XHTML, empty anchors and table cells ($bilingual)',
        () {
          final source =
              '<$prefix:html xmlns:$prefix="${content.xhtml}"><$prefix:head><$prefix:title>Book</$prefix:title></$prefix:head><$prefix:body><$prefix:h1 id="heading">Hello world.</$prefix:h1><$prefix:p><$prefix:a id="marker"/>Hello world.</$prefix:p><$prefix:table><$prefix:tbody><$prefix:tr><$prefix:td>Hello world.</$prefix:td></$prefix:tr></$prefix:tbody></$prefix:table></$prefix:body></$prefix:html>';
          final chapter = content.translated(content.inspect(source));
          final rendered = EpubRepacker().renderTranslatedChapter(
            chapter: chapter,
            bilingual: bilingual,
            targetLanguage: 'French',
          );
          final document = XmlDocument.parse(rendered);
          expect(document.rootElement.name.prefix, prefix);
          expect(
            document.descendants.whereType<XmlElement>().every(
              (e) => e.namespaceUri == content.xhtml,
            ),
            isTrue,
          );
          final nodes = document.descendants.whereType<XmlElement>().toList();
          expect(
            nodes.where((e) => e.getAttribute('id') == 'marker'),
            hasLength(1),
          );
          expect(
            nodes.singleWhere((e) => e.name.local == 'td').innerText,
            contains('Bonjour monde.'),
          );
          expect(rendered, contains('Bonjour monde.'));
          expect(
            EpubRepacker().debugNavigationLabels([
              chapter,
            ])['OPS/c.xhtml#heading'],
            'Bonjour monde.',
          );
        },
      );
    }
  }

  test(
    'case-distinct namespace bindings and local rebindings survive foreign snapshots',
    () {
      final source = content.book(
        '<p>Hello world. <S:svg viewBox="0 0 10 10"><S:defs><S:rect id="shape"/></S:defs><S:use L:href="#shape"/><g:math xmlns:g="http://www.w3.org/1998/Math/MathML"><g:mi>x</g:mi></g:math></S:svg><s:math><s:mi>y</s:mi></s:math></p>',
        attrs:
            'xmlns:S="http://www.w3.org/2000/svg" xmlns:s="http://www.w3.org/1998/Math/MathML" xmlns:L="http://www.w3.org/1999/xlink" xmlns:l="urn:other" xmlns:g="urn:outer"',
      );
      final elements = XmlDocument.parse(
        content.render(source),
      ).descendants.whereType<XmlElement>().toList();
      final svg = elements.singleWhere((e) => e.name.local == 'svg');
      expect(svg.namespaceUri, 'http://www.w3.org/2000/svg');
      expect(svg.getAttribute('viewBox'), '0 0 10 10');
      expect(
        elements
            .singleWhere((e) => e.name.local == 'use')
            .getAttribute('href', namespace: 'http://www.w3.org/1999/xlink'),
        '#shape',
      );
      expect(
        elements
            .where((e) => e.name.local == 'math')
            .map((e) => e.namespaceUri),
        everyElement('http://www.w3.org/1998/Math/MathML'),
      );
    },
  );

  test('Unicode names remain covered by the pre-parser nesting limit', () {
    final source = '${'<图:div>' * 140}text${'</图:div>' * 140}';
    expect(() => content.inspect(source), throwsFormatException);
    expect(() => validateEpubMarkupDepth(source), throwsFormatException);
  });

  test('Unicode XML path preserves scripts, CDATA and entity escapes', () {
    const source =
        '<_x:html xmlns:_x="http://www.w3.org/1999/xhtml"><_x:head><_x:title>Book</_x:title><_x:style><![CDATA[p::before {content: "<x/> & stuff";}]]></_x:style></_x:head><_x:body><_x:p>Hello world.</_x:p><script xmlns="http://www.w3.org/1999/xhtml"><![CDATA[if (a < b && c > d) run();]]></script></_x:body></_x:html>';
    final nodes = XmlDocument.parse(
      content.render(source),
    ).descendants.whereType<XmlElement>().toList();
    expect(
      nodes.singleWhere((e) => e.name.local == 'style').innerText,
      'p::before {content: "<x/> & stuff";}',
    );
    expect(
      nodes.singleWhere((e) => e.name.local == 'script').innerText,
      'if (a < b && c > d) run();',
    );
    expect(
      utf8.decode(utf8.encode(content.render(source))),
      content.render(source),
    );
  });

  test(
    'XML-style fragment with Unicode prefix preserves cell context and tail',
    () {
      final fragment = XhtmlHtmlCompatibility.parseFragment(
        '<图:td xmlns:图="${content.xhtml}">cell</图:td> tail',
      );
      expect(fragment.text, 'cell tail');
      expect(epubElements(fragment).single.localName, '图:td');
    },
  );

  test(
    'external CSS context keeps all translated whitespace without needing the stylesheet',
    () {
      final source = content.book(
        '<div class="poem"><p>Hello world.\n  Next\tline.</p></div>',
        head: '<link rel="stylesheet" type="text/css" href="poem.css"/>',
      );
      final paragraph = XmlDocument.parse(content.render(source)).descendants
          .whereType<XmlElement>()
          .singleWhere((e) => e.name.local == 'p');
      expect(paragraph.innerText, 'Bonjour monde.\n  Next\tline.');
    },
  );
}
