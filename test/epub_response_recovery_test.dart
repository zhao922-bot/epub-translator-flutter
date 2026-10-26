import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';

void main() {
  test('duration normalization handles spelled and numeric decades', () {
    for (final source in ['four decades', '4 decades']) {
      expect(TranslationConsistencyChecker.numbers(source, chinese: false), {
        '40',
      });
    }
    expect(TranslationConsistencyChecker.numbers('四十年', chinese: true), {'40'});
    expect(
      TranslationConsistencyChecker.numbers('4 centuries', chinese: false),
      {'400'},
    );
    expect(TranslationConsistencyChecker.numbers('4个世纪', chinese: true), {
      '400',
    });
    expect(
      TranslationConsistencyChecker.numbers('four years', chinese: false),
      {'4'},
    );
    expect(
      TranslationConsistencyChecker.numbers(
        '4 decade-long projects',
        chinese: false,
      ),
      {'4'},
    );
    expect(TranslationConsistencyChecker.numbers('the 1980s', chinese: false), {
      '1980',
    });
  });
  const client = TranslationApiClient();
  test(
    'non-thinking capability is scoped to the verified provider and alias',
    () async {
      final config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://api.edgefn.net/v1',
        model: 'DeepSeek-V4-Flash-0731',
        apiKey: 'test-key',
      );
      expect(config.automaticThinkingDisabled, isTrue);
      for (final other in [
        config.copyWith(apiBaseUrl: 'https://other.example/v1'),
        config.copyWith(apiBaseUrl: 'https://api.edgefn.net.evil.example/v1'),
        config.copyWith(model: 'unknown-model'),
        config.copyWith(reasoningEffort: ModelReasoningEffort.high),
      ]) {
        expect(other.automaticThinkingDisabled, isFalse);
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map>[];
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '好'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final dio = client.buildDio(config);
      dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
      addTearDown(() => dio.close(force: true));
      await client.postChatCompletions(
        dio: dio,
        data: {'messages': [], 'max_tokens': 128},
      );
      expect(requests.single['thinking'], {'type': 'disabled'});
      expect(requests.single.containsKey('reasoning_effort'), isFalse);
      await client.postChatCompletions(
        dio: dio,
        data: {
          'messages': [],
          'max_tokens': 128,
          'thinking': {'type': 'enabled'},
        },
      );
      expect(requests.last['thinking'], {'type': 'enabled'});
    },
  );
  for (final kind in [
    'translation',
    'chapterMemory',
    'semanticReview',
    'semanticVerification',
  ]) {
    test(
      'bounded reasoning-only recovery and sanitized metrics: $kind',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final budgets = <int>[];
        server.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          budgets.add(body['max_tokens'] as int);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': budgets.length == 1 ? 'length' : 'eos_token',
                  'message': {
                    'content': budgets.length == 1 ? '' : '完整译文',
                    'reasoning_content':
                        'Private reasoning must not be retained.',
                  },
                },
              ],
              'usage': {
                'prompt_tokens': 100,
                'completion_tokens': 256,
                'completion_tokens_details': {'reasoning_tokens': 200},
              },
            }),
          );
          await request.response.close();
        });
        final dio = client.buildDio(
          TranslationConfig.defaults().copyWith(
            apiBaseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'test-secret',
            model: 'unknown-compatible-model',
            maxOutputTokens: 2048,
          ),
        );
        addTearDown(() => dio.close(force: true));
        final response = await client.postChatCompletions(
          dio: dio,
          data: {
            'model': 'unknown-compatible-model',
            'max_tokens': 256,
            'messages': [
              {
                'role': 'user',
                'content': jsonEncode({'kind': kind}),
              },
            ],
          },
        );
        final review = kind.startsWith('semantic');
        expect(budgets, review ? [256] : [256, 2048]);
        if (review) {
          expect(
            () => client.extractMessageContent(response.data),
            throwsA(
              isA<TranslationParseException>().having(
                (e) => e.failure,
                'typed cause',
                TranslationResponseFailure.incomplete,
              ),
            ),
          );
        } else {
          expect(client.extractMessageContent(response.data), '完整译文');
        }
        final usage = client.metricsFor(dio).toJson();
        expect(usage['reasoningTokens'], review ? 200 : 400);
        expect(
          usage['finishReasons'],
          review ? {'length': 1} : {'length': 1, 'eos_token': 1},
        );
        expect(jsonEncode(usage), isNot(contains('Private reasoning')));
        final job = TranslationJob(
          id: 'test',
          inputPath: '',
          outputPath: '',
          status: TranslationJobStatus.completed,
          progress: 1,
          apiUsage: usage,
        );
        expect(TranslationJob.fromJson(job.toJson()).apiUsage, usage);
      },
    );
  }
  test('unknown completion status cannot leak arbitrary response data', () {
    expect(
      () => client.extractMessageContent({
        'choices': [
          {
            'finish_reason': 'private provider payload',
            'message': {'content': 'x'},
          },
        ],
      }),
      throwsA(
        isA<TranslationParseException>()
            .having(
              (e) => e.failure,
              'typed cause',
              TranslationResponseFailure.unsupportedFinish,
            )
            .having(
              (e) => e.message,
              'safe detail',
              isNot(contains('private provider payload')),
            ),
      ),
    );
  });
  test('context and inline risks trigger review without changing text', () {
    const checker = TranslationConsistencyChecker();
    for (final s in [
      'She handed him the letter.',
      'The coach tried to catch the ball.',
      'She was <i>almost</i> ready.',
    ]) {
      expect(checker.riskScore('<p>$s</p>', []), greaterThan(0));
    }
    final findings = checker.check(
      sourceHtml: '<p>She was <i>nearly</i> ready.</p>',
      translatedHtml: '<p>她几乎<i>几乎</i>准备好了。 。</p>',
      config: TranslationConfig.defaults(),
    );
    expect(
      findings.map((f) => f['code']),
      containsAll(['repetition', 'punctuation']),
    );
    final intentional = checker.check(
      sourceHtml: '<p>Very very slowly.</p>',
      translatedHtml: '<p>慢慢慢慢地。</p>',
      config: TranslationConfig.defaults(),
    );
    expect(intentional.map((f) => f['code']), isNot(contains('repetition')));
  });
}
