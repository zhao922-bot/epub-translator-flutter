/// Shared source-language signals for review selection and meaning analysis.
/// These indicate uncertainty to inspect, never a confirmed translation error.
class SemanticRiskSignals {
  static List<String> senseTerms(String source) => RegExp(
    r'\b(manager|observer|coach|senator|charge|pitch|court|office|rules)\b',
    caseSensitive: false,
  ).allMatches(source).map((m) => m[0]!.toLowerCase()).toSet().toList();
  static String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static List<String> focus(String source) => [
    if (RegExp(
      r'\b(he|him|his|she|her|they|them|their)\b',
      caseSensitive: false,
    ).hasMatch(source))
      'reference',
    if (RegExp(
      r'\b(not|never|ever|any|anything|always|all|none|nobody|without|less|more)\b|n[’\x27]t\b',
      caseSensitive: false,
    ).hasMatch(source))
      'scope',
    if (RegExp(
      r'\b(tried|trying|attempt|attempted|barely|almost|nearly|would|could|hoped|expected)\b|\bwent\b.{0,30}\bfor\b',
      caseSensitive: false,
    ).hasMatch(source))
      'outcome',
    if (RegExp(
          r'\b(manager|observer|coach|senator|charge|pitch|court|office|rules)\b',
          caseSensitive: false,
        ).hasMatch(source) ||
        RegExp('[“”"「」]').hasMatch(source))
      'sense',
    if (RegExp(r'[,—–()]').hasMatch(source)) 'embedded',
  ];
}
