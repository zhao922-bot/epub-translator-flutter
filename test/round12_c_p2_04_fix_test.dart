import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

const _source =
    '14. Этот обычный текст должен быть переведен полностью в 2020.';
const _translated = '14. This ordinary text must be translated fully in 2020.';

class _ReplyApi extends TranslationApiClient {
  _ReplyApi(this.fallbackHtml);

  final String fallbackHtml;
  int calls = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    final user = (data['messages'] as List).last['content'] as String;
    final String reply;
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      reply = jsonEncode({
        'blocks': [
          for (final block in payload['blocks'] as List)
            {'id': block['id'], 'html': block['html']},
        ],
      });
    } else {
      reply = fallbackHtml;
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': reply},
          },
        ],
      },
    );
  }
}

void main() {
  test('P2-04 带年份的非拉丁正文边界样本一致性验证', () {
    for (final text in [
      _source,
      '14. Этот обычный текст должен быть переведен полностью.',
      'Ibid. Этот обычный текст должен быть переведен полностью в 2020.',
      'Yardeni, op. cit., p. 62. Этот обычный текст должен быть переведен полностью.',
      '14. هذا النص العادي يجب أن يترجم بالكامل في 2020.',
    ]) {
      expect(
        TranslationQuality.isPureCitationMetadata(text),
        isFalse,
        reason: text,
      );
    }
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p class="endnotes1">$_source</p>',
        translatedHtml: '<p class="endnotes1">$_source</p>',
        targetLanguage: 'English',
        allowBibliographicRetention: true,
      )?.kind,
      TranslationResidualKind.longSourceText,
    );
  });

  test('P2-04 既有纯引用及数字定位信息一致性验证', () {
    for (final text in [
      'Ibid.',
      'Yardeni, op. cit., p. 62.',
      '21. Ibid.',
      'Smith, John (1999)',
      'Leonardo da Vinci, 318',
      'YARDENI',
      '（１４）',
      '١٤',
      '— …',
    ]) {
      expect(
        TranslationQuality.isPureCitationMetadata(text),
        isTrue,
        reason: text,
      );
    }
  });

  test('P2-04 endnotes1 正文进入实际质量门禁的一致性验证', () async {
    const sourceHtml = '<p class="endnotes1">$_source</p>';
    const translatedHtml = '<p class="endnotes1">$_translated</p>';
    final api = _ReplyApi(translatedHtml);
    final translator = EpubChapterTranslator(apiClient: api);
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    final validated = <String>[];
    final result = await translator.translateBlockBatchForTest(
      dio: dio,
      config: TranslationConfig.defaults().copyWith(
        targetLanguage: 'English',
        residualQualityCheck: true,
        styleProfileEnabled: false,
        maxRetries: 1,
      ),
      blocks: const [
        ExtractedBlock(
          id: 'note-14',
          tagName: 'p',
          sourceHtml: sourceHtml,
          sourceText: _source,
        ),
      ],
      onValidated: (id, value) async => validated.add(value),
    );
    expect(api.calls, 2);
    expect(result, [translatedHtml]);
    expect(validated, [translatedHtml]);
    expect(translator.getDegradedBlockIdsForTest(), isEmpty);
  });

  for (final citation in ['Ibid.', 'Yardeni, op. cit., p. 62.']) {
    test('P2-04 纯引用 $citation 的实际门禁一致性验证', () async {
      final sourceHtml = '<p class="endnotes1">$citation</p>';
      final api = _ReplyApi(sourceHtml);
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final result = await EpubChapterTranslator(apiClient: api)
          .translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              targetLanguage: 'Chinese',
              residualQualityCheck: true,
              styleProfileEnabled: false,
              maxRetries: 1,
            ),
            blocks: [
              ExtractedBlock(
                id: 'note',
                tagName: 'p',
                sourceHtml: sourceHtml,
                sourceText: citation,
              ),
            ],
          );
      expect(api.calls, 1);
      expect(result, [sourceHtml]);
    });
  }
}
