import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/cancellation_listener.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the A-round-8 review fixes (A-2..A-11).
void main() {
  TranslationConfig config() => TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://example.com/v1',
        apiKey: 'test-key',
        model: 'test',
        residualQualityCheck: false,
        styleProfileEnabled: false,
        maxRetries: 3,
      );

  DioException dio400(String body) => DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.badResponse,
        response: Response(
            requestOptions: RequestOptions(), statusCode: 400, data: body),
      );

  InspectedChapter chapter(String title, String path,
      {String text = 'Original prose.'}) {
    return const EpubHtmlExtractor()
        .inspectChapterBytes(
          chapterPath: path,
          bytes: utf8.encode(
              '<html><head><title>$title</title></head><body><p>$text</p></body></html>'),
        )
        .copyWith(
            title: title,
            category: ChapterCategory.content,
            includeInTranslation: true);
  }

  ExtractedBlock textBlock(String id, String text) => ExtractedBlock(
        id: id,
        tagName: 'p',
        sourceHtml: '<p>$text</p>',
        sourceText: text,
      );

  const notesChapter = InspectedChapter(
    path: 'OEBPS/notes.xhtml',
    title: 'Notes',
    body: '',
    originalHtml: '<html><body></body></html>',
    blocks: <ExtractedBlock>[],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );

  ExtractedBlock protectedBlock() => const ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml:
            '<p>Before <a id="footnote_ref_1" href="#note-1">*</a> after.</p>',
        sourceText: 'Before * after.',
      );

  group('A-2 checkpoint timeline is recorded before it is persisted', () {
    test('record runs before persist', () async {
      final order = <String>[];
      await EpubChapterTranslator.recordAndPersistChapterMemoryForTest(
        record: () => order.add('record'),
        persist: () async => order.add('persist'),
      );
      expect(order, ['record', 'persist']);
    });

    test('two recorded-then-persisted chapters: the disk timeline holds '
        'the latest entry', () async {
      final temp = await Directory.systemTemp.createTemp('a-round8-a2-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);

      Map<String, Object?> memory(String summary) => {
            'bookSummary': summary,
            'glossary': [
              {'source': 't', 'target': '译'},
            ],
          };

      // Chapter 1 finishes: record, then persist.
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'job-a2',
        chunkSize: 3000,
        memory: memory('live-1'),
        timeline: [
          (path: 'ch1.xhtml', memory: {'bookSummary': 's1'}),
        ],
      );
      // Chapter 2 finishes: record, then persist.
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'job-a2',
        chunkSize: 3000,
        memory: memory('live-2'),
        timeline: [
          (path: 'ch1.xhtml', memory: {'bookSummary': 's1'}),
          (path: 'ch2.xhtml', memory: {'bookSummary': 's2'}),
        ],
      );
      // Cancel after chapter 2 and resume: the on-disk timeline must
      // contain the latest chapter's memory entry, not lag one behind.
      final loaded =
          await EpubChapterTranslator.loadBookMemoryTimelineForTest(
        cacheStore: cache,
        jobKey: 'job-a2',
        chunkSize: 3000,
      );
      expect(loaded.map((e) => e['path']), ['ch1.xhtml', 'ch2.xhtml']);
      expect((loaded.last['memory'] as Map)['bookSummary'], 's2');
    });
  });

  group('A-3 footnote batch: context-overflow 400 shrinks instead of '
      'aborting the book', () {
    test('overflow 400 takes the per-reference fallback, not StateError',
        () async {
      final api = _FootnoteOverflowApi();
      final result = await EpubChapterTranslator(apiClient: api)
          .translateFootnoteBatchForTest(
        dio: api.buildDio(config()),
        config: config(),
        references: [
          FootnoteBlockReference(
              chapterIndex: 0,
              chapter: notesChapter,
              block: textBlock('p-1', 'Footnote one.')),
          FootnoteBlockReference(
              chapterIndex: 0,
              chapter: notesChapter,
              block: textBlock('p-2', 'Footnote two.')),
        ],
      );
      expect(result['f0:p-1'], contains('译文'));
      expect(result['f0:p-2'], contains('译文'));
      expect(api.requests.length, 3,
          reason: 'one batch attempt plus two per-reference shrink retries');
    });

    test('a non-overflow 400 still fails fast with StateError', () async {
      final api = _FootnoteOverflowApi()
        ..overflowBody = 'bad request: malformed json';
      await expectLater(
        EpubChapterTranslator(apiClient: api).translateFootnoteBatchForTest(
          dio: api.buildDio(config()),
          config: config(),
          references: [
            FootnoteBlockReference(
                chapterIndex: 0,
                chapter: notesChapter,
                block: textBlock('p-1', 'Footnote one.')),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('A-4 isContextOverflowError requires real length/overflow semantics',
      () {
    test('gateway 400s mentioning context structurally are not overflow',
        () {
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('{"error":"invalid context: missing request_id"}')),
          isFalse);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('gateway context canceled')),
          isFalse);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('bad request: malformed json')),
          isFalse);
    });

    test('genuine overflow phrasing is still detected', () {
      expect(
          TranslationApiClient.isContextOverflowError(dio400(
              "This model's maximum context length is 8192 tokens")),
          isTrue);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('context_length_exceeded')),
          isTrue);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('prompt is too long')),
          isTrue);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('input too large')),
          isTrue);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('token limit exceeded')),
          isTrue);
      expect(
          TranslationApiClient.isContextOverflowError(
              dio400('maximum context window exceeded')),
          isTrue);
    });
  });

  group('A-5 adaptive max_tokens ceiling', () {
    test('a giant single block gets a ceiling above 32768 within the '
        'model cap', () async {
      final api = _FakeApi();
      final bigText = List.filled(60000, 'word ').join();
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config()),
        config: config(),
        blocks: chapter('Big', 'big.xhtml', text: bigText).blocks,
      );
      final maxTokens = api.requests.single['max_tokens'] as int;
      expect(maxTokens, greaterThan(32768));
      expect(maxTokens, lessThanOrEqualTo(131072));
    });

    test('a normal multi-block batch keeps the 32768 ceiling', () async {
      final api = _FakeApi();
      final bigText = List.filled(30000, 'word ').join();
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config()),
        config: config(),
        blocks: [textBlock('p-1', bigText), textBlock('p-2', bigText)],
      );
      final maxTokens = api.requests.single['max_tokens'] as int;
      expect(maxTokens, 32768);
    });
  });

  group('A-6 slot context window follows the slot position', () {
    test('a late slot sees a window around itself, not the first 600 chars',
        () async {
      final api = _FakeApi()
        ..individualReply = '这是槽位译文'
        // Fail the slot batch once so the flow falls back to per-slot.
        ..nextSlotBatchRawReply = 'this is not JSON at all';
      final head = List.filled(500, 'lorem ').join(); // 3000 chars
      final block = ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml:
            '<p>$head<a id="footnote_ref_1" href="#note-1">*</a> needle-tail-marker</p>',
        sourceText: '$head* needle-tail-marker',
      );
      await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
        dio: api.buildDio(config()),
        config: config(),
        blocks: [block],
      );
      final slotRequests = api.requests.where((data) {
        final messages = data['messages'] as List;
        return messages.any((m) =>
            ((m as Map)['content'] as String).contains('blockSummary'));
      }).toList();
      expect(slotRequests, isNotEmpty,
          reason: 'the per-slot path must have been reached');
      String? lateSummary;
      for (final data in slotRequests) {
        final messages = data['messages'] as List;
        final system = messages
            .map((m) => (m as Map)['content'] as String)
            .firstWhere((c) => c.contains('blockSummary'));
        final slotContext =
            jsonDecode(system.substring(system.indexOf('{')))
                as Map<String, dynamic>;
        if (slotContext['currentSlotId'] == 's1') {
          lateSummary = slotContext['blockSummary'] as String;
        }
      }
      expect(lateSummary, isNotNull);
      final String summary = lateSummary!;
      expect(summary, contains('needle-tail-marker'),
          reason: 'the window must be centered on the late slot instead of '
              'truncated to the first 600 characters');
      expect(summary.length, lessThanOrEqualTo(600));
    });
  });

  group('A-7 an empty slot text is rejected in the batch path', () {
    test('the block falls back to per-slot translation; source text is kept',
        () async {
      final api = _EmptySlotBatchApi()..individualReply = '槽位译文';
      final result = await EpubChapterTranslator(apiClient: api)
          .translateBlockBatchForTest(
        dio: api.buildDio(config()),
        config: config(),
        blocks: [protectedBlock()],
      );
      expect(result.single, contains('槽位译文'));
      expect(api.individualCalls, greaterThan(0),
          reason: 'the empty slot went through per-slot failure collection '
              'instead of being rendered empty');
      expect(result.single.contains('<p></p>'), isFalse);
    });
  });

  group('A-8 memory snapshot selects before serializing', () {
    test('only the winning entry is serialized (O(1) per chapter)', () {
      int serializeCount = 0;
      final timeline = <({String path, Object? memory})>[
        for (int i = 0; i < 50; i++) (path: 'ch$i.xhtml', memory: 'mem$i'),
      ];
      final snapshot = EpubChapterTranslator.memorySnapshotForTest(
        timeline: timeline,
        positionByPath: {for (int i = 0; i < 50; i++) 'ch$i.xhtml': i},
        chapterPath: 'ch30.xhtml',
        serialize: (memory) {
          serializeCount++;
          return {'mem': memory};
        },
        fallback: {'live': true},
      );
      expect(snapshot, {'mem': 'mem29'});
      expect(serializeCount, 1,
          reason: 'selecting before serializing keeps it O(1), not O(n)');
    });

    test('the first chapter falls back to the live memory', () {
      final snapshot = EpubChapterTranslator.memorySnapshotForTest(
        timeline: [(path: 'ch0.xhtml', memory: 'mem0')],
        positionByPath: {'ch0.xhtml': 0},
        chapterPath: 'ch0.xhtml',
        serialize: (memory) => {'mem': memory},
        fallback: {'live': true},
      );
      expect(snapshot, {'live': true});
    });
  });

  group('A-9 incremental checkpoint persist merges correctly', () {
    test('three persists merge on disk without duplication or loss',
        () async {
      final temp = await Directory.systemTemp.createTemp('a-round8-a9-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);

      Map<String, Object?> memory(String summary) => {
            'bookSummary': summary,
            'glossary': [
              {'source': 't', 'target': '译'},
            ],
          };

      for (int n = 1; n <= 3; n++) {
        await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
          cacheStore: cache,
          jobKey: 'job-a9',
          chunkSize: 3000,
          memory: memory('live-$n'),
          timeline: [
            for (int i = 1; i <= n; i++)
              (path: 'ch$i.xhtml', memory: {'bookSummary': 's$i'}),
          ],
        );
      }
      final loaded =
          await EpubChapterTranslator.loadBookMemoryTimelineForTest(
        cacheStore: cache,
        jobKey: 'job-a9',
        chunkSize: 3000,
      );
      expect(
          loaded.map((e) => e['path']).toList(),
          ['ch1.xhtml', 'ch2.xhtml', 'ch3.xhtml'],
          reason: 'merged exactly once each: no duplicates, no loss');
      for (int i = 0; i < 3; i++) {
        expect((loaded[i]['memory'] as Map)['bookSummary'], 's${i + 1}');
      }
    });
  });

  group('A-10 context-overflow 400 gets an HTTP 400 degrade reason', () {
    test('the degraded-block sample line carries the 400 cause', () async {
      final translator = EpubChapterTranslator();
      final dio =
          Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
            ..httpClientAdapter = _AlwaysOverflowAdapter();
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: config(),
        blocks: [protectedBlock()],
      );
      // The block degrades to its source HTML instead of aborting.
      expect(result.single, protectedBlock().sourceHtml);
      expect(translator.degradedReasonForTest(blockId: 'p-1'),
          contains('HTTP 400'));
    });
  });

  group('A-11 CancellationListener isolates throwing callbacks', () {
    test('one throwing callback does not skip the rest', () async {
      final token = CancelToken();
      final called = <String>[];
      CancellationListener.listen(token, () => called.add('first'));
      CancellationListener.listen(token, () {
        called.add('throwing');
        throw StateError('listener boom');
      });
      CancellationListener.listen(token, () => called.add('last'));
      token.cancel('test');
      await token.whenCancel;
      // The bridge cancels on the whenCancel future; let it run.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(called, ['first', 'throwing', 'last']);
    });
  });
}

/// Fake API client capturing requests and serving canned replies.
class _FakeApi extends TranslationApiClient {
  final List<Map<String, dynamic>> requests = [];
  String individualReply = '这是槽位译文';
  int individualCalls = 0;

  /// One-shot raw content for the next protected-slot batch reply
  /// (e.g. 'this is not JSON at all' to force the per-slot fallback).
  String? nextSlotBatchRawReply;

  @override
  Dio buildDio(TranslationConfig config) =>
      Dio(BaseOptions(baseUrl: config.apiBaseUrl));

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    requests.add(data);
    final messages = data['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    Object reply;
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      final blocks = payload['blocks'] as List;
      final first = blocks.first as Map;
      if (first.containsKey('slots')) {
        final raw = nextSlotBatchRawReply;
        nextSlotBatchRawReply = null;
        if (raw != null) {
          reply = raw;
        } else {
          reply = {
            'blocks': [
              {
                'id': first['id'],
                'slots': [
                  for (final s in (first['slots'] as List))
                    {'id': (s as Map)['id'], 'text': '译文'},
                ],
              },
            ],
          };
        }
      } else {
        reply = {
          'blocks': [
            for (final b in blocks)
              {'id': (b as Map)['id'], 'html': '<p>译文</p>'},
          ],
        };
      }
    } else {
      individualCalls++;
      reply = individualReply;
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {
              'content': reply is String ? reply : jsonEncode(reply)
            }
          },
        ],
      },
    );
  }
}

/// Fails the first request with a context-overflow 400, then serves the
/// generic canned replies.
class _FootnoteOverflowApi extends _FakeApi {
  bool _failed = false;

  /// Body of the first (failing) response; override for non-overflow 400s.
  String overflowBody =
      '{"error":{"message":"This model\'s maximum context length is 8192 tokens"}}';

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    if (!_failed) {
      _failed = true;
      requests.add(data); // record the failed batch attempt too
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 400,
          data: overflowBody,
        ),
      );
    }
    return super.postChatCompletions(
        dio: dio, data: data, cancelToken: cancelToken);
  }
}

/// Serves a protected-slot batch reply whose first slot text is empty.
class _EmptySlotBatchApi extends _FakeApi {
  bool _replied = false;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    if (!_replied && user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      final blocks = payload['blocks'] as List;
      if (blocks.isNotEmpty && (blocks.first as Map).containsKey('slots')) {
        _replied = true;
        requests.add(data);
        final first = blocks.first as Map;
        final slots = (first['slots'] as List).cast<Map>();
        final reply = {
          'blocks': [
            {
              'id': first['id'],
              'slots': [
                for (int i = 0; i < slots.length; i++)
                  {'id': slots[i]['id'], 'text': i == 0 ? '' : '译文'},
              ],
            },
          ],
        };
        return Response(
          requestOptions: RequestOptions(),
          data: {
            'choices': [
              {'message': {'content': jsonEncode(reply)}},
            ],
          },
        );
      }
    }
    return super.postChatCompletions(
        dio: dio, data: data, cancelToken: cancelToken);
  }
}

/// Always answers with a context-overflow 400.
class _AlwaysOverflowAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      jsonEncode({
        'error': {
          'message': "This model's maximum context length is 8192 tokens"
        }
      }),
      400,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }
}
