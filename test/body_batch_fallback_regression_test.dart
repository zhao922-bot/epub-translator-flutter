import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

const _block = ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml: '<p>They sat on the bank.</p>',
  sourceText: 'They sat on the bank.',
);
const _before = ExtractedBlock(
  id: 'before',
  tagName: 'p',
  sourceHtml: '<p>The river flowed nearby.</p>',
  sourceText: 'The river flowed nearby.',
);
const _after = ExtractedBlock(
  id: 'after',
  tagName: 'p',
  sourceHtml: '<p>They watched the water.</p>',
  sourceText: 'They watched the water.',
);

Future<List<String>> _translate(
  _ContextAdapter adapter, {
  ExtractedBlock block = _block,
  Map<String, Object?>? memory,
}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
    ..httpClientAdapter = adapter;
  try {
    return await EpubChapterTranslator().translateBlockBatchForTest(
      dio: dio,
      config: TranslationConfig.defaults().copyWith(maxRetries: 2),
      blocks: <ExtractedBlock>[block],
      chapterTitle: 'At the river',
      contextBefore: const <ExtractedBlock>[_before],
      contextAfter: const <ExtractedBlock>[_after],
      bookMemory:
          memory ??
          <String, Object?>{
            'bookSummary': 'A walk along the river.',
            'glossary': <Object?>[
              <String, String>{'source': 'bank', 'target': '河岸'},
            ],
          },
    );
  } finally {
    dio.close(force: true);
  }
}

void _expectContext(_ContextAdapter adapter) {
  expect(adapter.fallbackContexts, isNotEmpty);
  for (final message in adapter.fallbackContexts) {
    expect(message, contains('Read-only reference'));
    expect(message, contains('translate only the HTML fragment or text'));
    final context =
        jsonDecode(message.substring(message.indexOf('\n') + 1))
            as Map<String, dynamic>;
    expect(context['chapterTitle'], 'At the river');
    expect(context['before'].toString(), contains('river flowed'));
    expect(context['after'].toString(), contains('watched the water'));
    expect(context['bookMemory'].toString(), contains('河岸'));
  }
}

void main() {
  final malformedReplies = <String, Object?>{
    'blocks object': <String, Object?>{'blocks': <String, Object?>{}},
    'numeric id': <String, Object?>{
      'blocks': <Object?>[
        <String, Object?>{'id': 1, 'html': '<p>译文</p>'},
      ],
    },
    'array html': <String, Object?>{
      'blocks': <Object?>[
        <String, Object?>{'id': 'p-1', 'html': <Object?>[]},
      ],
    },
  };
  for (final entry in malformedReplies.entries) {
    test('${entry.key} retries then falls back without TypeError', () async {
      final adapter = _ContextAdapter(batchReply: jsonEncode(entry.value));
      expect(await _translate(adapter), <String>['<p>他们坐在河岸上。</p>']);
      expect(adapter.batchRequests, 2);
      expect(adapter.fallbackContexts, hasLength(1));
      _expectContext(adapter);
    });
  }

  for (final protected in <bool>[false, true]) {
    final block = protected
        ? const ExtractedBlock(
            id: 'p-1',
            tagName: 'p',
            sourceHtml:
                '<p>They sat on the bank.'
                '<a id="footnote_ref_1" href="notes.xhtml#note-1">*</a></p>',
            sourceText: 'They sat on the bank.*',
          )
        : _block;
    // A single protected-block 413 intentionally fails fast; its text-slot
    // fallback is entered through malformed replies instead.
    for (final failure
        in protected ? <String>['invalid'] : <String>['413', 'invalid']) {
      test(
        '${protected ? 'slot' : 'block'} $failure fallback keeps terminology '
        'and adjacent context',
        () async {
          final normal = await _translate(_ContextAdapter(), block: block);
          final adapter = _ContextAdapter(
            batchStatus: failure == '413' ? 413 : 200,
            batchReply: failure == 'invalid' ? 'not JSON' : null,
          );
          expect(await _translate(adapter, block: block), normal);
          expect(normal.single, contains('河岸'));
          expect(normal.single, isNot(contains('银行')));
          _expectContext(adapter);
        },
      );
    }
  }

  test('fallback reference is bounded without losing the glossary', () async {
    final memory = <String, Object?>{
      'glossary': <Object?>[
        <String, String>{'source': 'bank', 'target': '河岸'},
      ],
      'bookSummary': 'long summary ' * 10000,
      'recentChapters': List<Object?>.filled(100, <String, String>{
        'summary': 'long chapter ' * 10000,
      }),
    };
    final original = jsonEncode(memory);
    final adapter = _ContextAdapter(batchStatus: 413);
    expect(await _translate(adapter, memory: memory), <String>[
      '<p>他们坐在河岸上。</p>',
    ]);
    _expectContext(adapter);
    expect(adapter.fallbackContexts.single.length, lessThan(17000));
    expect(jsonEncode(memory), original);
  });
}

/// Selects the term from the actual request context, so a lost glossary
/// produces a different translation rather than a canned successful reply.
class _ContextAdapter implements HttpClientAdapter {
  _ContextAdapter({this.batchReply, this.batchStatus = 200});

  final String? batchReply;
  final int batchStatus;
  int batchRequests = 0;
  final fallbackContexts = <String>[];

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
    final messages = request['messages'] as List;
    final userText = (messages.last as Map)['content'] as String;
    Object? payload;
    try {
      payload = jsonDecode(userText);
    } on FormatException {
      payload = null;
    }
    final isBatch = payload is Map && payload['blocks'] is List;
    Object? context;
    if (isBatch) {
      batchRequests++;
      context = payload['context'];
      if (batchStatus != 200) {
        return ResponseBody.fromString(
          '{}',
          batchStatus,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (batchReply != null) return _response(batchReply!);
    } else {
      for (final dynamic message in messages) {
        final content = (message as Map)['content'] as String;
        if (content.startsWith('Read-only reference')) {
          fallbackContexts.add(content);
          context = jsonDecode(content.substring(content.indexOf('\n') + 1));
        }
      }
    }
    final term = jsonEncode(context).contains('河岸') ? '河岸' : '银行';
    final text = '他们坐在$term上。';
    if (isBatch) {
      return _response(
        jsonEncode({
          'blocks': [
            for (final dynamic block in payload['blocks'] as List)
              if ((block as Map).containsKey('slots'))
                {
                  'id': block['id'],
                  'slots': [
                    for (final dynamic slot in block['slots'] as List)
                      {'id': (slot as Map)['id'], 'text': text},
                  ],
                }
              else
                {'id': block['id'], 'html': '<p>$text</p>'},
          ],
        }),
      );
    }
    return _response(userText.startsWith('<p>') ? '<p>$text</p>' : text);
  }

  ResponseBody _response(String content) => ResponseBody.fromString(
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
