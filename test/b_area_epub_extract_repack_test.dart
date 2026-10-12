import 'dart:convert';

import 'package:epub_translator_flutter/features/preview/application/preview_recovery.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

const _extractor = EpubHtmlExtractor();

InspectedChapter _inspect(
  String body, {
  String path = 'OEBPS/chapter.xhtml',
}) => _extractor.inspectChapterBytes(
  chapterPath: path,
  bytes: utf8.encode(
    '<html><head><title>Chapter One</title></head><body>$body</body></html>',
  ),
);

void _expectBounded(String text) {
  expect(
    text.length,
    lessThanOrEqualTo(EpubHtmlExtractor.previewCharacterLimit),
  );
  expect(text, endsWith('…'));
}

void main() {
  group('8: bounded preview data, complete translation data', () {
    test('multi-megabyte single paragraph retains its complete block', () {
      final text = '字' * (2 * 1024 * 1024);
      final chapter = _inspect('<p>$text</p>');
      _expectBounded(chapter.body);
      expect(chapter.blocks.single.sourceText, text);
      expect(chapter.originalHtml, contains(text));
    });

    test('no-block body fallback is also bounded', () {
      final chapter = _inspect('<pre>${'x' * 12000}</pre>');
      expect(chapter.blocks, isEmpty);
      _expectBounded(chapter.body);
    });

    test(
      'ordinary chapters and the existing twelve-block limit are unchanged',
      () {
        final chapter = _inspect('<p>First</p><p>Second</p>');
        expect(chapter.body, 'First\n\nSecond');
        expect(previewChapterFromInspected(chapter).body, chapter.body);
        expect(
          _inspect(List.generate(13, (i) => '<p>Block $i</p>').join()).body,
          List.generate(12, (i) => 'Block $i').join('\n\n'),
        );
      },
    );

    test(
      'boundary preserves complete surrogate pairs and exact-limit text',
      () {
        final exact = 'a' * EpubHtmlExtractor.previewCharacterLimit;
        expect(EpubHtmlExtractor.limitPreviewText(exact), exact);
        final text = '${'a' * 5998}😀tail';
        expect(EpubHtmlExtractor.limitPreviewText(text), '${'a' * 5998}…');
      },
    );

    test(
      'recovery bounds both block joins when original HTML is unavailable',
      () {
        final text = '文' * 12000;
        final inspected = _inspect('<p>$text</p>');
        final chapter = inspected.copyWith(
          originalHtml: '',
          blocks: [
            inspected.blocks.single.copyWith(translatedHtml: '<p>$text</p>'),
          ],
        );
        final preview = previewChapterFromInspected(chapter);
        _expectBounded(preview.body);
        _expectBounded(preview.translatedBody!);
      },
    );

    test('recovery with original HTML bounds both source and translation', () {
      final text = '文' * 12000;
      final inspected = _inspect('<p>$text</p>');
      final preview = previewChapterFromInspected(
        inspected.copyWith(
          blocks: [
            inspected.blocks.single.copyWith(translatedHtml: '<p>$text</p>'),
          ],
        ),
      );
      _expectBounded(preview.body);
      _expectBounded(preview.translatedBody!);
    });

    test('cached legacy source and translated excerpts are also bounded', () {
      final preview = previewChapterFromInspected(
        _inspect(
          '<p>Short</p>',
        ).copyWith(body: 'a' * 12000, translatedBody: '字' * 12000),
      );
      _expectBounded(preview.body);
      _expectBounded(preview.translatedBody!);
    });

    test('ordinary recovered translated excerpt is unchanged', () {
      final chapter = _inspect('<p>First</p><p>Second</p>');
      final preview = previewChapterFromInspected(
        chapter.copyWith(
          originalHtml: '',
          blocks: [
            chapter.blocks[0].copyWith(translatedHtml: '<p>第一</p>'),
            chapter.blocks[1].copyWith(translatedHtml: '<p>第二</p>'),
          ],
        ),
      );
      expect(preview.body, 'First\n\nSecond');
      expect(preview.translatedBody, '第一\n\n第二');
    });
  });

  group('12: block boundaries without altering inline words', () {
    final cases = <String, String>{
      '<div><p>First</p><p>Second</p></div>': 'First Second',
      '<div>Before<section>Inside</section>After</div>': 'Before Inside After',
      '<p>foo<b>bar</b>baz</p>': 'foobarbaz',
      '<p>foo<span>bar</span><a href="#">baz</a></p>': 'foobarbaz',
      '<p>First<br>Second</p>': 'First Second',
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final element = html_parser.parseFragment(entry.key).children.single;
        expect(_extractor.elementText(element), entry.value);
      });
    }
    test(
      'nested extracted block uses separators but retains original HTML',
      () {
        final chapter = _inspect(
          '<blockquote><p>First</p><p>Second</p></blockquote>',
        );
        expect(chapter.blocks.single.sourceText, 'First Second');
        expect(
          chapter.blocks.single.sourceHtml,
          contains('<p>First</p><p>Second</p>'),
        );
      },
    );
  });

  group('13: Unicode ancillary-title matching', () {
    final cases = <String, ChapterCategory>{
      'Cover 封面故事': ChapterCategory.content,
      'Copyright 版权与合理使用': ChapterCategory.content,
      'Cover故事': ChapterCategory.content,
      'Copyright Étude': ChapterCategory.content,
      'Copyright': ChapterCategory.ancillary,
      'Copyright © 2024': ChapterCategory.ancillary,
      '【Copyright】': ChapterCategory.ancillary,
      '封面故事': ChapterCategory.content,
      '中文 Preface 前言': ChapterCategory.frontMatter,
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          _extractor.categorizeChapter('OEBPS/chapter.xhtml', entry.key),
          entry.value,
        );
      });
    }
  });

  group('14: literal content survives export postprocessing', () {
    for (final tag in ['pre', 'code', 'script', 'style', 'textarea']) {
      test('$tag retains whitespace and typography classes', () {
        // Include CJK and redundant prose whitespace to activate both cleanup
        // passes. Nested code spans ensure protection applies to descendants.
        const literal = '甲  乙\n   丙';
        final content = tag == 'code' || tag == 'pre'
            ? '<span class="dropcap small-caps">$literal</span>'
            : literal;
        final inspected = _inspect('<blockquote>Source</blockquote>');
        final chapter = inspected.copyWith(
          blocks: [
            inspected.blocks.single.copyWith(
              translatedHtml:
                  '<blockquote><p>正文   多空格\n 下一行</p>'
                  '<$tag class="dropcap small-caps">$content</$tag></blockquote>',
            ),
          ],
        );
        final rendered = EpubRepacker().renderTranslatedChapter(
          chapter: chapter,
          bilingual: false,
        );
        final document = html_parser.parse(rendered);
        final element = document.querySelector(
          tag == 'style' ? 'blockquote style' : tag,
        )!;
        expect(element.text, literal);
        expect(element.classes, containsAll(['dropcap', 'small-caps']));
        if (tag == 'code' || tag == 'pre') {
          expect(
            element.querySelector('span')!.classes,
            containsAll(['dropcap', 'small-caps']),
          );
        }
        expect(document.querySelector('blockquote p')!.text, '正文 多空格 下一行');
      });
    }
  });

  group('15: only markup class tokens trigger TOC synchronization', () {
    final cases = <String, bool>{
      '<div data-class="toc"></div>': false,
      '<!-- <div class="toc"> -->': false,
      '<script>var s = "class=\'toc\'";</script>': false,
      '<style>/* class="toc" */</style>': false,
      '<div otherclass="toc"></div>': false,
      '<div class="toc-entry"></div>': false,
      '<div class="nav toc"></div>': true,
      "<div class='toc'></div>": true,
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final target = _inspect(
          '<h1>Original heading</h1>',
          path: 'OEBPS/target.xhtml',
        );
        final translatedTarget = target.copyWith(
          blocks: [
            target.blocks.single.copyWith(translatedHtml: '<h1>译后标题</h1>'),
          ],
        );
        final source = _inspect(
          '${entry.key}<p><a href="target.xhtml">Cross reference</a></p>',
        );
        final rendered = EpubRepacker().synchronizeHtmlTocForTest(
          tocPath: source.path,
          tocHtml: source.originalHtml,
          chapters: [source, translatedTarget],
        );
        expect(
          html_parser.parse(rendered).querySelector('a[href]')!.text,
          entry.value ? '译后标题' : 'Cross reference',
        );
      });
    }
  });
}
