import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

InspectedChapter _source(int index) => const EpubHtmlExtractor()
    .inspectChapterBytes(
      chapterPath: 'chapter-$index.xhtml',
      bytes: utf8.encode(
        '<body><p>Original $index ${'source prose ' * 30}</p></body>',
      ),
    )
    .copyWith(category: ChapterCategory.content, includeInTranslation: true);

InspectedChapter _released(InspectedChapter chapter) => chapter.copyWith(
  translatedBody: '译文',
  blocks: [
    for (final block in chapter.blocks)
      block.copyWith(
        sourceHtml: '',
        sourceText: '',
        translatedHtml: '<p>译文</p>',
      ),
  ],
);

class _StyleApi extends TranslationApiClient {
  _StyleApi(this.adapter);
  final _StyleAdapter adapter;

  @override
  Dio buildDio(TranslationConfig config) =>
      Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'))
        ..httpClientAdapter = adapter;
}

class _StyleAdapter implements HttpClientAdapter {
  Map<String, dynamic>? payload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    final data = options.data as Map<String, dynamic>;
    payload =
        jsonDecode((data['messages'] as List).last['content'] as String)
            as Map<String, dynamic>;
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'primaryGenre': 'literary fiction',
                'confidence': 'high',
              }),
            },
          },
        ],
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'regenerating a completed 1000-chapter book parses only sample candidates',
    () async {
      final originals = [for (int i = 0; i < 1000; i++) _source(i)];
      final chapters = [
        for (int i = 0; i < originals.length; i++)
          _released(originals[i]).copyWith(
            // Any accidental full-book restoration fails block-order validation.
            originalHtml: [0, 500, 999].contains(i)
                ? originals[i].originalHtml
                : '<body></body>',
          ),
      ];
      final adapter = _StyleAdapter();
      final profile = await EpubChapterTranslator(apiClient: _StyleApi(adapter))
          .generateStyleProfile(
            config: TranslationConfig.defaults().copyWith(
              styleProfileEnabled: true,
            ),
            chapters: chapters,
          );
      expect(profile.primaryGenre, 'literary fiction');
      final samples = adapter.payload!['chapters'] as List;
      expect(samples.map((sample) => sample['path']), [
        'chapter-0.xhtml',
        'chapter-500.xhtml',
        'chapter-999.xhtml',
      ]);
      expect(samples.map((sample) => sample['role']), [
        'earlyContent',
        'middleContent',
        'lateContent',
      ]);
      expect(
        samples,
        EpubChapterTranslator.styleProfileSourceChaptersForTest(originals),
      );
      expect(
        chapters.every((chapter) => chapter.blocks.single.sourceText.isEmpty),
        isTrue,
      );
    },
  );

  test(
    'mixed retained/released sources restore one chapter at a time and skip structural matter',
    () async {
      final first = _source(0);
      final chapters = [
        _released(
          _source(10),
        ).copyWith(title: 'Index', originalHtml: '<body></body>'),
        _released(
          _source(11),
        ).copyWith(includeInTranslation: false, originalHtml: '<body></body>'),
        first,
        for (int i = 1; i < 5; i++)
          _released(_source(i)).copyWith(
            originalHtml: [2, 4].contains(i)
                ? _source(i).originalHtml
                : '<body></body>',
          ),
      ];
      final progress = <(int, int)>[];
      final samples =
          await EpubChapterTranslator.restoredStyleProfileSourceChaptersForTest(
            chapters,
            isCancelled: () => false,
            onProgress: (done, total) => progress.add((done, total)),
          );
      expect(samples.map((sample) => sample['path']), [
        'chapter-0.xhtml',
        'chapter-2.xhtml',
        'chapter-4.xhtml',
      ]);
      expect(progress, [(0, 1), (1, 1), (0, 1), (1, 1)]);
      expect(
        samples.every((sample) => sample['text']!.contains('Original')),
        isTrue,
      );
      expect(
        samples.every((sample) => !sample['text']!.contains('译文')),
        isTrue,
      );
    },
  );

  test(
    'cancellation after the first sample prevents further source restoration',
    () async {
      bool cancelled = false;
      int restored = 0;
      await expectLater(
        EpubChapterTranslator.restoredStyleProfileSourceChaptersForTest(
          [for (int i = 0; i < 5; i++) _released(_source(i))],
          isCancelled: () => cancelled,
          onProgress: (done, _) {
            if (done == 1) {
              restored++;
              cancelled = true;
            }
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(restored, 1);
    },
  );
}
