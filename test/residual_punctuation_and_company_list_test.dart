import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';

const _phraseSource =
    '<p>Another Latin saying: <em>Materiam superabat opus. </em>'
    '(The workmanship was better than the material.) We control our work.</p>';
const _phraseTarget =
    '<p>另一句拉丁格言：<em>Materiam superabat opus。</em>'
    '（技艺胜过材料。）我们能掌控自己的工作。</p>';
const _companySource =
    '<p>She invested in Acme, reddit, Dropbox, and others. '
    'She urged founders to start small and learn.</p>';
const _companyTarget =
    '<p>她投资过 Acme、reddit、Dropbox 等公司，'
    '并鼓励创始人从小事做起，不断学习。</p>';

ExtractedBlock _block(String html) => ExtractedBlock(
  id: 'p-1',
  tagName: 'p',
  sourceHtml: html,
  sourceText: html.replaceAll(RegExp('<[^>]+>'), ''),
);

class _ReplyApi extends TranslationApiClient {
  _ReplyApi(this.html);
  final String html;
  int requests = 0;
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    requests++;
    final user = (data['messages'] as List).last['content'] as String;
    final content = user.startsWith('{')
        ? jsonEncode({
            'blocks': [
              for (final b in (jsonDecode(user) as Map)['blocks'] as List)
                {'id': b['id'], 'html': html},
            ],
          })
        : html;
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
  final valid = <(String, String)>[
    (_phraseSource, _phraseTarget),
    (
      '<p><em>Fac, si facis.</em> (Do it if you will do it.)</p>',
      '<p><em>Fac， si facis。</em>（要做，就去做。）</p>',
    ),
    (_companySource, _companyTarget),
    (
      _companySource,
      _companyTarget.replaceFirst('Acme、reddit、Dropbox', 'Acme，reddit，Dropbox'),
    ),
    (
      _companySource,
      _companyTarget.replaceFirst(
        'Acme、reddit、Dropbox',
        'Acme, reddit, Dropbox',
      ),
    ),
    (
      '<p>These brands include Acme, iRobot, and eBay. Choose what fits your needs.</p>',
      '<p>这些品牌包括 Acme、iRobot、eBay，请按需要选择。</p>',
    ),
  ];
  for (var index = 0; index < valid.length; index++) {
    final (source, target) = valid[index];
    test(
      'explained punctuation or source-owned company list $index passes',
      () {
        expect(
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: source,
            translatedHtml: target,
            targetLanguage: 'Chinese',
          ),
          isNull,
        );
        final result = EpubChapterTranslator.validateReviewSuggestion(
          config: TranslationConfig.defaults().copyWith(
            targetLanguage: 'Chinese',
          ),
          block: _block(source),
          translatedHtml: target,
        );
        expect(result, target);
      },
    );
  }

  final invalid = <(String, String)>[
    (_phraseSource, _phraseTarget.replaceFirst('superabat', 'alienum')),
    (_phraseSource, _phraseTarget.replaceFirst('（技艺胜过材料。）', '')),
    (_phraseSource, _phraseTarget.replaceFirst('。', '！')),
    (_companySource, _companySource),
    (
      _companySource,
      _companyTarget.replaceFirst(
        '并鼓励创始人从小事做起，不断学习。',
        'She urged founders to start small and learn.',
      ),
    ),
    (
      '<p>She packed Bread, milk, Cheese, and others. She worked carefully.</p>',
      '<p>她打包了 Bread、milk、Cheese 等东西，工作很认真。</p>',
    ),
    (
      '<p>She invested in Acme, research, and others. She started slowly.</p>',
      '<p>她投资 Acme、research 等项目，慢慢起步。</p>',
    ),
    (_companySource, '$_companyTarget<p>然后research继续。</p>'),
  ];
  for (var index = 0; index < invalid.length; index++) {
    final (source, target) = invalid[index];
    test('real residual or unsupported exemption $index remains rejected', () {
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

  for (final (source, target) in [valid.first, valid[2]]) {
    test(
      'accepted real-world shape is cached after one request: $source',
      () async {
        final api = _ReplyApi(target);
        final translator = EpubChapterTranslator(apiClient: api);
        final dio = Dio();
        addTearDown(() => dio.close(force: true));
        final cached = <String>[];
        final result = await translator.translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            targetLanguage: 'Chinese',
            maxRetries: 2,
            retryDelaySeconds: 0,
          ),
          blocks: [_block(source)],
          chapterPath: 'chapter.xhtml',
          onValidated: (_, html) async => cached.add(html),
        );
        expect(result.single, target);
        expect(api.requests, 1);
        expect(cached, [target]);
        expect(translator.getDegradedBlockIdsForTest(), isEmpty);
      },
    );
  }

  for (final redactToken in [false, true]) {
    test(
      'residual diagnostics identify tokens and redact secrets: $redactToken',
      () async {
        final api = _ReplyApi('<p>我们在research中学习。</p>');
        final translator = EpubChapterTranslator(apiClient: api);
        final dio = Dio();
        addTearDown(() => dio.close(force: true));
        await translator.translateBlockBatchForTest(
          dio: dio,
          config: TranslationConfig.defaults().copyWith(
            targetLanguage: 'Chinese',
            maxRetries: 1,
            retryDelaySeconds: 0,
            apiKey: redactToken ? 'research' : 'test-key',
          ),
          blocks: [_block('<p>We learn through careful research.</p>')],
          chapterPath: 'chapter.xhtml',
        );
        expect(
          translator.degradedReasonForTest(
            chapterPath: 'chapter.xhtml',
            blockId: 'p-1',
          ),
          allOf(
            contains('Residual quality check failed'),
            redactToken
                ? allOf(contains('[redacted]'), isNot(contains('research')))
                : contains('research'),
          ),
        );
      },
    );
  }
}
