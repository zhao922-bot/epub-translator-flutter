import 'dart:math';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import 'support/legacy_html_extractor.dart';

void main() {
  const extractor = EpubHtmlExtractor();
  const legacy = LegacyHtmlExtractor();
  final fixtures = <String>[
    'before <em>emphasis</em><!--note--><p id="p">block</p>after<br>line<img src="a.png">',
    ' \n<!--only comment--><p>block</p> \t<span>claimed</span><a href="#n">1</a>',
    '<div>start<section>nested <strong>text</strong><p>block</p>end</section>tail</div>',
    'start<script>ignored</script>middle<pre>preserved <em>code</em></pre>end',
    '<div><span epub:type="pagebreak">12</span></div><div><em> </em><!--empty--></div>',
    '<div><p><em>already claimed</em></p></div>',
    List.generate(
      2000,
      (i) => 'bare $i <em>inline $i</em><p id="p$i">block $i</p>',
    ).join(),
  ];
  final random = Random(42);
  const fragments = [
    'bare text',
    ' ',
    '<!--comment-->',
    '<em>inline</em>',
    '<br>',
    '<span>claimed</span>',
    '<a href="#n">1</a>',
    '<img src="x">',
    '<p>block</p>',
    '<div>nested<p>block</p>tail</div>',
    '<pre>code</pre>',
  ];
  fixtures.addAll(
    List.generate(
      30,
      (_) => List.generate(
        80,
        (_) => fragments[random.nextInt(fragments.length)],
      ).join(),
    ),
  );

  for (var i = 0; i < fixtures.length; i++) {
    test('mixed wrapping matches legacy DOM and blocks (fixture $i)', () {
      final document = parser.parse('<body>${fixtures[i]}</body>');
      final oldDocument = parser.parse('<body>${fixtures[i]}</body>');
      final originalText = document.body!.text;
      final originalNodes = <dom.Node>[];
      void collect(dom.Node node) {
        originalNodes.add(node);
        for (final child in node.nodes) {
          collect(child);
        }
      }

      collect(document.body!);
      final blocks = extractor.extractBlocks(
        document,
        chapterPath: 'chapter.xhtml',
      );
      final oldBlocks = legacy.extractBlocks(
        oldDocument,
        chapterPath: 'chapter.xhtml',
      );
      expect(document.outerHtml, oldDocument.outerHtml);
      expect(document.body!.text, originalText);
      expect(
        blocks
            .map((b) => [b.id, b.tagName, b.sourceHtml, b.sourceText])
            .toList(),
        oldBlocks
            .map((b) => [b.id, b.tagName, b.sourceHtml, b.sourceText])
            .toList(),
      );
      final retainedNodes = <dom.Node>{};
      void verifyParents(dom.Node node) {
        retainedNodes.add(node);
        for (final child in node.nodes) {
          expect(child.parentNode, same(node));
          verifyParents(child);
        }
      }

      verifyParents(document.body!);
      expect(retainedNodes.containsAll(originalNodes), isTrue);
      final once = document.outerHtml;
      extractor.extractBlocks(document, chapterPath: 'chapter.xhtml');
      expect(document.outerHtml, once, reason: 'normalization is idempotent');
    });
  }
}
