import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends TranslationApiClient {
  _Api(this.reply);
  final FutureOr<Object> Function(Map<String, dynamic> data) reply;
  final requests = <Map<String, dynamic>>[];
  int active = 0;
  int peak = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    requests.add(data);
    active++;
    if (active > peak) peak = active;
    try {
      final result = await reply(data);
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
    } finally {
      active--;
    }
  }
}

String _user(Map<String, dynamic> data) =>
    (data['messages'] as List).last['content'] as String;
Map<String, dynamic> _payload(Map<String, dynamic> data) =>
    jsonDecode(_user(data)) as Map<String, dynamic>;

const _text =
    'The traveler crossed the wide river and returned to the village.';
ExtractedBlock _block(String id, {bool protected = false}) => ExtractedBlock(
  id: id,
  tagName: 'p',
  sourceText: '$_text${protected ? '[1] Then he rested.' : ''}',
  sourceHtml: protected
      ? '<p>$_text<a href="#note">[1]</a> Then he rested.</p>'
      : '<p>$_text</p>',
);
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
List<FootnoteBlockReference> _references(List<ExtractedBlock> blocks) => [
  for (final block in blocks)
    FootnoteBlockReference(chapterIndex: 0, chapter: _chapter, block: block),
];

Object _validBatch(Map<String, dynamic> data) => {
  'blocks': [
    for (final block in _payload(data)['blocks'] as List)
      if (block['slots'] != null)
        {
          'id': block['id'],
          'slots': [
            for (final slot in block['slots'] as List)
              {'id': slot['id'], 'text': '旅人渡过大河，回到村庄。'},
          ],
        }
      else
        {'id': block['id'], 'html': '<p>旅人渡过大河，回到村庄。</p>'},
  ],
};

DioException _http(int status) {
  final options = RequestOptions();
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: options, statusCode: status),
  );
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    targetLanguage: 'zh',
    maxRetries: 3,
    maxConcurrent: 2,
    residualQualityCheck: true,
  );

  for (final malformed in [false, true]) {
    test(
      'A1 footnote fallback is parallel and bounded: malformed=$malformed',
      () async {
        final paired = Completer<void>();
        int started = 0;
        final api = _Api((data) async {
          if ((_payload(data)['blocks'] as List).length > 1) {
            return malformed ? 'invalid JSON' : _http(413);
          }
          if (++started == 2) paired.complete();
          await paired.future;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return _validBatch(data);
        });
        final result = await EpubChapterTranslator(apiClient: api)
            .translateFootnoteBatchForTest(
              dio: Dio(),
              config: config,
              references: _references([
                for (int i = 0; i < 6; i++) _block('$i'),
              ]),
            )
            .timeout(const Duration(seconds: 3));
        expect(result, hasLength(6));
        expect(api.peak, 2);
        expect(started, 6);
      },
    );
  }

  for (final failure in ['validation', 'transport', 'parse']) {
    for (final concurrency in [1, 2]) {
      test(
        'A1 protected $failure children share budget $concurrency without deadlock',
        () async {
          final paired = Completer<void>();
          int children = 0;
          final api = _Api((data) async {
            final user = _user(data);
            if (user.startsWith('{')) {
              if (failure == 'parse') return 'invalid JSON';
              final count = (_payload(data)['blocks'] as List).length;
              if (count == 4) {
                return switch (failure) {
                  'transport' => _http(413),
                  'parse' => 'invalid JSON',
                  _ => {'blocks': []},
                };
              }
            }
            if (++children == 2) paired.complete();
            if (concurrency == 2) await paired.future;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return user.startsWith('{') ? _validBatch(data) : '旅人渡过大河，回到村庄。';
          });
          final result = await EpubChapterTranslator(apiClient: api)
              .translateBlockBatchForTest(
                dio: Dio(),
                config: config.copyWith(
                  maxConcurrent: concurrency,
                  maxRetries: 1,
                ),
                blocks: [
                  for (int i = 0; i < 4; i++) _block('$i', protected: true),
                ],
              )
              .timeout(const Duration(seconds: 3));
          expect(result, hasLength(4));
          expect(result.every((html) => html.contains('旅人')), isTrue);
          expect(api.peak, concurrency);
        },
      );
    }
  }

  for (final mode in ['html', 'footnote', 'slots']) {
    test(
      'A2 $mode quality failure keeps success and retries only failed item',
      () async {
        final persisted = <String>[];
        int calls = 0;
        final api = _Api((data) {
          calls++;
          if (calls == 1) {
            final blocks = _payload(data)['blocks'] as List;
            return {
              'blocks': [
                for (int i = 0; i < blocks.length; i++)
                  if (mode == 'slots')
                    {
                      'id': blocks[i]['id'],
                      'slots': [
                        for (final slot in blocks[i]['slots'] as List)
                          {
                            'id': slot['id'],
                            'text': i == 1 ? slot['text'] : '旅人渡过大河，回到村庄。',
                          },
                      ],
                    }
                  else
                    {
                      'id': blocks[i]['id'],
                      'html': i == 1
                          ? blocks[i]['html']
                          : '<p>旅人渡过大河，回到村庄。</p>',
                    },
              ],
            };
          }
          expect(persisted, [mode == 'footnote' ? 'f0:good' : 'good']);
          if (mode == 'html') {
            expect(_user(data), _block('bad').sourceHtml);
            return '<p>旅人渡过大河，回到村庄。</p>';
          }
          expect(
            (_payload(data)['blocks'] as List).single['id'],
            mode == 'footnote' ? 'f0:bad' : 'bad',
          );
          return _validBatch(data);
        });
        final owner = EpubChapterTranslator(apiClient: api);
        final blocks = [
          _block('good', protected: mode == 'slots'),
          _block('bad', protected: mode == 'slots'),
        ];
        if (mode == 'footnote') {
          final result = await owner.translateFootnoteBatchForTest(
            dio: Dio(),
            config: config,
            references: _references(blocks),
            onValidated: (id, _) async => persisted.add(id),
          );
          expect(result.values.every((html) => html.contains('旅人')), isTrue);
        } else {
          final result = await owner.translateBlockBatchForTest(
            dio: Dio(),
            config: config,
            blocks: blocks,
            onValidated: (id, _) async => persisted.add(id),
          );
          expect(result.every((html) => html.contains('旅人')), isTrue);
        }
        expect(calls, 2);
        expect(persisted, [
          mode == 'footnote' ? 'f0:good' : 'good',
          mode == 'footnote' ? 'f0:bad' : 'bad',
        ]);
        expect(owner.getDegradedBlockIdsForTest(), isEmpty);
      },
    );
  }

  for (final status in [500, 429, 0]) {
    test(
      'A3 exhausted slot transport $status does not retry the outer round',
      () async {
        final slotCalls = <String, int>{};
        final error = status == 0
            ? DioException(
                requestOptions: RequestOptions(),
                type: DioExceptionType.receiveTimeout,
              )
            : _http(status);
        final api = _Api((data) {
          final user = _user(data);
          if (user.startsWith('{')) return 'invalid JSON';
          slotCalls.update(user, (n) => n + 1, ifAbsent: () => 1);
          return user == _text ? '旅人渡过大河，回到村庄。' : error;
        });
        final owner = EpubChapterTranslator(apiClient: api);
        final future = owner.translateBlockBatchForTest(
          dio: Dio(),
          config: config.copyWith(maxConcurrent: 1),
          blocks: [_block('a', protected: true)],
        );
        if (status == 0) {
          expect(await future, [_block('a', protected: true).sourceHtml]);
          expect(owner.getDegradedBlockIdsForTest(), hasLength(1));
        } else {
          await expectLater(future, throwsA(isA<DioException>()));
        }
        expect(slotCalls[_text], 1);
        // Slot-level retries follow the individual-slot policy, not the
        // batch-level shouldRetryBatchError: a timeout is retried once at
        // slot level (per maxAttemptsForError) even though a batch timeout
        // would take the shrink fallback instead of a batch retry.
        // v1.6.26 made this deliberate; A-P2-4 pins {'Second': 2}.
        expect(
          slotCalls['Then he rested.'],
          TranslationApiClient.maxAttemptsForError(config, error),
        );
        expect(slotCalls.keys.any((text) => text.contains('[RETRY]')), isFalse);
      },
    );
  }

  test(
    'A3 rebuilt-block quality failure retries with reason and can recover',
    () async {
      final users = <String>[];
      final api = _Api((data) {
        final user = _user(data);
        if (user.startsWith('{')) return 'invalid JSON';
        users.add(user);
        return user.contains('[RETRY]') ? '旅人渡过大河，回到村庄。' : user;
      });
      final owner = EpubChapterTranslator(apiClient: api);
      final result = await owner.translateBlockBatchForTest(
        dio: Dio(),
        config: config,
        blocks: [_block('a', protected: true)],
      );
      expect(users, hasLength(4));
      expect(users.take(2).every((user) => !user.contains('[RETRY]')), isTrue);
      expect(
        users
            .skip(2)
            .every(
              (user) =>
                  user.contains('[RETRY]') &&
                  user.contains('Possible untranslated source-language'),
            ),
        isTrue,
      );
      expect(result.single, contains('旅人'));
      expect(owner.getDegradedBlockIdsForTest(), isEmpty);
    },
  );

  test(
    'A4 individual slots have bounded block summary and neighbors, unchanged user text',
    () async {
      final block = _block('a', protected: true);
      final contexts = <Map<String, dynamic>>[];
      final users = <String>[];
      final api = _Api((data) {
        if (_user(data).startsWith('{')) return 'invalid JSON';
        users.add(_user(data));
        final message = (data['messages'] as List).firstWhere(
          (message) => (message['content'] as String).startsWith(
            'Read-only plain-text summary of the source block.',
          ),
        );
        expect(message['role'], 'system');
        expect(message['content'], contains('never this context'));
        // The full source HTML must not be re-sent once per slot (#19).
        expect(message['content'], isNot(contains(block.sourceHtml)));
        contexts.add(
          jsonDecode((message['content'] as String).split('\n').last)
              as Map<String, dynamic>,
        );
        return '旅人渡过大河，回到村庄。';
      });
      final result = await EpubChapterTranslator(
        apiClient: api,
      ).translateBlockBatchForTest(dio: Dio(), config: config, blocks: [block]);
      expect(users, [_text, 'Then he rested.']);
      expect(contexts.map((c) => c['blockSummary']), [
        block.sourceText,
        block.sourceText,
      ]);
      expect(contexts.map((c) => c['currentSlotId']).toSet(), hasLength(2));
      expect(contexts[0]['previousText'], isNull);
      expect((contexts[0]['nextText'] as String).trim(), users[1]);
      expect((contexts[1]['previousText'] as String).trim(), users[0]);
      expect(contexts[1]['nextText'], isNull);
      expect(result.single, contains('<a href="#note">[1]</a>'));
    },
  );
}
