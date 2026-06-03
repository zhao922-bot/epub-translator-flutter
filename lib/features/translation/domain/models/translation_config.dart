enum UiLanguage { english, chinese }

class TranslationConfig {
  const TranslationConfig({
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
    required this.uiLanguage,
    required this.targetLanguage,
    required this.bilingual,
    required this.chunkSize,
    required this.maxConcurrent,
    required this.timeoutSeconds,
    required this.maxRetries,
    required this.retryDelaySeconds,
    required this.disableThinking,
    required this.outputSuffix,
  });

  final String apiBaseUrl;
  final String apiKey;
  final String model;
  final UiLanguage uiLanguage;
  final String targetLanguage;
  final bool bilingual;
  final int chunkSize;
  final int maxConcurrent;
  final int timeoutSeconds;
  final int maxRetries;
  final int retryDelaySeconds;
  final bool disableThinking;
  final String outputSuffix;

  factory TranslationConfig.defaults() {
    return const TranslationConfig(
      apiBaseUrl: 'https://api.deepseek.com',
      apiKey: '',
      model: 'deepseek-chat',
      uiLanguage: UiLanguage.english,
      targetLanguage: 'Chinese',
      bilingual: false,
      chunkSize: 3000,
      maxConcurrent: 3,
      timeoutSeconds: 120,
      maxRetries: 3,
      retryDelaySeconds: 5,
      disableThinking: true,
      outputSuffix: '_translated',
    );
  }

  TranslationConfig copyWith({
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    UiLanguage? uiLanguage,
    String? targetLanguage,
    bool? bilingual,
    int? chunkSize,
    int? maxConcurrent,
    int? timeoutSeconds,
    int? maxRetries,
    int? retryDelaySeconds,
    bool? disableThinking,
    String? outputSuffix,
  }) {
    return TranslationConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      uiLanguage: uiLanguage ?? this.uiLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      bilingual: bilingual ?? this.bilingual,
      chunkSize: chunkSize ?? this.chunkSize,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      maxRetries: maxRetries ?? this.maxRetries,
      retryDelaySeconds: retryDelaySeconds ?? this.retryDelaySeconds,
      disableThinking: disableThinking ?? this.disableThinking,
      outputSuffix: outputSuffix ?? this.outputSuffix,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'apiBaseUrl': apiBaseUrl,
      'apiKey': apiKey,
      'model': model,
      'uiLanguage': uiLanguage.name,
      'targetLanguage': targetLanguage,
      'bilingual': bilingual,
      'chunkSize': chunkSize,
      'maxConcurrent': maxConcurrent,
      'timeoutSeconds': timeoutSeconds,
      'maxRetries': maxRetries,
      'retryDelaySeconds': retryDelaySeconds,
      'disableThinking': disableThinking,
      'outputSuffix': outputSuffix,
    };
  }

  factory TranslationConfig.fromJson(Map<String, dynamic> json) {
    final UiLanguage resolvedLanguage = UiLanguage.values.firstWhere(
      (UiLanguage value) => value.name == json['uiLanguage'],
      orElse: () => UiLanguage.english,
    );
    return TranslationConfig(
      apiBaseUrl: json['apiBaseUrl'] as String? ?? 'https://api.deepseek.com',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? 'deepseek-chat',
      uiLanguage: resolvedLanguage,
      targetLanguage: json['targetLanguage'] as String? ?? 'Chinese',
      bilingual: json['bilingual'] as bool? ?? false,
      chunkSize: json['chunkSize'] as int? ?? 3000,
      maxConcurrent: json['maxConcurrent'] as int? ?? 3,
      timeoutSeconds: json['timeoutSeconds'] as int? ?? 120,
      maxRetries: json['maxRetries'] as int? ?? 3,
      retryDelaySeconds: json['retryDelaySeconds'] as int? ?? 5,
      disableThinking: json['disableThinking'] as bool? ?? true,
      outputSuffix: json['outputSuffix'] as String? ?? '_translated',
    );
  }
}
