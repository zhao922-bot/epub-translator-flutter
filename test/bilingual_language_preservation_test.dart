import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  final cases = [
    (
      source: '<p>Hello</p>',
      translated: '<p lang="EN">Kept quote</p>',
      language: 'EN',
    ),
    (
      source: '<p>Hello</p>',
      translated: '<p xml:lang="en">Kept quote</p>',
      language: 'en',
    ),
    (source: '<p>Hello</p>', translated: '<p>你好</p>', language: 'zh-cn'),
    (
      source: '<p>Hello</p>',
      translated: '<p>你好 <q lang="en">Hello</q></p>',
      language: 'zh-cn',
    ),
    (
      source: '<p lang="en">Hello</p>',
      translated: '<p lang="en">你好</p>',
      language: 'zh-cn',
    ),
  ];
  for (var i = 0; i < cases.length; i++) {
    final item = cases[i];
    test(
      'bilingual language boundary survives full repack pipeline case $i',
      () {
        final chapter = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'chapter.xhtml',
          bytes: utf8.encode('<html><body>${item.source}</body></html>'),
        );
        final rendered = EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(translatedHtml: item.translated),
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
          item.language,
        );
        if (i == 1) {
          expect(translated.attributes['lang'], isNull);
        }
        if (i >= 2) {
          expect(translated.attributes['xml:lang'], 'zh-cn');
        }
        if (i == 3) {
          expect(translated.querySelector('q')!.attributes['lang'], 'en');
        }
        if (i == 4) {
          expect(
            html.parse(rendered).querySelector('p')!.attributes['lang'],
            'en',
          );
        }
      },
    );
  }
}
