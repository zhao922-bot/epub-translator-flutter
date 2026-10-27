import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_navigation.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'epub_namespace_regression_test.dart' as fixtures;

const _xhtml = 'http://www.w3.org/1999/xhtml';
const _voidNames = [
  'area',
  'base',
  'br',
  'col',
  'command',
  'embed',
  'hr',
  'img',
  'input',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
];

void main() {
  for (final tag in _voidNames) {
    test(
      'qualified $tag retains attributes and siblings over repeated export',
      () {
        for (final prefix in ['x', 'HTML', '_x', '书']) {
          for (final paired in [false, true]) {
            final name = '$prefix:$tag';
            final ending = paired ? '></$name>' : ' />';
            var source =
                '<$prefix:div xmlns:$prefix="$_xhtml">before<$name id="v" title="a &lt; b &gt; c /&gt; &quot;q&quot; &amp; d" xml:lang="en"$ending'
                'after</$prefix:div>';
            final originalLanguage = XmlDocument.parse(
              source,
            ).rootElement.childElements.single.getAttribute('xml:lang');
            expect(originalLanguage, 'en');
            for (var cycle = 0; cycle < 3; cycle++) {
              final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
                XhtmlHtmlCompatibility.parseFragment(source).outerHtml,
              );
              final xml = XmlDocument.parse(output);
              expect(
                xml.rootElement.innerText,
                'beforeafter',
                reason: '$name paired=$paired cycle=$cycle',
              );
              final element = xml.rootElement.childElements.single;
              expect(element.name.local, tag);
              expect(element.namespaceUri, _xhtml);
              expect(element.children, isEmpty);
              expect(element.getAttribute('id'), 'v');
              expect(element.getAttribute('title'), 'a < b > c /> "q" & d');
              expect(element.getAttribute('xml:lang'), originalLanguage);
              source = output;
            }
          }
        }
      },
    );
  }

  test(
    'prefixed void elements in synchronized navigation remain well-formed',
    () {
      const source =
          '<x:html xmlns:x="$_xhtml" xmlns:e="http://www.idpf.org/2007/ops"><x:head><x:title>Contents</x:title><x:meta name="test" content="value"/></x:head><x:body><x:nav e:type="toc"><x:ol><x:li><x:a href="chapter.xhtml">Old<x:br/>Title</x:a></x:li></x:ol></x:nav><x:nav e:type="page-list"><x:ol><x:li><x:a href="chapter.xhtml#p">4</x:a></x:li></x:ol></x:nav></x:body></x:html>';
      var output = source;
      for (var cycle = 0; cycle < 3; cycle++) {
        output = synchronizeEpub3Navigation(
          markup: output,
          documentPath: 'nav.xhtml',
          labelsByPath: {'chapter.xhtml': 'New title'},
          languageTag: 'en',
        );
        final xml = XmlDocument.parse(output);
        final anchors = xml.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'a')
            .toList();
        expect(anchors.map((e) => e.innerText), ['New title', '4']);
        expect(
          xml.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'br')
              .single
              .children,
          isEmpty,
        );
        expect(anchors.every((e) => e.namespaceUri == _xhtml), isTrue);
      }
    },
  );

  for (final bilingual in [false, true]) {
    test(
      'prefixed breaks and images survive inside protected foreignObject: $bilingual',
      () {
        final source = fixtures.prefixed(
          '<x:p>Hello. <s:svg xmlns:s="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><s:foreignObject width="10" height="10"><x:div>Inside<x:br/><x:img src="cover.png" alt="cover"/>Tail</x:div></s:foreignObject></s:svg> After.</x:p>',
        );
        final output = EpubRepacker().renderTranslatedChapter(
          chapter: fixtures.translatedChapter(source, 'Hello.', '你好。'),
          bilingual: bilingual,
        );
        final xml = XmlDocument.parse(output);
        final svgs = xml.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'svg')
            .toList();
        expect(svgs, hasLength(bilingual ? 2 : 1));
        for (final svg in svgs) {
          final inner = svg.descendants.whereType<XmlElement>().singleWhere(
            (e) => e.name.local == 'div',
          );
          expect(inner.namespaceUri, _xhtml);
          expect(inner.innerText, 'InsideTail');
          expect(inner.childElements.map((e) => e.name.local), ['br', 'img']);
          expect(inner.childElements.every((e) => e.children.isEmpty), isTrue);
          expect(inner.childElements.last.getAttribute('src'), 'cover.png');
        }
      },
    );
  }

  test(
    'empty markers retain extraction text on consecutive and mixed breaks',
    () {
      final node = XhtmlHtmlCompatibility.parseFragment(
        '<x:p xmlns:x="$_xhtml">One<x:br/><br/><x:br></x:br>Two<x:wbr/>Three</x:p>',
      ).children.single;
      expect(const EpubHtmlExtractor().elementText(node), 'One TwoThree');
      final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
        node.outerHtml,
      );
      final xml = XmlDocument.parse(output);
      expect(xml.rootElement.childElements.map((e) => e.name.local), [
        'br',
        'br',
        'br',
        'wbr',
      ]);
      expect(xml.rootElement.innerText, 'OneTwoThree');
    },
  );
}
