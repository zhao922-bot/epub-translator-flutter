import 'translation_consistency_checker.dart';
import 'semantic_risk_signals.dart';

/// Ground review in complete source units, not just a plausible draft.
/// Interpretations are model hypotheses; quoted source remains authoritative.
class SemanticSourceAnalysis {
  static List<String> senseTerms(String source) =>
      SemanticRiskSignals.senseTerms(source);
  static String normalize(String value) => SemanticRiskSignals.normalize(value);
  static List<String> focus(String source) => SemanticRiskSignals.focus(source);

  static List<Map<String, String>> units(String markup) {
    final text = TranslationConsistencyChecker.text(markup);
    final candidates = text
        .split(RegExp(r'(?<=[.!?;。！？；])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final pieces = <String>[];
    // Initials and common titles belong with the name that follows. A split
    // here would ask the reviewer to judge a fragment without its predicate.
    final abbreviation = RegExp(
      r'(?:\b[A-Z]|\b(?:Mr|Mrs|Ms|Dr|Prof|Gen|St|Jr|Sr))\.$',
    );
    for (final candidate in candidates) {
      if (pieces.isNotEmpty && abbreviation.hasMatch(pieces.last)) {
        pieces[pieces.length - 1] = '${pieces.last} $candidate';
      } else {
        pieces.add(candidate);
      }
    }
    // Keep every character even for unusually long paragraphs, while bounding
    // protocol overhead. The last unit may contain several sentences.
    if (pieces.length > 16) {
      final tail = pieces.sublist(15).join(' ');
      pieces.removeRange(15, pieces.length);
      pieces.add(tail);
    }
    return [
      for (var i = 0; i < pieces.length; i++)
        {
          'id': 'u$i',
          'source': pieces[i],
          'focus': focus(pieces[i]).join(','),
          if (senseTerms(pieces[i]).isNotEmpty)
            'senseTerms': senseTerms(pieces[i]).join(','),
        },
    ];
  }

  static List<Map<String, String>> validatePlan(
    Object? value,
    List<Map<String, String>> expected,
  ) {
    if (value is! List || value.length != expected.length) {
      throw const FormatException('Incomplete source analysis.');
    }
    final byId = <String, Map>{};
    for (final row in value) {
      if (row is! Map ||
          row['id'] is! String ||
          byId.containsKey(row['id']) ||
          row['meaning'] is! String ||
          (row['meaning'] as String).trim().isEmpty ||
          (row['meaning'] as String).length > 1200) {
        throw const FormatException('Invalid source analysis.');
      }
      byId[row['id'] as String] = row;
    }
    for (final unit in expected) {
      final row = byId[unit['id']];
      if (senseTerms(unit['source']!).any(
        (term) =>
            row?['sense'] is! String ||
            !(row!['sense'] as String).toLowerCase().contains(term),
      )) {
        throw const FormatException('Unresolved requested word sense.');
      }
      for (final key in focus(unit['source']!)) {
        final value = row?[key];
        if (value is! String ||
            value.trim().length < 8 ||
            value.length > 700 ||
            normalize(value).toLowerCase() ==
                normalize(unit['source']!).toLowerCase()) {
          throw const FormatException('Missing explicit meaning analysis.');
        }
      }
      if (focus(unit['source']!).contains('reference') &&
          !const {
            'singular',
            'plural',
            'mixed',
            'unknown',
          }.contains(row?['referenceNumber'])) {
        throw const FormatException('Missing reference number.');
      }
    }
    return [
      for (final unit in expected)
        {
          ...unit,
          'meaning':
              (byId[unit['id']]?['meaning'] as String?) ??
              (throw const FormatException('Missing source unit.')),
          for (final key in focus(unit['source']!))
            key: byId[unit['id']]![key] as String,
          if (focus(unit['source']!).contains('reference'))
            'referenceNumber': byId[unit['id']]!['referenceNumber'] as String,
        },
    ];
  }

  static List<Map<String, String>> validateCoverage(
    Object? value,
    List<Map<String, String>> plan,
    String draft, {
    required bool unchanged,
  }) {
    if (value is! List || value.length != plan.length) {
      throw const FormatException('Incomplete meaning coverage.');
    }
    final expected = plan.map((u) => u['id']).toSet();
    final seen = <String>{};
    final text = normalize(TranslationConsistencyChecker.text(draft));
    final result = <Map<String, String>>[];
    for (final row in value) {
      if (row is! Map ||
          row['id'] is! String ||
          !expected.contains(row['id']) ||
          !seen.add(row['id'] as String) ||
          !const {
            'equivalent',
            'mismatch',
            'missing',
            'uncertain',
          }.contains(row['verdict']) ||
          row['targetQuote'] is! String ||
          row['reason'] is! String ||
          (row['reason'] as String).trim().isEmpty ||
          (row['reason'] as String).length > 1200) {
        throw const FormatException('Invalid meaning coverage.');
      }
      final quote = normalize(row['targetQuote'] as String);
      final unit = plan.firstWhere((u) => u['id'] == row['id']);
      if (focus(unit['source']!).isNotEmpty &&
          (row['backMeaning'] is! String ||
              (row['backMeaning'] as String).trim().length < 8 ||
              (row['backMeaning'] as String).length > 1200)) {
        throw const FormatException('Missing independent draft meaning.');
      }
      if (unit.containsKey('referenceNumber')) {
        final number = row['referenceNumber'];
        final reference = row['referenceQuote'];
        if (!const {
              'singular',
              'plural',
              'mixed',
              'unknown',
            }.contains(number) ||
            reference is! String ||
            (reference.isNotEmpty && !quote.contains(reference)) ||
            (row['verdict'] == 'equivalent' &&
                (reference.isEmpty ||
                    (const {
                          'singular',
                          'plural',
                        }.contains(unit['referenceNumber']) &&
                        number != unit['referenceNumber'])))) {
          throw const FormatException('Contradictory reference coverage.');
        }
        if (number == 'singular' &&
            (RegExp(r'^(他们|她们|它们|他們|她們|它們)$').hasMatch(reference) ||
                (RegExp(r'^[他她它]$').hasMatch(reference) &&
                    !RegExp('$reference(?![们們])').hasMatch(quote)))) {
          throw const FormatException('Plural reference labelled singular.');
        }
      }
      if ((row['verdict'] == 'equivalent' && quote.isEmpty) ||
          (quote.isNotEmpty && !text.contains(quote)) ||
          (unchanged && row['verdict'] != 'equivalent')) {
        throw const FormatException('Unsupported unchanged meaning.');
      }
      result.add({
        for (final k in ['id', 'verdict', 'targetQuote', 'reason'])
          k: row[k] as String,
        for (final k in ['backMeaning', 'referenceNumber', 'referenceQuote'])
          if (row[k] is String) k: row[k] as String,
      });
    }
    return result;
  }
}
