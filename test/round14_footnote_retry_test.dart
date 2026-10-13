import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for A-1: a single footnote reference whose model reply
/// fails validation must not be re-billed. Before the fix, the outer
/// `on FormatException` single-reference branch re-invoked
/// `_translateFootnoteHtmlBatch` with the identical payload, burning a
/// second full request cycle.
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

  test(
    'single footnote validation failure degrades after one retry cycle, not two',
    () async {
      final _WrongIdAdapter adapter = _WrongIdAdapter();
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      final Map<String, String> result = await EpubChapterTranslator()
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

      // Degraded to source HTML.
      expect(result.values.single, block.sourceHtml);
      // One request cycle only: the outer single-reference branch must not
      // re-invoke _translateFootnoteHtmlBatch with the identical payload
      // (was 2 before the fix: one per cycle).
      expect(adapter.fetchCount, 1);
    },
  );
}

/// Returns a well-formed reply with an unknown id, triggering a
/// retryable FormatException on every attempt.
class _WrongIdAdapter implements HttpClientAdapter {
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
    final String body = jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{
            'content': jsonEncode(<String, Object?>{
              'blocks': <Object?>[
                <String, Object?>{'id': 'wrong-id', 'html': '<p>译文</p>'},
              ],
            }),
          },
        },
      ],
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}
