import 'dart:math';

/// An estimate of a physical request's input and maximum output tokens.
typedef TranslationAttemptEstimate = ({int input, int output});

/// Counts physical attempts. Only numeric usage and fixed labels are retained.
class TranslationApiMetrics {
  int requests = 0,
      errors = 0,
      promptTokens = 0,
      completionTokens = 0,
      elapsedMs = 0;
  int usageReportedRequests = 0;
  int totalUsageReportedRequests = 0;
  int reportedTotalTokens = 0;
  int reasoningReportedRequests = 0;
  int reasoningTokens = 0;
  int cachedPromptTokens = 0;
  int promptCacheReportedRequests = 0;
  int chargedTokensEstimate = 0;
  int estimatedUnreportedTokens = 0;
  final Map<String, int> byKind = {},
      finishReasons = {},
      elapsedMsByKind = {},
      promptTokensByKind = {},
      completionTokensByKind = {},
      chargedTokensEstimateByKind = {};

  Map<String, int> get _counts => {
    'requests': requests,
    'errors': errors,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'elapsedMs': elapsedMs,
    'usageReportedRequests': usageReportedRequests,
    'totalUsageReportedRequests': totalUsageReportedRequests,
    'reportedTotalTokens': reportedTotalTokens,
    'reasoningReportedRequests': reasoningReportedRequests,
    'reasoningTokens': reasoningTokens,
    'cachedPromptTokens': cachedPromptTokens,
    'promptCacheReportedRequests': promptCacheReportedRequests,
    'chargedTokensEstimate': chargedTokensEstimate,
    'estimatedUnreportedTokens': estimatedUnreportedTokens,
  };

  Map<String, Map<String, int>> get _groups => {
    'byKind': byKind,
    'finishReasons': finishReasons,
    'elapsedMsByKind': elapsedMsByKind,
    'promptTokensByKind': promptTokensByKind,
    'completionTokensByKind': completionTokensByKind,
    'chargedTokensEstimateByKind': chargedTokensEstimateByKind,
  };

  Map<String, Object> toJson() => {
    ..._counts,
    for (final e in _groups.entries) e.key: Map<String, int>.of(e.value),
  };

  TranslationApiMetrics();

  TranslationApiMetrics.fromJson(Map<String, Object?> json) {
    _addCounts((key) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw const FormatException('Invalid translation usage counter.');
      }
      return value;
    });
    for (final group in _groups.entries) {
      final value = json[group.key];
      if (value is! Map) {
        throw const FormatException('Invalid translation usage group.');
      }
      for (final e in value.entries) {
        final key = e.key;
        final count = e.value;
        if (key is! String || count is! int || count < 0) {
          throw const FormatException('Invalid translation usage group item.');
        }
        group.value[key] = count;
      }
    }
  }

  void _addCounts(int Function(String) count) {
    requests += count('requests');
    errors += count('errors');
    promptTokens += count('promptTokens');
    completionTokens += count('completionTokens');
    elapsedMs += count('elapsedMs');
    usageReportedRequests += count('usageReportedRequests');
    totalUsageReportedRequests += count('totalUsageReportedRequests');
    reportedTotalTokens += count('reportedTotalTokens');
    reasoningReportedRequests += count('reasoningReportedRequests');
    reasoningTokens += count('reasoningTokens');
    cachedPromptTokens += count('cachedPromptTokens');
    promptCacheReportedRequests += count('promptCacheReportedRequests');
    chargedTokensEstimate += count('chargedTokensEstimate');
    estimatedUnreportedTokens += count('estimatedUnreportedTokens');
  }

  void add(TranslationApiMetrics other) {
    final counts = other._counts;
    _addCounts((key) => counts[key]!);
    final groups = _groups;
    for (final group in other._groups.entries) {
      for (final e in group.value.entries) {
        _increment(groups[group.key]!, e.key, e.value);
      }
    }
  }

  void recordAttempt({
    required String kind,
    required TranslationAttemptEstimate estimate,
    Map? usage,
    String? finishReason,
    int elapsed = 0,
    bool failed = false,
  }) {
    requests++;
    _increment(byKind, kind, 1);
    if (failed) errors++;
    elapsedMs += elapsed;
    _increment(elapsedMsByKind, kind, elapsed);
    if (finishReason != null) _increment(finishReasons, finishReason, 1);

    final input = _tokenCount(
      usage?['prompt_tokens'] ?? usage?['input_tokens'],
    );
    final output = _tokenCount(
      usage?['completion_tokens'] ?? usage?['output_tokens'],
    );
    final total = _tokenCount(usage?['total_tokens']);
    final inputDetails =
        usage?['prompt_tokens_details'] ?? usage?['input_tokens_details'];
    final outputDetails =
        usage?['completion_tokens_details'] ?? usage?['output_tokens_details'];
    final cached = _tokenCount(
      (inputDetails is Map ? inputDetails['cached_tokens'] : null) ??
          usage?['prompt_cache_hit_tokens'],
    );
    final reasoning = _tokenCount(
      (outputDetails is Map ? outputDetails['reasoning_tokens'] : null) ??
          usage?['reasoning_tokens'],
    );
    if (input != null) {
      promptTokens += input;
      _increment(promptTokensByKind, kind, input);
    }
    if (output != null) {
      completionTokens += output;
      _increment(completionTokensByKind, kind, output);
    }
    if (cached != null) {
      promptCacheReportedRequests++;
      cachedPromptTokens += cached;
    }
    if (reasoning != null) {
      reasoningReportedRequests++;
      reasoningTokens += reasoning;
    }
    if (input != null && output != null) usageReportedRequests++;
    if (total != null) {
      totalUsageReportedRequests++;
      reportedTotalTokens += total;
    }

    final reportedInput = max(input ?? 0, cached ?? 0);
    final reportedOutput = max(output ?? 0, reasoning ?? 0);
    if (total != null) {
      _recordCharge(kind, max(total, reportedInput + reportedOutput));
      return;
    }
    final chargedInput = input ?? max(estimate.input, reportedInput);
    final chargedOutput = output ?? max(estimate.output, reportedOutput);
    _recordCharge(
      kind,
      max(chargedInput, reportedInput) + max(chargedOutput, reportedOutput),
    );
    estimatedUnreportedTokens +=
        (input == null ? chargedInput - reportedInput : 0) +
        (output == null ? chargedOutput - reportedOutput : 0);
  }

  void _recordCharge(String kind, int count) {
    chargedTokensEstimate += count;
    _increment(chargedTokensEstimateByKind, kind, count);
  }

  static int? _tokenCount(Object? value) =>
      value is int && value >= 0 ? value : null;

  static void _increment(Map<String, int> map, String key, int count) {
    map.update(key, (value) => value + count, ifAbsent: () => count);
  }
}
