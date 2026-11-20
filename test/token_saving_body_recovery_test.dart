import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _blocks = [
  ExtractedBlock(
    id: 'p-1',
    tagName: 'p',
    sourceHtml: '<p>The lighthouse shines each night.</p>',
    sourceText: 'The lighthouse shines each night.',
  ),
  ExtractedBlock(
    id: 'p-2',
    tagName: 'p',
    sourceHtml: '<p>A sailor sees the river.</p>',
    sourceText: 'A sailor sees the river.',
  ),
  ExtractedBlock(
    id: 'p-3',
    tagName: 'p',
    sourceHtml: '<p>The boat sails south.</p>',
    sourceText: 'The boat sails south.',
  ),
];
const _translations = {
  'p-1': '<p>灯塔每晚都亮着。</p>',
  'p-2': '<p>水手看见了河流。</p>',
  'p-3': '<p>小船往南航行。</p>',
};

void main() {
  late TranslationCacheStore cache;
  late EpubChapterTranslator translator;
  late TranslationConfig config;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('folio_body_test_');
    cache = TranslationCacheStore(cacheRoot: directory);
    addTearDown(() async {
      await cache.waitForMaintenanceForTest();
      await directory.delete(recursive: true);
    });
    translator = EpubChapterTranslator(cacheStore: cache);
    config = TranslationConfig.defaults().copyWith(
      tokenSavingMode: true,
      maxRetries: 2,
      lockedGlossary: 'lighthouse => 灯塔\nriver => 河流\nboat => 小船',
    );
  });

  Future<List<String>> translate(
    _ScriptedBodyAdapter adapter, {
    List<ExtractedBlock> blocks = _blocks,
    EpubChapterTranslator? using,
    TranslationConfig? withConfig,
    Future<void> Function(String, String)? onValidated,
  }) {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    return (using ?? translator).translateBlockBatchForTest(
      dio: dio,
      config: withConfig ?? config,
      blocks: blocks,
      chapterPath: 'chapter.xhtml',
      onValidated: onValidated,
    );
  }

  test(
    'keeps a valid paragraph and groups missing and residual repairs',
    () async {
      final validated = <String>[];
      final adapter = _ScriptedBodyAdapter((payload, options, attempt) {
        if (attempt == 0) {
          return _response(
            jsonEncode({
              'blocks': [
                _row('p-1'),
                {'id': 'p-2', 'html': _blocks[1].sourceHtml},
              ],
            }),
          );
        }
        expect(validated, ['p-1']);
        expect(payload['kind'], 'bodyRepair');
        final blocks = (payload['blocks'] as List).cast<Map>();
        expect([for (final row in blocks) row['id']], ['p-2', 'p-3']);
        expect(
          [for (final row in blocks) row['reason']],
          ['residual', 'missing'],
        );
        final context = payload['context'] as Map;
        expect(context['lockedGlossary'], [
          {'source': 'river', 'target': '河流'},
          {'source': 'boat', 'target': '小船'},
        ]);
        return _response(_rows(['p-2', 'p-3']));
      });
      expect(
        await translate(
          adapter,
          onValidated: (id, _) async => validated.add(id),
        ),
        _translations.values.toList(),
      );
      expect(adapter.outputBudgets, hasLength(2));
      expect(validated, _translations.keys.toList());
    },
  );

  test(
    'salvages a complete row where truncation cuts off after its brace',
    () async {
      final adapter = _ScriptedBodyAdapter((payload, options, attempt) {
        if (attempt == 0) {
          return _response(
            '{"blocks":[${jsonEncode(_row('p-1'))}',
            finish: 'length',
          );
        }
        expect(payload['kind'], 'bodyRepair');
        final records = (payload['blocks'] as List).cast<Map>();
        expect(records, hasLength(1));
        final row = records.single;
        expect(row['reason'], 'truncated');
        expect(row['id'], isNot('p-1'));
        return _response(_rows([row['id'] as String]));
      });
      expect(await translate(adapter), _translations.values.toList());
      expect(adapter.outputBudgets, hasLength(3));
    },
  );

  test('groups failed protected blocks and preserves their anchors', () async {
    final blocks = [
      for (int i = 0; i < _blocks.length; i++)
        _blocks[i].copyWith(
          sourceHtml:
              '<p>${_blocks[i].sourceText}'
              '<a id="footnote_ref_$i" href="notes.xhtml#note-$i">*</a></p>',
          sourceText: '${_blocks[i].sourceText}*',
        ),
    ];
    final validated = <String>[];
    final adapter = _ScriptedBodyAdapter((payload, options, attempt) {
      final requested = (payload['blocks'] as List).cast<Map>();
      expect(requested.every((row) => row.containsKey('slots')), isTrue);
      final ids = [for (final row in requested) row['id'] as String];
      if (attempt == 0) {
        expect(ids, _translations.keys.toList());
      } else {
        expect(validated, ['p-1']);
        expect(ids, ['p-2', 'p-3']);
      }
      return _response(
        jsonEncode({
          'blocks': [
            for (final row in attempt == 0 ? requested.take(1) : requested)
              {
                'id': row['id'],
                'slots': [
                  for (final slot in (row['slots'] as List).cast<Map>())
                    {
                      'id': slot['id'],
                      'text': _translations[row['id']]!.replaceAll(
                        RegExp('</?p>'),
                        '',
                      ),
                    },
                ],
              },
          ],
        }),
      );
    });
    final translated = await translate(
      adapter,
      blocks: blocks,
      onValidated: (id, _) async => validated.add(id),
    );
    expect(adapter.outputBudgets, hasLength(2));
    expect(validated, _translations.keys.toList());
    for (int i = 0; i < blocks.length; i++) {
      expect(translated[i], contains('href="notes.xhtml#note-$i"'));
      expect(
        translated[i],
        contains(_translations[blocks[i].id]!.substring(3, 5)),
      );
    }
  });

  test(
    'raises reasoning-only recovery within the current user output ceiling',
    () async {
      final adapter = _ScriptedBodyAdapter((payload, options, attempt) {
        if (attempt == 0) {
          return _response('', finish: 'length', reasoning: 'Thinking only.');
        }
        expect(payload['kind'], 'bodyRepair');
        return _response(_rows(['p-1']));
      });
      expect(
        await translate(
          adapter,
          blocks: [_blocks.first],
          withConfig: config.copyWith(maxOutputTokens: 512),
        ),
        [_translations['p-1']],
      );
      expect(adapter.outputBudgets, hasLength(2));
      expect(
        adapter.outputBudgets.last,
        greaterThan(adapter.outputBudgets.first),
      );
      expect(adapter.outputBudgets.last, lessThanOrEqualTo(512));

      final large = _ScriptedBodyAdapter((payload, options, attempt) {
        if (attempt == 0) {
          return _response('', finish: 'length', reasoning: 'Thinking only.');
        }
        expect(payload['kind'], 'bodyRepair');
        return _response(_rows(['p-1']));
      });
      expect(
        await translate(
          large,
          blocks: [_blocks.first],
          withConfig: config.copyWith(maxOutputTokens: 4096),
        ),
        [_translations['p-1']],
      );
      expect(large.outputBudgets.first, adapter.outputBudgets.first);
      expect(large.outputBudgets.last, greaterThan(1500));
      expect(large.outputBudgets.last, lessThanOrEqualTo(4096));
    },
  );

  test(
    'persists a paid draft before a canceled repair with semantic checks',
    () async {
      final checking = config.copyWith(semanticQualityCheck: true);
      final partial = _ScriptedBodyAdapter((payload, options, attempt) {
        if (attempt == 0) return _response(_rows(['p-1']));
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        );
      });
      await expectLater(
        translate(partial, withConfig: checking),
        throwsA(isA<TranslationCancelledException>()),
      );

      final resumed = _ScriptedBodyAdapter((payload, options, attempt) {
        expect(attempt, 0);
        final rows = (payload['blocks'] as List).cast<Map>();
        expect([for (final row in rows) row['id']], ['p-2', 'p-3']);
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        );
      });
      await expectLater(
        translate(
          resumed,
          using: EpubChapterTranslator(cacheStore: cache),
          withConfig: checking,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(resumed.outputBudgets, hasLength(1));
    },
  );
}

Map<String, String> _row(String id) => {'id': id, 'html': _translations[id]!};

String _rows(List<String> ids) => jsonEncode({
  'blocks': [for (final id in ids) _row(id)],
});

ResponseBody _response(
  String content, {
  String finish = 'stop',
  String? reasoning,
}) => ResponseBody.fromString(
  jsonEncode({
    'choices': [
      {
        'finish_reason': finish,
        'message': {'content': content, 'reasoning_content': ?reasoning},
      },
    ],
  }),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _ScriptedBodyAdapter implements HttpClientAdapter {
  _ScriptedBodyAdapter(this.respond);

  final ResponseBody Function(Map<String, dynamic>, RequestOptions, int)
  respond;
  final outputBudgets = <int>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = options.data as Map;
    final messages = (request['messages'] as List).cast<Map>();
    final payload =
        jsonDecode(messages.last['content'] as String) as Map<String, dynamic>;
    final attempt = outputBudgets.length;
    outputBudgets.add(
      (request['max_completion_tokens'] ?? request['max_tokens']) as int,
    );
    return respond(payload, options, attempt);
  }
}
