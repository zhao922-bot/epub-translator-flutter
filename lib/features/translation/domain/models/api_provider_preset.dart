import 'translation_config.dart';

/// Built-in API endpoint templates for Windows/Android users.
enum ApiProviderPreset { deepseek, custom }

extension ApiProviderPresetConfig on ApiProviderPreset {
  String get label => switch (this) {
    ApiProviderPreset.deepseek => 'DeepSeek',
    ApiProviderPreset.custom => 'Custom',
  };

  String get description => switch (this) {
    ApiProviderPreset.deepseek =>
      'Official DeepSeek chat endpoint (default for this app).',
    ApiProviderPreset.custom => 'Keep the current base URL and model.',
  };

  String get baseUrl => switch (this) {
    ApiProviderPreset.deepseek => 'https://api.deepseek.com',
    ApiProviderPreset.custom => '',
  };

  String get model => switch (this) {
    ApiProviderPreset.deepseek => 'deepseek-v4-flash',
    ApiProviderPreset.custom => '',
  };

  TranslationConfig applyTo(TranslationConfig config) {
    return switch (this) {
      ApiProviderPreset.deepseek => config.copyWith(
        apiProviderSelection: ApiProviderSelection.deepseek,
        apiBaseUrl: baseUrl,
        apiKey: config.deepseekApiKey,
        model: model,
      ),
      ApiProviderPreset.custom => config.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: config.customApiBaseUrl,
        apiKey: config.customApiKey,
        model: config.customModel,
      ),
    };
  }

  bool matches(TranslationConfig config) {
    return switch (this) {
      ApiProviderPreset.deepseek =>
        config.apiProviderSelection == ApiProviderSelection.deepseek,
      ApiProviderPreset.custom =>
        config.apiProviderSelection == ApiProviderSelection.custom,
    };
  }
}
