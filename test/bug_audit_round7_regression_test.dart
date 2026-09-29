import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/protected_anchor_text_slots.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';

void main() {
  test('protected slots exclude code and preserve indentation', () {
    const code = '\n  if (value) {\n    print(value);\n  }\n';
    final slots = ProtectedAnchorTextSlots.parse(
      '<p>Before <code>$code</code><a href="#n" role="doc-noteref">1</a> after.</p>',
    );
    expect(slots.slotTexts, ['Before ', ' after.']);
    final result = html.parseFragment(slots.render(['之前', '之后']));
    expect(result.querySelector('code')!.text, code);
    expect(result.querySelector('a')!.text, '1');
  });
  test(
    'structure rebuild preserves nested code after model removes its wrapper',
    () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>Run <code><b>print</b>(value)</code> now.</p>',
        translatedHtml: '<p>现在运行。</p>',
      );
      expect(
        html.parseFragment(result).querySelector('code')!.innerHtml,
        '<b>print</b>(value)',
      );
    },
  );
  for (final tag in ['svg', 'math']) {
    test('CDATA preserves literal text in $tag during export', () {
      final child = tag == 'svg' ? 'text' : 'mtext';
      const literal = 'x < y & z > 0';
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/chapter.xhtml',
        bytes: utf8.encode(
          '<html><body><$tag><$child><![CDATA[$literal]]></$child></$tag><p>Hello</p></body></html>',
        ),
      );
      final result = EpubRepacker().renderTranslatedChapter(
        chapter: chapter,
        bilingual: false,
      );
      expect(
        XmlDocument.parse(result).findAllElements(child).single.innerText,
        literal,
      );
    });
  }
  test('quality checker exempts preserved code but still checks prose', () {
    const code =
        'print("This is a long example output message with many English words that must stay unchanged")';
    const source = '<p>Run the following command now: <code>$code</code></p>';
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: source,
        translatedHtml: '<p>现在运行以下命令：<code>$code</code></p>',
        targetLanguage: 'Chinese',
      ),
      isNull,
    );
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: source,
        translatedHtml: source,
        targetLanguage: 'Chinese',
      ),
      isNotNull,
    );
  });
  for (final body in [
    '<p>Use &lt;tag&gt; safely.</p>',
    '<p><![CDATA[Hello world.]]></p>',
    '<p><![CDATA[Use <tag> safely.]]></p>',
    '<p>Before <![CDATA[<tag>]]> after.</p>',
  ]) {
    test('inspect retains XML character data: $body', () {
      final source = '<html><body>$body</body></html>';
      final expected = XmlDocument.parse(
        source,
      ).findAllElements('p').single.innerText;
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/chapter.xhtml',
        bytes: utf8.encode(source),
      );
      expect(chapter.blocks, hasLength(1));
      expect(chapter.blocks.single.sourceText, expected);
    });
  }
  test('standalone code is already excluded from translation', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(
        '<html><body><pre><code>print(value)</code></pre><p>Run this command.</p></body></html>',
      ),
    );
    expect(chapter.blocks.single.sourceText, 'Run this command.');
  });
  test('export without replacements retains ordinary body CDATA', () {
    const source = '<html><body><p><![CDATA[Hello world.]]></p></body></html>';
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(source),
    );
    final result = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
    );
    expect(html.parse(result).querySelector('p')!.text, 'Hello world.');
  });
  for (final footnote in [false, true]) {
    for (final tag in ['em', 'code', 'samp', 'kbd', 'var']) {
      test(
        'batch and export preserve non-prose $tag text, footnote=$footnote',
        () async {
          final source =
              '<html><body><p>Run <$tag>print(value)</$tag> now.${footnote ? '<a href="#n" role="doc-noteref">1</a>' : ''}</p></body></html>';
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'OPS/chapter.xhtml',
            bytes: utf8.encode(source),
          );
          final dio = Dio();
          addTearDown(() => dio.close(force: true));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final request =
                    jsonDecode(
                          ((options.data as Map)['messages'] as List)
                                  .last['content']
                              as String,
                        )
                        as Map;
                if (footnote && tag != 'em') {
                  for (final block in request['blocks'] as List) {
                    expect(
                      jsonEncode(block['slots']),
                      isNot(contains('print(value)')),
                    );
                  }
                }
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'choices': [
                        {
                          'message': {
                            'content': jsonEncode({
                              'blocks': [
                                for (final item in request['blocks'] as List)
                                  {
                                    'id': (item as Map)['id'],
                                    if (!footnote)
                                      'html': '<p>现在运行 <$tag>打印(值)</$tag>。</p>',
                                    if (footnote)
                                      'slots': [
                                        for (final slot
                                            in (item['slots'] as List)
                                                .asMap()
                                                .entries)
                                          {
                                            'id': slot.value['id'],
                                            'text': slot.key == 0
                                                ? '现在运行'
                                                : tag == 'em' && slot.key == 1
                                                ? '打印(值)'
                                                : '。',
                                          },
                                      ],
                                  },
                              ],
                            }),
                          },
                        },
                      ],
                    },
                  ),
                );
              },
            ),
          );
          final translations = await EpubTranslationRepository()
              .translateBlockBatchForTest(
                dio: dio,
                config: TranslationConfig.defaults().copyWith(
                  apiBaseUrl: 'https://audit.invalid/v1',
                  apiKey: 'mock',
                  maxRetries: 1,
                  residualQualityCheck: true,
                ),
                blocks: chapter.blocks,
              );
          final rendered = EpubRepacker().renderTranslatedChapter(
            chapter: chapter.copyWith(
              blocks: [
                chapter.blocks.single.copyWith(
                  translatedHtml: translations.single,
                ),
              ],
            ),
            bilingual: false,
          );
          final document = html.parse(rendered);
          expect(document.querySelector('p')!.text, contains('现在运行'));
          expect(
            document.querySelector(tag)!.text,
            tag == 'em' ? '打印(值)' : 'print(value)',
          );
        },
      );
    }
  }
}
