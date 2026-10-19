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
      var quote = normalize(value);
      if (source.contains(quote)) continue;
      // Models may wrap a verbatim excerpt in quotation delimiters which are
      // not part of the source passage. Remove at most one matching outer pair;
      // the enclosed text must still match verbatim, in order. Never normalize
      // internal punctuation, words, or numbers to manufacture evidence.
      const closingQuotes = {
        '"': '"',
        "'": "'",
        '“': '”',
        '‘': '’',
        '「': '」',
        '『': '』',
      };
      if (quote.length > 2 &&
          closingQuotes[quote[0]] == quote[quote.length - 1]) {
        quote = quote.substring(1, quote.length - 1).trim();
        if (quote.isEmpty) return false;
        if (source.contains(quote)) continue;
      }
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
