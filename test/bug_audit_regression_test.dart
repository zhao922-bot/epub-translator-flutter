import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  test(
    'connection probe preserves custom path and encoded query values',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Uri? observed;
      server.listen((request) async {
        observed = request.uri;
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'OK'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      await const TranslationApiClient().testConnection(
        config: TranslationConfig.defaults().copyWith(
          apiBaseUrl:
              'http://127.0.0.1:${server.port}/gateway/v1?token=a%2Fb&version=2024',
          apiKey: 'audit-placeholder',
        ),
      );
      expect(observed!.path, '/gateway/v1/chat/completions');
      expect(observed!.queryParameters, {'token': 'a/b', 'version': '2024'});
    },
  );

  for (final query in ['', '?token=demo']) {
    test('API request keeps endpoint path with base query "$query"', () async {
      const client = TranslationApiClient();
      final dio = client.buildDio(
        TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://example.test/v1$query',
          apiKey: 'audit-placeholder',
        ),
      );
      addTearDown(() => dio.close(force: true));
      Uri? observed;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            observed = options.uri;
            handler.resolve(
              Response(requestOptions: options, data: <String, Object?>{}),
            );
          },
        ),
      );
      await client.postChatCompletions(dio: dio, data: <String, dynamic>{});
      expect(observed!.path, '/v1/chat/completions');
      if (query.isNotEmpty) expect(observed!.queryParameters['token'], 'demo');
    });
  }

  test('French translation changes document language from English', () {
    final chapter = translatedChapter(
      '<html lang="en" xml:lang="en"><body><p>Hello world.</p></body></html>',
      ['<p>Bonjour le monde.</p>'],
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: false,
      targetLanguage: 'French',
    );
    final document = html.parse(output);
    expect(document.documentElement!.attributes['lang'], 'fr');
  });

  test('bilingual ordered list retains two logical numbered items', () {
    final chapter = translatedChapter(
      '<html><body><ol><li>First step.</li><li>Second step.</li></ol></body></html>',
      ['<li>第一步。</li>', '<li>第二步。</li>'],
    );
    final output = EpubRepacker().renderTranslatedChapter(
      chapter: chapter,
      bilingual: true,
      targetLanguage: 'Chinese',
    );
    final items = html.parse(output).querySelectorAll('ol > li');
    expect(
      items.length,
      2,
      reason:
          'Translations must remain inside their source list item so the second step stays numbered 2.',
    );
  });

  test('bilingual list keeps explicit numbering and source anchors', () {
    final chapter = translatedChapter(
      '<html lang="en"><body><ol start="4" reversed="reversed"><li id="step" value="9">First step.</li></ol></body></html>',
      ['<li id="step" value="9">第一步。</li>'],
    );
    final document = html.parse(
      EpubRepacker().renderTranslatedChapter(
        chapter: chapter,
        bilingual: true,
        targetLanguage: 'Chinese',
      ),
    );
    expect(document.querySelectorAll('ol > li'), hasLength(1));
    expect(document.querySelector('ol')!.attributes['start'], '4');
    expect(document.querySelector('li')!.attributes['value'], '9');
    expect(document.querySelectorAll('#step'), hasLength(1));
    expect(document.querySelector('li')!.text, contains('First step.'));
    final translated = document.querySelector('li [data-translation="true"]')!;
    expect(translated.text, '第一步。');
    expect(translated.attributes['lang'], 'zh-CN');
    expect(translated.attributes.containsKey('value'), isFalse);
    expect(document.documentElement!.attributes['lang'], 'en');
  });

  test(
    'French bilingual output retains source language and labels translation',
    () {
      final chapter = translatedChapter(
        '<html lang="en"><body><p>Hello.</p></body></html>',
        ['<p>Bonjour.</p>'],
      );
      final document = html.parse(
        EpubRepacker().renderTranslatedChapter(
          chapter: chapter,
          bilingual: true,
          targetLanguage: 'French',
        ),
      );
      expect(document.documentElement!.attributes['lang'], 'en');
      expect(
        document.querySelector('[data-translation="true"]')!.attributes['lang'],
        'fr',
      );
      expect(document.querySelector('p')!.text, 'Hello.');
    },
  );

  test(
    'second book does not reuse a context-dependent translation from first book',
    () async {
      final temp = await Directory.systemTemp.createTemp('cache-context-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = MemoryCache();
      final repository = EpubTranslationRepository(cacheStore: cache);
      var financialBook = false;
      var financialSharedRequests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final data =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final messages = data['messages'] as List;
        final payload =
            jsonDecode((messages.last as Map)['content'] as String)
                as Map<String, dynamic>;
        final kind = payload['kind'];
        Map<String, Object?> response;
        if (kind == 'initialBookMemory') {
          response = {
            'bookSummary': financialBook ? 'A bank branch.' : 'A riverbank.',
            'styleGuide': [],
            'glossary': [],
            'recentChapters': [],
          };
        } else if (kind == 'chapterMemory') {
          response = {
            'title': 'Chapter',
            'summary': 'Translated.',
            'continuityNotes': [],
            'glossary': [],
          };
        } else {
          response = {
            'blocks': [
              for (final rawBlock in payload['blocks'] as List)
                (() {
                  final block = rawBlock as Map;
                  final id = block['id'];
                  if (financialBook && id == 'p-2') financialSharedRequests++;
                  return {
                    'id': id,
                    'html': id == 'p-2'
                        ? (financialBook ? '<p>银行很安静。</p>' : '<p>河岸很安静。</p>')
                        : (financialBook
                              ? '<p>她把存款交给柜员。</p>'
                              : '<p>她沿着河流走。</p>'),
                  };
                })(),
            ],
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(response)},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'audit-placeholder',
        model: 'audit-model',
        styleProfileEnabled: false,
        residualQualityCheck: false,
        maxConcurrent: 1,
        maxRetries: 1,
      );
      final first = File('${temp.path}/river.epub');
      final second = File('${temp.path}/bank.epub');
      await writeBook(
        first,
        '<p>She walked along the river.</p><p>The bank was quiet.</p>',
      );
      await writeBook(
        second,
        '<p>She gave her savings to the teller.</p><p>The bank was quiet.</p>',
      );
      Future<String> translate(File file) async {
        final inspected = await repository.startJob(
          inputPath: file.path,
          outputDirectory: temp.path,
          config: config,
        );
        final result = await repository.translateChapters(
          inputPath: file.path,
          outputDirectory: temp.path,
          config: config,
          chapters: inspected.chapters,
        );
        final archive = ZipDecoder().decodeBytes(
          await File(result.job.outputPath).readAsBytes(),
        );
        return utf8.decode(
          archive.findFile('OPS/chapter.xhtml')!.content as List<int>,
        );
      }

      await translate(first);
      financialBook = true;
      final secondOutput = await translate(second);
      expect(secondOutput, contains('银行很安静。'));
      expect(financialSharedRequests, 1);
      // The unchanged book must still resume without translating the block again.
      expect(await translate(second), contains('银行很安静。'));
      expect(financialSharedRequests, 1);
      // Editing context in the same book must also invalidate the shared block.
      financialBook = false;
      await writeBook(
        second,
        '<p>She walked along the river.</p><p>The bank was quiet.</p>',
      );
      expect(await translate(second), contains('河岸很安静。'));
    },
  );
}

InspectedChapter translatedChapter(String source, List<String> translations) {
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: 'OPS/chapter.xhtml',
    bytes: utf8.encode(source),
  );
  expect(chapter.blocks.length, translations.length);
  return chapter.copyWith(
    blocks: [
      for (var i = 0; i < chapter.blocks.length; i++)
        chapter.blocks[i].copyWith(translatedHtml: translations[i]),
    ],
  );
}

class MemoryCache extends TranslationCacheStore {
  final values = <String, String>{};
  @override
  Future<String?> getBlockTranslation(String key) async => values[key];
  @override
  Future<void> putBlockTranslation(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<JobResumeState?> loadJobState(String key) async => null;
  @override
  Future<void> saveJobState(JobResumeState state) async {}
  @override
  Future<void> clearJobState(String key) async {}
}

Future<void> writeBook(File file, String body) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/content.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/chapter.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body>$body</body></html>',
      ),
    );
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
}
