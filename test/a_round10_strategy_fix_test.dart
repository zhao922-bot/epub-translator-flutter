import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _config = TranslationConfig.defaults().copyWith(
  apiKey: 'test-key',
  targetLanguage: 'Chinese',
  residualQualityCheck: false,
  styleProfileEnabled: false,
  maxConcurrent: 3,
  maxRetries: 4,
);

ExtractedBlock _slots(
  List<String> texts, {
  String? sourceText,
}) => ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml:
      '<p>${[for (int i = 0; i < texts.length; i++) '${const HtmlEscape(HtmlEscapeMode.element).convert(texts[i])}<a href="#n$i">*</a>'].join()}</p>',
  sourceText: sourceText ?? '${texts.join('*')}*',
);

class _Client extends TranslationApiClient {
  _Client(this.reply);
  final String Function(String user) reply;
  int batches = 0;
  final Map<String, int> individualCounts = {};
  final Map<String, Map<String, dynamic>> contexts = {};

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final user = messages.last['content'] as String;
    if (user.startsWith('{')) {
      batches++;
    } else {
      individualCounts.update(user, (n) => n + 1, ifAbsent: () => 1);
      final context = messages[messages.length - 2]['content'] as String;
      final decoded =
          jsonDecode(context.substring(context.indexOf('\n') + 1))
              as Map<String, dynamic>;
      contexts[decoded['currentSlotId'] as String] = decoded;
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': reply(user)},
          },
        ],
      },
    );
  }
}

Dio _dio() {
  final dio = Dio();
  addTearDown(() => dio.close(force: true));
  return dio;
}

void main() {
  for (final individual in [false, true]) {
    for (final sample in [
      (source: '1. First paragraph.', reply: '1. 第一段。', accepted: true),
      (
        source: '12) First\n13) Second',
        reply: '12) 第一段\n13) 第二段',
        accepted: true,
      ),
      (source: 'First paragraph.', reply: '1. 第一段。', accepted: false),
      (source: '1. First paragraph.', reply: '1) 第一段。', accepted: false),
      (source: '1. First paragraph.', reply: '**第一段。**', accepted: false),
    ]) {
      test(
        'A-P2-3 ${sample.source}, individual=$individual, ${sample.reply}',
        () async {
          final block = _slots([sample.source]);
          final api = _Client((user) {
            if (!user.startsWith('{')) return sample.reply;
            if (individual) return 'invalid JSON';
            return jsonEncode({
              'blocks': [
                {
                  'id': block.id,
                  'slots': [
                    {'id': 's0', 'text': sample.reply},
                  ],
                },
              ],
            });
          });
          final translator = EpubChapterTranslator(apiClient: api);
          final result = await translator.translateBlockBatchForTest(
            dio: _dio(),
            config: _config,
            blocks: [block],
          );
          expect(api.batches, 1);
          expect(
            api.individualCounts.values.fold(0, (a, b) => a + b),
            individual || !sample.accepted ? 1 : 0,
          );
          if (sample.accepted) {
            expect(result.single, contains(sample.reply));
            expect(translator.getDegradedBlockIdsForTest(), isEmpty);
          } else {
            expect(result, [block.sourceHtml]);
            expect(translator.getDegradedBlockIdsForTest(), hasLength(1));
          }
        },
      );
    }
  }

  for (final type in [
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    for (final recover in [true, false]) {
      test(
        'A-P2-4 $type retries only failing slot, recover=$recover',
        () async {
          final block = _slots(['First', 'Second']);
          int failingCalls = 0;
          final api = _Client((user) {
            if (user.startsWith('{')) return 'invalid JSON';
            if (user == 'Second' && (++failingCalls == 1 || !recover)) {
              throw DioException(requestOptions: RequestOptions(), type: type);
            }
            return '成功译文';
          });
          final translator = EpubChapterTranslator(apiClient: api);
          final result = await translator.translateBlockBatchForTest(
            dio: _dio(),
            config: _config,
            blocks: [block],
          );
          expect(api.batches, 1);
          expect(api.individualCounts, {'First': 1, 'Second': 2});
          expect(result.single, recover ? contains('成功译文') : block.sourceHtml);
          expect(
            translator.getDegradedBlockIdsForTest(),
            recover ? isEmpty : hasLength(1),
          );
        },
      );
    }
  }

  test(
    'A-P2-5 lone HTML footnote overflow makes exactly one request',
    () async {
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'notes.xhtml',
        bytes: utf8.encode('<html><body><p>Original note.</p></body></html>'),
      );
      final reference = FootnoteBlockReference(
        chapterIndex: 0,
        chapter: chapter,
        block: chapter.blocks.single,
      );
      final api = _Client(
        (_) => throw DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 400,
            data: 'maximum context length exceeded',
          ),
        ),
      );
      final translator = EpubChapterTranslator(apiClient: api);
      final result = await translator.translateFootnoteBatchForTest(
        dio: _dio(),
        config: _config,
        references: [reference],
      );
      expect(api.batches, 1);
      expect(api.individualCounts, isEmpty);
      expect(result, {reference.requestId: reference.block.sourceHtml});
      expect(translator.getDegradedBlockIdsForTest(), hasLength(1));
      expect(
        translator.degradedReasonForTest(
          chapterPath: chapter.path,
          blockId: reference.block.id,
        ),
        contains('HTTP 400'),
      );
    },
  );

  for (final missing in [false, true]) {
    test(
      'A-PERF-1 cached spans match ordered lookup, missing=$missing',
      () async {
        final texts = [
          'Hello world ${'opening ' * 100}',
          'world',
          'middle ' * 100,
          'world',
          'ending ' * 100,
        ];
        final block = _slots(
          texts,
          sourceText: missing
              ? '${'unmatched prefix ' * 100}${texts.skip(1).join('*')}'
              : null,
        );
        final api = _Client(
          (user) => user.startsWith('{') ? 'invalid JSON' : '译文',
        );
        await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
          dio: _dio(),
          config: _config,
          blocks: [block],
        );
        expect(api.contexts, hasLength(texts.length));
        for (int index = 0; index < texts.length; index++) {
          expect(
            api.contexts['s$index']!['blockSummary'],
            EpubChapterTranslator.blockContextSummaryForTest(
              block,
              slotText: texts[index],
              slotIndex: index,
              slotTexts: texts,
            ),
          );
        }
        if (!missing) {
          expect(
            api.contexts['s1']!['blockSummary'],
            isNot(api.contexts['s3']!['blockSummary']),
          );
        }
      },
    );
  }
}
