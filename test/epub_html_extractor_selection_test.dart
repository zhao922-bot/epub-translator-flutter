import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const EpubHtmlExtractor extractor = EpubHtmlExtractor();

  test('image-only cover is ancillary and not recommended', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/book_epub_cvi_r1.htm',
      bytes: utf8.encode('''
<html><head><title>Example Book</title></head>
<body><div class="cover"><img src="cover.jpg" alt=""/></div></body></html>
'''),
    );

    expect(chapter.blocks, isEmpty);
    expect(chapter.category, ChapterCategory.ancillary);
    expect(chapter.recommendedForTranslation, isFalse);
    expect(chapter.includeInTranslation, isFalse);
  });

  test('image-only title page is front matter and not recommended', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/book_epub_tp_r1.htm',
      bytes: utf8.encode('''
<html><head><title>Example Book</title></head>
<body><div class="titlepage"><img src="title.jpg" alt=""/></div></body></html>
'''),
    );

    expect(chapter.blocks, isEmpty);
    expect(chapter.category, ChapterCategory.frontMatter);
    expect(chapter.recommendedForTranslation, isFalse);
    expect(chapter.includeInTranslation, isFalse);
  });

  test('non-empty content remains recommended', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/chapter01.xhtml',
      bytes: utf8.encode('''
<html><head><title>Chapter One</title></head>
<body><p>Translatable body text.</p></body></html>
'''),
    );

    expect(chapter.blocks, hasLength(1));
    expect(chapter.category, ChapterCategory.content);
    expect(chapter.recommendedForTranslation, isTrue);
    expect(chapter.includeInTranslation, isTrue);
  });

  test('direct TOC links are extracted as translatable link blocks', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/toc.xhtml',
      bytes: utf8.encode('''
<html><head><title>Contents</title></head><body>
<div class="toc_chap"><a href="chapter01.xhtml">1 The First Chapter</a></div>
</body></html>
'''),
    );

    expect(chapter.blocks, hasLength(1));
    expect(chapter.blocks.single.tagName, 'a');
    expect(chapter.blocks.single.sourceText, '1 The First Chapter');
    expect(
      chapter.blocks.single.sourceHtml,
      '<a href="chapter01.xhtml">1 The First Chapter</a>',
    );
  });

  test('common opaque EPUB filename aliases are categorized correctly', () {
    expect(
      extractor.categorizeChapter('OEBPS/book_cop_r1.htm', 'Example'),
      ChapterCategory.ancillary,
    );
    expect(
      extractor.categorizeChapter('OEBPS/book_ind_r1.htm', 'Example'),
      ChapterCategory.reference,
    );
    expect(
      extractor.categorizeChapter('OEBPS/book_ill_r1.htm', 'Example'),
      ChapterCategory.reference,
    );
    expect(
      extractor.categorizeChapter('OEBPS/book_prf_r1.htm', 'Example'),
      ChapterCategory.frontMatter,
    );
    expect(
      extractor.categorizeChapter('OEBPS/book_toc_r1.htm', 'Example'),
      ChapterCategory.frontMatter,
    );
    expect(
      extractor.categorizeChapter('OEBPS/book_ack_r1.htm', 'Example'),
      ChapterCategory.backMatter,
    );
  });
}
