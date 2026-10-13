import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

const _history = <Map<String, Object?>>[
  {'title': 'First', 'summary': 'First summary', 'path': 'first.xhtml'},
  {'title': 'Second', 'summary': 'Second summary', 'path': 'second.xhtml'},
];
const _block = ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml: '<p>The concept of entitlement changes.</p>',
  sourceText: 'The concept of entitlement changes.',
);
const _chapter = InspectedChapter(
  path: 'chapter.xhtml',
  title: 'Chapter',
  body: 'Source',
  originalHtml: '<body><p>Source</p></body>',
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: true,
  blocks: [_block],
);

class _ReplyAdapter implements HttpClientAdapter {
  final payloads = <Map<String, dynamic>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    final messages = (options.data as Map)['messages'] as List;
    final payload =
        jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
    payloads.add(payload);
    final reply = payload['kind'] == 'chapterMemory'
        ? <String, Object?>{'summary': 'Updated summary'}
        : <String, Object?>{
            'blocks': [
              for (final block in payload['blocks'] as List)
                {'id': block['id'], 'html': '<p>entitlement概念改变。</p>'},
            ],
          };
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': jsonEncode(reply)},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  group('A-P2-13 trusted confirmation serialization', () {
    for (final confidence in ['low', null]) {
      test(
        'preserves confirmation with ${confidence ?? 'missing'} confidence',
        () {
          final merged = EpubChapterTranslator.mergeBookMemoryForTest(
            {
              'styleProfile': {
                'tone': 'formal',
                'confidence': ?confidence,
              },
              'styleProfileConfirmed': true,
            },
            {'summary': 'New summary'},
          );
          expect(merged['styleProfileConfirmed'], isTrue);
          expect((merged['styleProfile'] as Map)['tone'], 'formal');
        },
      );
    }
  });

  group('A-P2-14 confirmation requires trusted input', () {
    const memory = <String, Object?>{
      'styleProfile': {'tone': 'formal', 'confidence': 'high'},
      'styleProfileConfirmed': true,
    };
    test('untrusted high-confidence input cannot claim confirmation', () {
      final result = EpubChapterTranslator.mergeBookMemoryForTest(
        memory,
        {},
        trustedMemoryLocks: false,
      );
      expect(result.containsKey('styleProfileConfirmed'), isFalse);
    });
    test('trusted high-confidence input preserves confirmation', () {
      final result = EpubChapterTranslator.mergeBookMemoryForTest(
        memory,
        {},
        trustedMemoryLocks: true,
      );
      expect(result['styleProfileConfirmed'], isTrue);
    });
    test('untrusted merge round-trip drops a previously trusted flag', () {
      final trusted = EpubChapterTranslator.mergeBookMemoryForTest(memory, {});
      expect(trusted['styleProfileConfirmed'], isTrue);
      final result = EpubChapterTranslator.mergeBookMemoryForTest(trusted, {
        'summary': 'Next',
      }, trustedMemoryLocks: false);
      expect(result.containsKey('styleProfileConfirmed'), isFalse);
    });
  });

  group('A-P2-15 empty chapters preserve rolling history', () {
    final emptyChapters = <String, Map<String, Object?>>{
      'empty': {},
      'whitespace': {
        'title': '  ',
        'summary': '\n',
        'continuityNotes': ['\t'],
      },
      'invalid fields': {
        'title': 42,
        'summary': [],
        'continuityNotes': [false],
        'glossary': [
          {'source': 'term', 'target': 42},
        ],
      },
      'stamped path only': {'path': 'new.xhtml'},
    };
    for (final entry in emptyChapters.entries) {
      test('${entry.key} does not evict recent chapters', () {
        final merged = EpubChapterTranslator.mergeBookMemoryForTest({
          'recentChapters': _history,
        }, entry.value);
        final baseline = EpubChapterTranslator.mergeBookMemoryForTest({
          'recentChapters': _history,
        }, {});
        expect(merged['recentChapters'], baseline['recentChapters']);
        expect((merged['recentChapters'] as List).length, 2);
        expect(
          (merged['recentChapters'] as List).first,
          containsPair('path', 'first.xhtml'),
        );
      });
    }
    test('valid glossary alone still merges and advances history', () {
      const glossary = [
        {'source': 'Alice', 'target': '艾丽丝'},
      ];
      final merged = EpubChapterTranslator.mergeBookMemoryForTest(
        {'recentChapters': _history},
        {'glossary': glossary},
      );
      expect(merged['glossary'], hasLength(1));
      expect((merged['glossary'] as List).single, containsPair('source', 'Alice'));
      expect((merged['glossary'] as List).single, containsPair('target', '艾丽丝'));
      final recent = merged['recentChapters'] as List;
      expect(recent, hasLength(2));
      expect(recent.first, containsPair('path', 'second.xhtml'));
      expect(recent.last, containsPair('glossary', glossary));
    });
  });

  group('A-P2-16 degraded blocks stay out of rolling memory', () {
    for (final translatedHtml in ['', '   ']) {
      test(
        'excludes degraded source with translatedHtml "$translatedHtml"',
        () async {
          final adapter = _ReplyAdapter();
          final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
            ..httpClientAdapter = adapter;
          addTearDown(() => dio.close(force: true));
          final chapter = _chapter.copyWith(
            blocks: [
              _block.copyWith(translatedHtml: translatedHtml),
              const ExtractedBlock(
                id: 'p-2',
                tagName: 'p',
                sourceHtml: '<p>Translated source</p>',
                sourceText: 'Translated source',
                translatedHtml: '<p>正常译文</p>',
              ),
              const ExtractedBlock(
                id: 'p-3',
                tagName: 'p',
                sourceHtml: '<p>Ordinary fallback</p>',
                sourceText: 'Ordinary fallback',
              ),
            ],
          );
          await EpubChapterTranslator().updateBookMemoryAfterChapterForTest(
            dio: dio,
            config: TranslationConfig.defaults(),
            currentMemory: {},
            chapter: chapter,
            degradedBlockIds: {
              EpubChapterTranslator.degradedKeyForTest(
                chapterPath: chapter.path,
                blockId: 'p-1',
              ),
              EpubChapterTranslator.degradedKeyForTest(
                chapterPath: 'other.xhtml',
                blockId: 'p-2',
              ),
            },
          );
          final text = (adapter.payloads.single['chapter'] as Map)['text'];
          expect(text, '正常译文 Ordinary fallback');
          expect(text, isNot(contains(_block.sourceText)));
        },
      );
    }
    test('all degraded skips request and preserves memory', () async {
      final adapter = _ReplyAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final result = await EpubChapterTranslator()
          .updateBookMemoryAfterChapterForTest(
            dio: dio,
            config: TranslationConfig.defaults(),
            currentMemory: {'recentChapters': _history},
            chapter: _chapter,
            degradedBlockIds: {
              EpubChapterTranslator.degradedKeyForTest(
                chapterPath: _chapter.path,
                blockId: _block.id,
              ),
            },
          );
      expect(adapter.payloads, isEmpty);
      expect(
        result,
        EpubChapterTranslator.mergeBookMemoryForTest({
          'recentChapters': _history,
        }, {}),
      );
    });
  });

  test(
    'A-P2-22 batch production quality check honors locked source terms',
    () async {
      final adapter = _ReplyAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final translator = EpubChapterTranslator();
      final validated = <String>[];
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: TranslationConfig.defaults().copyWith(
          targetLanguage: 'Chinese',
          residualQualityCheck: true,
          lockedGlossary: 'entitlement => 权利',
          maxRetries: 0,
        ),
        blocks: [_block],
        chapterPath: _chapter.path,
        onValidated: (id, html) async => validated.add(html),
      );
      expect(result.single, contains('entitlement概念改变。'));
      expect(validated, result);
      expect(adapter.payloads, hasLength(1));
      expect(translator.getDegradedBlockIdsForTest(), isEmpty);
    },
  );
}
