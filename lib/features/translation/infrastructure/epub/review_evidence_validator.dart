/// Validate each verbatim fragment of an explicitly abbreviated quotation.
/// Ellipses may omit text, but may never hide an invented or reordered fragment.
class ReviewEvidenceValidator {
  static String normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool supports(Object? quotes, String evidence) {
    final values = quotes is String ? [quotes] : quotes;
    if (values is! List || values.isEmpty || values.length > 8) return false;
    final source = normalize(evidence);
    for (final value in values) {
      if (value is! String || value.trim().isEmpty || value.length > 4000) {
        return false;
      }
      final quote = normalize(value);
      if (source.contains(quote)) continue;
      final fragments = quote.split(RegExp(r'\s+(?:\.{3}|…)\s+'));
      if (fragments.length < 2 || fragments.any((s) => s.trim().length < 12)) {
        return false;
      }
      var cursor = 0;
      for (final fragment in fragments) {
        final at = source.indexOf(fragment, cursor);
        if (at < 0) return false;
        cursor = at + fragment.length;
      }
    }
    return true;
  }
}
