import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

void main() {
  const EpubHtmlExtractor extractor = EpubHtmlExtractor();

  test('XHTML normalization respects quoted attributes and HTML void tags', () {
    const String source =
        '<p><img src="cover.jpg"/><a id="p1" title="keep /> quoted"/></p>';

    expect(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(source),
      '<p><img src="cover.jpg"/><a id="p1" title="keep /> quoted"></a></p>',
    );
  });

  test('EPUB output normalization produces well-formed XHTML', () {
    const String html =
        '<html><head><meta charset="utf-8"><link href="book.css"></head>'
        '<body>A&nbsp;B<br><img src="cover.jpg"></body></html>';

    final String xhtml = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(html);

    expect(xhtml, contains('<meta charset="utf-8" />'));
    expect(xhtml, contains('<link href="book.css" />'));
    expect(xhtml, contains('A&#160;B<br />'));
    expect(xhtml, contains('<img src="cover.jpg" />'));
    expect(() => XmlDocument.parse(xhtml), returnsNormally);
  });

  test('CJK translation input joins decorative split words', () {
    const String source =
        '<p><span class="dropcaps2line">E</span>'
        '<span class="small">VERY ONE OF TODAY</span>’'
        '<span class="small">S</span> ideas —P<span class="small">RINCE</span></p>';

    final String prepared =
        EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
          sourceHtml: source,
          targetLanguage: 'Chinese',
        );

    expect(prepared, '<p>EVERY ONE OF TODAY’S ideas —PRINCE</p>');
    expect(prepared, isNot(contains('dropcaps2line')));
    expect(prepared, isNot(contains('class="small"')));
    expect(
      EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml: source,
        targetLanguage: 'French',
      ),
      source,
    );
  });

  test('XHTML empty anchors do not swallow following chapter content', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/chapter.xhtml',
      bytes: utf8.encode(_sourceChapter),
    );

    expect(chapter.blocks, hasLength(3));
    expect(chapter.blocks[0].sourceHtml, contains('<a id="page1"></a>1'));
    expect(chapter.blocks[0].sourceHtml, isNot(contains('CHALLENGE')));
    expect(
      chapter.blocks[2].sourceHtml,
      contains('<a class="hlink" id="term1"></a>important'),
    );
    expect(
      chapter.blocks[2].sourceHtml,
      isNot(contains('<a class="hlink" id="term1">important')),
    );
  });

  test('repacked CJK chapter keeps marker anchors empty and local', () {
    final InspectedChapter inspected = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/chapter.xhtml',
      bytes: utf8.encode(_sourceChapter),
    );
    final InspectedChapter translated = inspected.copyWith(
      blocks: <ExtractedBlock>[
        inspected.blocks[0].copyWith(
          translatedHtml: '<h1 class="chapter_num"><a id="page1"/>1</h1>',
        ),
        inspected.blocks[1].copyWith(
          translatedHtml: '<h1 class="chapter_title">未来的挑战</h1>',
        ),
        inspected.blocks[2].copyWith(
          translatedHtml:
              '<p class="nonindent"><span class="dropcaps2line">W</span><span class="small">每当</span>我面试求职者时，都会问<a class="hlink" id="term1"/>这个问题。</p>',
        ),
      ],
    );

    final String rendered = EpubRepacker().renderTranslatedChapter(
      chapter: translated,
      bilingual: false,
    );
    final document = html_parser.parse(rendered);

    expect(document.querySelectorAll('body > a'), isEmpty);
    expect(document.querySelector('h1.chapter_num > a')?.text, isEmpty);
    expect(document.querySelector('p > a#term1')?.text, isEmpty);
    expect(document.querySelector('p')?.text, '每当我面试求职者时，都会问这个问题。');
    expect(document.querySelector('span.dropcaps2line'), isNull);
    expect(document.querySelector('span.small'), isNull);
  });

  test('CJK output gets safe line spacing and inert marker styling', () {
    final InspectedChapter inspected = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/chapter.xhtml',
      bytes: utf8.encode(_sourceChapter),
    );
    final InspectedChapter translated = inspected.copyWith(
      blocks: inspected.blocks
          .map(
            (ExtractedBlock block) => block.copyWith(
              translatedHtml: switch (block.id) {
                'h1-1' => '<h1 class="chapter_num"><a id="page1"></a>1</h1>',
                'h1-2' => '<h1 class="chapter_title">未来的挑战</h1>',
                _ => '<p class="nonindent">中文正文。</p>',
              },
            ),
          )
          .toList(),
    );

    final String rendered = EpubRepacker().renderTranslatedChapter(
      chapter: translated,
      bilingual: false,
    );

    expect(rendered, contains('class="epub-translator-cjk"'));
    expect(rendered, contains('title="EPUB Translator CJK compatibility"'));
    expect(rendered, contains('line-height: 1.65'));
    expect(rendered, contains('color: inherit'));
    expect(rendered, contains('epub-translator-anchor-marker'));
    expect(() => XmlDocument.parse(rendered), returnsNormally);
  });

  test('real href links remain clickable and are not marker-styled', () {
    final InspectedChapter inspected = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/toc.xhtml',
      bytes: utf8.encode('''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title></head>
<body><p><a class="hlink" href="chapter.xhtml#target">Chapter One</a></p></body></html>
'''),
    );
    final InspectedChapter translated = inspected.copyWith(
      blocks: <ExtractedBlock>[
        inspected.blocks.single.copyWith(
          translatedHtml:
              '<p><a class="hlink" href="chapter.xhtml#target">第一章</a></p>',
        ),
      ],
    );

    final String rendered = EpubRepacker().renderTranslatedChapter(
      chapter: translated,
      bilingual: false,
    );
    final document = html_parser.parse(rendered);
    final link = document.querySelector('a[href]');

    expect(link?.attributes['href'], 'chapter.xhtml#target');
    expect(link?.classes, isNot(contains('epub-translator-anchor-marker')));
  });

  test('translated navigation and package metadata use target language', () {
    final InspectedChapter chapter = InspectedChapter(
      path: 'OEBPS/chapter.xhtml',
      title: 'Chapter One',
      body: 'Chapter One',
      originalHtml: '<html><body><h1>1</h1><h1>Chapter One</h1></body></html>',
      blocks: const <ExtractedBlock>[
        ExtractedBlock(
          id: 'h1-1',
          tagName: 'h1',
          sourceHtml: '<h1>1</h1>',
          sourceText: '1',
          translatedHtml: '<h1>1</h1>',
        ),
        ExtractedBlock(
          id: 'h1-2',
          tagName: 'h1',
          sourceHtml: '<h1>Chapter One</h1>',
          sourceText: 'Chapter One',
          translatedHtml: '<h1>第一章</h1>',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );
    final Map<String, String> replacements = EpubRepacker()
        .renderNavigationMetadataForTest(
          archiveFiles: <String, List<int>>{
            'META-INF/container.xml': utf8.encode('''
<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
'''),
            'OEBPS/content.opf': utf8.encode('''
<package xmlns="http://www.idpf.org/2007/opf"><metadata><dc:language xmlns:dc="http://purl.org/dc/elements/1.1/">en</dc:language></metadata><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"/></package>
'''),
            'OEBPS/toc.ncx': utf8.encode('''
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" xml:lang="en"><navMap><navPoint><navLabel><text>Chapter One</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>
'''),
          },
          chapters: <InspectedChapter>[chapter],
          targetLanguage: 'Chinese',
        );

    final XmlDocument opf = XmlDocument.parse(
      replacements['OEBPS/content.opf']!,
    );
    final XmlDocument ncx = XmlDocument.parse(replacements['OEBPS/toc.ncx']!);
    expect(
      opf.descendants
          .whereType<XmlElement>()
          .singleWhere((XmlElement node) => node.name.local == 'language')
          .innerText,
      'zh-CN',
    );
    expect(ncx.rootElement.getAttribute('xml:lang'), 'zh-CN');
    expect(
      ncx.descendants
          .whereType<XmlElement>()
          .singleWhere((XmlElement node) => node.name.local == 'text')
          .innerText,
      '1. 第一章',
    );

    final String synchronizedToc = EpubRepacker().synchronizeHtmlTocForTest(
      tocPath: 'OEBPS/toc.xhtml',
      tocHtml:
          '<html><body><a href="chapter.xhtml">1 Chapter One</a></body></html>',
      chapters: <InspectedChapter>[
        chapter,
        InspectedChapter(
          path: 'OEBPS/toc.xhtml',
          title: 'Contents',
          body: 'Contents',
          originalHtml: '<html><body class="toc"></body></html>',
          blocks: const <ExtractedBlock>[],
          category: ChapterCategory.frontMatter,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
      ],
    );
    expect(synchronizedToc, contains('>1. 第一章</a>'));
  });
}

const String _sourceChapter = '''
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Zero to One</title></head>
<body>
<h1 class="chapter_num"><a id="page1"/>1</h1>
<h1 class="chapter_title">THE CHALLENGE OF THE FUTURE</h1>
<p class="nonindent"><span class="dropcaps2line">W</span><span class="small">HENEVER</span> I ask an <a class="hlink" id="term1"/>important truth.</p>
</body>
</html>
''';
