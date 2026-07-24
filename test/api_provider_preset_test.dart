import 'package:epub_translator_flutter/features/translation/domain/models/api_provider_preset.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only exposes DeepSeek and Custom provider choices', () {
    expect(ApiProviderPreset.values, <ApiProviderPreset>[
      ApiProviderPreset.deepseek,
      ApiProviderPreset.custom,
    ]);
    expect(
      ApiProviderPreset.values.map((ApiProviderPreset value) => value.label),
      <String>['DeepSeek', 'Custom'],
    );
  });

  test('DeepSeek preset applies the new default model', () {
    final TranslationConfig configured = ApiProviderPreset.deepseek.applyTo(
      TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://custom.example/v1',
        model: 'custom-model',
      ),
    );

    expect(configured.apiBaseUrl, 'https://api.deepseek.com');
    expect(configured.model, 'deepseek-v4-flash');
    expect(ApiProviderPreset.deepseek.matches(configured), isTrue);
  });

  test('Custom restores its saved API settings after using DeepSeek', () {
    final TranslationConfig original = TranslationConfig.defaults().copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      apiBaseUrl: 'https://custom.example/v1',
      apiKey: 'sk-preserved',
      model: 'custom-model',
      customApiBaseUrl: 'https://custom.example/v1',
      customApiKey: 'sk-preserved',
      customModel: 'custom-model',
    );

    final TranslationConfig configured = ApiProviderPreset.custom.applyTo(
      ApiProviderPreset.deepseek.applyTo(original),
    );

    expect(configured.apiBaseUrl, 'https://custom.example/v1');
    expect(configured.apiKey, 'sk-preserved');
    expect(configured.model, 'custom-model');
    expect(ApiProviderPreset.custom.matches(configured), isTrue);
  });

  test('provider matching follows the explicit selected profile', () {
    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      model: 'another-model',
    );

    expect(ApiProviderPreset.deepseek.matches(config), isFalse);
    expect(ApiProviderPreset.custom.matches(config), isTrue);
  });
}
