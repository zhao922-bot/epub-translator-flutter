import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

InspectedChapter chapter(
  String source, {
  String path = 'OPS/chapter.xhtml',
  List<String>? translations,
}) {
  final result = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: path,
    bytes: utf8.encode(source),
  );
  if (translations == null) return result;
  expect(
    result.blocks.length,
    translations.length,
    reason: 'Fixture block count',
  );
  return result.copyWith(
    blocks: [
      for (var i = 0; i < translations.length; i++)
        result.blocks[i].copyWith(translatedHtml: translations[i]),
    ],
  );
}

String? effectiveLanguage(dom.Element element) {
  dom.Element? current = element;
  while (current != null) {
    final language =
        current.attributes['xml:lang'] ?? current.attributes['lang'];
    if (language != null) return language;
    current = current.parent;
  }
  return null;
}

void main() {
  test('control: ordinary paragraphs are selected for translation', () {
    final result = chapter(
      '<html><body><p>The morning was cold.</p></body></html>',
    );
    expect(result.blocks.single.sourceText, 'The morning was cold.');
    expect(result.includeInTranslation, isTrue);
  });

  test('div-only chapter must not silently lose all translation blocks', () {
    final result = chapter(
      '<html><body><div>The morning was cold.</div><div>She opened the door.</div></body></html>',
    );
    expect(
      result.blocks.map((b) => b.sourceText).join(' '),
      contains('The morning was cold.'),
    );
    expect(result.includeInTranslation, isTrue);
  });

  test('mixed div text must include text outside nested spans', () {
    final result = chapter(
      '<html><body><div>Before <span>middle</span> after.</div></body></html>',
    );
    expect(
      result.blocks.map((b) => b.sourceText).join(' '),
      contains('Before middle after.'),
    );
  });

  test('TOC section anchors must not collapse into one chapter label', () {
    const toc =
        '<html><body><nav><a href="chapter.xhtml#intro">Introduction</a><a href="chapter.xhtml#ending">Conclusion</a></nav></body></html>';
    final output = EpubRepacker().synchronizeHtmlTocForTest(
      tocPath: 'OPS/toc.xhtml',
      tocHtml: toc,
      chapters: [
        chapter(toc, path: 'OPS/toc.xhtml'),
        chapter(
          '<html><body><h1 id="intro">Introduction</h1><h2 id="ending">Conclusion</h2></body></html>',
          translations: ['<h1 id="intro">引言</h1>', '<h2 id="ending">结论</h2>'],
        ),
      ],
    );
    final labels = html
        .parse(output)
        .querySelectorAll('a')
        .map((a) => a.text.trim())
        .toList();
    expect(
      labels.toSet(),
      hasLength(2),
      reason: 'Distinct sections need distinct labels; observed $labels',
    );
    expect(labels, ['引言', '结论']);
  });

  test('bilingual table blank cells must not shift data under wrong headers', () {
    final input = chapter(
      '<html><body><table><tr><th>Name</th><th>Price</th></tr><tr><td></td><td>Ten</td></tr></table></body></html>',
      translations: ['<th>名称</th>', '<th>价格</th>', '<td>十</td>'],
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: input,
      bilingual: true,
      targetLanguage: 'Chinese',
    );
    final rows = html.parse(output).querySelectorAll('tr');
    final widths = rows.map((row) => row.children.length).toList();
    expect(
      widths[1],
      widths[0],
      reason: 'Unspanned rows must retain aligned columns; observed $widths',
    );
  });

  test(
    'translated French body must override inherited English body language',
    () {
      final input = chapter(
        '<html lang="en" xml:lang="en"><body lang="en" xml:lang="en"><p>Hello.</p></body></html>',
        translations: ['<p>Bonjour.</p>'],
      );
      final output = EpubRepacker().renderTranslatedChapter(
        chapter: input,
        bilingual: false,
        targetLanguage: 'French',
      );
      final document = html.parse(output);
      expect(document.documentElement!.attributes['lang'], 'fr');
      expect(effectiveLanguage(document.querySelector('p')!), 'fr');
    },
  );

  for (final entry in {
    'chapter.xhtml': 'chapter.xhtml',
    'chapter%231.xhtml': 'chapter#1.xhtml',
    'chapter': 'chapter',
  }.entries) {
    test('XHTML spine resolves manifest href ${entry.key}', () {
      final result = EpubInspector.chapterPathsFromOpfBytes(
        files: {
          'OPS/content.opf': utf8.encode(
            '<package><manifest><item id="ch" href="${entry.key}" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>',
          ),
          'OPS/${entry.value}': utf8.encode(
            '<html><body><p>Hello.</p></body></html>',
          ),
        },
        opfPath: 'OPS/content.opf',
      );
      expect(result.chapterPaths, ['OPS/${entry.value}']);
    });
  }

  test('fallback text round-trips without swallowing paragraphs or code', () {
    const source =
        '<html><body><div id="section">Before <em>emphasis</em> '
        '<a id="ref" href="#note" role="doc-noteref">1</a><p id="paragraph">Paragraph.</p>'
        '<div>Nested text.</div>After.<pre><code>keep()</code></pre></div></body></html>';
    final inspected = chapter(source);
    expect(inspected.blocks.map((b) => b.sourceText).toList(), [
      'Before emphasis 1',
      'Paragraph.',
      'Nested text.',
      'After.',
    ]);
    final translated = chapter(
      source,
      translations: [
        '<span>前文 <em>强调</em> <a id="ref" href="#note" role="doc-noteref">1</a></span>',
        '<p id="paragraph">段落。</p>',
        '<span>嵌套文字。</span>',
        '<span>后文。</span>',
      ],
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: translated,
      bilingual: false,
    );
    expect(() => XmlDocument.parse(output), returnsNormally);
    final document = html.parse(output);
    expect(
      document.querySelector('#section')!.text,
      contains('嵌套文字。后文。keep()'),
    );
    expect(document.querySelectorAll('#paragraph'), hasLength(1));
    expect(document.querySelectorAll('#ref'), hasLength(1));
    expect(document.querySelector('code')!.text, 'keep()');
    expect(document.querySelector('#section')!.text, isNot(contains('Before')));
  });

  for (final bilingual in [false, true]) {
    test('table spans and anchors survive repack (bilingual=$bilingual)', () {
      final input = chapter(
        '<html lang="en"><body><table><tr><th id="heading" colspan="2">Heading</th></tr>'
        '<tr><td id="cell" rowspan="2" headers="heading">Cell</td><td></td></tr><tr><td></td></tr></table></body></html>',
        translations: [
          '<th id="heading" colspan="2">标题</th>',
          '<td id="cell" rowspan="2" headers="heading">内容</td>',
        ],
      );
      final output = EpubRepacker().renderTranslatedChapter(
        chapter: input,
        bilingual: bilingual,
      );
      expect(() => XmlDocument.parse(output), returnsNormally);
      final document = html.parse(output);
      expect(
        document.querySelectorAll('tr').map((r) => r.children.length).toList(),
        [1, 2, 1],
      );
      expect(document.querySelectorAll('#heading'), hasLength(1));
      expect(document.querySelectorAll('#cell'), hasLength(1));
      expect(document.querySelector('#heading')!.attributes['colspan'], '2');
      expect(document.querySelector('#cell')!.attributes['rowspan'], '2');
      expect(document.querySelector('#cell')!.attributes['headers'], 'heading');
    });

    test(
      'nested translated language and untranslated source stay distinct (bilingual=$bilingual)',
      () {
        final input = chapter(
          '<html lang="en"><body><p id="translated" lang="en"><em lang="en">Hello.</em></p>'
          '<p id="original">Not translated.</p></body></html>',
        );
        final updated = input.copyWith(
          blocks: [
            input.blocks[0].copyWith(
              translatedHtml:
                  '<p id="translated" lang="en"><em xml:lang="en">Bonjour.</em></p>',
            ),
            input.blocks[1],
          ],
        );
        final document = html.parse(
          EpubRepacker().renderTranslatedChapter(
            chapter: updated,
            bilingual: bilingual,
            targetLanguage: 'French',
          ),
        );
        final translated = document.querySelectorAll('em').last;
        expect(effectiveLanguage(translated), 'fr');
        expect(effectiveLanguage(document.querySelector('#original')!), 'en');
        if (bilingual) {
          expect(
            effectiveLanguage(document.querySelector('#translated em')!),
            'en',
          );
        }
      },
    );
  }

  test('bare translated text receives a language boundary', () {
    final input = chapter(
      '<html lang="en"><body lang="en"><p>Hello.</p></body></html>',
      translations: ['Bonjour.'],
    );
    final document = html.parse(
      EpubRepacker().renderTranslatedChapter(
        chapter: input,
        bilingual: false,
        targetLanguage: 'French',
      ),
    );
    expect(effectiveLanguage(document.querySelector('body span')!), 'fr');
  });

  test('HTML and NCX use encoded section anchors and preserve unknown ones', () {
    final content = chapter(
      '<html><body><h1 id="intro">Introduction</h1><h2 id="结尾">Ending</h2></body></html>',
      translations: ['<h1 id="intro">引言</h1>', '<h2 id="结尾">结语</h2>'],
    );
    const toc =
        '<html><body><a href="chapter.xhtml#intro"><span>Intro</span><span class="pagenum">1</span></a>'
        '<a href="chapter.xhtml#%E7%BB%93%E5%B0%BE">Ending</a><a href="chapter.xhtml#unknown">Keep this</a></body></html>';
    final rendered = EpubRepacker().synchronizeHtmlTocForTest(
      tocPath: 'OPS/toc.xhtml',
      tocHtml: toc,
      chapters: [
        chapter(toc, path: 'OPS/toc.xhtml'),
        content,
      ],
    );
    expect(
      html.parse(rendered).querySelectorAll('a').map((a) => a.text).toList(),
      ['引言1', '结语', 'Keep this'],
    );
    final replacements = EpubRepacker().renderNavigationMetadataForTest(
      archiveFiles: {
        'META-INF/container.xml': utf8.encode(
          '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
        ),
        'OPS/content.opf': utf8.encode(
          '<package><metadata/><manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"/></package>',
        ),
        'OPS/toc.ncx': utf8.encode(
          '<ncx><navMap><navPoint><navLabel><text>Intro</text></navLabel><content src="chapter.xhtml#intro"/>'
          '<navPoint><navLabel><text>Ending</text></navLabel><content src="chapter.xhtml#%E7%BB%93%E5%B0%BE"/></navPoint></navPoint>'
          '<navPoint><navLabel><text>Keep this</text></navLabel><content src="chapter.xhtml#unknown"/></navPoint></navMap></ncx>',
        ),
      },
      chapters: [content],
      targetLanguage: 'Chinese',
    );
    expect(
      XmlDocument.parse(replacements['OPS/toc.ncx']!).descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'text')
          .map((e) => e.innerText)
          .toList(),
      ['引言', '结语', 'Keep this'],
    );
  });

  test(
    'extensionless chapter is inspected and exported through a real EPUB',
    () async {
      final temp = await Directory.systemTemp.createTemp('round2-epub-');
      addTearDown(() => temp.delete(recursive: true));
      final input = File('${temp.path}/input.epub');
      await input.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
            ..addFile(
              ArchiveFile.string(
                'META-INF/container.xml',
                '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
              ),
            )
            ..addFile(
              ArchiveFile.string(
                'OPS/content.opf',
                '<package><metadata/><manifest><item id="ch" href="chapter" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>',
              ),
            )
            ..addFile(
              ArchiveFile.string(
                'OPS/chapter',
                '<html lang="en"><body><div id="content">Hello <em>world</em>.</div></body></html>',
              ),
            ),
        ),
      );
      final result = await EpubInspector().inspect(
        inputPath: input.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      );
      expect(result.chapters, hasLength(1));
      expect(result.warnings, isEmpty);
      final original = result.chapters.single;
      expect(original.blocks.single.sourceText, 'Hello world.');
      final translated = original.copyWith(
        blocks: [
          original.blocks.single.copyWith(
            translatedHtml: '<span>Bonjour <em>monde</em>.</span>',
          ),
        ],
      );
      final outputPath = '${temp.path}/translated.epub';
      await EpubRepacker().writeTranslatedEpub(
        inputPath: input.path,
        outputFilePath: outputPath,
        config: TranslationConfig.defaults().copyWith(
          targetLanguage: 'French',
          bilingual: false,
        ),
        chapters: [translated],
      );
      final archive = ZipDecoder().decodeBytes(
        await File(outputPath).readAsBytes(),
      );
      final output = utf8.decode(
        archive.findFile('OPS/chapter')!.content as List<int>,
      );
      expect(() => XmlDocument.parse(output), returnsNormally);
      final document = html.parse(output);
      expect(document.querySelector('#content')!.text, 'Bonjour monde.');
      expect(effectiveLanguage(document.querySelector('em')!), 'fr');
    },
  );

  test(
    'manifest media type takes precedence while missing types retain fallback',
    () {
      final result = EpubInspector.chapterPathsFromOpfBytes(
        files: {
          'content.opf': utf8.encode(
            '<package><manifest><item id="image" href="image.xhtml" media-type="image/svg+xml"/>'
            '<item id="legacy" href="legacy.xhtml"/></manifest><spine><itemref idref="image"/><itemref idref="legacy"/></spine></package>',
          ),
        },
        opfPath: 'content.opf',
      );
      expect(result.chapterPaths, ['legacy.xhtml']);
    },
  );
}
