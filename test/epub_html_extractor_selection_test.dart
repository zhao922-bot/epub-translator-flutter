import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
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

  test('marks only the author row in a preface signature metadata group', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The translated preface prose ends here with a complete final sentence.</p>
  <p class="sig">Peter Thiel</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">Los Angeles</p>
</section>
</body></html>
'''),
    );

    final Map<String, ExtractedBlock> byText = <String, ExtractedBlock>{
      for (final ExtractedBlock block in chapter.blocks)
        block.sourceText: block,
    };
    expect(byText['Peter Thiel']?.isAuthorSignature, isTrue);
    expect(byText['January 6, 2020']?.isAuthorSignature, isFalse);
    expect(byText['Los Angeles']?.isAuthorSignature, isFalse);

    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: byText['Peter Thiel']!.sourceHtml,
        translatedHtml: byText['Peter Thiel']!.sourceHtml,
        targetLanguage: 'Chinese',
        allowRetainedAuthorSignature: byText['Peter Thiel']!.isAuthorSignature,
      ),
      isNull,
    );
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: byText['Los Angeles']!.sourceHtml,
        translatedHtml: byText['Los Angeles']!.sourceHtml,
        targetLanguage: 'Chinese',
        allowRetainedAuthorSignature: byText['Los Angeles']!.isAuthorSignature,
      )?.kind,
      TranslationResidualKind.longSourceText,
    );
  });

  test('does not mark a work title in a terminal preface metadata group', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Strategic Investment</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">Los Angeles</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('does not mark a place in the author position', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Los Angeles</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">California</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('requires the signature date to consume the complete row', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Peter Thiel</p>
  <p class="sig">Drafted January 6, 2020 for publication</p>
  <p class="sig">Los Angeles</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('requires the location row to consume the complete value', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Peter Thiel</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">Los Angeles and further explanatory prose</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('requires the signature group to end the semantic preface', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Peter Thiel</p>
  <p class="sig">January 6, 2020</p>
  <p class="sig">Los Angeles</p>
  <p>Additional prose follows the supposed signature group.</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('does not mark a signature group inside a nonterminal wrapper', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <div>
    <p>The preface closes with enough ordinary prose to establish the boundary.</p>
    <p class="sig">Peter Thiel</p>
    <p class="sig">January 6, 2020</p>
    <p class="sig">Los Angeles</p>
  </div>
  <p>Additional prose follows outside the wrapper.</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('requires one shared signature class across the complete group', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/preface.xhtml',
      bytes: utf8.encode('''
<html><head><title>Preface</title></head><body>
<section epub:type="preface" role="doc-preface">
  <p>The preface closes with enough ordinary prose to establish the boundary.</p>
  <p class="sig">Peter Thiel</p>
  <p class="signature">January 6, 2020</p>
  <p class="author-signature">Los Angeles</p>
</section>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
  });

  test('does not infer author signatures in an ordinary content chapter', () {
    final InspectedChapter chapter = extractor.inspectChapterBytes(
      chapterPath: 'OEBPS/chapter01.xhtml',
      bytes: utf8.encode('''
<html><head><title>Chapter One</title></head><body>
  <p class="sig">Strategic Investment</p>
  <p class="sig">January 6, 2020</p>
</body></html>
'''),
    );

    expect(
      chapter.blocks.any((ExtractedBlock block) => block.isAuthorSignature),
      isFalse,
    );
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
