import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';

class ControlReplyClient extends TranslationApiClient {
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async => Response(
    requestOptions: RequestOptions(),
    data: {
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {
            'content': jsonEncode({
              'blocks': [
                {'id': 'p-1', 'html': '<p>你好\u0001，世界。</p>'},
              ],
            }),
          },
        },
      ],
    },
  );
}

const xhtml = 'http://www.w3.org/1999/xhtml';
String render(String body, {String head = ''}) {
  final source =
      '<x:html xmlns:x="$xhtml" xmlns:s="http://www.w3.org/2000/svg"><x:head><x:title>Book</x:title>$head</x:head><x:body>$body<x:p>Hello world.</x:p></x:body></x:html>';
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'OPS/c.xhtml',
    bytes: utf8.encode(source),
  );
  return EpubRepacker().renderTranslatedChapter(
    chapter: chapter.copyWith(
      blocks: [
        for (final b in chapter.blocks)
          b.copyWith(
            translatedHtml: b.sourceHtml.replaceAll('Hello world.', '你好，世界。'),
          ),
      ],
    ),
    bilingual: false,
    targetLanguage: 'Chinese',
  );
}

void main() {
  test('escaped generic targets converge from forward and reverse glosses', () {
    for (final source in [
      '<p>使用 列表&lt;T&gt; (List)。</p>',
      '<p>使用 List（列表&lt;T&gt;）。</p>',
    ]) {
      final html = ProperNameNormalizer.normalizeHtml(
        source,
        ProperNameNormalizer.parseGlossary('List => 列表<T>'),
        targetLanguage: 'Chinese',
      );
      expect(
        XhtmlHtmlCompatibility.parseFragment(html).text,
        '使用 列表<T>（List）。',
      );
    }
  });
  test('SVG qualified names and case-sensitive attributes survive export', () {
    final output = render(
      '<s:svg viewBox="0 0 100 100"><s:defs><s:linearGradient id="g"><s:stop offset="0"/></s:linearGradient></s:defs><s:rect width="100" height="100" fill="url(#g)"/></s:svg>',
    );
    final doc = XmlDocument.parse(output);
    final svg = doc.descendants.whereType<XmlElement>().singleWhere(
      (e) => e.name.local == 'svg',
    );
    expect(svg.getAttribute('viewBox'), '0 0 100 100');
    expect(
      doc.descendants.whereType<XmlElement>().any(
        (e) => e.name.local == 'linearGradient',
      ),
      isTrue,
    );
  });
  test('prefixed style retains CDATA semantics and literal selectors', () {
    final css = 'x|p::before { content: "<a/> &nbsp;"; }';
    final output = render('', head: '<x:style><![CDATA[$css]]></x:style>');
    final style = XmlDocument.parse(output).descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.name.local == 'style');
    expect(style.innerText, css);
  });
  test('unprefixed script preserves XML-escaped characters', () {
    const raw =
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><script>if (a &lt; b &amp;&amp; c &gt; d) alert(&quot;ok&quot;);</script></head><body><p>Hello world.</p></body></html>';
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/c.xhtml',
      bytes: utf8.encode(raw),
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        blocks: [
          for (final b in chapter.blocks)
            b.copyWith(
              translatedHtml: b.sourceHtml.replaceAll('Hello world.', '你好，世界。'),
            ),
        ],
      ),
      bilingual: false,
      targetLanguage: 'Chinese',
    );
    final script = XmlDocument.parse(output).descendants
        .whereType<XmlElement>()
        .singleWhere((e) => e.name.local == 'script');
    expect(script.innerText, 'if (a < b && c > d) alert("ok");');
  });
  test('depth guard accepts a flat legal 500-node chapter', () {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/c.xhtml',
      bytes: utf8.encode(
        '<html xmlns="$xhtml"><head><title>B</title></head><body>${'<p>Hello.</p>' * 500}</body></html>',
      ),
    );
    expect(chapter.blocks, hasLength(500));
  });
  test('prefixed raw-text adapter encodes CDATA as character data', () {
    const source = '<x:style><![CDATA[x|p { content: "<a/>"; }]]></x:style>';
    final normalized = XhtmlHtmlCompatibility.normalizeForHtmlParser(source);
    expect(normalized, contains('&lt;a/&gt;'));
  });
  test('locked target with literal generic parameter remains plain text', () {
    final html = ProperNameNormalizer.normalizeHtml(
      '<p>使用 List 来存储数据。</p>',
      ProperNameNormalizer.parseGlossary('List => 列表<T>'),
      targetLanguage: 'Chinese',
    );
    final text = XhtmlHtmlCompatibility.parseFragment(html).text;
    expect(text, contains('列表<T>'));
  });
  test(
    'locked target containing entity syntax is not decoded into another term',
    () {
      final html = ProperNameNormalizer.normalizeHtml(
        '<p>使用 Alice 来表示符号。</p>',
        ProperNameNormalizer.parseGlossary('Alice => 字面值&lt;'),
        targetLanguage: 'Chinese',
      );
      final text = XhtmlHtmlCompatibility.parseFragment(html).text;
      expect(text, contains('字面值&lt;'));
    },
  );
  test(
    'translation output does not contain XML 1.0 forbidden control characters',
    () {
      final source =
          '<html xmlns="$xhtml"><head><title>B</title></head><body><p>Hello world.</p></body></html>';
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/c.xhtml',
        bytes: utf8.encode(source),
      );
      expect(
        () => EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(
                translatedHtml: '<p>你好\u0001，世界。</p>',
              ),
            ],
          ),
          bilingual: false,
          targetLanguage: 'Chinese',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'API quality gate rejects XML-forbidden characters before caching',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://offline.invalid/v1'));
      final translator = EpubChapterTranslator(apiClient: ControlReplyClient());
      var validatedWithControl = false;
      try {
        final reply = await translator.translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'offline-test',
            styleProfileEnabled: false,
          ),
          blocks: [
            const ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml: '<p>Hello world.</p>',
              sourceText: 'Hello world.',
            ),
          ],
          onValidated: (_, html) async {
            validatedWithControl = html.contains('\u0001');
          },
        );
        expect(reply.every((html) => !html.contains('\u0001')), isTrue);
        expect(validatedWithControl, isFalse);
      } finally {
        dio.close(force: true);
      }
    },
  );
}
