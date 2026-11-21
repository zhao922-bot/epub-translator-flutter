/// Orchestration must stop without substituting a fallback translation.
sealed class TranslationBookBudgetException implements Exception {
  const TranslationBookBudgetException();
}

/// A whole-book run cannot afford another physical API attempt.
class TranslationBudgetPausedException extends TranslationBookBudgetException {
  const TranslationBudgetPausedException(this.apiUsage);

  final Map<String, Object> apiUsage;

  int get maxBookTokens => apiUsage['maxBookTokens'] as int;
  int get nextRequestEstimatedTokens =>
      apiUsage['nextRequestEstimatedTokens'] as int;
}

class TranslationBudgetAccountingException
    extends TranslationBookBudgetException {
  const TranslationBudgetAccountingException({this.inUse = false});

  final bool inUse;

  @override
  String toString() => inUse
      ? 'Another run is recording API usage for this EPUB. Try again after it stops.'
      : 'API usage for this EPUB could not be read or saved.';
}
