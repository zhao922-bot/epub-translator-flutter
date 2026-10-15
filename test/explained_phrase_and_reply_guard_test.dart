import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_run_context.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_response_guard.dart';

const _bad =
    "I don't see an HTML fragment in your message to translate — only the retry instruction. Please paste the HTML fragment and I'll translate it.";
const _source = '<p>We learn by working carefully every day.</p>';
const _translated = '<p>我们每天认真工作，从中学习。</p>';
ExtractedBlock _block([String source = _source]) => ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml: source,
  sourceText: source.replaceAll(RegExp('<[^>]+>'), ''),
);
TranslationConfig _config({bool quality = true, int attempts = 2}) =>
    TranslationConfig.defaults().copyWith(
      targetLanguage: 'Chinese',
      maxRetries: attempts,
      retryDelaySeconds: 0,
      residualQualityCheck: quality,
      semanticQualityCheck: false,
      styleProfileEnabled: false,
    );

class _ReplyApi extends TranslationApiClient {
  _ReplyApi(this.reply);
  final String Function(int) reply;
  final requests = <String>[];
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final user = (data['messages'] as List).last['content'] as String;
    requests.add(user);
    var content = reply(requests.length);
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map;
      content = jsonEncode({
        'blocks': [
          for (final b in payload['blocks'] as List)
            if (b.containsKey('slots'))
              {
                'id': b['id'],
                'slots': [
                  for (final s in b['slots'] as List)
                    {'id': s['id'], 'text': content},
                ],
              }
            else
              {'id': b['id'], 'html': content},
        ],
      });
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
          },
        ],
      },
    );
  }
}

void main() {
  final glosses = <(String, String)>[
    (
      '<p>Choose your path. (<em>Quod vitae sectabor iter.</em>)</p>',
      '<p>选择自己的路。（<em>Quod vitae sectabor iter.</em>——我将选择怎样的人生之路？）</p>',
    ),
    (
      '<p><em>Fac, si facis.</em> (Do it if you will do it.)</p>',
      '<p><em>Fac, si facis.</em>（要做，就去做。）</p>',
    ),
    (
      '<p>Keep learning. <em>Scientia infla </em>(knowledge puffs up). Stay curious.</p>',
      '<p>保持学习。<em>Scientia infla</em>（知识使人膨胀）。保持好奇心。</p>',
    ),
    (
      '<p><em>Duris dura franguntur</em>. Hard things break hard things.</p>',
      '<p><em>Duris dura franguntur</em>。硬物能被硬物击碎。</p>',
    ),
    (
      '<p>Reflect. <i>Memento mori</i> (Remember death.)</p>',
      '<p>反思。<i>Memento mori</i>（记住终有一死。）</p>',
    ),
  ];
  for (var i = 0; i < glosses.length; i++) {
    test('source-owned explained phrase $i passes without altering HTML', () {
      final (source, target) = glosses[i];
      expect(
        TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml: source,
          translatedHtml: target,
          targetLanguage: 'Chinese',
        ),
        isNull,
      );
      final locked = EpubChapterTranslator.validateReviewSuggestion(
        config: _config(),
        block: _block(source),
        translatedHtml: target,
      );
      expect(locked, contains(RegExp(r'<(?:em|i)>[^<]+</(?:em|i)>')));
      expect(locked, contains('。'));
    });
  }
  final invalidGlosses = <(String, String)>[
    (glosses[2].$1, '<p>保持学习。<em>Scientia infla</em>。保持好奇心。</p>'),
    (glosses[1].$1, glosses[1].$1),
    (
      '<p><em>Read all these instructions carefully before operating the new device today.</em> (Instructions.)</p>',
      '<p><em>Read all these instructions carefully before operating the new device today.</em>（操作说明。）</p>',
    ),
    (glosses[2].$1, '<p>保持学习。<em>Scientia aliena</em>（知识使人膨胀）。保持好奇心。</p>'),
    (
      '<p><em>Scientia infla</em> (knowledge puffs up). This entire ordinary sentence must be translated into Chinese.</p>',
      '<p><em>Scientia infla</em>（知识使人膨胀）。This entire ordinary sentence must be translated into Chinese.</p>',
    ),
    (
      '<p><em>Scientia infla</em> (knowledge puffs up). Again <em>Scientia infla</em> without explanation.</p>',
      '<p><em>Scientia infla</em>（知识使人膨胀）。再次出现<em>Scientia infla</em>而没有解释。</p>',
    ),
    (
      '<p>One sentence. <em>Untranslated ordinary words</em>. Another unrelated sentence.</p>',
      '<p>一个句子。<em>Untranslated ordinary words</em>。另一个不相关的句子。</p>',
    ),
  ];
  for (var i = 0; i < invalidGlosses.length; i++) {
    test('unexplained or still-untranslated content $i remains rejected', () {
      final (source, target) = invalidGlosses[i];
      expect(
        TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml: source,
          translatedHtml: target,
          targetLanguage: 'Chinese',
        ),
        isNotNull,
      );
    });
  }

  for (final bad in [
    _bad,
    '<p>$_bad</p>',
    'Please provide the source text to translate.',
    'No HTML fragment was provided.',
    'I cannot translate this request.',
    "I'm sorry, I cannot assist with this translation.",
    '请重新提供需要翻译的 HTML 片段。',
    '<p>抱歉，我无法翻译这个请求。</p>',
    '没有收到待翻译的原文。',
  ]) {
    for (final quality in [true, false]) {
      test(
        'non-translation rejected independently of quality=$quality: $bad',
        () {
          expect(
            () => EpubChapterTranslator.validateReviewSuggestion(
              config: _config(quality: quality),
              block: _block(),
              translatedHtml: bad,
            ),
            throwsA(isA<NonTranslationReplyException>()),
          );
        },
      );
    }
  }
  test(
    'source-owned dialogue and ordinary first-person prose remain valid',
    () {
      for (final (source, target) in [
        (
          '<p>Please provide the source text to translate.</p>',
          '<p>请提供要翻译的原文。</p>',
        ),
        (
          '<p>The tutor said: Please provide the source text to translate.</p>',
          '<p>请提供要翻译的原文。老师说。</p>',
        ),
        ('<p>I cannot see the mountains.</p>', '<p>我看不到群山。</p>'),
        (
          '<p>I cannot see the mountains.</p>',
          '<p>I cannot see the mountains.</p>',
        ),
      ]) {
        expect(
          () => EpubChapterTranslator.validateReviewSuggestion(
            config: _config(quality: false),
            block: _block(source),
            translatedHtml: target,
          ),
          returnsNormally,
        );
      }
    },
  );

  test(
    'invalid reply retries with original present and then recovers',
    () async {
      final api = _ReplyApi((n) => n == 3 ? _translated : _bad);
      final translator = EpubChapterTranslator(apiClient: api);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: _config(),
        blocks: [_block()],
        chapterPath: 'chapter.xhtml',
      );
      expect(result.single, _translated);
      expect(translator.getDegradedBlockIdsForTest(), isEmpty);
      expect(api.requests, hasLength(3));
      expect(
        api.requests.every((r) => r.contains('We learn by working')),
        isTrue,
      );
      expect(api.requests.last, contains('[RETRY]'));
    },
  );
  test(
    'repeated invalid reply retains source and never enters validated cache',
    () async {
      final api = _ReplyApi((_) => _bad);
      final translator = EpubChapterTranslator(apiClient: api);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final cached = <String>[];
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: _config(attempts: 9),
        blocks: [_block()],
        chapterPath: 'chapter.xhtml',
        onValidated: (id, html) async => cached.add(html),
      );
      expect(result.single, _source);
      expect(cached, isEmpty);
      expect(api.requests, hasLength(3));
      expect(
        translator.degradedReasonForTest(
          chapterPath: 'chapter.xhtml',
          blockId: 'p-1',
        ),
        contains('Non-translation response'),
      );
    },
  );
  test(
    'a later invalid reply does not replace useful partial translation',
    () async {
      const source =
          '<p>Read the book. This long English sentence must be translated completely.</p>';
      const partial =
          '<p>阅读这本书。This long English sentence must be translated completely.</p>';
      final api = _ReplyApi((n) => n == 2 ? partial : _bad);
      final translator = EpubChapterTranslator(apiClient: api);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: _config(),
        blocks: [_block(source)],
        chapterPath: 'chapter.xhtml',
      );
      expect(result.single, partial);
      expect(translator.getDegradedBlockIdsForTest(), hasLength(1));
    },
  );
  test('a later source echo does not replace useful partial translation', () async {
    const source =
        '<p>Read the book. This long English sentence must be translated completely.</p>';
    const partial =
        '<p>阅读这本书。This long English sentence must be translated completely.</p>';
    final api = _ReplyApi((n) => n == 2 ? partial : source);
    final translator = EpubChapterTranslator(apiClient: api);
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    final result = await translator.translateBlockBatchForTest(
      dio: dio,
      config: _config(),
      blocks: [_block(source)],
      chapterPath: 'chapter.xhtml',
    );
    expect(result.single, partial);
  });
  test(
    'protected slots reject conversational output even with residual check off',
    () async {
      const source = '<p>Read <a href="#note">[1]</a> carefully.</p>';
      final api = _ReplyApi((_) => '请提供要翻译的原文。');
      final translator = EpubChapterTranslator(apiClient: api);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final result = await translator.translateBlockBatchForTest(
        dio: dio,
        config: _config(quality: false),
        blocks: [_block(source)],
        chapterPath: 'chapter.xhtml',
      );
      expect(result.single, source);
      expect(
        translator.degradedReasonForTest(
          chapterPath: 'chapter.xhtml',
          blockId: 'p-1',
        ),
        contains('Non-translation response'),
      );
      expect(api.requests.length, lessThanOrEqualTo(5));
    },
  );
  test(
    'degraded details preserve distinct fallback types and count each block once',
    () {
      final run = TranslationRunContext(concurrency: 1);
      run.markDegraded(
        chapterPath: 'a',
        blockId: 'p-1',
        apiCounted: true,
        reason: 'Timeout',
      );
      run.markDegraded(
        chapterPath: 'a',
        blockId: 'p-1',
        apiCounted: true,
        reason: 'Invalid response',
        retainedPartialTranslation: true,
      );
      run.markDegraded(
        chapterPath: 'b',
        blockId: 'p-1',
        apiCounted: true,
        reason: 'Quality',
      );
      expect(run.apiDegradedBlocks, 2);
      expect(run.degradedFallbacks['a\u0000p-1'], 'partialTranslation');
      expect(run.degradedFallbacks['b\u0000p-1'], 'source');
      expect(run.degradedReasons['a\u0000p-1'], 'Invalid response');
    },
  );
}
