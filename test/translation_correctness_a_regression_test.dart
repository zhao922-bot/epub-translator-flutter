import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptApi extends TranslationApiClient {
  _ScriptApi(this.reply);
  final Object Function(Map<String, dynamic> data, int call) reply;
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    requests.add(data);
    final result = reply(data, requests.length);
    if (result is Exception || result is Error) throw result;
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {
              'content': result is String ? result : jsonEncode(result),
            },
          },
        ],
      },
    );
  }
}

ExtractedBlock _block(String id, String html) =>
    ExtractedBlock(id: id, tagName: 'p', sourceHtml: html, sourceText: 'Hello');

const _chapter = InspectedChapter(
  path: 'notes.xhtml',
  title: 'Notes',
  body: '',
  originalHtml: '',
  blocks: [],
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: true,
);

DioException _http(int status) {
  final options = RequestOptions();
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: options, statusCode: status),
  );
}

DioException _timeout() => DioException(
  requestOptions: RequestOptions(),
  type: DioExceptionType.receiveTimeout,
);

void main() {
  final config = TranslationConfig.defaults().copyWith(
    targetLanguage: 'zh',
    maxRetries: 1,
    maxConcurrent: 1,
    residualQualityCheck: false,
  );
  final plain = _block('A', '<p>Hello</p>');
  final protected = _block('B', '<p>Hello <a href="#n1">[1]</a></p>');

  group('A1 unified fallback classification', () {
    for (final timeoutFirst in [true, false]) {
      test(
        'footnote timeout/parse cross-over: timeoutFirst=$timeoutFirst',
        () async {
          final api = _ScriptApi(
            (_, call) =>
                (call == 1) == timeoutFirst ? _timeout() : 'invalid JSON',
          );
          final owner = EpubChapterTranslator(apiClient: api);
          final result = await owner.translateFootnoteBatchForTest(
            dio: Dio(),
            config: config,
            references: [
              FootnoteBlockReference(
                chapterIndex: 0,
                chapter: _chapter,
                block: plain,
              ),
            ],
          );
          expect(result['f0:A'], plain.sourceHtml);
          expect(owner.getDegradedBlockIdsForTest(), isNotEmpty);
        },
      );
    }
    test('slot parse failure then per-slot timeout preserves source', () async {
      final api = _ScriptApi(
        (_, call) => call == 1 ? 'invalid JSON' : _timeout(),
      );
      final owner = EpubChapterTranslator(apiClient: api);
      expect(
        await owner.translateBlockBatchForTest(
          dio: Dio(),
          config: config,
          blocks: [protected],
        ),
        [protected.sourceHtml],
      );
      expect(owner.getDegradedBlockIdsForTest(), isNotEmpty);
    });
    for (final error in [
      const TranslationCancelledException(),
      _http(401),
      _http(403),
      _http(404),
    ]) {
      test(
        'slot fallback propagates ${error.runtimeType} ${error is DioException ? error.response?.statusCode : "cancel"}',
        () async {
          final api = _ScriptApi(
            (_, call) => call == 1 ? 'invalid JSON' : error,
          );
          await expectLater(
            EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
              dio: Dio(),
              config: config,
              blocks: [protected],
            ),
            throwsA(
              error is TranslationCancelledException
                  ? isA<TranslationCancelledException>()
                  : isA<StateError>(),
            ),
          );
        },
      );
    }
  });

  group('A2 oversized singleton degrades with report tracking', () {
    for (final slot in [false, true]) {
      for (final footnote in [false, true]) {
        test('HTTP 413 slot=$slot footnote=$footnote', () async {
          final block = slot ? protected : plain;
          final api = _ScriptApi((_, _) => _http(413));
          final owner = EpubChapterTranslator(apiClient: api);
          if (footnote) {
            final result = await owner.translateFootnoteBatchForTest(
              dio: Dio(),
              config: config,
              references: [
                FootnoteBlockReference(
                  chapterIndex: 0,
                  chapter: _chapter,
                  block: block,
                ),
              ],
            );
            expect(result['f0:${block.id}'], block.sourceHtml);
          } else {
            expect(
              await owner.translateBlockBatchForTest(
                dio: Dio(),
                config: config,
                blocks: [block],
              ),
              [block.sourceHtml],
            );
          }
          expect(owner.getDegradedBlockIdsForTest(), hasLength(1));
          expect(api.requests.length, lessThanOrEqualTo(2));
        });
      }
    }
  });

  group('A3 validated sub-results are persisted before later cancellation', () {
    test(
      'valid ordinary item persists before failed item single fallback',
      () async {
        final persisted = <String, String>{};
        final api = _ScriptApi((_, call) {
          if (call == 1) {
            return {
              'blocks': [
                {'id': 'A', 'html': '<p>你好</p>'},
                {'id': 'B', 'html': '<p></p>'},
              ],
            };
          }
          expect(persisted, {'A': '<p>你好</p>'});
          return const TranslationCancelledException();
        });
        await expectLater(
          EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
            dio: Dio(),
            config: config,
            blocks: [plain, _block('B', '<p>World</p>')],
            onValidated: (id, html) async {
              persisted[id] = html;
            },
          ),
          throwsA(isA<TranslationCancelledException>()),
        );
      },
    );
    test('left slot split persists before right split cancellation', () async {
      final persisted = <String, String>{};
      final api = _ScriptApi((data, call) {
        if (call == 1) return {'blocks': []};
        if (call == 2) {
          final payload =
              jsonDecode((data['messages'] as List).last['content'] as String)
                  as Map;
          return {
            'blocks': [
              for (final block in payload['blocks'] as List)
                {
                  'id': block['id'],
                  'slots': [
                    for (final slot in block['slots'] as List)
                      {'id': slot['id'], 'text': '你好'},
                  ],
                },
            ],
          };
        }
        expect(persisted.keys, ['B']);
        return const TranslationCancelledException();
      });
      await expectLater(
        EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
          dio: Dio(),
          config: config,
          blocks: [
            protected,
            protected.copyWith(id: 'C'),
          ],
          onValidated: (id, html) async {
            persisted[id] = html;
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(persisted['B'], contains('你好'));
    });
    for (final footnote in [false, true]) {
      test('mixed HTML/slot batch footnote=$footnote', () async {
        final persisted = <String, String>{};
        final id = footnote ? 'f0:A' : 'A';
        final api = _ScriptApi((_, call) {
          if (call == 1) {
            return {
              'blocks': [
                {'id': id, 'html': '<p>你好</p>'},
              ],
            };
          }
          expect(persisted[id], '<p>你好</p>');
          return const TranslationCancelledException();
        });
        final owner = EpubChapterTranslator(apiClient: api);
        Future<void> persist(String id, String html) async {
          persisted[id] = html;
        }

        await expectLater(
          footnote
              ? owner.translateFootnoteBatchForTest(
                  dio: Dio(),
                  config: config,
                  references: [
                    for (final b in [plain, protected])
                      FootnoteBlockReference(
                        chapterIndex: 0,
                        chapter: _chapter,
                        block: b,
                      ),
                  ],
                  onValidated: persist,
                )
              : owner.translateBlockBatchForTest(
                  dio: Dio(),
                  config: config,
                  blocks: [plain, protected],
                  onValidated: persist,
                ),
          throwsA(isA<TranslationCancelledException>()),
        );
        expect(persisted, {id: '<p>你好</p>'});
      });
    }
  });

  group('A4 empty translated body cannot overwrite a nonempty source', () {
    test(
      'protected markers cannot disguise an empty translated body',
      () async {
        final api = _ScriptApi((data, call) {
          if (call == 1) {
            final payload =
                jsonDecode((data['messages'] as List).last['content'] as String)
                    as Map;
            return {
              'blocks': [
                for (final block in payload['blocks'] as List)
                  {
                    'id': block['id'],
                    'slots': [
                      for (final slot in block['slots'] as List)
                        {'id': slot['id'], 'text': ' '},
                    ],
                  },
              ],
            };
          }
          return ' ';
        });
        final persisted = <String>[];
        final owner = EpubChapterTranslator(apiClient: api);
        expect(
          await owner.translateBlockBatchForTest(
            dio: Dio(),
            config: config,
            blocks: [protected],
            onValidated: (id, html) async {
              persisted.add(html);
            },
          ),
          [protected.sourceHtml],
        );
        expect(owner.getDegradedBlockIdsForTest(), hasLength(1));
        expect(persisted, isEmpty);
      },
    );
    for (final html in ['<p></p>', '<p> </p>', '<p>&nbsp;</p>']) {
      test(html, () async {
        final api = _ScriptApi(
          (_, call) => call == 1
              ? {
                  'blocks': [
                    {'id': 'A', 'html': html},
                  ],
                }
              : html,
        );
        final owner = EpubChapterTranslator(apiClient: api);
        expect(
          await owner.translateBlockBatchForTest(
            dio: Dio(),
            config: config,
            blocks: [plain],
          ),
          [plain.sourceHtml],
        );
        expect(owner.getDegradedBlockIdsForTest(), hasLength(1));
      });
    }
  });

  group(
    'A5 ordinary response IDs must be unique and exactly cover request',
    () {
      for (final ids in [
        ['A', 'A'],
        ['A', 'unknown'],
      ]) {
        test('$ids is rejected before any item is accepted', () async {
          final api = _ScriptApi(
            (_, call) => call == 1
                ? {
                    'blocks': [
                      for (final id in ids) {'id': id, 'html': '<p>冲突结果</p>'},
                    ],
                  }
                : '<p>正确译文</p>',
          );
          expect(
            await EpubChapterTranslator(
              apiClient: api,
            ).translateBlockBatchForTest(
              dio: Dio(),
              config: config,
              blocks: [plain, _block('B', '<p>World</p>')],
            ),
            ['<p>正确译文</p>', '<p>正确译文</p>'],
          );
          expect(api.requests, hasLength(3));
        });
      }
    },
  );

  test(
    'A6 single fallback strips complete HTML fence before restoration',
    () async {
      final api = _ScriptApi(
        (_, call) => call == 1 ? 'invalid JSON' : '```html\n<p>你好</p>\n```',
      );
      expect(
        await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
          dio: Dio(),
          config: config,
          blocks: [plain],
        ),
        ['<p>你好</p>'],
      );
    },
  );
  for (final wrapper in [
    '```html\n<p>你好</p>',
    'Translation: <p>你好</p>',
    'Here is the translated HTML: <p>你好</p>',
    '<div>Translation: <p>你好</p></div>',
    '<p>你好</p> Explanation of the translation.',
    '{"html":"你好"}',
  ]) {
    test('A6 rejects malformed or explanatory wrapper $wrapper', () async {
      final api = _ScriptApi((_, call) => call == 1 ? 'invalid JSON' : wrapper);
      expect(
        await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
          dio: Dio(),
          config: config,
          blocks: [plain],
        ),
        [plain.sourceHtml],
      );
    });
  }

  for (final attribute in [
    'id="target"',
    'name="target"',
    'epub:type="term"',
    'role="note"',
  ]) {
    test('A7 flattened smallcaps retains semantic attribute $attribute', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml:
            '<p><span class="smallcaps" $attribute>HELLO</span> world</p>',
        translatedHtml: '<p>Bonjour le monde</p>',
      );
      expect(result, contains(attribute));
      expect(result, contains('Bonjour le monde'));
      expect(result, isNot(contains('smallcaps')));
    });
  }

  for (final scalar in ['2024', '3.14', 'true', 'false', 'null']) {
    test('A9 valid source scalar $scalar survives per-slot fallback', () async {
      final block = _block('B', '<p>$scalar<a href="#n1">[1]</a></p>');
      final api = _ScriptApi((_, call) => call == 1 ? 'invalid JSON' : scalar);
      final owner = EpubChapterTranslator(apiClient: api);
      expect(
        await owner.translateBlockBatchForTest(
          dio: Dio(),
          config: config,
          blocks: [block],
        ),
        [block.sourceHtml],
      );
      expect(owner.getDegradedBlockIdsForTest(), isEmpty);
    });
  }
  test('A9 JSON container still rejected by per-slot fallback', () async {
    final api = _ScriptApi(
      (_, call) => call == 1 ? 'invalid JSON' : '{"text":"你好"}',
    );
    final owner = EpubChapterTranslator(apiClient: api);
    expect(
      await owner.translateBlockBatchForTest(
        dio: Dio(),
        config: config,
        blocks: [protected],
      ),
      [protected.sourceHtml],
    );
    expect(owner.getDegradedBlockIdsForTest(), hasLength(1));
  });

  for (final language in [
    'zh',
    'ZH-cn',
    'ja',
    'JA_JP',
    'ko-KR',
    '日本語',
    '한국어',
  ]) {
    test('A11/A12 mixed-case styles and language alias $language', () {
      final result = EpubChapterTranslator.prepareBlockHtmlForTargetForTest(
        sourceHtml:
            '<p><span class="DropCap">H</span><span class="SMALLCAPS">ELLO</span></p>',
        targetLanguage: language,
      );
      expect(result, '<p>HELLO</p>');
    });
  }
  test('A12 regional title script recognition', () {
    expect(
      EpubChapterTranslator.titleAlreadyInTargetLanguage('こんにちは', 'JA_jp'),
      isTrue,
    );
    expect(
      EpubChapterTranslator.titleAlreadyInTargetLanguage('한국어', 'ko-KR'),
      isTrue,
    );
    expect(
      EpubChapterTranslator.titleAlreadyInTargetLanguage('中文', 'zh-CN'),
      isFalse,
    );
  });
  for (final language in ['zh-TW', 'ja-JP', 'ko_KR']) {
    test(
      'A12/A13 CJK gloss prompt uses translated term(original) for $language',
      () async {
        final api = _ScriptApi(
          (_, _) => {
            'blocks': [
              {'id': 'A', 'html': '<p>你好</p>'},
            ],
          },
        );
        await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
          dio: Dio(),
          config: config.copyWith(targetLanguage: language),
          blocks: [plain],
        );
        final system =
            (api.requests.single['messages'] as List).first['content']
                as String;
        expect(system, contains('伐林开垦（assarting）'));
        expect(system, isNot(contains('assarting（伐林开垦）')));
        expect(system.contains('choose between 您'), language.startsWith('zh'));
      },
    );
  }
}
