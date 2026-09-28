import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the cross-file footnote translation path:
/// - deterministic HTTP errors (401/403/404) fail fast with the localized
///   diagnostic instead of burning per-reference fallback requests;
/// - a send timeout degrades like a receive timeout instead of aborting
///   the whole run.
void main() {
  InspectedChapter chapter() => const InspectedChapter(
    path: 'OEBPS/notes.xhtml',
    title: 'Notes',
    body: '',
    originalHtml: '<html><body></body></html>',
    blocks: <ExtractedBlock>[],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );

  const ExtractedBlock block = ExtractedBlock(
    id: 'p-1',
    tagName: 'p',
    sourceHtml: '<p>Footnote text one.</p>',
    sourceText: 'Footnote text one.',
  );

  TranslationConfig config() => TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://api.example.test',
    maxRetries: 3,
  );

  group('footnote error handling', () {
    test('a 401 fails fast with the localized diagnostic', () async {
      final _StatusCodeAdapter adapter = _StatusCodeAdapter(401);
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      await expectLater(
        EpubChapterTranslator().translateFootnoteBatchForTest(
          dio: dio,
          config: config(),
          references: <FootnoteBlockReference>[
            FootnoteBlockReference(
              chapterIndex: 0,
              chapter: chapter(),
              block: block,
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('HTTP 401'),
          ),
        ),
      );
      // Fail fast: no per-reference fallback requests are billed after a
      // deterministic 401.
      expect(adapter.fetchCount, 1);
    });

    test(
      'a send timeout degrades the reference like a receive timeout',
      () async {
        final _ThrowingAdapter adapter = _ThrowingAdapter(
          DioExceptionType.sendTimeout,
        );
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        // Used to rethrow and abort the whole run; now the reference is
        // retried on its own and degrades to its source HTML, matching the
        // main block path.
        final Map<String, String> translated = await EpubChapterTranslator()
            .translateFootnoteBatchForTest(
              dio: dio,
              config: config(),
              references: <FootnoteBlockReference>[
                FootnoteBlockReference(
                  chapterIndex: 0,
                  chapter: chapter(),
                  block: block,
                ),
              ],
            );

        expect(translated, <String, String>{
          'f0:p-1': '<p>Footnote text one.</p>',
        });
        expect(adapter.fetchCount, 2);
      },
    );
  });
}

/// Always answers with the same HTTP status code.
class _StatusCodeAdapter implements HttpClientAdapter {
  _StatusCodeAdapter(this.statusCode);

  final int statusCode;
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
      jsonEncode(<String, Object?>{'error': 'status $statusCode'}),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

/// Always throws the same transport-level DioException.
class _ThrowingAdapter implements HttpClientAdapter {
  _ThrowingAdapter(this.type);

  final DioExceptionType type;
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
    throw DioException(requestOptions: options, type: type);
  }
}
