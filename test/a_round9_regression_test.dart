import 'helpers/memory_history_cache.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

TranslationConfig _config() => TranslationConfig.defaults().copyWith(
  apiBaseUrl: 'https://example.com/v1',
  apiKey: 'test-key',
  model: 'test',
  residualQualityCheck: false,
  styleProfileEnabled: false,
  maxRetries: 2,
);

const _plainBlock = ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml: '<p>Original prose.</p>',
  sourceText: 'Original prose.',
);
const _protectedBlock = ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml:
      '<p>Original prose.<a id="footnote_ref_1" href="#note-1">*</a></p>',
  sourceText: 'Original prose.*',
);

void main() {
  group('P1-#1 atomic HTTP 400 handling', () {
    for (final overflow in [true, false]) {
      test(
        overflow
            ? 'context overflow retains source'
            : 'content filter remains fatal',
        () async {
          final api = _Http400Client(
            overflow
                ? "This model's maximum context length is 8192 tokens"
                : 'Request rejected by content filter',
          );
          final dio = api.buildDio(_config());
          addTearDown(() => dio.close(force: true));
          final translator = EpubChapterTranslator(apiClient: api);
          final future = translator.translateBlockBatchForTest(
            dio: dio,
            config: _config(),
            blocks: [_plainBlock],
          );
          if (overflow) {
            expect(await future, [_plainBlock.sourceHtml]);
            expect(
              translator.degradedReasonForTest(blockId: 'p-1'),
              contains('HTTP 400'),
            );
            expect(
              api.calls,
              2,
              reason: 'one batch and one atomic fallback, without retries',
            );
          } else {
            await expectLater(future, throwsA(isA<StateError>()));
            expect(api.calls, 1);
          }
        },
      );
    }
  });

  group('P2-#5 protected batch slots reject pollution before cache writes', () {
    for (final polluted in [
      '翻译结果：污染译文',
      '```text\n污染译文\n```',
      '**污染译文**',
      null,
    ]) {
      test(
        polluted == null
            ? 'clean slots translate normally'
            : 'rejects $polluted',
        () async {
          final adapter = _ContextAdapter(slotReply: polluted ?? '干净批量译文');
          final dio = Dio(BaseOptions(baseUrl: _config().apiBaseUrl))
            ..httpClientAdapter = adapter;
          addTearDown(() => dio.close(force: true));
          final dir = await Directory.systemTemp.createTemp('round9-cache-');
          addTearDown(() => dir.delete(recursive: true));
          final cache = TranslationCacheStore(cacheRoot: dir);
          final writes = <String>[];
          final result = await EpubChapterTranslator(cacheStore: cache)
              .translateBlockBatchForTest(
                dio: dio,
                config: _config(),
                blocks: [_protectedBlock],
                onValidated: (id, html) async {
                  writes.add(html);
                  await cache.putBlockTranslation(id, html);
                },
              );
          expect(adapter.batchRequests, 1);
          expect(result.single, contains(polluted == null ? '干净批量译文' : '单槽译文'));
          expect(result.single, isNot(contains('污染译文')));
          expect(
            adapter.individualRequests,
            polluted == null ? 0 : greaterThan(0),
          );
          expect(writes, isNotEmpty);
          expect(writes.join(), isNot(contains('污染译文')));
          expect(await cache.getBlockTranslation('p-1'), result.single);
        },
      );
    }
  });

  group('P2-#6 book title cleanup', () {
    final cleanCases = <String, String>{
      '翻译结果：中文书名': '中文书名',
      'Sure, here is the translation: Chinese Title': 'Chinese Title',
      '```plain-text\n中文书名\n```': '中文书名',
      '**中文书名**': '中文书名',
      '__中文书名__': '中文书名',
      '~~中文书名~~': '中文书名',
      '*中文书名*': '中文书名',
      '_中文书名_': '中文书名',
      '# 中文书名': '中文书名',
      '> 中文书名': '中文书名',
      '- 中文书名': '中文书名',
      '1. 中文书名': '中文书名',
      '“「中文书名」”': '中文书名',
      '翻译结果：**「中文书名」**': '中文书名',
    };
    for (final entry in cleanCases.entries) {
      test('cleans ${entry.key}', () {
        expect(
          EpubChapterTranslator.cleanBookTitleForTest(entry.key),
          entry.value,
        );
      });
    }
    for (final raw in ['', '翻译结果：', '** **', '```text\n\n```']) {
      test('empty cleanup rejects ${jsonEncode(raw)}', () {
        expect(
          () => EpubChapterTranslator.cleanBookTitleForTest(raw),
          throwsA(isA<FormatException>()),
        );
      });
    }
    for (final raw in [
      '```text\n中文书名',
      '<b>中文书名</b>',
      '{"title":"中文书名"}',
      '["中文书名"]',
      '[中文书名](https://example.com)',
    ]) {
      test('residual wrapper rejects $raw', () {
        expect(
          () => EpubChapterTranslator.cleanBookTitleForTest(raw),
          throwsA(isA<TranslationParseException>()),
        );
      });
    }
  });

  for (final title in [
    '翻译结果：**中文书名**',
    '<b>中文书名</b>',
    '翻译结果：',
    'Original Title',
  ]) {
    test('cached run isolates release callback and handles title $title', () async {
      final dir = await Directory.systemTemp.createTemp('round9-title-');
      addTearDown(() => dir.delete(recursive: true));
      const html = '<html><body><p>Original body</p></body></html>';
      final input = File('${dir.path}/book.epub');
      final archive = Archive();
      final files = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml':
            '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
        'content.opf':
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Original Title</dc:title></metadata>'
            '<manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="ch"/></spine></package>',
        'chapter.xhtml': html,
      };
      for (final entry in files.entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final api = _TitleClient(title);
      int releases = 0;
      final result =
          await EpubChapterTranslator(
            cacheStore: _CachedBody(),
            apiClient: api,
          ).translateChapters(
            inputPath: input.path,
            outputDirectory: dir.path,
            config: _config(),
            chapters: [
              const EpubHtmlExtractor().inspectChapterBytes(
                chapterPath: 'chapter.xhtml',
                bytes: utf8.encode(html),
              ),
            ],
            cancelToken: CancelToken(),
            onChapterSourcesReleased: (path) {
              expect(path, 'chapter.xhtml');
              releases++;
              throw StateError('release callback boom');
            },
          );
      expect(releases, greaterThan(0));
      expect(api.calls, 1);
      expect(result.job.cachedBlocks, 1);
      final failed = title == '<b>中文书名</b>' || title == '翻译结果：';
      expect(
        result.job.status,
        failed
            ? TranslationJobStatus.completedWithWarnings
            : TranslationJobStatus.completed,
      );
      expect(await File(result.job.outputPath).exists(), isTrue);
      final output = await EpubIsolateWorker.loadArchiveFiles(
        result.job.outputPath,
      );
      final opf = utf8.decode(output['content.opf']!);
      expect(
        XmlDocument.parse(opf).findAllElements('dc:title').single.innerText,
        title == '翻译结果：**中文书名**' ? '中文书名' : 'Original Title',
      );
      expect(opf, isNot(contains('翻译结果：')));
    });
  }
}

class _Http400Client extends TranslationApiClient {
  _Http400Client(this.body);
  final String body;
  int calls = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    throw DioException(
      requestOptions: RequestOptions(),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(),
        statusCode: 400,
        data: {
          'error': {'message': body},
        },
      ),
    );
  }
}

class _ContextAdapter implements HttpClientAdapter {
  _ContextAdapter({required this.slotReply});
  final String slotReply;
  int batchRequests = 0;
  int individualRequests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = BytesBuilder();
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.add(chunk);
      }
    }
    final request = jsonDecode(utf8.decode(bytes.takeBytes())) as Map;
    final user =
        ((request['messages'] as List).last as Map)['content'] as String;
    Object? payload;
    try {
      payload = jsonDecode(user);
    } on FormatException {
      payload = null;
    }
    final String content;
    if (payload is Map && payload['blocks'] is List) {
      batchRequests++;
      // JSON escapes keep the transport's fence stripper from consuming a
      // fence inside a slot; validation must examine the decoded slot value.
      content = jsonEncode({
        'blocks': [
          for (final dynamic block in payload['blocks'] as List)
            {
              'id': (block as Map)['id'],
              'slots': [
                for (final dynamic slot in block['slots'] as List)
                  {'id': (slot as Map)['id'], 'text': slotReply},
              ],
            },
        ],
      }).replaceAll('`', r'\u0060');
    } else {
      individualRequests++;
      content = '单槽译文';
    }
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _CachedBody extends TranslationCacheStore with MemoryHistoryCache {
  @override
  Future<String?> getBlockTranslation(String cacheKey) async => '<p>正文译文</p>';
  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => null;
  @override
  Future<void> saveJobState(JobResumeState state) async {}
}

class _TitleClient extends TranslationApiClient {
  _TitleClient(this.title);
  final String title;
  int calls = 0;
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    expect(data['messages'][0]['content'], contains('book title'));
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': title},
          },
        ],
      },
    );
  }
}
