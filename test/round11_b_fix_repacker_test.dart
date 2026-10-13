import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  // -------------------------------------------------------------------------
  // P2-#12: bilingual lang comparison is case-insensitive (BCP 47).
  // -------------------------------------------------------------------------
  group('P2-#12 case-insensitive stale lang echo', () {
    test('case-normalized echo takes the target language', () {
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'chapter.xhtml',
        bytes: utf8.encode('<html><body><p lang="en">Hello</p></body></html>'),
      );
      final rendered = EpubRepacker().renderTranslatedChapter(
        chapter: chapter.copyWith(
          blocks: [
            chapter.blocks.single.copyWith(
              translatedHtml: '<p lang="EN">你好</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'zh-CN',
      );
      final translated = html
          .parse(rendered)
          .querySelector('[data-translation]')!;
      expect(
        translated.attributes['lang'] ?? translated.attributes['xml:lang'],
        'zh-cn',
      );
    });

    test('deliberate foreign mark without a source mark is still kept', () {
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'chapter.xhtml',
        bytes: utf8.encode('<html><body><p>Hello</p></body></html>'),
      );
      final rendered = EpubRepacker().renderTranslatedChapter(
        chapter: chapter.copyWith(
          blocks: [
            chapter.blocks.single.copyWith(
              translatedHtml: '<p lang="EN">Kept quote</p>',
            ),
          ],
        ),
        bilingual: true,
        targetLanguage: 'zh-CN',
      );
      final translated = html
          .parse(rendered)
          .querySelector('[data-translation]')!;
      expect(
        translated.attributes['lang'] ?? translated.attributes['xml:lang'],
        'EN',
      );
    });
  });
}
