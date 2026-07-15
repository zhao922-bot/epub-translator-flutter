import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _RetryOnceBatchAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    if (fetchCount == 1) {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{'error': 'temporary overload'}),
        500,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': <Object?>[
                  <String, Object?>{
                    'id': 'block-1',
                    'html': '<p>Translated text.</p>',
                  },
                ],
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _RateLimitThenSuccessBatchAdapter implements HttpClientAdapter {
  _RateLimitThenSuccessBatchAdapter({required this.rateLimitResponses});

  final int rateLimitResponses;
  int fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    if (fetchCount <= rateLimitResponses) {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{'error': 'rate limit'}),
        429,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }

    final BytesBuilder builder = BytesBuilder();
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        builder.add(chunk);
      }
    }
    final Map<String, dynamic> request =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final List<dynamic> blocks = payload['blocks'] as List<dynamic>;

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': blocks
                    .cast<Map<String, dynamic>>()
                    .map(
                      (Map<String, dynamic> block) => <String, Object?>{
                        'id': block['id'],
                        'html': '<p>Translated after rate limit.</p>',
                      },
                    )
                    .toList(),
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _RecordingBatchAdapter implements HttpClientAdapter {
  Map<String, dynamic>? lastRequestBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final BytesBuilder builder = BytesBuilder();
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        builder.add(chunk);
      }
    }
    lastRequestBody =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
    final Map<String, dynamic> request = lastRequestBody!;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final List<dynamic> blocks = payload['blocks'] as List<dynamic>;

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': blocks
                    .cast<Map<String, dynamic>>()
                    .map(
                      (Map<String, dynamic> block) => <String, Object?>{
                        'id': block['id'],
                        'html': '<p>Translated ${block['id']}</p>',
                      },
                    )
                    .toList(),
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _ResidualThenTranslatedBatchAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    final bool firstAttempt = fetchCount == 1;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': <Object?>[
                  <String, Object?>{
                    'id': 'block-1',
                    'html': firstAttempt
                        ? '<p>This sentence still has many English words remaining untranslated in the result.</p>'
                        : '<p>这句话已经翻译完成。</p>',
                  },
                ],
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _ProperNounBatchAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': <Object?>[
                  <String, Object?>{
                    'id': 'block-1',
                    'html': '<p>Alice 在 EPUB 和 API 文档中找到了线索。</p>',
                  },
                ],
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _RecordingMemoryAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final BytesBuilder builder = BytesBuilder();
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        builder.add(chunk);
      }
    }
    final Map<String, dynamic> request =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    payloads.add(payload);

    final Object responsePayload = switch (payload['kind']) {
      'initialBookMemory' => <String, Object?>{
        'bookSummary': 'A mystery about a locked hallway.',
        'styleGuide': <String>['Keep character names consistent.'],
        'glossary': <Object?>[
          <String, String>{'source': 'Alice', 'target': '艾丽丝'},
        ],
        'recentChapters': <Object?>[],
      },
      'chapterMemory' => <String, Object?>{
        'title': (payload['chapter'] as Map<String, dynamic>)['title'],
        'summary': 'Alice found a brass key.',
        'continuityNotes': <String>['The brass key should stay important.'],
        'glossary': <Object?>[
          <String, String>{'source': 'brass key', 'target': '黄铜钥匙'},
        ],
      },
      _ => throw StateError('Unexpected memory payload: ${payload['kind']}'),
    };

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(responsePayload),
            },
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group('batch fallback policy', () {
    DioException dioException({int? statusCode}) {
      return DioException(
        requestOptions: RequestOptions(path: '/chat/completions'),
        response: statusCode == null
            ? null
            : Response<dynamic>(
                requestOptions: RequestOptions(path: '/chat/completions'),
                statusCode: statusCode,
              ),
      );
    }

    test(
      'does not expand auth or rate-limit failures into per-block calls',
      () {
        expect(
          EpubTranslationRepository.shouldFallbackBatchDioExceptionForTest(
            dioException(statusCode: 401),
          ),
          isFalse,
        );
        expect(
          EpubTranslationRepository.shouldFallbackBatchDioExceptionForTest(
            dioException(statusCode: 403),
          ),
          isFalse,
        );
        expect(
          EpubTranslationRepository.shouldFallbackBatchDioExceptionForTest(
            dioException(statusCode: 429),
          ),
          isFalse,
        );
      },
    );

    test('does not expand network failures into per-block calls', () {
      expect(
        EpubTranslationRepository.shouldFallbackBatchDioExceptionForTest(
          dioException(),
        ),
        isFalse,
      );
    });

    test('can fall back when the batch payload is too large', () {
      expect(
        EpubTranslationRepository.shouldFallbackBatchDioExceptionForTest(
          dioException(statusCode: 413),
        ),
        isTrue,
      );
    });
  });

  group('output suffix', () {
    test('replaces characters that are invalid in Windows filenames', () {
      expect(
        EpubTranslationRepository.sanitizeOutputSuffixForTest(' :bad/name? '),
        '_bad_name_',
      );
    });

    test('falls back when suffix is empty after sanitizing', () {
      expect(
        EpubTranslationRepository.sanitizeOutputSuffixForTest('   '),
        '_translated',
      );
    });
  });

  group('cache key correctness', () {
    const ExtractedBlock block = ExtractedBlock(
      id: 'block-1',
      tagName: 'p',
      sourceHtml: '<p>Hello Alice.</p>',
      sourceText: 'Hello Alice.',
    );

    test('block cache key changes when lockedGlossary changes', () {
      final TranslationConfig base = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
        lockedGlossary: '',
      );
      final String withoutGlossary = EpubChapterTranslator.blockCacheKeyForTest(
        config: base,
        block: block,
        chapterPath: 'chapter-1.xhtml',
      );
      final String withGlossary = EpubChapterTranslator.blockCacheKeyForTest(
        config: base.copyWith(lockedGlossary: 'Alice => 艾丽丝'),
        block: block,
        chapterPath: 'chapter-1.xhtml',
      );

      expect(withoutGlossary, isNot(equals(withGlossary)));
      expect(withoutGlossary, hasLength(64));
      expect(withGlossary, hasLength(64));
    });

    test('job key changes when lockedGlossary changes', () {
      final TranslationConfig base = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
        lockedGlossary: '',
      );
      final List<InspectedChapter> chapters = <InspectedChapter>[
        _chapter(
          path: 'chapter-1.xhtml',
          title: 'Chapter One',
          category: ChapterCategory.content,
          text: 'Hello Alice.',
        ),
      ];
      final String withoutGlossary = EpubChapterTranslator.jobKeyForTest(
        inputFingerprint: 'fingerprint-1',
        config: base,
        chapters: chapters,
      );
      final String withGlossary = EpubChapterTranslator.jobKeyForTest(
        inputFingerprint: 'fingerprint-1',
        config: base.copyWith(lockedGlossary: 'Alice => 艾丽丝'),
        chapters: chapters,
      );

      expect(withoutGlossary, isNot(equals(withGlossary)));
      expect(withoutGlossary, hasLength(64));
      expect(withGlossary, hasLength(64));
    });
  });

  group('batch retry policy', () {
    test('retries a transient batch request before falling back', () async {
      final _RetryOnceBatchAdapter adapter = _RetryOnceBatchAdapter();
      final Dio dio = Dio(
        BaseOptions(
          baseUrl: 'https://api.example.test/v1',
          headers: <String, String>{
            'Authorization': 'Bearer sk-test',
            'Content-Type': 'application/json',
          },
        ),
      )..httpClientAdapter = adapter;

      final List<String> translated = await EpubTranslationRepository()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiBaseUrl: 'https://api.example.test',
              apiKey: 'sk-test',
              maxRetries: 2,
              retryDelaySeconds: 1,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'block-1',
                tagName: 'p',
                sourceHtml: '<p>Source text.</p>',
                sourceText: 'Source text.',
              ),
            ],
          );

      expect(adapter.fetchCount, 2);
      expect(translated, <String>['<p>Translated text.</p>']);
    });

    test(
      'keeps retrying rate-limited batches beyond normal retry count',
      () async {
        final _RateLimitThenSuccessBatchAdapter adapter =
            _RateLimitThenSuccessBatchAdapter(rateLimitResponses: 4);
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final List<String> translated = await EpubTranslationRepository()
            .translateBlockBatchForTest(
              dio: dio,
              config: TranslationConfig.defaults().copyWith(
                apiKey: 'sk-test',
                maxRetries: 3,
                retryDelaySeconds: 1,
              ),
              blocks: const <ExtractedBlock>[
                ExtractedBlock(
                  id: 'block-1',
                  tagName: 'p',
                  sourceHtml: '<p>Source text.</p>',
                  sourceText: 'Source text.',
                ),
              ],
            );

        expect(adapter.fetchCount, 5);
        expect(translated, <String>['<p>Translated after rate limit.</p>']);
      },
    );
  });

  group('translation residual detection', () {
    test(
      'retries Chinese-target batches that come back mostly untranslated',
      () async {
        final _ResidualThenTranslatedBatchAdapter adapter =
            _ResidualThenTranslatedBatchAdapter();
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final List<String>
        translated = await EpubTranslationRepository().translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'sk-test',
            targetLanguage: 'Chinese',
            maxRetries: 2,
            retryDelaySeconds: 1,
          ),
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'block-1',
              tagName: 'p',
              sourceHtml:
                  '<p>This sentence should be translated into Chinese before it is accepted.</p>',
              sourceText:
                  'This sentence should be translated into Chinese before it is accepted.',
            ),
          ],
        );

        expect(adapter.fetchCount, 2);
        expect(translated, <String>['<p>这句话已经翻译完成。</p>']);
      },
    );

    test(
      'does not retry Chinese translations with normal proper nouns',
      () async {
        final _ProperNounBatchAdapter adapter = _ProperNounBatchAdapter();
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final List<String> translated = await EpubTranslationRepository()
            .translateBlockBatchForTest(
              dio: dio,
              config: TranslationConfig.defaults().copyWith(
                apiKey: 'sk-test',
                targetLanguage: 'Chinese',
                maxRetries: 2,
                retryDelaySeconds: 1,
              ),
              blocks: const <ExtractedBlock>[
                ExtractedBlock(
                  id: 'block-1',
                  tagName: 'p',
                  sourceHtml:
                      '<p>Alice found a clue in the EPUB and API documents.</p>',
                  sourceText:
                      'Alice found a clue in the EPUB and API documents.',
                ),
              ],
            );

        expect(adapter.fetchCount, 1);
        expect(translated, <String>['<p>Alice 在 EPUB 和 API 文档中找到了线索。</p>']);
      },
    );
  });

  group('context-aware batching', () {
    test('adds neighboring context without making it translatable', () async {
      final _RecordingBatchAdapter adapter = _RecordingBatchAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String> translated = await EpubTranslationRepository()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(apiKey: 'sk-test'),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-2',
                tagName: 'p',
                sourceHtml: '<p>She looked back.</p>',
                sourceText: 'She looked back.',
              ),
            ],
            chapterTitle: 'Chapter One',
            contextBefore: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: '<p>Alice opened the door.</p>',
                sourceText: 'Alice opened the door.',
              ),
            ],
            contextAfter: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-3',
                tagName: 'p',
                sourceHtml: '<p>The hallway was empty.</p>',
                sourceText: 'The hallway was empty.',
              ),
            ],
          );

      final List<dynamic> messages =
          adapter.lastRequestBody!['messages'] as List<dynamic>;
      final Map<String, dynamic> payload =
          jsonDecode(
                (messages.last as Map<String, dynamic>)['content'] as String,
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> context =
          payload['context'] as Map<String, dynamic>;

      expect(context['chapterTitle'], 'Chapter One');
      expect((context['before'] as List<dynamic>).single, <String, String>{
        'id': 'p-1',
        'text': 'Alice opened the door.',
      });
      expect((context['after'] as List<dynamic>).single, <String, String>{
        'id': 'p-3',
        'text': 'The hallway was empty.',
      });
      expect(payload['blocks'], hasLength(1));
      expect(translated, <String>['<p>Translated p-2</p>']);
    });

    test('builds context from neighboring chapter blocks', () {
      final List<Map<String, Object?>> plan =
          EpubTranslationRepository.batchPlanForTest(
            chapterTitle: 'Chapter One',
            chunkSize: 500,
            pendingBlocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-2',
                tagName: 'p',
                sourceHtml: '<p>She looked back.</p>',
                sourceText: 'She looked back.',
              ),
            ],
            chapterBlocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: '<p>Alice opened the door.</p>',
                sourceText: 'Alice opened the door.',
              ),
              ExtractedBlock(
                id: 'p-2',
                tagName: 'p',
                sourceHtml: '<p>She looked back.</p>',
                sourceText: 'She looked back.',
              ),
              ExtractedBlock(
                id: 'p-3',
                tagName: 'p',
                sourceHtml: '<p>The hallway was empty.</p>',
                sourceText: 'The hallway was empty.',
              ),
            ],
          );

      expect(plan.single['ids'], <String>['p-2']);
      expect(plan.single['before'], <Map<String, String>>[
        <String, String>{'id': 'p-1', 'text': 'Alice opened the door.'},
      ]);
      expect(plan.single['after'], <Map<String, String>>[
        <String, String>{'id': 'p-3', 'text': 'The hallway was empty.'},
      ]);
    });

    test('includes rolling book memory in the read-only context', () async {
      final _RecordingBatchAdapter adapter = _RecordingBatchAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      await EpubTranslationRepository().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(apiKey: 'sk-test'),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'p-4',
            tagName: 'p',
            sourceHtml: '<p>Alice held the key.</p>',
            sourceText: 'Alice held the key.',
          ),
        ],
        chapterTitle: 'Chapter Two',
        bookMemory: const <String, Object?>{
          'bookSummary': 'A mystery about a locked hallway.',
          'styleGuide': <String>['Keep character names consistent.'],
          'glossary': <Object?>[
            <String, String>{'source': 'Alice', 'target': '艾丽丝'},
          ],
          'recentChapters': <Object?>[
            <String, String>{
              'title': 'Chapter One',
              'summary': 'Alice found a brass key.',
            },
          ],
        },
      );

      final List<dynamic> messages =
          adapter.lastRequestBody!['messages'] as List<dynamic>;
      final Map<String, dynamic> payload =
          jsonDecode(
                (messages.last as Map<String, dynamic>)['content'] as String,
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> context =
          payload['context'] as Map<String, dynamic>;
      final Map<String, dynamic> bookMemory =
          context['bookMemory'] as Map<String, dynamic>;

      expect(bookMemory['bookSummary'], 'A mystery about a locked hallway.');
      expect(bookMemory['recentChapters'], hasLength(1));
      expect(payload['blocks'], hasLength(1));
    });
  });

  group('rolling book memory', () {
    test('builds initial memory from front matter and early content', () async {
      final _RecordingMemoryAdapter adapter = _RecordingMemoryAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final Map<String, Object?> memory = await EpubTranslationRepository()
          .generateInitialBookMemoryForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(apiKey: 'sk-test'),
            chapters: <InspectedChapter>[
              _chapter(
                path: 'toc.xhtml',
                title: 'Table of Contents',
                category: ChapterCategory.frontMatter,
                text: 'Chapter One\nChapter Two',
              ),
              _chapter(
                path: 'preface.xhtml',
                title: 'Preface',
                category: ChapterCategory.frontMatter,
                text: 'This is a quiet mystery.',
              ),
              _chapter(
                path: 'chapter-1.xhtml',
                title: 'Chapter One',
                category: ChapterCategory.content,
                text: 'Alice opened the door.',
              ),
              _chapter(
                path: 'skipped.xhtml',
                title: 'Skipped Chapter',
                category: ChapterCategory.content,
                text: 'This chapter was explicitly unchecked.',
                includeInTranslation: false,
              ),
            ],
          );

      expect(memory['bookSummary'], 'A mystery about a locked hallway.');
      expect(adapter.payloads.single['kind'], 'initialBookMemory');
      expect(
        (adapter.payloads.single['chapters'] as List<dynamic>).map(
          (dynamic item) => (item as Map<String, dynamic>)['title'],
        ),
        <String>['Table of Contents', 'Preface', 'Chapter One'],
      );
    });

    test('rolls chapter memory into recent chapter context', () async {
      final _RecordingMemoryAdapter adapter = _RecordingMemoryAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final Map<String, Object?> memory = await EpubTranslationRepository()
          .updateBookMemoryAfterChapterForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(apiKey: 'sk-test'),
            currentMemory: const <String, Object?>{
              'bookSummary': 'A mystery about a locked hallway.',
              'styleGuide': <String>['Keep character names consistent.'],
              'glossary': <Object?>[],
              'recentChapters': <Object?>[],
            },
            chapter: _chapter(
              path: 'chapter-1.xhtml',
              title: 'Chapter One',
              category: ChapterCategory.content,
              text: 'Alice opened the door.',
            ),
          );

      expect((memory['recentChapters'] as List<Object?>), hasLength(1));
      expect(
        ((memory['recentChapters'] as List<Object?>).single!
            as Map<String, Object?>)['summary'],
        'Alice found a brass key.',
      );
      expect(adapter.payloads.single['kind'], 'chapterMemory');
      expect(
        (adapter.payloads.single['bookMemory']
            as Map<String, dynamic>)['bookSummary'],
        'A mystery about a locked hallway.',
      );
    });
  });

  group('tiny block batching', () {
    test(
      'packs short note markers together instead of overcharging HTML shell',
      () {
        final List<ExtractedBlock> tinyBlocks = List<ExtractedBlock>.generate(
          4,
          (int index) => ExtractedBlock(
            id: 'note-$index',
            tagName: 'p',
            sourceHtml:
                '<p class="footnote-ref" id="fnref-$index"><a href="#fn-$index">[$index]</a></p>',
            sourceText: '[$index]',
          ),
        );

        final List<Map<String, Object?>> plan =
            EpubTranslationRepository.batchPlanForTest(
              chapterTitle: 'Notes',
              chunkSize: 220,
              pendingBlocks: tinyBlocks,
              chapterBlocks: tinyBlocks,
            );

        expect(plan, hasLength(1));
        expect(plan.single['ids'], <String>[
          'note-0',
          'note-1',
          'note-2',
          'note-3',
        ]);
      },
    );
  });

  group('strict HTML structure lock', () {
    test('accepts translated text when tags and attributes match', () {
      expect(
        EpubTranslationRepository.htmlStructureMatchesForTest(
          sourceHtml:
              '<p class="lead" id="p1">Hello <a href="#fn1" class="ref">[1]</a> <em>world</em>.</p>',
          translatedHtml:
              '<p id="p1" class="lead">你好 <a class="ref" href="#fn1">[1]</a> <em>世界</em>。</p>',
        ),
        isTrue,
      );
    });

    test('rejects changed tags and attributes', () {
      expect(
        EpubTranslationRepository.htmlStructureMatchesForTest(
          sourceHtml:
              '<p class="lead">Hello <a href="#fn1">[1]</a> <em>world</em>.</p>',
          translatedHtml:
              '<p class="changed">你好 <span>[1]</span> <em>世界</em>。</p>',
        ),
        isFalse,
      );
    });

    test('rebuilds translated text into the original HTML skeleton', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p class="lead" id="p1">Hello <em>world</em>.</p>',
        translatedHtml:
            '<div><p class="other" id="p1">你好 <em>世界</em>。</p></div>',
      );

      expect(locked, '<p class="lead" id="p1">你好 <em>世界</em>。</p>');
    });

    test('keeps original links when the model removes footnote anchors', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<p>参见[1]。</p>',
      );

      expect(locked, contains('href="#note-1"'));
      expect(locked, contains('id="ref-1"'));
      expect(locked, contains('<a href="#note-1" id="ref-1">[1]</a>'));
      expect(locked, '<p>参见<a href="#note-1" id="ref-1">[1]</a>。</p>');
    });

    test('restores protected footnote marker text when structure matches', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<p>参见<a href="#note-1" id="ref-1">[一]</a>。</p>',
      );

      expect(locked, '<p>参见<a href="#note-1" id="ref-1">[1]</a>。</p>');
    });

    test('uses translated-looking markers only to place original anchors', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<p>参见[一]。</p>',
      );

      expect(locked, '<p>参见<a href="#note-1" id="ref-1">[1]</a>。</p>');
    });

    test('restores protected marker text when rebuilding same text slots', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<div>参见 <a href="#note-1" id="ref-1">[一]</a>。</div>',
      );

      expect(locked, '<p>参见 <a href="#note-1" id="ref-1">[1]</a>。</p>');
    });

    test('does not protect ordinary paragraph ids as translatable text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p id="p1">Hello <em>world</em>.</p>',
        translatedHtml: '<p id="p1">你好世界。</p>',
      );

      expect(locked, '<p id="p1">你好世界。<em></em></p>');
    });

    test('does not restore ordinary hyperlink text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>Visit <a href="https://example.test">the site</a>.</p>',
        translatedHtml: '<p>访问 <a href="https://example.test">这个网站</a>。</p>',
      );

      expect(locked, '<p>访问 <a href="https://example.test">这个网站</a>。</p>');
    });

    test('restores short pagebreak markers when structure matches', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Before <span epub:type="pagebreak" role="doc-pagebreak">12</span> after.</p>',
        translatedHtml:
            '<p>Before <span epub:type="pagebreak" role="doc-pagebreak">twelve</span> after.</p>',
      );

      expect(
        locked,
        '<p>Before <span epub:type="pagebreak" role="doc-pagebreak">12</span> after.</p>',
      );
    });

    test('does not restore pagebreak text when it contains body prose', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><span epub:type="pagebreak" role="doc-pagebreak">This was not a page number but a full sentence with several English words.</span></p>',
        translatedHtml:
            '<p><span epub:type="pagebreak" role="doc-pagebreak">Translated body prose.</span></p>',
      );

      expect(locked, contains('Translated body prose.'));
      expect(locked, isNot(contains('This was not a page number')));
    });

    test('does not restore translatable footnote body text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p epub:type="footnote">Original note.</p>',
        translatedHtml: '<p epub:type="footnote">译注。</p>',
      );

      expect(locked, '<p epub:type="footnote">译注。</p>');
    });
  });
}

InspectedChapter _chapter({
  required String path,
  required String title,
  required ChapterCategory category,
  required String text,
  bool includeInTranslation = true,
}) {
  return InspectedChapter(
    path: path,
    title: title,
    body: text,
    originalHtml: '<html><body><p>$text</p></body></html>',
    blocks: <ExtractedBlock>[
      ExtractedBlock(
        id: '$path#0',
        tagName: 'p',
        sourceHtml: '<p>$text</p>',
        sourceText: text,
      ),
    ],
    category: category,
    recommendedForTranslation: true,
    includeInTranslation: includeInTranslation,
  );
}
