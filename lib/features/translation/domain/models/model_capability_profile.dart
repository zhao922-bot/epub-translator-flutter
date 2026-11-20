import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'chat_api_endpoint.dart';

enum ModelReasoningEffort {
  automatic,
  low,
  high,
  max,
  providerDefault,
  none,
  minimal,
  medium,
  xhigh,
  custom;

  static const wireValues = [none, minimal, low, medium, high, xhigh, max];
}

enum ModelThinkingMode { automatic, enabled, disabled }

/// Each choice writes only the named reasoning field. No arbitrary JSON can
/// override the model, messages, transport, or other request parameters.
enum CustomReasoningField {
  effort('reasoning_effort'),
  thinkingType('thinking.type'),
  enableThinking('enable_thinking'),
  thinkingBudget('thinking_budget'),
  routerEffort('reasoning.effort'),
  routerEnabled('reasoning.enabled'),
  routerBudget('reasoning.max_tokens');

  const CustomReasoningField(this.wireLabel);

  final String wireLabel;

  bool get isEffort => this == effort || this == routerEffort;
  bool get isBudget => this == thinkingBudget || this == routerBudget;

  String? normalizeValue(String value) {
    if (isEffort) {
      return ModelReasoningEffort.wireValues.any(
            (effort) => effort.name == value,
          )
          ? value
          : null;
    }
    if (isBudget) {
      final budget = int.tryParse(value, radix: 10);
      return budget != null && budget >= 1 && budget <= 32768
          ? '$budget'
          : null;
    }
    return const {'enabled', 'disabled'}.contains(value) ? value : null;
  }

  Map<String, Object> _parameters(String value) => switch (this) {
    effort => {'reasoning_effort': value},
    thinkingType => {
      'thinking': {'type': value},
    },
    enableThinking => {'enable_thinking': value == 'enabled'},
    thinkingBudget => {'thinking_budget': int.parse(value)},
    routerEffort => {
      'reasoning': {'effort': value},
    },
    routerEnabled => {
      'reasoning': {'enabled': value == 'enabled'},
    },
    routerBudget => {
      'reasoning': {'max_tokens': int.parse(value)},
    },
  };
}

/// A user-declared parameter applies only to the endpoint/model they configured.
/// The route digest avoids persisting a second copy of the base URL.
@immutable
class CustomReasoningParameters {
  const CustomReasoningParameters._(this._route, this.field, this.value);

  static CustomReasoningParameters? forEndpoint({
    required String baseUrl,
    required String model,
    required CustomReasoningField field,
    required String value,
  }) {
    final normalized = field.normalizeValue(value.trim());
    if (normalized == null || baseUrl.trim().isEmpty || model.trim().isEmpty) {
      return null;
    }
    return CustomReasoningParameters._(
      _routeKey(baseUrl, model),
      field,
      normalized,
    );
  }

  final String _route;
  final CustomReasoningField field;
  final String value;

  static String _routeKey(String baseUrl, String model) => sha256
      .convert(utf8.encode(jsonEncode([baseUrl.trim(), model.trim()])))
      .toString();

  bool matches(String baseUrl, String model) =>
      _route == _routeKey(baseUrl, model);

  Map<String, String> toJson() => {
    'route': _route,
    'field': field.name,
    'value': value,
  };

  static CustomReasoningParameters? fromJson(Object? json) {
    if (json is! Map) return null;
    final route = json['route'];
    final value = json['value'];
    if (route is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(route) ||
        value is! String) {
      return null;
    }
    for (final field in CustomReasoningField.values) {
      if (field.name != json['field']) continue;
      final normalized = field.normalizeValue(value);
      if (normalized != null) {
        return CustomReasoningParameters._(route, field, normalized);
      }
    }
    return null;
  }
}

typedef _NativeReasoning = ({
  Set<ModelReasoningEffort> efforts,
  bool supportsThinkingSwitch,
  bool usesCompletionTokenLimit,
  int? contextWindowTokens,
});

/// Resolved from the active Chat Completions endpoint and model identifier.
@immutable
class ModelCapabilityProfile {
  const ModelCapabilityProfile._({
    required this.normalizedHost,
    required this.normalizedModel,
    required this.isGlm53,
    required this.supportedEfforts,
    required this.supportsThinkingSwitch,
    required this.contextWindowTokens,
    required this.reasoningParameters,
    required this.ordinaryBodyReasoningParameters,
    required this.bodyUsesLowerReasoning,
    required this.bodyThinksByDefault,
    required this.forceProviderDefaults,
    required this.automaticThinkingDisabled,
    required this.needsReasoningHeadroom,
    required this.usesCompletionTokenLimit,
    required this.reasoningCacheIdentity,
  });

  final String normalizedHost;
  final String normalizedModel;
  final bool isGlm53;
  final Set<ModelReasoningEffort> supportedEfforts;
  final bool supportsThinkingSwitch;
  final int? contextWindowTokens;
  final Map<String, Object> reasoningParameters;
  final Map<String, Object> ordinaryBodyReasoningParameters;
  final bool forceProviderDefaults;
  final bool automaticThinkingDisabled;
  final bool needsReasoningHeadroom;
  final bool usesCompletionTokenLimit;
  final String? reasoningCacheIdentity;
  final bool bodyUsesLowerReasoning;
  final bool bodyThinksByDefault;

  bool bodyNeedsReasoningHeadroom({required bool preferLowReasoning}) =>
      (needsReasoningHeadroom || bodyThinksByDefault) &&
      !(preferLowReasoning && bodyUsesLowerReasoning);

  bool get supportsSseStreaming => true;
  String? get effectiveReasoningEffort =>
      reasoningParameters['reasoning_effort'] as String?;

  static final RegExp _glm53Pattern = RegExp(r'(^|/)glm-5\.3(?:-flash)?$');
  static const _threeEfforts = {
    ModelReasoningEffort.low,
    ModelReasoningEffort.high,
    ModelReasoningEffort.max,
  };
  static const _openAiGpt5Efforts = {
    ModelReasoningEffort.minimal,
    ModelReasoningEffort.low,
    ModelReasoningEffort.medium,
    ModelReasoningEffort.high,
  };
  static const _openAiGpt51Efforts = {
    ModelReasoningEffort.none,
    ModelReasoningEffort.low,
    ModelReasoningEffort.medium,
    ModelReasoningEffort.high,
  };
  static const _openAiGpt54Efforts = {
    ..._openAiGpt51Efforts,
    ModelReasoningEffort.xhigh,
  };
  static const _openAiPath = '/v1';
  static const _zAiPath = {'/api/paas/v4', '/api/coding/paas/v4'};
  static const _noReasoningFields = <String, Object>{};
  static const _thinkingDisabled = <String, Object>{
    'thinking': {'type': 'disabled'},
  };

  static _NativeReasoning? _nativeReasoning(Uri? uri, String model) {
    if (uri == null || uri.scheme != 'https' || uri.port != 443) return null;
    final host = uri.host;
    // https://api-docs.deepseek.com/guides/thinking_mode
    // https://api-docs.deepseek.com/quick_start/pricing
    if (host == 'api.deepseek.com' &&
        uri.path == _openAiPath &&
        const {
          'deepseek-flash',
          'deepseek-v4-flash',
          'deepseek-v4-flash-vision-exp',
          'deepseek-v4-pro',
        }.contains(model)) {
      return (
        efforts: _threeEfforts,
        supportsThinkingSwitch: true,
        usesCompletionTokenLimit: false,
        contextWindowTokens: 1000000,
      );
    }
    // https://docs.z.ai/guides/capabilities/thinking
    // https://docs.z.ai/guides/llm/glm-5.3
    if (host == 'api.z.ai' &&
        _zAiPath.contains(uri.path) &&
        const {'glm-5.3', 'glm-5.3-flash'}.contains(model)) {
      return (
        efforts: _threeEfforts,
        supportsThinkingSwitch: false,
        usesCompletionTokenLimit: false,
        contextWindowTokens: model == 'glm-5.3' ? 1000000 : null,
      );
    }
    // https://developers.openai.com/api/docs/models/gpt-5
    // https://developers.openai.com/api/docs/models/gpt-5.1
    // https://developers.openai.com/api/docs/models/gpt-5.2
    // https://developers.openai.com/api/docs/models/gpt-5.4
    if (host == 'api.openai.com' && uri.path == _openAiPath) {
      return switch (model) {
        'gpt-5' || 'gpt-5-2025-08-07' => (
          efforts: _openAiGpt5Efforts,
          supportsThinkingSwitch: false,
          usesCompletionTokenLimit: true,
          contextWindowTokens: 400000,
        ),
        'gpt-5.1' || 'gpt-5.1-2025-11-13' => (
          efforts: _openAiGpt51Efforts,
          supportsThinkingSwitch: false,
          usesCompletionTokenLimit: true,
          contextWindowTokens: 400000,
        ),
        'gpt-5.2' || 'gpt-5.2-2025-12-11' => (
          efforts: _openAiGpt54Efforts,
          supportsThinkingSwitch: false,
          usesCompletionTokenLimit: true,
          contextWindowTokens: 400000,
        ),
        'gpt-5.4' || 'gpt-5.4-2026-03-05' => (
          efforts: _openAiGpt54Efforts,
          supportsThinkingSwitch: false,
          usesCompletionTokenLimit: true,
          contextWindowTokens: 1050000,
        ),
        _ => null,
      };
    }
    // https://docs.siliconflow.cn/en/api-reference/chat-completions/chat-completions
    if (host == 'api.siliconflow.cn' &&
        uri.path == _openAiPath &&
        const {
          'pro/deepseek-ai/deepseek-v4',
          'deepseek-ai/deepseek-v4-flash',
          'pro/zai-org/glm-5.2',
        }.contains(model)) {
      return (
        efforts: const {ModelReasoningEffort.high, ModelReasoningEffort.max},
        supportsThinkingSwitch: false,
        usesCompletionTokenLimit: false,
        contextWindowTokens: null,
      );
    }
    return null;
  }

  static ModelCapabilityProfile resolve({
    required String apiBaseUrl,
    required String model,
    required ModelReasoningEffort reasoningEffort,
    bool tokenSavingMode = false,
    ModelThinkingMode thinkingMode = ModelThinkingMode.automatic,
    CustomReasoningParameters? customReasoning,
  }) {
    final uri = normalizedChatApiBaseUri(apiBaseUrl);
    final host = uri?.host ?? '';
    final normalizedModel = model.trim().toLowerCase();
    final isGlm53 = _glm53Pattern.hasMatch(normalizedModel);
    final native = _nativeReasoning(uri, normalizedModel);
    final efforts = native?.efforts ?? const <ModelReasoningEffort>{};
    final canToggleThinking = native?.supportsThinkingSwitch ?? false;
    final useCompletionLimit = native?.usesCompletionTokenLimit ?? false;
    final edgefnAlias =
        host == 'api.edgefn.net' &&
        normalizedModel == 'deepseek-v4-flash-0731' &&
        (!tokenSavingMode ||
            (uri?.scheme == 'https' && uri?.port == 443 && uri?.path == '/v1'));
    final automatic = reasoningEffort == ModelReasoningEffort.automatic;
    final providerDefault =
        reasoningEffort == ModelReasoningEffort.providerDefault;
    final custom = reasoningEffort == ModelReasoningEffort.custom;
    final legacyAutoLow = automatic && isGlm53 && !tokenSavingMode;
    final legacyManual =
        !tokenSavingMode &&
        native == null &&
        _threeEfforts.contains(reasoningEffort);
    final nativeToggle = canToggleThinking && !providerDefault && !custom
        ? thinkingMode
        : ModelThinkingMode.automatic;
    final automaticThinkingDisabled = automatic && edgefnAlias;
    final normal = <String, Object>{};
    if (custom && customReasoning?.matches(apiBaseUrl, model) == true) {
      normal.addAll(customReasoning!.field._parameters(customReasoning.value));
    } else if (!providerDefault && !custom) {
      if (automaticThinkingDisabled) normal.addAll(_thinkingDisabled);
      if (nativeToggle != ModelThinkingMode.automatic) {
        normal['thinking'] = {'type': nativeToggle.name};
      }
      if (nativeToggle != ModelThinkingMode.disabled) {
        if (legacyAutoLow) {
          normal['reasoning_effort'] = 'low';
        } else if (legacyManual || efforts.contains(reasoningEffort)) {
          normal['reasoning_effort'] = reasoningEffort.name;
        }
      }
    }

    Map<String, Object> ordinaryBody = normal;
    if (tokenSavingMode &&
        automatic &&
        nativeToggle == ModelThinkingMode.automatic) {
      if (canToggleThinking || edgefnAlias) {
        ordinaryBody = _thinkingDisabled;
      } else if (efforts.contains(ModelReasoningEffort.low)) {
        final effort = efforts.contains(ModelReasoningEffort.none)
            ? 'none'
            : 'low';
        ordinaryBody = {'reasoning_effort': effort};
      }
    }

    final disablesThinking =
        nativeToggle == ModelThinkingMode.disabled ||
        automaticThinkingDisabled ||
        normal['reasoning_effort'] == 'none' ||
        normal['enable_thinking'] == false ||
        (normal['thinking'] as Map?)?['type'] == 'disabled' ||
        (normal['reasoning'] as Map?)?['enabled'] == false ||
        (normal['reasoning'] as Map?)?['effort'] == 'none';
    final headroom =
        !disablesThinking &&
        ((isGlm53 && (!tokenSavingMode || native != null)) ||
            useCompletionLimit ||
            normal.isNotEmpty);
    final additional = Map.of(normal)..remove('reasoning_effort');
    if (automaticThinkingDisabled) additional.remove('thinking');
    final cacheIdentity =
        additional.isNotEmpty ||
            !identical(ordinaryBody, normal) ||
            (providerDefault && edgefnAlias) ||
            useCompletionLimit
        ? 'reasoning-v1:${jsonEncode([additional, ordinaryBody, useCompletionLimit])}'
        : null;
    return ModelCapabilityProfile._(
      normalizedHost: host,
      normalizedModel: normalizedModel,
      isGlm53: isGlm53,
      supportedEfforts: efforts,
      supportsThinkingSwitch: canToggleThinking,
      contextWindowTokens: native?.contextWindowTokens,
      reasoningParameters: normal.isEmpty
          ? _noReasoningFields
          : Map.unmodifiable(normal),
      ordinaryBodyReasoningParameters: Map.unmodifiable(ordinaryBody),
      bodyUsesLowerReasoning: !identical(ordinaryBody, normal),
      bodyThinksByDefault:
          tokenSavingMode && native != null && !disablesThinking,
      forceProviderDefaults: providerDefault,
      automaticThinkingDisabled: automaticThinkingDisabled,
      needsReasoningHeadroom: headroom,
      usesCompletionTokenLimit: useCompletionLimit,
      reasoningCacheIdentity: cacheIdentity,
    );
  }
}
