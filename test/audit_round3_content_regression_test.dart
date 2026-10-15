import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'support/epub_fixture_factory.dart' as fixture;

const xhtml = 'http://www.w3.org/1999/xhtml';
String book(String body, {String attrs = '', String head = ''}) =>
    '<html xmlns="$xhtml" lang="en" xml:lang="en" $attrs><head><title>Chapter</title>$head</head><body>$body</body></html>';
InspectedChapter inspect(String source) =>
    const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/c.xhtml',
      bytes: utf8.encode(source),
    );
InspectedChapter translated(InspectedChapter c) => c.copyWith(
  blocks: [
    for (final b in c.blocks)
      b.copyWith(
        translatedHtml: b.sourceHtml.replaceAll(
          'Hello world.',
          'Bonjour monde.',
        ),
      ),
  ],
);
String render(String source) => EpubRepacker().renderTranslatedChapter(
  chapter: translated(inspect(source)),
  bilingual: false,
  targetLanguage: 'French',
);
Future<void> save(String kind, String source, {bool svg = false}) async {
  final dir = await Directory.systemTemp.createTemp('round3-content-');
  addTearDown(() => dir.delete(recursive: true));
  final input = await fixture.makeBook(
    dir,
    'source-$kind',
    source,
    withSvg: svg,
  );
  await EpubRepacker().writeTranslatedEpub(
    inputPath: input.path,
    outputFilePath: '${dir.path}/export-$kind.epub',
    config: TranslationConfig.defaults().copyWith(
      styleProfileEnabled: false,
      targetLanguage: 'French',
    ),
    chapters: [translated(inspect(source))],
  );
}

void main() {
  for (final prefix in ['x', '_x', '图']) {
    test('XHTML prefix $prefix retains translatable paragraphs', () async {
      final label = {'x': 'lower', '_x': 'underscore', '图': 'unicode'}[prefix]!;
      final source =
          '<$prefix:html xmlns:$prefix="$xhtml" lang="en" xml:lang="en"><$prefix:head><$prefix:title>Chapter</$prefix:title></$prefix:head><$prefix:body><$prefix:p>Hello world.</$prefix:p></$prefix:body></$prefix:html>';
      await save('xhtml-prefix-$label', source);
      expect(inspect(source).blocks, hasLength(1));
    });
  }
  for (final prefix in ['s', 'S', '_s', '图']) {
    test('SVG ancestor namespace prefix $prefix preserves drawing', () async {
      final source = book(
        '<p>Hello world. <$prefix:svg viewBox="0 0 10 10"><$prefix:defs><$prefix:linearGradient id="g"><$prefix:stop offset="0" stop-color="red"/></$prefix:linearGradient></$prefix:defs><$prefix:rect width="10" height="10" fill="url(#g)"/></$prefix:svg></p>',
        attrs: 'xmlns:$prefix="http://www.w3.org/2000/svg"',
      );
      final label = {
        's': 'lower',
        'S': 'upper',
        '_s': 'underscore',
        '图': 'unicode',
      }[prefix]!;
      await save('svg-prefix-$label', source, svg: true);
      final output = render(source);
      final document = XmlDocument.parse(output);
      final svg = document.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'svg')
          .toList();
      expect(svg, hasLength(1));
      expect(svg.single.namespaceUri, 'http://www.w3.org/2000/svg');
      expect(svg.single.getAttribute('viewBox'), '0 0 10 10');
      expect(
        svg.single.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == 'linearGradient',
        ),
        isTrue,
      );
    });
  }
  test('uppercase inherited XLink prefix retains bound references', () async {
    final source = book(
      '<p>Hello world. <s:svg viewBox="0 0 10 10"><s:defs><s:rect id="shape" width="10" height="10"/></s:defs><s:use L:href="#shape"/></s:svg></p>',
      attrs:
          'xmlns:s="http://www.w3.org/2000/svg" xmlns:L="http://www.w3.org/1999/xlink"',
    );
    await save('svg-xlink-upper', source, svg: true);
    final use = XmlDocument.parse(render(source)).descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.name.local == 'use');
    expect(
      use.getAttribute('href', namespace: 'http://www.w3.org/1999/xlink'),
      '#shape',
    );
  });
  for (final style in ['pre-wrap', 'pre-line', 'pre', 'break-spaces']) {
    test(
      'inline CSS white-space $style preserves intentional line breaks',
      () async {
        final source = book(
          '<p style="white-space: $style">Hello world.\n  Next line.</p>',
        );
        await save('white-space-$style', source);
        final p = XmlDocument.parse(render(source)).descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.local == 'p');
        expect(p.innerText, contains('\n'));
        if (style != 'pre-line') expect(p.innerText, contains('  Next'));
      },
    );
  }
  test(
    'inherited stylesheet white-space preserves intentional line breaks',
    () async {
      final source = book(
        '<div class="poem"><p>Hello world.\n  Next line.</p></div>',
        head: '<style type="text/css">.poem { white-space: pre-wrap; }</style>',
      );
      await save('white-space-inherited', source);
      expect(
        XmlDocument.parse(render(source)).descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.local == 'p')
            .innerText,
        contains('\n  Next'),
      );
    },
  );
  test(
    'protected SVG xml:space text survives whitespace normalization',
    () async {
      final source = book(
        '<p>Hello world. <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 20"><text xml:space="preserve">A  B</text></svg></p>',
      );
      await save('svg-whitespace', source, svg: true);
      final text = XmlDocument.parse(render(source)).descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'text');
      expect(text.innerText, 'A  B');
    },
  );
}
