import '../../../../shared/logging/app_logger.dart';
import 'model_capability_profile.dart';

export 'model_capability_profile.dart'
    show
        CustomReasoningField,
        CustomReasoningParameters,
        ModelCapabilityProfile,
        ModelReasoningEffort,
        ModelThinkingMode;

enum UiLanguage { english, chinese }

enum AppThemeMode { system, light, dark }

enum ApiProviderSelection { deepseek, custom }

enum TranslationTuningPreset { stable, balanced, fast }

enum SemanticReviewScope { risksOnly, all }

class TranslationConfig {
  const TranslationConfig({
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
    required this.apiProviderSelection,
    required this.deepseekApiKey,
    required this.customApiBaseUrl,
    required this.customApiKey,
    required this.customModel,
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
    required this.styleProfileEnabled,
    required this.textScale,
    required this.lockedGlossary,
    required this.httpProxy,
    this.reasoningEffort = ModelReasoningEffort.automatic,
    this.thinkingMode = ModelThinkingMode.automatic,
    this.customReasoning,
    this.maxOutputTokens = 8192,
    this.semanticQualityCheck = false,
    this.autoApplyVerifiedCorrections = false,
    this.retryIncompleteReviews = false,
    this.maxSemanticReviewRequests = 8,
    this.semanticReviewScope = SemanticReviewScope.risksOnly,
    this.maxSemanticReviewTokens = 64000,
    this.useStreamingApi = false,
    this.tokenSavingMode = false,
    this.maxBookTokens = 0,
  });

  final String apiBaseUrl;
  final String apiKey;
  final String model;
  final ApiProviderSelection apiProviderSelection;

  /// Provider-specific values retained when the user temporarily switches
  /// between the built-in DeepSeek profile and Custom.
  final String deepseekApiKey;
  final String customApiBaseUrl;
  final String customApiKey;
  final String customModel;
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

  /// When true, infer a book style profile from front matter/early chapters
  /// and inject soft genre/tone constraints into translation prompts.
  final bool styleProfileEnabled;

  /// UI text scale factor (accessibility), 0.91.3.
  final double textScale;

  /// User-locked glossary lines: `source => target` per line.
  final String lockedGlossary;

  /// Optional HTTP proxy for API traffic ("host:port" or "http://host:port").
  /// Empty means no explicit proxy (system proxy settings on Windows/Android
  /// are not visible to Dart's HttpClient, hence this manual override).
  /// Local and private destinations always bypass it (no_proxy semantics).
  final String httpProxy;

  final ModelReasoningEffort reasoningEffort;
  final ModelThinkingMode thinkingMode;
  final CustomReasoningParameters? customReasoning;
  final int maxOutputTokens;
  final bool semanticQualityCheck;

  /// Apply only evidence-backed suggestions approved by a separate verifier.
  final bool autoApplyVerifiedCorrections;
  final bool retryIncompleteReviews;
  final int maxSemanticReviewRequests;
  final SemanticReviewScope semanticReviewScope;

  /// Conservative local reservation, including maximum response tokens.
  final int maxSemanticReviewTokens;

  /// Whether to request OpenAI-compatible Server-Sent Events (`stream: true`)
  /// when communicating with chat-completions endpoints (falling back cleanly
  /// to buffered JSON responses when the server returns `application/json`).
  final bool useStreamingApi;

  /// Opts into compact prompts and adaptive translation request planning.
  final bool tokenSavingMode;

  /// Cumulative estimate threshold across requests for the same book/task.
  /// A zero value leaves the book unbounded.
  final int maxBookTokens;

  static const int maxBookTokenBudget = 1000000000;

  /// Resolved capability profile for the active endpoint, model, and effort.
  ModelCapabilityProfile get capabilities => ModelCapabilityProfile.resolve(
    apiBaseUrl: apiBaseUrl,
    model: model,
    reasoningEffort: reasoningEffort,
    thinkingMode: thinkingMode,
    tokenSavingMode: tokenSavingMode,
    customReasoning: apiProviderSelection == ApiProviderSelection.custom
        ? customReasoning
        : null,
  );

  /// Only auto-configure models with verified reasoning-effort support.
  /// Other compatible APIs keep their own defaults unless explicitly opted in.
  bool get isGlm53 => capabilities.isGlm53;

  String? get effectiveReasoningEffort => capabilities.effectiveReasoningEffort;

  /// Verified provider/model capability, not a general OpenAI-compatible flag.
  /// This alias otherwise spends its entire small translation/memory budget on
  /// hidden reasoning. Explicit user effort choices retain provider behavior.
  bool get automaticThinkingDisabled => capabilities.automaticThinkingDisabled;

  /// Persistence separates the proxy endpoint from its entire authentication
  /// component. Keep the combined URL in memory for the existing UI/client.
  /// Split textually so even a malformed URL cannot leak credentials to JSON.
  String get httpProxyAddress {
    final value = httpProxy.trim();
    final schemeEnd = value.indexOf('://');
    final start = schemeEnd < 0 ? 0 : schemeEnd + 3;
    final at = value.lastIndexOf('@');
    return at < start
        ? value
        : value.substring(0, start) + value.substring(at + 1);
  }

  String get httpProxyAuthentication {
    final value = httpProxy.trim();
    final schemeEnd = value.indexOf('://');
    final start = schemeEnd < 0 ? 0 : schemeEnd + 3;
    final at = value.lastIndexOf('@');
    return at < start ? '' : value.substring(start, at);
  }

  static String authenticatedProxy(String address, String authentication) {
    if (authentication.isEmpty || address.isEmpty) return address;
    final schemeEnd = address.indexOf('://');
    final start = schemeEnd < 0 ? 0 : schemeEnd + 3;
    return '${address.substring(0, start)}$authentication@${address.substring(start)}';
  }

  factory TranslationConfig.defaults() {
    return const TranslationConfig(
      apiBaseUrl: 'https://api.deepseek.com',
      apiKey: '',
      model: 'deepseek-v4-flash',
      apiProviderSelection: ApiProviderSelection.deepseek,
      deepseekApiKey: '',
      customApiBaseUrl: '',
      customApiKey: '',
      customModel: '',
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
      styleProfileEnabled: true,
      textScale: 1.0,
      lockedGlossary: '',
      httpProxy: '',
    );
  }

  TranslationConfig copyWith({
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    ApiProviderSelection? apiProviderSelection,
    String? deepseekApiKey,
    String? customApiBaseUrl,
    String? customApiKey,
    String? customModel,
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
    bool? styleProfileEnabled,
    double? textScale,
    String? lockedGlossary,
    String? httpProxy,
    ModelReasoningEffort? reasoningEffort,
    ModelThinkingMode? thinkingMode,
    CustomReasoningParameters? customReasoning,
    int? maxOutputTokens,
    bool? semanticQualityCheck,
    bool? autoApplyVerifiedCorrections,
    bool? retryIncompleteReviews,
    int? maxSemanticReviewRequests,
    SemanticReviewScope? semanticReviewScope,
    int? maxSemanticReviewTokens,
    bool? useStreamingApi,
    bool? tokenSavingMode,
    int? maxBookTokens,
  }) {
    return TranslationConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      semanticReviewScope: semanticReviewScope ?? this.semanticReviewScope,
      maxSemanticReviewTokens:
          maxSemanticReviewTokens ?? this.maxSemanticReviewTokens,
      useStreamingApi: useStreamingApi ?? this.useStreamingApi,
      tokenSavingMode: tokenSavingMode ?? this.tokenSavingMode,
      maxBookTokens: maxBookTokens ?? this.maxBookTokens,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      apiProviderSelection: apiProviderSelection ?? this.apiProviderSelection,
      deepseekApiKey: deepseekApiKey ?? this.deepseekApiKey,
      customApiBaseUrl: customApiBaseUrl ?? this.customApiBaseUrl,
      customApiKey: customApiKey ?? this.customApiKey,
      customModel: customModel ?? this.customModel,
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
      styleProfileEnabled: styleProfileEnabled ?? this.styleProfileEnabled,
      textScale: textScale ?? this.textScale,
      lockedGlossary: lockedGlossary ?? this.lockedGlossary,
      httpProxy: httpProxy ?? this.httpProxy,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      thinkingMode: thinkingMode ?? this.thinkingMode,
      customReasoning: customReasoning ?? this.customReasoning,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      semanticQualityCheck: semanticQualityCheck ?? this.semanticQualityCheck,
      autoApplyVerifiedCorrections:
          autoApplyVerifiedCorrections ?? this.autoApplyVerifiedCorrections,
      retryIncompleteReviews:
          retryIncompleteReviews ?? this.retryIncompleteReviews,
      maxSemanticReviewRequests:
          maxSemanticReviewRequests ?? this.maxSemanticReviewRequests,
    );
  }

  Map<String, dynamic> toJson() {
    // Credential-bearing components are rejected in BOTH slots: an old
    // custom URL stored from a previous version must never persist plaintext
    // credentials (P1-9), even when DeepSeek is currently selected. Ordinary
    // non-credential query parameters and path '@' are allowed by
    // validateApiUrl, so a stale legitimate custom URL no longer blocks
    // saving unrelated settings (#17); fragments are rejected outright
    // (C-1: never sent to the server, zero legitimate use).
    validateApiUrl(apiBaseUrl);
    validateApiUrl(customApiBaseUrl);
    return <String, dynamic>{
      'apiBaseUrl': apiBaseUrl,
      'model': model,
      'apiProviderSelection': apiProviderSelection.name,
      'customApiBaseUrl': customApiBaseUrl,
      'customModel': customModel,
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
      'styleProfileEnabled': styleProfileEnabled,
      'textScale': textScale,
      'lockedGlossary': lockedGlossary,
      'httpProxy': httpProxyAddress,
      'reasoningEffort': reasoningEffort.name,
      'thinkingMode': thinkingMode.name,
      if (customReasoning != null) 'customReasoning': customReasoning!.toJson(),
      'maxOutputTokens': maxOutputTokens,
      'semanticQualityCheck': semanticQualityCheck,
      'autoApplyVerifiedCorrections': autoApplyVerifiedCorrections,
      'retryIncompleteReviews': retryIncompleteReviews,
      'maxSemanticReviewRequests': maxSemanticReviewRequests,
      'semanticReviewScope': semanticReviewScope.name,
      'maxSemanticReviewTokens': maxSemanticReviewTokens,
      'useStreamingApi': useStreamingApi,
      'tokenSavingMode': tokenSavingMode,
      'maxBookTokens': maxBookTokens,
    };
  }

  /// API authentication belongs in the secure API-key slot, not in the URL.
  ///
  /// Rejected outright: userinfo (`user:pass@host`), query parameters whose
  /// names look like secrets (`key`, `token`, `secret`, `password` and
  /// friends), and any fragment. A fragment is never sent to the server, so
  /// it has zero legitimate use in an API base URL — while the OAuth
  /// implicit-flow shape (`#api_key=sk-xxx`) would silently drop the key
  /// from requests and could leak it through history/logs. Ordinary query
  /// parameters (e.g. `/v1?tenant=books`) and `@` inside the path (e.g.
  /// `/@team/v1`) remain allowed.
  static void validateApiUrl(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final Uri? uri = Uri.tryParse(trimmed);
    // A malformed URL cannot be inspected reliably for embedded credentials.
    // Keep it as an unsaved UI draft rather than persisting sensitive text.
    if (uri == null) {
      throw const FormatException(
        'API URL is invalid. Check the address and port.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'API URLs must not embed userinfo credentials; '
        'put the API key in the key field.',
      );
    }
    // Uri.tryParse populates [Uri.fragment] even for schemeless input
    // (e.g. `example.com#frag`), so a direct emptiness check is enough;
    // an empty fragment (`...#`) carries nothing and is allowed.
    if (uri.fragment.isNotEmpty) {
      throw const FormatException(
        'API URLs must not contain a fragment; '
        'put the API key in the key field.',
      );
    }
    for (final String name in uri.queryParameters.keys) {
      if (_looksLikeCredentialQueryParam(name)) {
        throw FormatException(
          'API URL query parameter "$name" looks like an embedded '
          'credential; put the API key in the key field.',
        );
      }
    }
  }

  /// Whether a query parameter name looks like an embedded secret.
  /// Deliberately conservative: a bare substring check would false-positive
  /// on innocent words (`monkey`), so only exact/affixed matches and a few
  /// common separator-less compounds (`apikey`) count.
  static bool _looksLikeCredentialQueryParam(String name) {
    final String lower = name.toLowerCase();
    const List<String> keywords = <String>[
      'key',
      'token',
      'secret',
      'password',
      'passwd',
      'pwd',
    ];
    for (final String keyword in keywords) {
      if (lower == keyword ||
          lower.endsWith('_$keyword') ||
          lower.endsWith('-$keyword') ||
          lower.startsWith('${keyword}_') ||
          lower.startsWith('$keyword-') ||
          lower.contains('_${keyword}_') ||
          lower.contains('-$keyword-')) {
        return true;
      }
    }
    const List<String> compounds = <String>[
      'apikey',
      'accesstoken',
      'authkey',
      'clientsecret',
      'apisecret',
    ];
    return compounds.contains(lower);
  }

  factory TranslationConfig.fromJson(Map<String, dynamic> json) {
    final bool explicitlyCustom =
        json['apiProviderSelection'] == ApiProviderSelection.custom.name;
    final String apiBaseUrl = explicitlyCustom
        ? _readTrimmedStringAllowEmpty(json['apiBaseUrl'])
        : _readTrimmedString(
            json['apiBaseUrl'],
            fallback: 'https://api.deepseek.com',
          );
    final String model = explicitlyCustom
        ? _readTrimmedStringAllowEmpty(json['model'])
        : _readTrimmedString(json['model'], fallback: 'deepseek-v4-flash');
    final ApiProviderSelection providerSelection = ApiProviderSelection.values
        .firstWhere(
          (ApiProviderSelection value) =>
              value.name == json['apiProviderSelection'],
          orElse: () => _looksLikeDeepSeekProvider(apiBaseUrl)
              ? ApiProviderSelection.deepseek
              : ApiProviderSelection.custom,
        );
    final UiLanguage resolvedLanguage = UiLanguage.values.firstWhere(
      (UiLanguage value) => value.name == json['uiLanguage'],
      orElse: () => UiLanguage.english,
    );
    final AppThemeMode resolvedThemeMode = AppThemeMode.values.firstWhere(
      (AppThemeMode value) => value.name == json['themeMode'],
      orElse: () => AppThemeMode.dark,
    );
    final double textScale =
        (_readFiniteNumber(json['textScale'], field: 'textScale') ?? 1.0)
            .clamp(0.9, 1.3)
            .toDouble();
    return TranslationConfig(
      apiBaseUrl: apiBaseUrl,
      reasoningEffort: ModelReasoningEffort.values.firstWhere(
        (v) => v.name == json['reasoningEffort'],
        orElse: () => ModelReasoningEffort.automatic,
      ),
      thinkingMode: ModelThinkingMode.values.firstWhere(
        (value) => value.name == json['thinkingMode'],
        orElse: () => ModelThinkingMode.automatic,
      ),
      customReasoning: CustomReasoningParameters.fromJson(
        json['customReasoning'],
      ),
      maxOutputTokens: _readBoundedInt(
        json['maxOutputTokens'],
        fallback: 8192,
        min: 512,
        max: 32768,
      ),
      semanticQualityCheck: json['semanticQualityCheck'] == true,
      autoApplyVerifiedCorrections:
          json['autoApplyVerifiedCorrections'] == true,
      retryIncompleteReviews: json['retryIncompleteReviews'] == true,
      semanticReviewScope: SemanticReviewScope.values.firstWhere(
        (v) => v.name == json['semanticReviewScope'],
        orElse: () => SemanticReviewScope.risksOnly,
      ),
      maxSemanticReviewTokens: _readBoundedInt(
        json['maxSemanticReviewTokens'],
        fallback: 64000,
        min: 4000,
        max: 1024000,
      ),
      maxSemanticReviewRequests: _readBoundedInt(
        json['maxSemanticReviewRequests'],
        fallback: 8,
        min: 1,
        max: 64,
      ),
      apiKey: _readTrimmedString(json['apiKey']),
      model: model,
      apiProviderSelection: providerSelection,
      deepseekApiKey: _readTrimmedString(json['deepseekApiKey']),
      customApiBaseUrl: json['customApiBaseUrl'] is String
          ? _readTrimmedStringAllowEmpty(json['customApiBaseUrl'])
          : providerSelection == ApiProviderSelection.custom
          ? apiBaseUrl
          : '',
      customApiKey: _readTrimmedString(json['customApiKey']),
      customModel: json['customModel'] is String
          ? _readTrimmedStringAllowEmpty(json['customModel'])
          : providerSelection == ApiProviderSelection.custom
          ? model
          : '',
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
      styleProfileEnabled: json['styleProfileEnabled'] as bool? ?? true,
      textScale: textScale,
      lockedGlossary: _readTrimmedString(json['lockedGlossary']),
      httpProxy: _readTrimmedStringAllowEmpty(json['httpProxy']),
      useStreamingApi: json['useStreamingApi'] == true,
      tokenSavingMode: json['tokenSavingMode'] == true,
      maxBookTokens: _readBoundedInt(
        json['maxBookTokens'],
        fallback: 0,
        min: 0,
        max: maxBookTokenBudget,
      ),
    );
  }

  static String _readTrimmedString(Object? value, {String fallback = ''}) {
    if (value is! String) {
      return fallback;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static String _readTrimmedStringAllowEmpty(Object? value) {
    return value is String ? value.trim() : '';
  }

  static bool _looksLikeDeepSeekProvider(String apiBaseUrl) {
    final String url = apiBaseUrl.trim().toLowerCase().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    return (url == 'https://api.deepseek.com' ||
        url == 'https://api.deepseek.com/v1');
  }

  static int _readBoundedInt(
    Object? value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final int? parsed = _readFiniteNumber(
      value,
      field: 'integer setting',
    )?.round();
    return (parsed ?? fallback).clamp(min, max).toInt();
  }

  static num? _readFiniteNumber(Object? value, {required String field}) {
    final parsed = value is num
        ? value
        : value is String
        ? num.tryParse(value.trim())
        : null;
    if (parsed != null && !parsed.isFinite) {
      AppLogger.warn('Non-finite $field; using default.', tag: 'settings');
      return null;
    }
    return parsed;
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
