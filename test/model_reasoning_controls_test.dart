import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_artifact_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _client = TranslationApiClient();

TranslationConfig _endpoint(String url, String model) =>
    TranslationConfig.defaults().copyWith(
      apiBaseUrl: url,
      model: model,
      apiProviderSelection: ApiProviderSelection.custom,
      customApiBaseUrl: url,
      customModel: model,
    );

class _Capture {
  _Capture(this.server);

  final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  String finishReason = 'stop';

  static Future<_Capture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final capture = _Capture(server);
    addTearDown(() => server.close(force: true));
    server.listen(capture.respond);
    return capture;
  }

  Future<void> respond(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    requests.add(jsonDecode(body) as Map<String, dynamic>);
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'finish_reason': finishReason,
            'message': {'content': 'fixture output'},
          },
        ],
      }),
    );
    await request.response.close();
  }

  Future<void> send(
    TranslationConfig config, {
    bool stream = false,
    Map<String, dynamic> data = const {},
  }) async {
    final dio = _client.buildDio(config);
    // Resolve the provider profile from the configured endpoint; capture the
    // resulting request on loopback without contacting the real service.
    dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
    try {
      await _client.postChatCompletionsStream(
        dio: dio,
        stream: stream,
        data: {
          'model': config.model,
          'messages': [
            {'role': 'user', 'content': 'fixture body'},
          ],
          'max_tokens': 137,
          ...data,
        },
      );
    } finally {
      dio.close(force: true);
    }
  }
}

void main() {
  test(
    'token savings is opt-in and legacy reasoning selections round-trip',
    () {
      expect(TranslationConfig.defaults().tokenSavingMode, isFalse);
      for (final name in ['automatic', 'low', 'high', 'max']) {
        final legacy = TranslationConfig.fromJson({'reasoningEffort': name});
        expect(legacy.reasoningEffort.name, name);
        expect(legacy.thinkingMode, ModelThinkingMode.automatic);
        expect(legacy.tokenSavingMode, isFalse);
        final enabled = TranslationConfig.fromJson(
          legacy.copyWith(tokenSavingMode: true).toJson(),
        );
        expect(enabled.tokenSavingMode, isTrue);
        expect(enabled.reasoningEffort.name, name);
        expect(enabled.residualQualityCheck, legacy.residualQualityCheck);
      }
    },
  );

  test('known models expose documented effort values and context windows', () {
    final deepSeek = TranslationConfig.defaults().capabilities;
    expect(deepSeek.supportedEfforts, {
      ModelReasoningEffort.low,
      ModelReasoningEffort.high,
      ModelReasoningEffort.max,
    });
    expect(deepSeek.supportsThinkingSwitch, isTrue);
    expect(deepSeek.contextWindowTokens, 1000000);
    final glm = _endpoint(
      'https://api.z.ai/api/paas/v4',
      'glm-5.3',
    ).capabilities;
    expect(glm.supportedEfforts, deepSeek.supportedEfforts);
    expect(glm.supportsThinkingSwitch, isFalse);
    expect(glm.contextWindowTokens, 1000000);
    final openAi = _endpoint(
      'https://api.openai.com/v1',
      'gpt-5.4',
    ).capabilities;
    expect(openAi.supportedEfforts, {
      ModelReasoningEffort.none,
      ModelReasoningEffort.low,
      ModelReasoningEffort.medium,
      ModelReasoningEffort.high,
      ModelReasoningEffort.xhigh,
    });
    expect(openAi.contextWindowTokens, 1050000);
    for (final config in [
      _endpoint('https://api.openai.com.example/v1', 'gpt-5.4'),
      _endpoint('https://api.openai.com/test/v1', 'gpt-5.4'),
      _endpoint('https://api.z.ai:8443/api/paas/v4', 'glm-5.3'),
      _endpoint('https://gateway.example/v1', 'zai-org/GLM-5.3-Flash'),
      _endpoint('https://api.deepseek.com', 'unlisted-model'),
    ]) {
      final profile = config.copyWith(tokenSavingMode: true).capabilities;
      expect(profile.supportedEfforts, isEmpty);
      expect(profile.contextWindowTokens, isNull);
      expect(profile.ordinaryBodyReasoningParameters, isEmpty);
    }
  });

  test('registry and transport share the official completion endpoint', () {
    for (final base in [
      'https://api.z.ai/api/paas/v4',
      'https://api.z.ai/api/paas/v4/chat/completions',
    ]) {
      expect(_client.normalizedBaseUrl(base), 'https://api.z.ai/api/paas/v4');
      expect(
        _endpoint(base, 'glm-5.3').capabilities.contextWindowTokens,
        1000000,
      );
    }
    expect(
      _endpoint(
        'api.openai.com/v1/chat/completions',
        'gpt-5.2',
      ).capabilities.supportedEfforts,
      contains(ModelReasoningEffort.xhigh),
    );
    expect(
      _client.normalizedBaseUrl('https://gateway.example/api/paas/v4'),
      'https://gateway.example/api/paas/v4/v1',
    );
  });

  test(
    'provider default omits all reasoning fields in both request modes',
    () async {
      final capture = await _Capture.start();
      final config = TranslationConfig.defaults().copyWith(
        tokenSavingMode: true,
        reasoningEffort: ModelReasoningEffort.providerDefault,
        thinkingMode: ModelThinkingMode.enabled,
      );
      const reasoningKeys = [
        'reasoning_effort',
        'reasoning',
        'thinking',
        'enable_thinking',
        'thinking_budget',
      ];
      for (final stream in [false, true]) {
        await capture.send(
          config,
          stream: stream,
          data: {
            '_folioFerryBudgetedBody': true,
            '_folioFerryPreferLowReasoning': true,
            for (final key in reasoningKeys) key: 'should be omitted',
          },
        );
        final request = capture.requests.last;
        expect(reasoningKeys.any(request.containsKey), isFalse);
        expect(
          request.keys.any((key) => key.startsWith('_folioFerry')),
          isFalse,
        );
        expect(request['max_tokens'], 137);
        expect(request['stream'], stream ? true : null);
      }
    },
  );

  test(
    'ordinary-body policy is verified, explicit choices win, and budget does not retry',
    () async {
      final capture = await _Capture.start();
      final deepSeek = TranslationConfig.defaults().copyWith(
        tokenSavingMode: true,
      );
      const body = {
        '_folioFerryBudgetedBody': true,
        '_folioFerryPreferLowReasoning': true,
      };
      capture.finishReason = 'length';
      await capture.send(deepSeek, data: body);
      expect(capture.requests, hasLength(1));
      expect(capture.requests.single['thinking'], {'type': 'disabled'});
      expect(capture.requests.single['max_tokens'], 137);

      capture.finishReason = 'stop';
      await capture.send(deepSeek, data: {'_folioFerryBudgetedBody': true});
      expect(capture.requests.last.containsKey('thinking'), isFalse);
      await capture.send(
        deepSeek.copyWith(reasoningEffort: ModelReasoningEffort.high),
        data: body,
      );
      expect(capture.requests.last['reasoning_effort'], 'high');
      expect(capture.requests.last.containsKey('thinking'), isFalse);
      await capture.send(
        deepSeek.copyWith(thinkingMode: ModelThinkingMode.enabled),
        data: body,
      );
      expect(capture.requests.last['thinking'], {'type': 'enabled'});
      await capture.send(
        deepSeek.copyWith(apiBaseUrl: 'https://proxy.example/v1'),
        data: body,
      );
      expect(capture.requests.last.containsKey('thinking'), isFalse);
    },
  );

  test(
    'OpenAI uses exact effort and native completion limit in both request modes',
    () async {
      final capture = await _Capture.start();
      final config = _endpoint('https://api.openai.com/v1', 'gpt-5.4').copyWith(
        tokenSavingMode: true,
        reasoningEffort: ModelReasoningEffort.xhigh,
      );
      for (final stream in [false, true]) {
        await capture.send(
          config,
          stream: stream,
          data: {
            '_folioFerryBudgetedBody': true,
            '_folioFerryPreferLowReasoning': true,
            'temperature': 0.2,
          },
        );
        final request = capture.requests.last;
        expect(request['reasoning_effort'], 'xhigh');
        expect(request['max_completion_tokens'], 137);
        expect(request.containsKey('max_tokens'), isFalse);
        expect(request.containsKey('temperature'), isFalse);
      }
    },
  );

  test(
    'custom reasoning declarations are allowlisted and scoped to their route',
    () async {
      final capture = await _Capture.start();
      final config = _endpoint('https://proxy.example/v1', 'private-model');
      for (final (field, value, sentKey, sentValue) in [
        (CustomReasoningField.effort, 'medium', 'reasoning_effort', 'medium'),
        (
          CustomReasoningField.enableThinking,
          'disabled',
          'enable_thinking',
          false,
        ),
        (CustomReasoningField.thinkingBudget, '1024', 'thinking_budget', 1024),
        (
          CustomReasoningField.routerEffort,
          'xhigh',
          'reasoning',
          {'effort': 'xhigh'},
        ),
      ]) {
        final parameters = CustomReasoningParameters.forEndpoint(
          baseUrl: config.apiBaseUrl,
          model: config.model,
          field: field,
          value: value,
        );
        expect(parameters, isNotNull);
        final restored = TranslationConfig.fromJson(
          config
              .copyWith(
                customReasoning: parameters,
                reasoningEffort: ModelReasoningEffort.custom,
              )
              .toJson(),
        );
        await capture.send(restored);
        expect(capture.requests.last[sentKey], sentValue);
        await capture.send(restored.copyWith(model: 'other-model'));
        expect(capture.requests.last.containsKey(sentKey), isFalse);
        await capture.send(
          restored.copyWith(apiBaseUrl: 'https://proxy.example/other'),
        );
        expect(capture.requests.last.containsKey(sentKey), isFalse);
      }
      expect(
        CustomReasoningParameters.forEndpoint(
          baseUrl: config.apiBaseUrl,
          model: config.model,
          field: CustomReasoningField.effort,
          value: '{"messages": []}',
        ),
        isNull,
      );
    },
  );

  test('explicit and default thinking keep adaptive body headroom', () {
    final config = TranslationConfig.defaults().copyWith(tokenSavingMode: true);
    expect(
      config.capabilities.bodyNeedsReasoningHeadroom(preferLowReasoning: true),
      isFalse,
    );
    expect(
      config.capabilities.bodyNeedsReasoningHeadroom(preferLowReasoning: false),
      isTrue,
    );
    for (final effort in [
      ModelReasoningEffort.high,
      ModelReasoningEffort.providerDefault,
    ]) {
      expect(
        config
            .copyWith(reasoningEffort: effort)
            .capabilities
            .bodyNeedsReasoningHeadroom(preferLowReasoning: true),
        isTrue,
      );
    }
    expect(
      config
          .copyWith(thinkingMode: ModelThinkingMode.disabled)
          .capabilities
          .bodyNeedsReasoningHeadroom(preferLowReasoning: true),
      isFalse,
    );
  });

  test('mode and explicit reasoning changes are isolated in artifact keys', () {
    final config = TranslationConfig.defaults();
    String key(TranslationConfig config) => TranslationArtifactCache.key(
      config,
      'semanticDraft',
      {'fixture': true},
    );
    expect(key(config.copyWith(tokenSavingMode: true)), isNot(key(config)));
    expect(
      key(config.copyWith(thinkingMode: ModelThinkingMode.disabled)),
      isNot(key(config)),
    );
    expect(
      key(
        config.copyWith(reasoningEffort: ModelReasoningEffort.providerDefault),
      ),
      key(config),
    );
  });
}
