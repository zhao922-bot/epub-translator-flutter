import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _chapter = InspectedChapter(
  path: 'chapter.xhtml',
  title: 'Chapter',
  body: 'A chapter.',
  originalHtml: '<html><body><p>A chapter.</p></body></html>',
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: true,
  blocks: [
    ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml: '<p>A chapter.</p>',
      sourceText: 'A chapter.',
    ),
  ],
);

class _ReplyAdapter implements HttpClientAdapter {
  _ReplyAdapter(this.content);

  final String content;
  final List<Map<String, dynamic>> payloads = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    final data = options.data as Map<String, dynamic>;
    final messages = data['messages'] as List;
    payloads.add(
      jsonDecode((messages.last as Map)['content'] as String)
          as Map<String, dynamic>,
    );
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
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

/// Represents a long chapter whose tail must never be accessed or parsed.
class _GuardedBlocks extends ListBase<ExtractedBlock> {
  _GuardedBlocks(this.prefix);

  final List<ExtractedBlock> prefix;
  int reads = 0;

  @override
  int get length => 100000;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  ExtractedBlock operator [](int index) {
    reads += 1;
    if (index >= prefix.length) {
      throw StateError(
        'Chapter tail accessed after excerpt budget was reached',
      );
    }
    return prefix[index];
  }

  @override
  void operator []=(int index, ExtractedBlock value) =>
      throw UnsupportedError('read only');
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    maxRetries: 4,
    retryDelaySeconds: 0,
    styleProfileEnabled: true,
  );

  test(
    'style regeneration restores released originals, not translations',
    () async {
      final original = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'chapter.xhtml',
        bytes: utf8.encode(
          '<body><p>Original prose for style analysis.</p></body>',
        ),
      );
      final released = original.copyWith(
        translatedBody: '已完成的译文',
        blocks: [
          for (final block in original.blocks)
            block.copyWith(
              sourceHtml: '',
              sourceText: '',
              translatedHtml: '<p>译文</p>',
            ),
        ],
      );
      final adapter = _ReplyAdapter('{"primaryGenre":"Literary fiction"}');
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final profile = await EpubChapterTranslator().generateStyleProfileForTest(
        dio: dio,
        config: config,
        chapters: [released],
      );
      expect(profile.primaryGenre, 'Literary fiction');
      final sample =
          (adapter.payloads.single['chapters'] as List).single as Map;
      expect(sample['text'], contains('Original prose for style analysis.'));
      expect(sample['text'], isNot(contains('译文')));
      expect(released.blocks.single.sourceText, isEmpty);
    },
  );

  test('empty style samples fail explicitly without a paid request', () async {
    final adapter = _ReplyAdapter('{}');
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    await expectLater(
      EpubChapterTranslator().generateStyleProfileForTest(
        dio: dio,
        config: config,
        chapters: [_chapter.copyWith(includeInTranslation: false)],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'hint',
          contains('No source samples'),
        ),
      ),
    );
    expect(adapter.payloads, isEmpty);
  });

  for (final kind in ['styleProfile', 'initialBookMemory', 'chapterMemory']) {
    for (final content in ['not JSON', '{"summary":', '[]', '']) {
      test('$kind rejects "$content" after exactly one paid request', () async {
        final adapter = _ReplyAdapter(content);
        final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
          ..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        final translator = EpubChapterTranslator();
        final Future<Object?> result = switch (kind) {
          'styleProfile' => translator.generateStyleProfileForTest(
            dio: dio,
            config: config,
            chapters: [_chapter],
          ),
          'initialBookMemory' => translator.generateInitialBookMemoryForTest(
            dio: dio,
            config: config,
            chapters: [_chapter],
          ),
          _ => translator.updateBookMemoryAfterChapterForTest(
            dio: dio,
            config: config,
            currentMemory: const {},
            chapter: _chapter,
          ),
        };
        await expectLater(result, throwsA(isA<TranslationParseException>()));
        expect(adapter.payloads, hasLength(1));
        expect(adapter.payloads.single['kind'], kind);
      });
    }
  }

  for (final translated in [false, true]) {
    test('2400-character budget stops before the long chapter tail '
        '(translated=$translated)', () async {
      final adapter = _ReplyAdapter('{}');
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final blocks = _GuardedBlocks([
        for (int i = 0; i < 2; i++)
          ExtractedBlock(
            id: 'p-$i',
            tagName: 'p',
            sourceHtml: '<p>source</p>',
            sourceText: translated ? 'source' : '字' * 1200,
            translatedHtml: translated ? '<p><b>${'字' * 1200}</b></p>' : null,
          ),
      ]);
      final chapter = _chapter.copyWith(blocks: blocks);
      final translator = EpubChapterTranslator();
      if (translated) {
        await translator.updateBookMemoryAfterChapterForTest(
          dio: dio,
          config: config,
          currentMemory: const {},
          chapter: chapter,
        );
      } else {
        await translator.generateInitialBookMemoryForTest(
          dio: dio,
          config: config,
          chapters: [chapter],
        );
      }
      final payload = adapter.payloads.single;
      final sample = translated
          ? payload['chapter'] as Map
          : (payload['chapters'] as List).single as Map;
      final text = sample['text'] as String;
      expect(text, '${'字' * 1200} ${'字' * 1196}...');
      expect(text.length, 2400);
      expect(blocks.reads, 2);
    });
  }

  test(
    'chapter excerpt preserves entities, whitespace and source fallback',
    () async {
      final adapter = _ReplyAdapter('{}');
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/v1'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final chapter = _chapter.copyWith(
        blocks: [
          _chapter.blocks.single.copyWith(
            translatedHtml: '<p> \n译文 <em>&amp; 内容</em>\t </p>',
          ),
          _chapter.blocks.single.copyWith(
            sourceText: '\n\t ',
            translatedHtml: ' ',
          ),
          _chapter.blocks.single.copyWith(
            sourceText: '  fallback\t text  ',
            translatedHtml: '',
          ),
        ],
      );
      await EpubChapterTranslator().updateBookMemoryAfterChapterForTest(
        dio: dio,
        config: config,
        currentMemory: const {},
        chapter: chapter,
      );
      expect(
        (adapter.payloads.single['chapter'] as Map)['text'],
        '译文 & 内容 fallback text',
      );
    },
  );
}
