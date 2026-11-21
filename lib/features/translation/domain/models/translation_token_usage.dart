import 'dart:math';

/// User-facing view of cumulative accounting. Provider usage and conservative
/// charges for unreported physical requests stay distinct throughout.
class TranslationTokenUsage {
  const TranslationTokenUsage(this.values);

  final Map<String, Object> values;

  TranslationTokenUsage get cumulative {
    final snapshot = values['cumulativeUsage'];
    return snapshot is Map<String, Object>
        ? TranslationTokenUsage(snapshot)
        : this;
  }

  int count(String key) {
    final value = values[key];
    return value is int && value >= 0 ? value : 0;
  }

  int get requests => count('requests');
  int get reportedRequests => min(requests, count('usageReportedRequests'));
  int get totalReportedRequests =>
      min(requests, count('totalUsageReportedRequests'));
  int get incompleteUsageRequests => max(0, requests - reportedRequests);
  int get promptTokens => count('promptTokens');
  int get completionTokens => count('completionTokens');
  int get reportedTokens => promptTokens + completionTokens;
  int get estimatedUnreportedTokens => count('estimatedUnreportedTokens');
  int get accountedTokens => values.containsKey('chargedTokensEstimate')
      ? count('chargedTokensEstimate')
      : reportedTokens + estimatedUnreportedTokens;
  int get priorAccountedTokens =>
      min(accountedTokens, count('priorChargedTokensEstimate'));
  int get maxBookTokens => count('maxBookTokens');
  int get nextRequestTokens => count('nextRequestEstimatedTokens');
  bool get hasCachedPromptUsage =>
      count('promptCacheReportedRequests') > 0 ||
      count('cachedPromptTokens') > 0;
  bool get hasReasoningUsage =>
      count('reasoningReportedRequests') > 0 || count('reasoningTokens') > 0;

  int get minimumSuggestedBudget => accountedTokens + max(1, nextRequestTokens);

  Map<String, int> countsByKind(String key) {
    final value = values[key];
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String &&
            entry.value is int &&
            (entry.value as int) >= 0)
          entry.key as String: entry.value as int,
    };
  }
}
