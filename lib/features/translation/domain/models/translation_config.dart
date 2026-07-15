enum UiLanguage { english, chinese }

enum AppThemeMode { system, light, dark }

enum TranslationTuningPreset { stable, balanced, fast }

class TranslationConfig {
  const TranslationConfig({
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
    required this.uiLanguage,
    required this.themeMode,
    required this.targetLanguage,
    required this.bilingual,
    required this.chunkSize,
    required this.maxConcurrent,
    required this.timeoutSeconds,
    required this.maxRetries,
    required this.retryDelaySeconds,
    required this.outputSuffix,
    required this.residualQualityCheck,
    required this.textScale,
    required this.lockedGlossary,
  });

  final String apiBaseUrl;
  final String apiKey;
  final String model;
  final UiLanguage uiLanguage;
  final AppThemeMode themeMode;
  final String targetLanguage;
  final bool bilingual;
  final int chunkSize;
  final int maxConcurrent;
  final int timeoutSeconds;
  final int maxRetries;
  final int retryDelaySeconds;
  final String outputSuffix;

  /// When true, reject translations that leave long source-language residuals.
  final bool residualQualityCheck;

  /// UI text scale factor (accessibility), 0.9–1.3.
  final double textScale;

  /// User-locked glossary lines: `source => target` per line.
  final String lockedGlossary;

  factory TranslationConfig.defaults() {
    return const TranslationConfig(
      apiBaseUrl: 'https://api.deepseek.com',
      apiKey: '',
      model: 'deepseek-chat',
      uiLanguage: UiLanguage.english,
      themeMode: AppThemeMode.dark,
      targetLanguage: 'Chinese',
      bilingual: false,
      chunkSize: 3000,
      maxConcurrent: 3,
      timeoutSeconds: 120,
      maxRetries: 3,
      retryDelaySeconds: 5,
      outputSuffix: '_translated',
      residualQualityCheck: true,
      textScale: 1.0,
      lockedGlossary: '',
    );
  }

  TranslationConfig copyWith({
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    UiLanguage? uiLanguage,
    AppThemeMode? themeMode,
    String? targetLanguage,
    bool? bilingual,
    int? chunkSize,
    int? maxConcurrent,
    int? timeoutSeconds,
    int? maxRetries,
    int? retryDelaySeconds,
    String? outputSuffix,
    bool? residualQualityCheck,
    double? textScale,
    String? lockedGlossary,
  }) {
    return TranslationConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      uiLanguage: uiLanguage ?? this.uiLanguage,
      themeMode: themeMode ?? this.themeMode,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      bilingual: bilingual ?? this.bilingual,
      chunkSize: chunkSize ?? this.chunkSize,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      maxRetries: maxRetries ?? this.maxRetries,
      retryDelaySeconds: retryDelaySeconds ?? this.retryDelaySeconds,
      outputSuffix: outputSuffix ?? this.outputSuffix,
      residualQualityCheck: residualQualityCheck ?? this.residualQualityCheck,
      textScale: textScale ?? this.textScale,
      lockedGlossary: lockedGlossary ?? this.lockedGlossary,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'apiBaseUrl': apiBaseUrl,
      'model': model,
      'uiLanguage': uiLanguage.name,
      'themeMode': themeMode.name,
      'targetLanguage': targetLanguage,
      'bilingual': bilingual,
      'chunkSize': chunkSize,
      'maxConcurrent': maxConcurrent,
      'timeoutSeconds': timeoutSeconds,
      'maxRetries': maxRetries,
      'retryDelaySeconds': retryDelaySeconds,
      'outputSuffix': outputSuffix,
      'residualQualityCheck': residualQualityCheck,
      'textScale': textScale,
      'lockedGlossary': lockedGlossary,
    };
  }

  factory TranslationConfig.fromJson(Map<String, dynamic> json) {
    final UiLanguage resolvedLanguage = UiLanguage.values.firstWhere(
      (UiLanguage value) => value.name == json['uiLanguage'],
      orElse: () => UiLanguage.english,
    );
    final AppThemeMode resolvedThemeMode = AppThemeMode.values.firstWhere(
      (AppThemeMode value) => value.name == json['themeMode'],
      orElse: () => AppThemeMode.dark,
    );
    final double textScale = switch (json['textScale']) {
      num value => value.toDouble().clamp(0.9, 1.3),
      String value => double.tryParse(value.trim())?.clamp(0.9, 1.3) ?? 1.0,
      _ => 1.0,
    };
    return TranslationConfig(
      apiBaseUrl: _readTrimmedString(
        json['apiBaseUrl'],
        fallback: 'https://api.deepseek.com',
      ),
      apiKey: _readTrimmedString(json['apiKey']),
      model: _readTrimmedString(json['model'], fallback: 'deepseek-chat'),
      uiLanguage: resolvedLanguage,
      themeMode: resolvedThemeMode,
      targetLanguage: _readTrimmedString(
        json['targetLanguage'],
        fallback: 'Chinese',
      ),
      bilingual: json['bilingual'] as bool? ?? false,
      chunkSize: _readBoundedInt(
        json['chunkSize'],
        fallback: 3000,
        min: 1000,
        max: 12000,
      ),
      maxConcurrent: _readBoundedInt(
        json['maxConcurrent'],
        fallback: 3,
        min: 1,
        max: 8,
      ),
      timeoutSeconds: _readBoundedInt(
        json['timeoutSeconds'],
        fallback: 120,
        min: 30,
        max: 300,
      ),
      maxRetries: _readBoundedInt(
        json['maxRetries'],
        fallback: 3,
        min: 1,
        max: 6,
      ),
      retryDelaySeconds: _readBoundedInt(
        json['retryDelaySeconds'],
        fallback: 5,
        min: 1,
        max: 15,
      ),
      outputSuffix: _readTrimmedString(
        json['outputSuffix'],
        fallback: '_translated',
      ),
      residualQualityCheck: json['residualQualityCheck'] as bool? ?? true,
      textScale: textScale,
      lockedGlossary: _readTrimmedString(json['lockedGlossary']),
    );
  }

  static String _readTrimmedString(Object? value, {String fallback = ''}) {
    if (value is! String) {
      return fallback;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static int _readBoundedInt(
    Object? value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final int? parsed = switch (value) {
      int value => value,
      num value => value.round(),
      String value =>
        int.tryParse(value.trim()) ?? double.tryParse(value.trim())?.round(),
      _ => null,
    };
    return (parsed ?? fallback).clamp(min, max).toInt();
  }
}

extension TranslationTuningPresetConfig on TranslationTuningPreset {
  int get chunkSize => switch (this) {
    TranslationTuningPreset.stable => 2500,
    TranslationTuningPreset.balanced => 5000,
    TranslationTuningPreset.fast => 8000,
  };

  int get maxConcurrent => switch (this) {
    TranslationTuningPreset.stable => 2,
    TranslationTuningPreset.balanced => 4,
    TranslationTuningPreset.fast => 8,
  };

  int get timeoutSeconds => switch (this) {
    TranslationTuningPreset.stable => 180,
    TranslationTuningPreset.balanced => 150,
    TranslationTuningPreset.fast => 120,
  };

  int get maxRetries => switch (this) {
    TranslationTuningPreset.stable => 4,
    TranslationTuningPreset.balanced => 3,
    TranslationTuningPreset.fast => 2,
  };

  int get retryDelaySeconds => switch (this) {
    TranslationTuningPreset.stable => 6,
    TranslationTuningPreset.balanced => 5,
    TranslationTuningPreset.fast => 3,
  };

  TranslationConfig applyTo(TranslationConfig config) {
    return config.copyWith(
      chunkSize: chunkSize,
      maxConcurrent: maxConcurrent,
      timeoutSeconds: timeoutSeconds,
      maxRetries: maxRetries,
      retryDelaySeconds: retryDelaySeconds,
    );
  }

  bool matches(TranslationConfig config) {
    return config.chunkSize == chunkSize &&
        config.maxConcurrent == maxConcurrent &&
        config.timeoutSeconds == timeoutSeconds &&
        config.maxRetries == maxRetries &&
        config.retryDelaySeconds == retryDelaySeconds;
  }
}
