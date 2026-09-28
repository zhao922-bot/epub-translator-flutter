import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the protected-anchor slot retry pipeline:
/// - a single stubborn slot must degrade instead of killing the whole book;
/// - a repeated identical render/quality failure must stop re-billing whole
///   rounds, and a retried round must carry the failure reason into the prompt.
void main() {
  group('protected slot retry fixes', () {
    test('an unparseable single-slot reply degrades the block instead of '
        'aborting the book', () async {
      const String sourceHtml =
          '<p>Before the marker'
          '<a id="footnote_ref_1" href="notes.xhtml#note-1">*</a>'
          ' after the marker.</p>';
      final _SlotScenarioAdapter adapter = _SlotScenarioAdapter(
        slotTextReply: (String content) =>
            content.contains('after the marker') ? '' : '标记前译文',
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      // The batch reply is not JSON at all, so the batch path throws
      // TranslationParseException and the single-request path takes over.
      // Every slot-text reply is empty, so each slot deterministically
      // throws TranslationParseException. The block must keep its source
      // HTML (and be reported degraded) instead of throwing.
      final List<String> translated = await EpubTranslationRepository()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiBaseUrl: 'https://api.example.test',
              maxRetries: 2,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: sourceHtml,
                sourceText: 'Before the marker* after the marker.',
              ),
            ],
          );

      expect(translated, <String>[sourceHtml]);
      // One batch attempt (not retryable: parse failure); the first slot
      // translates, the second comes back empty (deterministic parse
      // failure, not retryable either): no retry storm, no throw.
      expect(adapter.batchFetchCount, 1);
      expect(adapter.slotTextFetchCount, 2);
    });

    test('a repeated identical render failure stops re-billing whole rounds '
        'and the retry carries the failure reason', () async {
      const String sourceHtml =
          '<p>Once upon a time there was a long English sentence that '
          'should be translated carefully.'
          '<a id="footnote_ref_1" href="notes.xhtml#note-1">*</a>'
          ' After the marker text.</p>';
      const String stubbornEnglishReply =
          'Once upon a time there was a long English sentence that should '
          'be translated carefully.';
      final _SlotScenarioAdapter adapter = _SlotScenarioAdapter(
        transientSlotFailures: 2,
        slotTextReply: (_) => stubbornEnglishReply,
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = adapter;

      // Every slot-text request first fails twice with a transient 500,
      // then "succeeds" by echoing English back. The echoed English trips
      // the residual-quality gate when the protected slots are rendered,
      // so every whole round fails with the identical quality rejection.
      // The second identical failure must stop the loop instead of burning
      // a third maxRetries-sized round, and the block degrades.
      final List<String> translated = await EpubTranslationRepository()
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiBaseUrl: 'https://api.example.test',
              maxRetries: 3,
            ),
            blocks: const <ExtractedBlock>[
              ExtractedBlock(
                id: 'p-1',
                tagName: 'p',
                sourceHtml: sourceHtml,
                sourceText:
                    'Once upon a time there was a long English '
                    'sentence that should be translated carefully.* After '
                    'the marker text.',
              ),
            ],
          );

      expect(translated, <String>[sourceHtml]);
      expect(adapter.batchFetchCount, 1);
      // Two rounds of (2 slots x 3 attempts). A third round would mean the
      // old maxRetries^2-style whole-round retry storm (18 requests).
      expect(adapter.slotTextFetchCount, 12);
      // The second round told the model why the first round was rejected.
      expect(adapter.sawRetryInstruction, isTrue);
    });
    test(
      'a send timeout on a single protected-slot request degrades instead of '
      'aborting the run',
      () async {
        const String sourceHtml =
            '<p>Before the marker'
            '<a id="footnote_ref_1" href="notes.xhtml#note-1">*</a>'
            ' after the marker.</p>';
        final _SendTimeoutAdapter adapter = _SendTimeoutAdapter();
        final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
          ..httpClientAdapter = adapter;

        // Used to rethrow and kill the whole book; now a send timeout on one
        // slot request degrades to the source text, matching the receive
        // timeout behavior and the main block path.
        final List<String> translated = await EpubTranslationRepository()
            .translateBlockBatchForTest(
              dio: dio,
              config: TranslationConfig.defaults().copyWith(
                apiBaseUrl: 'https://api.example.test',
                maxRetries: 2,
              ),
              blocks: const <ExtractedBlock>[
                ExtractedBlock(
                  id: 'p-1',
                  tagName: 'p',
                  sourceHtml: sourceHtml,
                  sourceText: 'Before the marker* after the marker.',
                ),
              ],
            );

        expect(translated, <String>[sourceHtml]);
        expect(adapter.fetchCount, 1);
      },
    );
  });
}

/// Always throws a send-timeout DioException.
class _SendTimeoutAdapter implements HttpClientAdapter {
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
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.sendTimeout,
    );
  }
}

/// Fake translation API that distinguishes the protected-slot batch payload
/// (JSON with "slots") from per-slot plain-text payloads.
class _SlotScenarioAdapter implements HttpClientAdapter {
  _SlotScenarioAdapter({
    this.transientSlotFailures = 0,
    required this.slotTextReply,
  });

  final int transientSlotFailures;
  final String Function(String userContent) slotTextReply;

  int batchFetchCount = 0;
  int slotTextFetchCount = 0;
  final Map<String, int> _slotTextAttemptsBySource = <String, int>{};
  bool sawRetryInstruction = false;

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

    final Object? decoded = _tryJsonDecode(userContent);
    if (decoded is Map<String, dynamic> && decoded['blocks'] is List) {
      // Batch payload (either the HTML batch or the slot batch): reply with
      // non-JSON content so the batch path throws TranslationParseException
      // and the single-request/individual path takes over.
      batchFetchCount += 1;
      return _textResponse('this is not json');
    }

    // Per-slot plain-text payload. Transient failures are counted per
    // distinct prompt (a retried round carries a [RETRY] suffix, so it gets
    // a fresh transient-failure budget), so every whole round sees the same
    // failure shape.
    slotTextFetchCount += 1;
    final int attempts = (_slotTextAttemptsBySource[userContent] ?? 0) + 1;
    _slotTextAttemptsBySource[userContent] = attempts;
    if (userContent.contains('[RETRY]')) {
      sawRetryInstruction = true;
    }
    if (attempts <= transientSlotFailures) {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{'error': 'temporary overload'}),
        500,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return _chatResponse(slotTextReply(userContent));
  }

  ResponseBody _chatResponse(String content) {
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': content},
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  ResponseBody _textResponse(String content) {
    return ResponseBody.fromString(
      content,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain'],
      },
    );
  }

  static Object? _tryJsonDecode(String value) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
}
