import 'package:flutter/foundation.dart';

/// User preference for reasoning effort sent to models that support it.
enum ModelReasoningEffort { automatic, low, high, max }

/// Declarative per-provider / per-model capability descriptor derived from the
/// active API endpoint, model identifier, and reasoning effort preference.
///
/// Centralizing endpoint and model heuristics here prevents vendor/alias
/// special-cases from scattering across `TranslationConfig`, API clients, and
/// semantic review prompts.
@immutable
class ModelCapabilityProfile {
  const ModelCapabilityProfile({
    required this.normalizedHost,
    required this.normalizedModel,
    required this.isGlm53,
    required this.effectiveReasoningEffort,
    required this.automaticThinkingDisabled,
    required this.needsReasoningHeadroom,
    required this.supportsSseStreaming,
  });

  final String normalizedHost;
  final String normalizedModel;
  final bool isGlm53;
  final String? effectiveReasoningEffort;
  final bool automaticThinkingDisabled;
  final bool needsReasoningHeadroom;
  final bool supportsSseStreaming;

  static final RegExp _glm53Pattern = RegExp(
    r'(^|/)glm-5\.3(?:-flash)?$',
    caseSensitive: false,
  );

  /// Registry of host/model aliases whose automatic mode disables hidden
  /// chain-of-thought so small translation/memory token budgets are not consumed
  /// before emitting translated HTML or JSON.
  static const Map<String, Set<String>> _autoDisableThinkingAliases =
      <String, Set<String>>{
        'api.edgefn.net': <String>{'deepseek-v4-flash-0731'},
      };

  static ModelCapabilityProfile resolve({
    required String apiBaseUrl,
    required String model,
    required ModelReasoningEffort reasoningEffort,
  }) {
    final String host =
        Uri.tryParse(apiBaseUrl.trim())?.host.toLowerCase() ?? '';
    final String normalizedModel = model.trim().toLowerCase();
    final bool isGlm53 = _glm53Pattern.hasMatch(normalizedModel);
    final String? effectiveEffort =
        reasoningEffort == ModelReasoningEffort.automatic
        ? (isGlm53 ? 'low' : null)
        : reasoningEffort.name;
    final bool autoDisableThinking =
        reasoningEffort == ModelReasoningEffort.automatic &&
        (_autoDisableThinkingAliases[host]?.contains(normalizedModel) ?? false);
    final bool needsHeadroom = isGlm53 || effectiveEffort != null;

    return ModelCapabilityProfile(
      normalizedHost: host,
      normalizedModel: normalizedModel,
      isGlm53: isGlm53,
      effectiveReasoningEffort: effectiveEffort,
      automaticThinkingDisabled: autoDisableThinking,
      needsReasoningHeadroom: needsHeadroom,
      supportsSseStreaming: true,
    );
  }
}
