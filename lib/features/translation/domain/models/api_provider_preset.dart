import 'translation_config.dart';

/// Built-in API endpoint templates for Windows/Android users.
enum ApiProviderPreset { deepseek, openAiCompatible, custom }

extension ApiProviderPresetConfig on ApiProviderPreset {
  String get label => switch (this) {
    ApiProviderPreset.deepseek => 'DeepSeek',
    ApiProviderPreset.openAiCompatible => 'OpenAI-compatible',
    ApiProviderPreset.custom => 'Custom',
  };

  String get description => switch (this) {
    ApiProviderPreset.deepseek =>
      'Official DeepSeek chat endpoint (default for this app).',
    ApiProviderPreset.openAiCompatible =>
      'Generic OpenAI-style /v1/chat/completions hosts.',
    ApiProviderPreset.custom => 'Keep the current base URL and model.',
  };

  String get baseUrl => switch (this) {
    ApiProviderPreset.deepseek => 'https://api.deepseek.com',
    ApiProviderPreset.openAiCompatible => 'https://api.openai.com',
    ApiProviderPreset.custom => '',
  };

  String get model => switch (this) {
    ApiProviderPreset.deepseek => 'deepseek-chat',
    ApiProviderPreset.openAiCompatible => 'gpt-4o-mini',
    ApiProviderPreset.custom => '',
  };

  TranslationConfig applyTo(TranslationConfig config) {
    if (this == ApiProviderPreset.custom) {
      return config;
    }
    return config.copyWith(apiBaseUrl: baseUrl, model: model);
  }

  bool matches(TranslationConfig config) {
    if (this == ApiProviderPreset.custom) {
      return !ApiProviderPreset.deepseek.matches(config) &&
          !ApiProviderPreset.openAiCompatible.matches(config);
    }
    final String url = config.apiBaseUrl.trim().toLowerCase();
    final String expected = baseUrl.toLowerCase();
    return url == expected ||
        url == '$expected/v1' ||
        url.startsWith('$expected/');
  }
}
