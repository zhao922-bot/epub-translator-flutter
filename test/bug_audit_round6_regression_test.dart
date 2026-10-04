import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:html/parser.dart' as html;
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'bug_audit_round4_regression_test.dart' as fixture;

void main() {
  for (final protected in [
    '<!-- <a/> <br> &nbsp; -->',
    '<![CDATA[<a/> <br> &nbsp;]]>',
    '<?example <a/> <br> &nbsp; ?>',
    '<script>var s = "<a/> <br> &nbsp;";</script>',
    '<STYLE>.a::before { content: "<a/> <br> &nbsp;"; }</STYLE>',
    '<script data-value=">">var s = "<a/>";</script>',
  ]) {
    test(
      'preserves opaque content while normalizing adjacent markup: $protected',
      () {
        expect(
          XhtmlHtmlCompatibility.normalizeForHtmlParser(
            '$protected<a id="x"/>',
          ),
          '${protected.startsWith('<![CDATA[') ? '&lt;a/&gt; &lt;br&gt; &amp;nbsp;' : protected}<a id="x"></a>',
        );
        expect(
          XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
            '$protected<p>A&nbsp;B<br></p>',
          ),
          '$protected<p>A&#160;B<br /></p>',
        );
      },
    );
  }
  test('self-closing script does not hide following markup', () {
    expect(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(
        '<script src="x.js"/><a id="x"/>',
      ),
      '<script src="x.js"></script><a id="x"></a>',
    );
  });
  test('style CDATA survives real chapter export', () {
    const css = '.label::before { content: "<a/> <br> &nbsp;"; }';
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'OPS/chapter.xhtml',
      bytes: utf8.encode(
        '<html><head><style><![CDATA[$css]]></style></head><body><p>Hello</p></body></html>',
      ),
    );
    final result = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        blocks: [chapter.blocks.single.copyWith(translatedHtml: '<p>你好</p>')],
      ),
      bilingual: false,
    );
    expect(
      XmlDocument.parse(result).findAllElements('style').first.innerText,
      css,
    );
  });
  for (final kind in ['ipv4', 'ipv6-url', 'ipv6-bare']) {
    test('configured local proxy can carry requests: $kind', () async {
      final address = kind == 'ipv4'
          ? InternetAddress.loopbackIPv4
          : InternetAddress.loopbackIPv6;
      final server = await HttpServer.bind(address, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('local proxy reached');
        await request.response.close();
      });
      if (kind != 'ipv4') {
        // Verify the OS loopback route separately from the app's proxy code.
        // Only an unavailable native route skips the proxy assertion below.
        try {
          final probe = await Socket.connect(
            address,
            server.port,
            timeout: const Duration(seconds: 2),
          );
          probe.destroy();
        } on SocketException catch (error) {
          markTestSkipped('Native IPv6 loopback unavailable: $error');
          return;
        }
      }
      final proxy = kind == 'ipv4'
          ? '127.0.0.1:${server.port}'
          : '${kind == 'ipv6-url' ? 'http://' : ''}[::1]:${server.port}';
      expect(TranslationApiClient.validateProxySetting(proxy), isNull);
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://audit.invalid/v1',
        apiKey: 'mock',
        httpProxy: proxy,
        timeoutSeconds: 2,
      );
      final dio = const TranslationApiClient().buildDio(config);
      addTearDown(() => dio.close(force: true));
      final response = await dio.get<String>('/probe');
      expect(response.data, 'local proxy reached');
    });
  }
  for (final name in ['chapter.xhtml', 'chapter#1.xhtml', 'chapter?1.xhtml']) {
    test('inspect encoded manifest path $name', () async {
      final dir = await Directory.systemTemp.createTemp('epub-audit6-');
      addTearDown(() => dir.delete(recursive: true));
      final book = await fixture.writeBook(dir, chapterName: name);
      final result = await EpubInspector().inspect(
        inputPath: book.path,
        outputDirectory: dir.path,
        cancelToken: CancelToken(),
      );
      expect(result.chapters.single.path, 'OPS/$name');
    });
  }
  for (final script in [
    'var marker = "plain";',
    'var marker = "&lt;a id=\'mark\'/&gt;";',
    '<![CDATA[var marker = "<a id=\'mark\'/>";]]>',
    '<![CDATA[var marker = "<br>";]]>',
  ]) {
    test('export preserves XML script text: $script', () {
      final source =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title>'
          '<script>$script</script></head><body><p>Hello world</p></body></html>';
      final expected = XmlDocument.parse(
        source,
      ).findAllElements('script').single.innerText;
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/chapter.xhtml',
        bytes: utf8.encode(source),
      );
      final rendered = EpubRepacker().renderTranslatedChapter(
        chapter: chapter.copyWith(
          blocks: [
            chapter.blocks.single.copyWith(translatedHtml: '<p>你好世界</p>'),
          ],
        ),
        bilingual: false,
      );
      final actual = XmlDocument.parse(
        rendered,
      ).findAllElements('script').single.innerText;
      expect(actual, expected);
    });
  }
  for (final bilingual in [false, true]) {
    for (final tag in ['p', 'caption']) {
      test(
        'batch translation and export preserve $tag structure: bilingual=$bilingual',
        () async {
          final fragment =
              '<$tag id="label" class="caption-style">Annual revenue</$tag>';
          final source =
              '<html><body>${tag == 'caption' ? '<table>$fragment<tr><td></td></tr></table>' : fragment}</body></html>';
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'OPS/chapter.xhtml',
            bytes: utf8.encode(source),
          );
          expect(chapter.blocks, hasLength(1));
          expect(chapter.blocks.single.tagName, tag);
          final config = TranslationConfig.defaults().copyWith(
            apiBaseUrl: 'https://audit.invalid/v1',
            apiKey: 'mock',
            maxRetries: 1,
          );
          final dio = Dio();
          addTearDown(() => dio.close(force: true));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final payload =
                    jsonDecode(
                          ((options.data as Map)['messages'] as List)
                                  .last['content']
                              as String,
                        )
                        as Map;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'choices': [
                        {
                          'message': {
                            'content': jsonEncode({
                              'blocks': [
                                for (final item in payload['blocks'] as List)
                                  {
                                    'id': (item as Map)['id'],
                                    'html': '<$tag>年度收入</$tag>',
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
          final translated = await EpubTranslationRepository()
              .translateBlockBatchForTest(
                dio: dio,
                config: config,
                blocks: chapter.blocks,
              );
          final rendered = EpubRepacker().renderTranslatedChapter(
            chapter: chapter.copyWith(
              blocks: [
                chapter.blocks.single.copyWith(
                  translatedHtml: translated.single,
                ),
              ],
            ),
            bilingual: bilingual,
          );
          final document = html.parse(rendered);
          final result = document.querySelector(tag);
          expect(result, isNotNull, reason: document.body!.innerHtml);
          expect(
            document.querySelectorAll(tag).any((e) => e.text.contains('年度收入')),
            isTrue,
          );
          expect(result!.attributes['id'], 'label');
          expect(result.attributes['class'], 'caption-style');
          expect(document.querySelectorAll('#label'), hasLength(1));
          if (tag == 'caption') {
            expect(document.querySelectorAll('caption'), hasLength(1));
            expect(result.parent!.localName, 'table');
            if (bilingual) expect(result.text, contains('Annual revenue'));
          }
        },
      );
    }
  }
}
