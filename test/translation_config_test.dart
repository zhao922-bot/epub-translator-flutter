import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not persist secrets or removed provider-specific switches', () {
    final Map<String, dynamic> json = TranslationConfig.defaults()
        .copyWith(apiKey: 'sk-test-secret')
        .toJson();

    expect(json, isNot(contains('apiKey')));
    expect(json, isNot(contains('disableThinking')));
  });

  test('loads numeric settings from compatible json values safely', () {
    final TranslationConfig config =
        TranslationConfig.fromJson(<String, dynamic>{
          'chunkSize': 8000.0,
          'maxConcurrent': '12',
          'timeoutSeconds': 5,
          'maxRetries': 0,
          'retryDelaySeconds': '20',
        });

    expect(config.chunkSize, 8000);
    expect(config.maxConcurrent, 8);
    expect(config.timeoutSeconds, 30);
    expect(config.maxRetries, 1);
    expect(config.retryDelaySeconds, 15);
  });

  test('normalizes pasted text settings from persisted json', () {
    final TranslationConfig config =
        TranslationConfig.fromJson(<String, dynamic>{
          'apiBaseUrl': ' https://api.edgefn.net/v1\r\n ',
          'apiKey': ' sk-secret\r\n ',
          'model': ' DeepSeek-V4-Flash\n ',
          'targetLanguage': ' Chinese ',
          'outputSuffix': ' _translated ',
        });

    expect(config.apiBaseUrl, 'https://api.edgefn.net/v1');
    expect(config.apiKey, 'sk-secret');
    expect(config.model, 'DeepSeek-V4-Flash');
    expect(config.targetLanguage, 'Chinese');
    expect(config.outputSuffix, '_translated');
  });

  test('persists and restores the selected app theme mode', () {
    final Map<String, dynamic> json = TranslationConfig.defaults()
        .copyWith(themeMode: AppThemeMode.light)
        .toJson();

    expect(json['themeMode'], 'light');
    expect(TranslationConfig.fromJson(json).themeMode, AppThemeMode.light);
    expect(
      TranslationConfig.fromJson(<String, dynamic>{
        'themeMode': 'system',
      }).themeMode,
      AppThemeMode.system,
    );
    expect(
      TranslationConfig.fromJson(<String, dynamic>{
        'themeMode': 'unknown',
      }).themeMode,
      AppThemeMode.dark,
    );
  });
}
