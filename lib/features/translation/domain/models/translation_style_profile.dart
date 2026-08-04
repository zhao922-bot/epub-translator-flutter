/// Compact, executable translation-style constraints inferred before a run.
///
/// Richer than a single genre label: prompts should prefer
/// [translationConstraints]/[avoid], with [confidence] gating injection.
class TranslationStyleProfile {
  const TranslationStyleProfile({
    this.primaryGenre = '',
    this.secondaryGenres = const <String>[],
    this.tone = '',
    this.sentenceStyle = '',
    this.translationConstraints = const <String>[],
    this.avoid = const <String>[],
    this.confidence = TranslationStyleConfidence.low,
  });

  static const TranslationStyleProfile empty = TranslationStyleProfile();

  factory TranslationStyleProfile.fromJson(Map<String, Object?> json) {
    return TranslationStyleProfile(
      primaryGenre: _stringValue(json['primaryGenre']),
      secondaryGenres: _stringList(json['secondaryGenres'], limit: 4),
      tone: _stringValue(json['tone']),
      sentenceStyle: _stringValue(json['sentenceStyle']),
      translationConstraints: _stringList(
        json['translationConstraints'],
        limit: 8,
      ),
      avoid: _stringList(json['avoid'], limit: 6),
      confidence: TranslationStyleConfidenceParsing.parse(json['confidence']),
    );
  }

  final String primaryGenre;
  final List<String> secondaryGenres;
  final String tone;
  final String sentenceStyle;
  final List<String> translationConstraints;
  final List<String> avoid;
  final TranslationStyleConfidence confidence;

  bool get isEmpty =>
      primaryGenre.isEmpty &&
      secondaryGenres.isEmpty &&
      tone.isEmpty &&
      sentenceStyle.isEmpty &&
      translationConstraints.isEmpty &&
      avoid.isEmpty;

  /// Auto-inferred profiles inject only when confidence is medium/high.
  bool get shouldInject =>
      !isEmpty && confidence != TranslationStyleConfidence.low;

  /// User-confirmed/edited profiles inject whenever non-empty.
  bool get shouldInjectWhenConfirmed => !isEmpty;

  TranslationStyleProfile copyWith({
    String? primaryGenre,
    List<String>? secondaryGenres,
    String? tone,
    String? sentenceStyle,
    List<String>? translationConstraints,
    List<String>? avoid,
    TranslationStyleConfidence? confidence,
  }) {
    return TranslationStyleProfile(
      primaryGenre: primaryGenre ?? this.primaryGenre,
      secondaryGenres: secondaryGenres ?? this.secondaryGenres,
      tone: tone ?? this.tone,
      sentenceStyle: sentenceStyle ?? this.sentenceStyle,
      translationConstraints:
          translationConstraints ?? this.translationConstraints,
      avoid: avoid ?? this.avoid,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (primaryGenre.isNotEmpty) 'primaryGenre': primaryGenre,
      if (secondaryGenres.isNotEmpty) 'secondaryGenres': secondaryGenres,
      if (tone.isNotEmpty) 'tone': tone,
      if (sentenceStyle.isNotEmpty) 'sentenceStyle': sentenceStyle,
      if (translationConstraints.isNotEmpty)
        'translationConstraints': translationConstraints,
      if (avoid.isNotEmpty) 'avoid': avoid,
      'confidence': confidence.name,
    };
  }

  /// Prompt fragment for auto-inferred profiles (confidence-gated).
  String toPromptInstruction({required String targetLanguage}) {
    if (!shouldInject) {
      return '';
    }
    return forTargetLanguage(targetLanguage)._buildInstruction(
      targetLanguage: targetLanguage,
      confirmed: false,
    );
  }

  /// Prompt fragment for a user-confirmed/edited profile.
  String toConfirmedPromptInstruction({required String targetLanguage}) {
    if (!shouldInjectWhenConfirmed) {
      return '';
    }
    return forTargetLanguage(targetLanguage)._buildInstruction(
      targetLanguage: targetLanguage,
      confirmed: true,
    );
  }

  /// Returns a profile safe to inject for [targetLanguage].
  ///
  /// For non-English targets, rules that tell the model to keep whole English
  /// quotations/dialogue intact are removed and replaced with an explicit
  /// "translate quoted prose" constraint. Proper names, work titles, URLs and
  /// short technical terms remain allowed.
  TranslationStyleProfile forTargetLanguage(String targetLanguage) {
    if (!_requiresTranslatedQuotedProse(targetLanguage)) {
      return this;
    }

    final List<String> safeConstraints = translationConstraints
        .where((String rule) => !_retainsSourceLanguageQuotedProse(rule))
        .toList(growable: true);
    final List<String> safeAvoid = avoid
        .where((String rule) => !_retainsSourceLanguageQuotedProse(rule))
        .toList(growable: false);

    final bool needsQuoteTranslationRule = translationConstraints.any(
          _retainsSourceLanguageQuotedProse,
        ) ||
        avoid.any(_retainsSourceLanguageQuotedProse);
    if (needsQuoteTranslationRule) {
      final String quoteRule =
          'Quoted prose, dialogue, and epigraphs must be translated into '
          '${targetLanguage.trim()}; keep only proper names, work titles, '
          'URLs, and short technical terms in the source language';
      if (!safeConstraints.any(
        (String rule) => rule.toLowerCase().contains('quoted prose, dialogue'),
      )) {
        safeConstraints.insert(0, quoteRule);
      }
    }

    return copyWith(
      translationConstraints: safeConstraints.take(8).toList(growable: false),
      avoid: safeAvoid.take(6).toList(growable: false),
    );
  }

  String _buildInstruction({
    required String targetLanguage,
    required bool confirmed,
  }) {
    final TranslationStyleProfile safeProfile = forTargetLanguage(
      targetLanguage,
    );
    final List<String> parts = <String>[
      if (primaryGenre.isNotEmpty) 'Genre: $primaryGenre',
      if (secondaryGenres.isNotEmpty)
        'Secondary: ${secondaryGenres.join(', ')}',
      if (tone.isNotEmpty) 'Tone: $tone',
      if (sentenceStyle.isNotEmpty) 'Sentence style: $sentenceStyle',
      if (safeProfile.translationConstraints.isNotEmpty)
        'Do: ${safeProfile.translationConstraints.join('; ')}',
      if (safeProfile.avoid.isNotEmpty)
        'Avoid: ${safeProfile.avoid.join('; ')}',
    ];
    if (parts.isEmpty) {
      return '';
    }
    final String prefix = confirmed
        ? ' Apply this user-confirmed book style profile while translating into $targetLanguage. '
        : ' Apply this book style profile while translating into $targetLanguage. ';
    return '$prefix'
        'Treat it as soft constraints: preserve meaning and HTML structure first, '
        'never invent plot/facts, and do not force genre cliches. '
        '${parts.join(' | ')}.';
  }

  String get summaryLabel {
    if (isEmpty) {
      return '';
    }
    final String genre = primaryGenre.isEmpty ? 'unknown' : primaryGenre;
    return '$genre (${confidence.name})';
  }

  bool sameContentAs(TranslationStyleProfile other) {
    return primaryGenre == other.primaryGenre &&
        _listEquals(secondaryGenres, other.secondaryGenres) &&
        tone == other.tone &&
        sentenceStyle == other.sentenceStyle &&
        _listEquals(translationConstraints, other.translationConstraints) &&
        _listEquals(avoid, other.avoid) &&
        confidence == other.confidence;
  }

  static bool _listEquals(List<String> left, List<String> right) {
    if (identical(left, right)) {
      return true;
    }
    if (left.length != right.length) {
      return false;
    }
    for (int index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  static String _stringValue(Object? value) {
    if (value is String) {
      return value.trim();
    }
    if (value == null) {
      return '';
    }
    // Coerce numbers/bools so model drift does not drop the whole profile.
    return value.toString().trim();
  }

  static List<String> _stringList(Object? value, {required int limit}) {
    if (value is String) {
      final String trimmed = value.trim();
      if (trimmed.isEmpty) {
        return const <String>[];
      }
      // Accept single string or semicolon/newline separated constraints.
      final List<String> parts = trimmed
          .split(RegExp(r'[\n;|]'))
          .map((String item) => item.trim())
          .where((String item) => item.isNotEmpty)
          .take(limit)
          .toList(growable: false);
      return parts.isEmpty ? <String>[trimmed] : parts;
    }
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map<String>((dynamic item) => _stringValue(item))
        .where((String item) => item.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }

  static bool _requiresTranslatedQuotedProse(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    if (lower.isEmpty) {
      return false;
    }
    if (RegExp(r'^(en|eng|english)([-_\s].*)?$').hasMatch(lower)) {
      return false;
    }
    if (lower.contains('english') &&
        !lower.contains('chinese') &&
        !lower.contains('中文') &&
        !lower.contains('japanese') &&
        !lower.contains('korean')) {
      return false;
    }
    return true;
  }

  static bool _retainsSourceLanguageQuotedProse(String rule) {
    final String lower = rule.trim().toLowerCase();
    if (lower.isEmpty) {
      return false;
    }

    final bool mentionsQuotedMaterial = RegExp(
      r'\b(quote|quotes|quoted|quotation|quotations|epigraph|epigraphs|dialogue|dialog)\b',
    ).hasMatch(lower);
    final bool mentionsEnglish = RegExp(r'\benglish\b').hasMatch(lower);
    final bool retainsSourceLanguage = RegExp(
      r'\b(keep|preserve|retain|leave)\b',
    ).hasMatch(lower);

    if (mentionsQuotedMaterial && mentionsEnglish && retainsSourceLanguage) {
      return true;
    }
    if (mentionsQuotedMaterial &&
        RegExp(
          r'(in english|original english|english with .+ attribution|keep .+ english|preserve .+ english)',
        ).hasMatch(lower)) {
      return true;
    }
    if (RegExp(
      r'(keep|preserve|retain).{0,40}(dialogue|dialog|quotation|quote|epigraph).{0,20}(english|source language)',
    ).hasMatch(lower)) {
      return true;
    }
    return false;
  }
}

enum TranslationStyleConfidence { high, medium, low }

class TranslationStyleConfidenceParsing {
  static TranslationStyleConfidence parse(Object? value) {
    final String raw = value is String ? value.trim().toLowerCase() : '';
    return switch (raw) {
      'high' => TranslationStyleConfidence.high,
      'medium' => TranslationStyleConfidence.medium,
      'med' => TranslationStyleConfidence.medium,
      'low' => TranslationStyleConfidence.low,
      _ => TranslationStyleConfidence.low,
    };
  }
}
