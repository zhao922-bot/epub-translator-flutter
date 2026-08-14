import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

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

class _FootnoteResponseAdapter implements HttpClientAdapter {
  _FootnoteResponseAdapter(this.responseBlocks);

  final List<Map<String, Object?>> responseBlocks;
  Map<String, dynamic>? lastPayload;
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
    final Map<String, dynamic> request =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
    lastRequestBody = request;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final String userContent =
        (messages.last as Map<String, dynamic>)['content'] as String;
    try {
      lastPayload = jsonDecode(userContent) as Map<String, dynamic>;
    } on FormatException {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'content': '```text\nunsafe fallback wrapper\n```',
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

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': responseBlocks,
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

class _MixedProtocolAdapter implements HttpClientAdapter {
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
    final List<Map<String, dynamic>> blocks =
        (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    final List<Map<String, Object?>> responseBlocks = blocks
        .map((block) {
          final String id = block['id'] as String;
          if (block.containsKey('slots')) {
            return <String, Object?>{
              'id': id,
              'slots': (block['slots'] as List<dynamic>)
                  .cast<Map<String, dynamic>>()
                  .map(
                    (Map<String, dynamic> slot) => <String, Object?>{
                      'id': slot['id'],
                      'text': slot['id'] == 's1'
                          ? '<script>alert("slot")</script>尾部译文'
                          : '$id 译文',
                    },
                  )
                  .toList(growable: false),
            };
          }
          return <String, Object?>{'id': id, 'html': '<p>普通译文</p>'};
        })
        .toList(growable: false);
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': responseBlocks,
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

class _ProtectedSlotSplitAdapter implements HttpClientAdapter {
  final List<List<String>> requestIds = <List<String>>[];

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
    final List<Map<String, dynamic>> blocks =
        (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    requestIds.add(
      blocks
          .map((Map<String, dynamic> block) => block['id'] as String)
          .toList(growable: false),
    );

    final bool dropLast = blocks.length > 1;
    final Iterable<Map<String, dynamic>> returned = dropLast
        ? blocks.take(blocks.length - 1)
        : blocks;
    final List<Map<String, Object?>> responseBlocks = returned
        .map((block) {
          final String blockId = block['id'] as String;
          return <String, Object?>{
            'id': blockId,
            'slots': (block['slots'] as List<dynamic>)
                .map((Object? rawSlot) {
                  final Map<String, dynamic> slot =
                      rawSlot as Map<String, dynamic>;
                  return <String, Object?>{
                    'id': slot['id'],
                    'text': blockId == 'protected-a' ? '第一段译文' : '第二段译文',
                  };
                })
                .toList(growable: false),
          };
        })
        .toList(growable: false);

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': responseBlocks,
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

class _ProtectedSlotPlainFallbackAdapter implements HttpClientAdapter {
  _ProtectedSlotPlainFallbackAdapter({
    this.plainResponses = const <String>['第一段译文', '结尾译文'],
  });

  final List<String> plainResponses;
  final List<String> plainInputs = <String>[];
  final List<String> plainSystemPrompts = <String>[];
  int strictRequestCount = 0;

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
    final String systemPrompt =
        (messages.first as Map<String, dynamic>)['content'] as String;
    final String userContent =
        (messages.last as Map<String, dynamic>)['content'] as String;

    Object? responseContent;
    try {
      final Object? decoded = jsonDecode(userContent);
      if (decoded is Map<String, dynamic> && decoded.containsKey('blocks')) {
        strictRequestCount += 1;
        responseContent = jsonEncode(<String, Object?>{
          'blocks': const <Object?>[],
        });
      }
    } on FormatException {
      // Individual-slot fallback intentionally sends plain source text.
    }

    if (responseContent == null) {
      plainInputs.add(userContent);
      plainSystemPrompts.add(systemPrompt);
      final int responseIndex = plainInputs.length - 1;
      responseContent = responseIndex < plainResponses.length
          ? plainResponses[responseIndex]
          : plainResponses.last;
    }

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': responseContent},
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

class _ProtectedSlotQualityRetryAdapter implements HttpClientAdapter {
  int strictRequestCount = 0;
  final List<String> plainInputs = <String>[];

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
    final String userContent =
        (messages.last as Map<String, dynamic>)['content'] as String;

    Object responseContent;
    try {
      final Object? decoded = jsonDecode(userContent);
      if (decoded is Map<String, dynamic> && decoded.containsKey('blocks')) {
        strictRequestCount += 1;
        responseContent = jsonEncode(<String, Object?>{
          'blocks': const <Object?>[],
        });
      } else {
        throw const FormatException();
      }
    } on FormatException {
      plainInputs.add(userContent);
      final int index = plainInputs.length - 1;
      responseContent = switch (index) {
        0 => 'Read this sentence right now.',
        1 => '第二段已经翻译。',
        2 => '第一段已经翻译。',
        _ => '第二段已经翻译。',
      };
    }

    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': responseContent},
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

class _ProtectedSlotPayloadTooLargeAdapter implements HttpClientAdapter {
  int strictRequestCount = 0;
  int plainRequestCount = 0;

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
    final String userContent =
        (messages.last as Map<String, dynamic>)['content'] as String;

    try {
      final Object? decoded = jsonDecode(userContent);
      if (decoded is Map<String, dynamic> && decoded.containsKey('blocks')) {
        strictRequestCount += 1;
        return ResponseBody.fromString(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'content': jsonEncode(<String, Object?>{
                    'blocks': const <Object?>[],
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
    } on FormatException {
      // Individual-slot fallback uses plain text rather than JSON.
    }

    plainRequestCount += 1;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'error': 'payload too large'}),
      413,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _HtmlFootnotePayloadTooLargeAdapter implements HttpClientAdapter {
  int requestCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'error': 'payload too large'}),
      413,
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

class _SequencedHtmlBatchAdapter implements HttpClientAdapter {
  _SequencedHtmlBatchAdapter(this.responses);

  final List<String> responses;
  int fetchCount = 0;

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
    final List<dynamic> blocks = payload['blocks'] as List<dynamic>;
    final String blockId =
        (blocks.single as Map<String, dynamic>)['id'] as String;

    fetchCount += 1;
    final int responseIndex = fetchCount <= responses.length
        ? fetchCount - 1
        : responses.length - 1;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'blocks': <Object?>[
                  <String, Object?>{
                    'id': blockId,
                    'html': responses[responseIndex],
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

    test('ordinary block cache key remains compatible with v12', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
      );
      final String currentKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block,
        chapterPath: 'chapter-1.xhtml',
      );
      final String legacyV12Key = sha256
          .convert(
            utf8.encode(
              <Object>[
                'v12-protected-anchor-text-slots',
                'https://api.example.test/v1',
                config.model.trim(),
                config.targetLanguage.trim(),
                config.lockedGlossary.trim(),
                config.residualQualityCheck,
                config.styleProfileEnabled,
                'none',
                'chapter-1.xhtml',
                block.sourceHtml,
              ].join('|'),
            ),
          )
          .toString();

      expect(currentKey, legacyV12Key);
    });

    test('author signature block uses an isolated cache key', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
      );
      final String ordinaryKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block,
        chapterPath: 'chapter-1.xhtml',
      );
      final String signatureKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block.copyWith(isAuthorSignature: true),
        chapterPath: 'chapter-1.xhtml',
      );

      expect(signatureKey, isNot(ordinaryKey));
    });

    test(
      'block cache key invalidates v9 through v11 footnote structure results',
      () {
        final TranslationConfig config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://api.example.test',
          model: 'example-model',
          targetLanguage: 'Chinese',
        );
        final String currentKey = EpubChapterTranslator.blockCacheKeyForTest(
          config: config,
          block: block,
          chapterPath: 'chapter-1.xhtml',
        );
        final String v9Key = sha256
            .convert(
              utf8.encode(
                <Object>[
                  'v9-cjk-inline-typography',
                  'https://api.example.test/v1',
                  config.model.trim(),
                  config.targetLanguage.trim(),
                  config.lockedGlossary.trim(),
                  config.residualQualityCheck,
                  config.styleProfileEnabled,
                  'none',
                  'chapter-1.xhtml',
                  block.sourceHtml,
                ].join('|'),
              ),
            )
            .toString();
        final String v10Key = sha256
            .convert(
              utf8.encode(
                <Object>[
                  'v10-footnote-anchor-lock',
                  'https://api.example.test/v1',
                  config.model.trim(),
                  config.targetLanguage.trim(),
                  config.lockedGlossary.trim(),
                  config.residualQualityCheck,
                  config.styleProfileEnabled,
                  'none',
                  'chapter-1.xhtml',
                  block.sourceHtml,
                ].join('|'),
              ),
            )
            .toString();
        final String v11Key = sha256
            .convert(
              utf8.encode(
                <Object>[
                  'v11-conservative-footnote-anchor-lock',
                  'https://api.example.test/v1',
                  config.model.trim(),
                  config.targetLanguage.trim(),
                  config.lockedGlossary.trim(),
                  config.residualQualityCheck,
                  config.styleProfileEnabled,
                  'none',
                  'chapter-1.xhtml',
                  block.sourceHtml,
                ].join('|'),
              ),
            )
            .toString();

        expect(currentKey, isNot(equals(v9Key)));
        expect(currentKey, isNot(equals(v10Key)));
        expect(currentKey, isNot(equals(v11Key)));
      },
    );

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

    test('block cache key changes when confirmed style profile changes', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
      );
      const TranslationStyleProfile business = TranslationStyleProfile(
        primaryGenre: 'business nonfiction',
        tone: 'analytical',
        confidence: TranslationStyleConfidence.high,
      );
      const TranslationStyleProfile literary = TranslationStyleProfile(
        primaryGenre: 'literary fiction',
        tone: 'lyrical',
        confidence: TranslationStyleConfidence.high,
      );

      final String businessKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block,
        chapterPath: 'chapter-1.xhtml',
        confirmedStyleProfile: business,
      );
      final String literaryKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block,
        chapterPath: 'chapter-1.xhtml',
        confirmedStyleProfile: literary,
      );

      expect(businessKey, isNot(equals(literaryKey)));
      expect(businessKey, hasLength(64));
      expect(literaryKey, hasLength(64));
    });

    test('job key changes when confirmed style profile changes', () {
      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.example.test',
        model: 'example-model',
        targetLanguage: 'Chinese',
        styleProfileEnabled: true,
      );
      final List<InspectedChapter> chapters = <InspectedChapter>[
        _chapter(
          path: 'chapter-1.xhtml',
          title: 'Chapter One',
          category: ChapterCategory.content,
          text: 'Hello Alice.',
        ),
      ];
      const TranslationStyleProfile business = TranslationStyleProfile(
        primaryGenre: 'business nonfiction',
        confidence: TranslationStyleConfidence.high,
      );
      const TranslationStyleProfile literary = TranslationStyleProfile(
        primaryGenre: 'literary fiction',
        confidence: TranslationStyleConfidence.high,
      );

      final String businessKey = EpubChapterTranslator.jobKeyForTest(
        inputFingerprint: 'fingerprint-1',
        config: config,
        chapters: chapters,
        confirmedStyleProfile: business,
      );
      final String literaryKey = EpubChapterTranslator.jobKeyForTest(
        inputFingerprint: 'fingerprint-1',
        config: config,
        chapters: chapters,
        confirmedStyleProfile: literary,
      );

      expect(businessKey, isNot(equals(literaryKey)));
      expect(businessKey, hasLength(64));
      expect(literaryKey, hasLength(64));
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

  test(
    'mixed chapter batch keeps HTML blocks and groups protected slots',
    () async {
      final _MixedProtocolAdapter adapter = _MixedProtocolAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String>
      translated = await EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 1,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'protected-a',
            tagName: 'p',
            sourceHtml: '<p>First <a href="#n1"><span>[1]</span></a> tail.</p>',
            sourceText: 'First [1] tail.',
          ),
          ExtractedBlock(
            id: 'ordinary',
            tagName: 'p',
            sourceHtml: '<p>Ordinary text.</p>',
            sourceText: 'Ordinary text.',
          ),
          ExtractedBlock(
            id: 'chapter-nav',
            tagName: 'p',
            sourceHtml: '<p><a href="#appendix-a">A</a></p>',
            sourceText: 'A',
          ),
          ExtractedBlock(
            id: 'protected-b',
            tagName: 'p',
            sourceHtml:
                '<p>Second <a href="chapter.xhtml#footnote_ref_2" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
            sourceText: 'Second *',
          ),
        ],
      );

      expect(adapter.payloads, hasLength(2));
      final List<Map<String, dynamic>> htmlBlocks =
          (adapter.payloads.first['blocks'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final List<Map<String, dynamic>> slotBlocks =
          (adapter.payloads.last['blocks'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      expect(
        htmlBlocks.map((Map<String, dynamic> block) => block.keys.toSet()),
        everyElement(<String>{'id', 'html'}),
      );
      expect(
        htmlBlocks.map((Map<String, dynamic> block) => block['id']),
        <String>['ordinary', 'chapter-nav'],
      );
      expect(
        slotBlocks.map((Map<String, dynamic> block) => block['id']),
        <String>['protected-a', 'protected-b'],
      );
      expect(
        slotBlocks.map((Map<String, dynamic> block) => block.keys.toSet()),
        everyElement(<String>{'id', 'slots'}),
      );
      expect(jsonEncode(slotBlocks), isNot(contains('href')));
      expect(translated[0], contains('href="#n1"'));
      expect(translated[1], '<p>普通译文</p>');
      expect(translated[2], contains('href="#appendix-a"'));
      expect(translated[2], contains('普通译文'));
      expect(translated[3], contains('role="doc-backlink"'));
      expect(translated[0], contains('&lt;script&gt;'));
      expect(translated[0], isNot(contains('<script>')));
    },
  );

  test(
    'splits malformed protected slot batches and preserves every result',
    () async {
      final _ProtectedSlotSplitAdapter adapter = _ProtectedSlotSplitAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String> translated = await EpubChapterTranslator()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'protected-a',
                tagName: 'p',
                sourceHtml:
                    '<p>First <a href="#n1"><span>[1]</span></a> tail.</p>',
                sourceText: 'First [1] tail.',
              ),
              ExtractedBlock(
                id: 'protected-b',
                tagName: 'p',
                sourceHtml:
                    '<p>Second <a href="#n2"><span>[2]</span></a> ending.</p>',
                sourceText: 'Second [2] ending.',
              ),
            ],
          );

      expect(adapter.requestIds, <List<String>>[
        <String>['protected-a', 'protected-b'],
        <String>['protected-a'],
        <String>['protected-b'],
      ]);
      expect(translated[0], contains('href="#n1"'));
      expect(translated[0], contains('第一段译文'));
      expect(translated[1], contains('href="#n2"'));
      expect(translated[1], contains('第二段译文'));
    },
  );

  test(
    'falls back to individual plain-text slots for one malformed protected block',
    () async {
      final _ProtectedSlotPlainFallbackAdapter adapter =
          _ProtectedSlotPlainFallbackAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String> translated = await EpubChapterTranslator()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'protected-a',
                tagName: 'p',
                sourceHtml:
                    '<p>First <a href="#n1"><span>[1]</span></a> tail.</p>',
                sourceText: 'First [1] tail.',
              ),
            ],
          );

      expect(adapter.strictRequestCount, 1);
      expect(adapter.plainInputs, <String>['First', 'tail.']);
      expect(
        adapter.plainSystemPrompts,
        everyElement(contains('Return only the translated text')),
      );
      expect(translated.single, contains('第一段译文'));
      expect(translated.single, contains('结尾译文'));
      expect(translated.single, contains('href="#n1"'));
      expect(translated.single, contains('[1]'));
    },
  );

  test(
    'preserves a work title when a malformed protected batch falls back to slots',
    () async {
      final _ProtectedSlotPlainFallbackAdapter adapter =
          _ProtectedSlotPlainFallbackAdapter(
            plainResponses: const <String>[
              '《五百年跃迁》的作者',
              'The 500-Year Delta: What Happens After What Comes Next',
              '描述了一场深刻转型。',
              '其他作家也赞同。',
            ],
          );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String>
      translated = await EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 1,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'p-2',
            tagName: 'p',
            sourceHtml:
                '<p id="p-2">Authors of <i>The 500-Year Delta: What Happens After What Comes Next</i> describe a profound transition.<a id="footnote_ref_37" href="part0023_split_006.html#ch06-en37" role="doc-noteref"><sup>37</sup></a> Other writers agree.<a id="footnote_ref_38" href="part0023_split_006.html#ch06-en38" role="doc-noteref"><sup>38</sup></a></p>',
            sourceText:
                'Authors of The 500-Year Delta: What Happens After What Comes Next describe a profound transition. 37 Other writers agree. 38',
          ),
        ],
      );

      expect(adapter.strictRequestCount, 1);
      expect(adapter.plainInputs, <String>[
        'Authors of',
        'The 500-Year Delta: What Happens After What Comes Next',
        'describe a profound transition.',
        'Other writers agree.',
      ]);
      expect(translated.single, contains('The 500-Year Delta'));
      expect(
        translated.single,
        contains(
          'id="footnote_ref_37" href="part0023_split_006.html#ch06-en37"',
        ),
      );
      expect(
        translated.single,
        contains(
          'id="footnote_ref_38" href="part0023_split_006.html#ch06-en38"',
        ),
      );
    },
  );

  test(
    'retries a complete individual-slot round after rebuilt HTML fails quality',
    () async {
      final _ProtectedSlotQualityRetryAdapter adapter =
          _ProtectedSlotQualityRetryAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String>
      translated = await EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 2,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'protected-retry',
            tagName: 'p',
            sourceHtml:
                '<p id="body">Read this sentence right now.<a id="ref-1" href="#note-1"><sup>1</sup></a>Translate this tail too.</p>',
            sourceText:
                'Read this sentence right now. 1 Translate this tail too.',
          ),
        ],
      );

      expect(adapter.strictRequestCount, 2);
      expect(adapter.plainInputs, <String>[
        'Read this sentence right now.',
        'Translate this tail too.',
        'Read this sentence right now.',
        'Translate this tail too.',
      ]);
      expect(translated.single, contains('第一段已经翻译。'));
      expect(translated.single, contains('第二段已经翻译。'));
      expect(translated.single, contains('id="body"'));
      expect(translated.single, contains('id="ref-1" href="#note-1"'));
    },
  );

  test('does not retry HTTP 413 during individual-slot fallback', () async {
    final _ProtectedSlotPayloadTooLargeAdapter adapter =
        _ProtectedSlotPayloadTooLargeAdapter();
    final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
      ..httpClientAdapter = adapter;

    await expectLater(
      EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 3,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'protected-413',
            tagName: 'p',
            sourceHtml:
                '<p>Translate this sentence.<a href="#note-1"><sup>1</sup></a></p>',
            sourceText: 'Translate this sentence. 1',
          ),
        ],
      ),
      throwsA(
        isA<DioException>().having(
          (DioException error) => error.response?.statusCode,
          'status code',
          413,
        ),
      ),
    );

    expect(adapter.strictRequestCount, 3);
    expect(adapter.plainRequestCount, 1);
  });

  test('rejects unsafe individual-slot fallback output', () async {
    final _ProtectedSlotPlainFallbackAdapter adapter =
        _ProtectedSlotPlainFallbackAdapter(
          plainResponses: const <String>['```text\n不安全译文\n```'],
        );
    final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
      ..httpClientAdapter = adapter;

    await expectLater(
      EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 1,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'protected-a',
            tagName: 'p',
            sourceHtml: '<p>First <a href="#n1"><span>[1]</span></a></p>',
            sourceText: 'First [1]',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  for (final MapEntry<String, String> wrapper in <String, String>{
    'JSON scalar': '"第一段译文"',
    'Markdown emphasis': '**第一段译文**',
    'Markdown inline code': '`第一段译文`',
    'Markdown strikethrough': '~~第一段译文~~',
    'Markdown link': '[第一段译文](https://example.com)',
    'Markdown list': '- 第一段译文',
    'Chinese explanation label': '以下是译文：第一段译文',
    'Chinese courtesy explanation': '好的，以下是译文：第一段译文',
    'English explanation label':
        'Here is the translation: first translated sentence.',
    'English courtesy explanation':
        'Sure, here is the translation: first translated sentence.',
    'HTML comment': '<!-- explanation -->第一段译文',
  }.entries) {
    test('rejects ${wrapper.key} in individual-slot fallback output', () async {
      final _ProtectedSlotPlainFallbackAdapter adapter =
          _ProtectedSlotPlainFallbackAdapter(
            plainResponses: <String>[wrapper.value],
          );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      await expectLater(
        EpubChapterTranslator().translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'sk-test',
            targetLanguage: 'Chinese',
            maxRetries: 1,
          ),
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'protected-a',
              tagName: 'p',
              sourceHtml: '<p>First <a href="#n1"><span>[1]</span></a></p>',
              sourceText: 'First [1]',
            ),
          ],
        ),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test(
    'allows legitimate bracketed prose in individual-slot fallback',
    () async {
      final _ProtectedSlotPlainFallbackAdapter adapter =
          _ProtectedSlotPlainFallbackAdapter(
            plainResponses: const <String>['[第一段译文]'],
          );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String> translated = await EpubChapterTranslator()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'protected-a',
                tagName: 'p',
                sourceHtml: '<p>First <a href="#n1"><span>[1]</span></a></p>',
                sourceText: 'First [1]',
              ),
            ],
          );

      expect(translated.single, contains('[第一段译文]'));
      expect(translated.single, contains('href="#n1"'));
    },
  );

  test(
    'rejects duplicate protected slot request ids before fallback',
    () async {
      final _ProtectedSlotSplitAdapter adapter = _ProtectedSlotSplitAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      await expectLater(
        EpubChapterTranslator().translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'sk-test',
            targetLanguage: 'Chinese',
            maxRetries: 1,
          ),
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'protected-a',
              tagName: 'p',
              sourceHtml:
                  '<p>First <a href="#n1"><span>[1]</span></a> tail.</p>',
              sourceText: 'First [1] tail.',
            ),
            ExtractedBlock(
              id: 'protected-a',
              tagName: 'p',
              sourceHtml:
                  '<p>Second <a href="#n2"><span>[2]</span></a> ending.</p>',
              sourceText: 'Second [2] ending.',
            ),
          ],
        ),
        throwsA(isA<FormatException>()),
      );
      expect(adapter.requestIds, isEmpty);
    },
  );

  group('cross-file footnote response ids', () {
    test('does not retry HTTP 413 for an HTML footnote batch', () async {
      final _HtmlFootnotePayloadTooLargeAdapter adapter =
          _HtmlFootnotePayloadTooLargeAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      await expectLater(
        EpubChapterTranslator().translateFootnoteBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'sk-test',
            targetLanguage: 'Chinese',
            maxRetries: 3,
          ),
          references: <FootnoteBlockReference>[
            _footnoteReference(0, 'A normal HTML footnote.'),
          ],
        ),
        throwsA(
          isA<DioException>().having(
            (DioException error) => error.response?.statusCode,
            'status code',
            413,
          ),
        ),
      );

      expect(adapter.requestCount, 1);
    });

    test('same-file short marker uses slots in the footnote batch', () async {
      final _FootnoteResponseAdapter adapter = _FootnoteResponseAdapter(
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'f0:p-1',
            'slots': <Object?>[
              <String, Object?>{'id': 's0', 'text': '正文译文'},
              <String, Object?>{'id': 's1', 'text': '尾部译文'},
            ],
          },
        ],
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final Map<String, String> translated = await EpubChapterTranslator()
          .translateFootnoteBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            references: <FootnoteBlockReference>[
              _footnoteReference(
                0,
                'Body [1] tail.',
                sourceHtml:
                    '<p>Body <a href="#note-1"><span>[1]</span></a> tail.</p>',
              ),
            ],
          );

      final Map<String, dynamic> requestBlock =
          (adapter.lastPayload!['blocks'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(requestBlock.keys.toSet(), <String>{'id', 'slots'});
      expect(jsonEncode(requestBlock), isNot(contains('href')));
      expect(translated['f0:p-1'], contains('href="#note-1"'));
      expect(translated['f0:p-1'], contains('>[1]</span>'));
    });

    test(
      'maps a shuffled response by its globally unique request ids',
      () async {
        final _FootnoteResponseAdapter adapter = _FootnoteResponseAdapter(
          <Map<String, Object?>>[
            <String, Object?>{'id': 'f1:p-1', 'html': '<p>第二条脚注。</p>'},
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>第一条脚注。</p>'},
          ],
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final Map<String, String> translated = await EpubChapterTranslator()
            .translateFootnoteBatchForTest(
              dio: dio,
              config: TranslationConfig.defaults().copyWith(
                apiKey: 'sk-test',
                targetLanguage: 'Chinese',
                maxRetries: 1,
              ),
              references: <FootnoteBlockReference>[
                _footnoteReference(0, 'First footnote.'),
                _footnoteReference(1, 'Second footnote.'),
              ],
            );

        expect(
          (adapter.lastPayload!['blocks'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map((Map<String, dynamic> block) => block.keys.toSet()),
          everyElement(<String>{'id', 'html'}),
        );
        expect(
          (adapter.lastPayload!['blocks'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map((Map<String, dynamic> block) => block['id']),
          <String>['f0:p-1', 'f1:p-1'],
        );
        expect(translated, <String, String>{
          'f0:p-1': '<p>第一条脚注。</p>',
          'f1:p-1': '<p>第二条脚注。</p>',
        });
      },
    );

    test(
      'uses one strict slot request and renders shuffled text into source anchors',
      () async {
        final _FootnoteResponseAdapter adapter = _FootnoteResponseAdapter(
          <Map<String, Object?>>[
            <String, Object?>{
              'id': 'f1:p-1',
              'slots': <Object?>[
                <String, Object?>{
                  'id': 's0',
                  'text': '<script>alert("note")</script>脚注译文。',
                },
              ],
            },
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{'id': 's0', 'text': '正文开头'},
                <String, Object?>{
                  'id': 's1',
                  'text': '<script>alert("body")</script>正文结尾',
                },
              ],
            },
          ],
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final Map<String, String>
        translated = await EpubChapterTranslator().translateFootnoteBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'sk-test',
            targetLanguage: 'Chinese',
            maxRetries: 1,
            residualQualityCheck: false,
          ),
          references: <FootnoteBlockReference>[
            _footnoteReference(
              0,
              'Body opening [1] body ending.',
              sourceHtml:
                  '<p id="body"><span>Body opening </span><a id="footnote_ref_1" href="notes.xhtml#note-1" role="doc-noteref" class="footnote_ref keep"><span aria-hidden="true">[1]</span></a><em> body ending.</em></p>',
            ),
            _footnoteReference(
              1,
              'Footnote text. *',
              sourceHtml:
                  '<p id="note-1" role="doc-footnote">Footnote text. <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink" class="return"><span class="footnote_num">*</span></a></p>',
            ),
          ],
        );

        final Map<String, dynamic> payload = adapter.lastPayload!;
        final List<Map<String, dynamic>> requestBlocks =
            (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
        expect(
          requestBlocks.map((Map<String, dynamic> block) => block['id']),
          <String>['f0:p-1', 'f1:p-1'],
        );
        expect(
          requestBlocks.map((Map<String, dynamic> block) => block.keys.toSet()),
          everyElement(<String>{'id', 'slots'}),
        );
        expect(jsonEncode(payload), isNot(contains('notes.xhtml#note-1')));
        expect(jsonEncode(payload), isNot(contains('footnote_ref_1')));
        expect(jsonEncode(payload), isNot(contains('<a')));
        final List<dynamic> messages =
            adapter.lastRequestBody!['messages'] as List<dynamic>;
        final String systemPrompt =
            (messages.first as Map<String, dynamic>)['content'] as String;
        expect(systemPrompt, contains('never return HTML'));
        expect(systemPrompt, contains('strict JSON'));

        expect(translated.keys, <String>['f0:p-1', 'f1:p-1']);
        final String body = translated['f0:p-1']!;
        final String note = translated['f1:p-1']!;
        expect(body, contains('href="notes.xhtml#note-1"'));
        expect(body, contains('id="footnote_ref_1"'));
        expect(body, contains('role="doc-noteref"'));
        expect(body, contains('class="footnote_ref keep"'));
        expect(body, contains('[1]'));
        expect(note, contains('href="chapter.xhtml#footnote_ref_1"'));
        expect(note, contains('role="doc-backlink"'));
        expect(note, contains('class="footnote_num"'));
        expect(note, contains('>*</span>'));
        expect(body, contains('&lt;script&gt;'));
        expect(note, contains('&lt;script&gt;'));
        expect(html_parser.parseFragment(body).querySelector('script'), isNull);
        expect(html_parser.parseFragment(note).querySelector('script'), isNull);
      },
    );

    for (final MapEntry<String, List<Map<String, Object?>>> malformed
        in <String, List<Map<String, Object?>>>{
          'missing block id': <Map<String, Object?>>[],
          'duplicate block id': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{'id': 's0', 'text': '甲'},
              ],
            },
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{'id': 's0', 'text': '乙'},
              ],
            },
          ],
          'slot count mismatch': <Map<String, Object?>>[
            <String, Object?>{'id': 'f0:p-1', 'slots': <Object?>[]},
          ],
          'unknown slot id': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{'id': 's9', 'text': '甲'},
              ],
            },
          ],
          'duplicate slot id': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{'id': 's0', 'text': '甲'},
                <String, Object?>{'id': 's0', 'text': '乙'},
              ],
            },
          ],
          'non-string slot text': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'f0:p-1',
              'slots': <Object?>[
                <String, Object?>{
                  'id': 's0',
                  'text': <String, String>{'html': '<b>甲</b>'},
                },
              ],
            },
          ],
        }.entries) {
      test('rejects slot response with ${malformed.key}', () async {
        final _FootnoteResponseAdapter adapter = _FootnoteResponseAdapter(
          malformed.value,
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final bool duplicateBlock = malformed.key == 'duplicate block id';
        final bool duplicateSlot = malformed.key == 'duplicate slot id';
        await expectLater(
          EpubChapterTranslator().translateFootnoteBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            references: <FootnoteBlockReference>[
              _footnoteReference(
                0,
                duplicateSlot ? 'Before * after' : 'Footnote text. *',
                sourceHtml: duplicateSlot
                    ? '<p>Before <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a> after</p>'
                    : '<p>Footnote text. <a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
              ),
              if (duplicateBlock)
                _footnoteReference(
                  1,
                  'Second footnote. *',
                  sourceHtml:
                      '<p>Second footnote. <a href="chapter.xhtml#footnote_ref_2" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
                ),
            ],
          ),
          throwsA(isA<FormatException>()),
        );
      });
    }

    for (final MapEntry<String, List<Map<String, Object?>>> malformed
        in <String, List<Map<String, Object?>>>{
          'missing id': <Map<String, Object?>>[
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>第一条脚注。</p>'},
          ],
          'duplicate id': <Map<String, Object?>>[
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>第一条脚注。</p>'},
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>重复脚注。</p>'},
          ],
          'unknown id': <Map<String, Object?>>[
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>第一条脚注。</p>'},
            <String, Object?>{'id': 'f9:p-1', 'html': '<p>未知脚注。</p>'},
          ],
          'empty html': <Map<String, Object?>>[
            <String, Object?>{'id': 'f0:p-1', 'html': '<p>第一条脚注。</p>'},
            <String, Object?>{'id': 'f1:p-1', 'html': ' '},
          ],
        }.entries) {
      test('rejects ${malformed.key} instead of guessing ownership', () async {
        final _FootnoteResponseAdapter adapter = _FootnoteResponseAdapter(
          malformed.value,
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        await expectLater(
          EpubChapterTranslator().translateFootnoteBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'sk-test',
              targetLanguage: 'Chinese',
              maxRetries: 1,
            ),
            references: <FootnoteBlockReference>[
              _footnoteReference(0, 'First footnote.'),
              _footnoteReference(1, 'Second footnote.'),
            ],
          ),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('translation residual detection', () {
    test(
      'accepts a retained author signature through the batch path',
      () async {
        final _SequencedHtmlBatchAdapter adapter = _SequencedHtmlBatchAdapter(
          const <String>['<p class="sig">Peter Thiel</p>'],
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final List<String> translated = await EpubChapterTranslator()
            .translateBlockBatchForTest(
              dio: dio,
              config: TranslationConfig.defaults().copyWith(
                apiKey: 'sk-test',
                targetLanguage: 'Chinese',
                maxRetries: 1,
              ),
              blocks: const <ExtractedBlock>[
                ExtractedBlock(
                  id: 'p-11',
                  tagName: 'p',
                  sourceHtml: '<p class="sig">Peter Thiel</p>',
                  sourceText: 'Peter Thiel',
                  isAuthorSignature: true,
                ),
              ],
            );

        expect(adapter.fetchCount, 1);
        expect(translated, const <String>['<p class="sig">Peter Thiel</p>']);
      },
    );

    test('accepts a source-owned English work title in the real p-2 shape', () async {
      const String sourceHtml =
          '<p id="p-2">George Gilder, author of <i>The 500-Year Delta: What Happens After What Comes Next</i>, predicts a profound transition.<a id="ch06-en37-ref" href="part0023_split_006.html#ch06-en37"><sup>37</sup></a> Other writers reach a similar conclusion.<a id="ch06-en38-ref" href="part0023_split_006.html#ch06-en38"><sup>38</sup></a></p>';
      const String translatedHtml =
          '<p id="p-2">《五百年跃迁》的作者乔治·吉尔德在<i>The 500-Year Delta: What Happens After What Comes Next</i>中预言了一场深刻转型。<a id="ch06-en37-ref" href="part0023_split_006.html#ch06-en37"><sup>37</sup></a>其他作家也得出了相似结论。<a id="ch06-en38-ref" href="part0023_split_006.html#ch06-en38"><sup>38</sup></a></p>';
      final _SequencedHtmlBatchAdapter adapter = _SequencedHtmlBatchAdapter(
        const <String>[translatedHtml],
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final List<String>
      translated = await EpubChapterTranslator().translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          apiKey: 'sk-test',
          targetLanguage: 'Chinese',
          maxRetries: 2,
          retryDelaySeconds: 1,
        ),
        blocks: const <ExtractedBlock>[
          ExtractedBlock(
            id: 'p-2',
            tagName: 'p',
            sourceHtml: sourceHtml,
            sourceText:
                'George Gilder, author of The 500-Year Delta: What Happens After What Comes Next, predicts a profound transition. 37 Other writers reach a similar conclusion. 38',
          ),
        ],
      );

      expect(adapter.fetchCount, 1);
      expect(translated.single, contains('The 500-Year Delta'));
      expect(
        translated.single,
        contains('href="part0023_split_006.html#ch06-en37"'),
      );
      expect(translated.single, contains('id="ch06-en37-ref"'));
      expect(
        translated.single,
        contains('href="part0023_split_006.html#ch06-en38"'),
      );
      expect(translated.single, contains('id="ch06-en38-ref"'));
    });

    test(
      'retries a CJK-adjacent lowercase English leak before accepting Chinese',
      () async {
        final _SequencedHtmlBatchAdapter adapter = _SequencedHtmlBatchAdapter(
          const <String>[
            '<p>随着边界消失，entitlement概念随之瓦解。</p>',
            '<p>随着边界消失，权利概念也随之瓦解。</p>',
          ],
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        final List<String>
        translated = await EpubChapterTranslator().translateBlockBatchForTest(
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
                  '<p>As borders disappear, the concept of entitlement falls apart.</p>',
              sourceText:
                  'As borders disappear, the concept of entitlement falls apart.',
            ),
          ],
        );

        expect(adapter.fetchCount, 2);
        expect(translated.single, '<p>随着边界消失，权利概念也随之瓦解。</p>');
        expect(translated.single, isNot(contains('entitlement')));
      },
    );

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

    test(
      'removes emptied inline emphasis after rebuilding a folded translation',
      () {
        final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
          sourceHtml:
              '<p>Some of the <i class="calibre3">agri deserti,</i> or deserted farms were brought back.</p>',
          translatedHtml: '<p>部分荒废农地重新开垦利用。</p>',
        );

        expect(locked, '<p>部分荒废农地重新开垦利用。</p>');
        expect(locked, isNot(contains('<i')));
      },
    );

    test(
      'folded audited term translation passes residual check after lock',
      () {
        const String sourceHtml =
            '<p class="noindent">Some of the <i class="calibre3">agri deserti,</i> or deserted farms were brought back into production.</p>';
        const String modelHtml =
            '<p class="noindent">部分荒废农地被重新开垦利用。</p>';
        final String locked =
            EpubTranslationRepository.lockHtmlStructureForTest(
              sourceHtml: sourceHtml,
              translatedHtml: modelHtml,
            );
        expect(locked, isNot(contains('<i')));
        expect(
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: sourceHtml,
            translatedHtml: locked,
            targetLanguage: 'Chinese',
          ),
          isNull,
        );
      },
    );

    test('keeps original links when the model removes footnote anchors', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<p>参见[1]。</p>',
      );

      expect(locked, contains('href="#note-1"'));
      expect(locked, contains('id="ref-1"'));
      expect(locked, contains('<a href="#note-1" id="ref-1">[1]</a>'));
      expect(locked, '<p>参见[1]。<a href="#note-1" id="ref-1">[1]</a></p>');
    });

    test('restores a cross-file body marker moved outside its anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Source<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>译文*<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>译文<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
      );
      expect('*'.allMatches(locked), hasLength(1));
    });

    test('keeps a fullwidth star beside an empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Source<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>译文＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>译文＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
      );
    });

    test('keeps a Chinese numeral beside an empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Source<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">1</span></a></p>',
        translatedHtml:
            '<p>译文一<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>译文一<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">1</span></a></p>',
      );
    });

    test('keeps nonliteral marker variants beside an empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Body *<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>正文*＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>正文*＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
      );
    });

    test('removes only the marker adjacent to an empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Body＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>正文＊*<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>正文＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
      );
    });

    test('does not remove a source body symbol beside an empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Body＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>正文＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>正文＊<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
      );
    });

    test('keeps an eleven marker variant beside its empty protected anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Body<a href="chapter-fn.xhtml#footnote_11" id="footnote_ref_11"><span class="footnote_ref">11</span></a></p>',
        translatedHtml:
            '<p>正文十一<a href="chapter-fn.xhtml#footnote_11" id="footnote_ref_11"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>正文十一<a href="chapter-fn.xhtml#footnote_11" id="footnote_ref_11"><span class="footnote_ref">11</span></a></p>',
      );
    });

    test('keeps Chinese body text beside an empty numeric anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>First<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">1</a></p>',
        translatedHtml:
            '<p>第一<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"></a></p>',
      );

      expect(
        locked,
        '<p>第一<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">1</a></p>',
      );
    });

    test('keeps bracketed body prose beside an empty bracketed anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Body [important]<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">[1]</a></p>',
        translatedHtml:
            '<p>正文[重要]<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"></a></p>',
      );

      expect(
        locked,
        '<p>正文[重要]<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">[1]</a></p>',
      );
    });

    test('protects a cross-file footnote anchor by its reference id', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Source<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">*</a></p>',
        translatedHtml:
            '<p>译文*<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1"></a></p>',
      );

      expect(
        locked,
        '<p>译文<a href="chapter-fn.xhtml#footnote_1" id="footnote_ref_1">*</a></p>',
      );
    });

    test('protects a class-marked cross-file footnote anchor without an id', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Source<a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref">*</span></a></p>',
        translatedHtml:
            '<p>译文*<a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref"></span></a></p>',
      );

      expect(
        locked,
        '<p>译文<a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref">*</span></a></p>',
      );
    });

    test('moves translated prose out of a doc-backlink marker', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a> Original quotation.</p>',
        translatedHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">* 译后引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a>译后引文</p>',
      );
      expect(
        locked,
        isNot(contains('<span class="footnote_num">* 译后引文</span>')),
      );
    });

    test('moves overflow prose out of a structurally matching doc-backlink', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        translatedHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">* 译后引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a>译后引文</p>',
      );
    });

    test('keeps nested overflow text without moving model nodes', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        translatedHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span><i>译后</i><span>引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a>译后引文</p>',
      );
      expect(locked, isNot(contains('<i>')));
    });

    test('keeps nested overflow text when source has following prose', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a> Original.</p>',
        translatedHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span><i>译后</i><span>引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a>译后引文</p>',
      );
    });

    test('keeps translated body slots while placing overflow in source text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a> First <em>second</em>.</p>',
        translatedHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*译后</span></a> Translated <em>第二</em>.</p>',
      );

      expect(
        locked,
        '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a>译后 Translated <em>第二</em>.</p>',
      );
    });

    test('extracts safe overflow text without model element nodes', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a> Original.</p>',
        translatedHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span><i>译后</i><span>引文</span></a></p>',
      );

      expect(locked, contains('译后引文'));
      expect(locked, isNot(contains('<i>')));
      expect(locked, isNot(contains('<span>引文</span>')));
    });

    test('drops unsafe overflow elements while keeping safe text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a> Original.</p>',
        translatedHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span><script>alert(1)</script><img onerror="x">安全文本</a></p>',
      );

      expect(locked, contains('安全文本'));
      expect(locked, isNot(contains('<script')));
      expect(locked, isNot(contains('<img')));
      expect(locked, isNot(contains('onerror')));
      expect(locked, isNot(contains('alert(1)')));
    });

    test('keeps a word boundary between overflow and following text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>*</span></a> quotation</p>',
        translatedHtml:
            '<p><a href="chapter.xhtml#ref" role="doc-backlink"><span>* Translated</span></a> quotation</p>',
      );

      expect(locked, contains('Translated quotation'));
      expect(locked, isNot(contains('Translatedquotation')));
    });

    test('keeps only prose explicitly moved out of a protected-only anchor', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        translatedHtml:
            '<p>unexpected<a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">* 译后引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a>译后引文</p>',
      );
    });

    test('keeps the inserted overflow instead of an identical outside text', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a></p>',
        translatedHtml:
            '<p>译后引文<a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">* 译后引文</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a>译后引文</p>',
      );
    });

    test('keeps a role-only backlink marker when no text slot can accept prose', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink">*</a></p>',
        translatedHtml:
            '<p>译后<a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink"></a>引文</p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink">*</a></p>',
      );
    });

    test('keeps prose-bearing doc-backlinks translatable', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink">Back to text</a></p>',
        translatedHtml:
            '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink">返回正文</a></p>',
      );

      expect(
        locked,
        '<p><a href="Chapter.xhtml#footnote_ref_1" role="doc-backlink">返回正文</a></p>',
      );
    });

    for (final String attribute in <String>[
      'role="doc-noteref"',
      'epub:type="noteref"',
    ]) {
      test('keeps prose-bearing noteref links translatable: $attribute', () {
        final String locked =
            EpubTranslationRepository.lockHtmlStructureForTest(
              sourceHtml:
                  '<p><a href="#note-1" $attribute>Read the note</a></p>',
              translatedHtml: '<p><a href="#note-1" $attribute>阅读注释</a></p>',
            );

        expect(locked, '<p><a href="#note-1" $attribute>阅读注释</a></p>');
      });
    }

    test('keeps prose-bearing class-marked cross-file links translatable', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p><a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref">See note</span></a></p>',
        translatedHtml:
            '<p><a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref">参见注释</span></a></p>',
      );

      expect(
        locked,
        '<p><a href="chapter-fn.xhtml#footnote_1"><span class="footnote_ref">参见注释</span></a></p>',
      );
    });

    for (final String role in <String>[' doc-backlink ', 'link doc-backlink']) {
      test('protects a marker when role tokens include doc-backlink: $role', () {
        final String
        locked = EpubTranslationRepository.lockHtmlStructureForTest(
          sourceHtml:
              '<p>Source<a href="Chapter.xhtml#footnote_ref_1" role="$role">*</a></p>',
          translatedHtml:
              '<p>译文*<a href="Chapter.xhtml#footnote_ref_1" role="$role"></a></p>',
        );

        expect(
          locked,
          '<p>译文<a href="Chapter.xhtml#footnote_ref_1" role="$role">*</a></p>',
        );
      });
    }

    test('restores protected footnote marker text when structure matches', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
        translatedHtml: '<p>参见<a href="#note-1" id="ref-1">[一]</a>。</p>',
      );

      expect(locked, '<p>参见<a href="#note-1" id="ref-1">[1]</a>。</p>');
    });

    test(
      'keeps translated-looking body text when rebuilding original anchors',
      () {
        final String locked =
            EpubTranslationRepository.lockHtmlStructureForTest(
              sourceHtml: '<p>See <a href="#note-1" id="ref-1">[1]</a>.</p>',
              translatedHtml: '<p>参见[一]。</p>',
            );

        expect(locked, '<p>参见[一]。<a href="#note-1" id="ref-1">[1]</a></p>');
      },
    );

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

    test('does not protect an ordinary cross-file hyperlink', () {
      final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Visit <a href="chapter-2.xhtml#section-1">the next section</a>.</p>',
        translatedHtml: '<p>访问<a href="chapter-2.xhtml#section-1">下一节</a>。</p>',
      );

      expect(locked, '<p>访问<a href="chapter-2.xhtml#section-1">下一节</a>。</p>');
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

FootnoteBlockReference _footnoteReference(
  int chapterIndex,
  String text, {
  String? sourceHtml,
}) {
  final InspectedChapter chapter = _chapter(
    path: 'OPS/Text/note-$chapterIndex-fn.xhtml',
    title: 'Footnote ${chapterIndex + 1}',
    category: ChapterCategory.reference,
    text: text,
  );
  return FootnoteBlockReference(
    chapterIndex: chapterIndex,
    chapter: chapter,
    block: ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml: sourceHtml ?? '<p>$text</p>',
      sourceText: text,
    ),
  );
}
