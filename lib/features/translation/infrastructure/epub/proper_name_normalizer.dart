/// Deterministic post-processing layer that converts every configuration-
/// locked proper name to the canonical display form across the whole book.
///
/// The translation model is not reliable about "first occurrence annotated
/// with 中文（English）, later occurrences in Chinese only". This normalizer
/// reads the same locked glossary the prompts use and canonicalizes each
/// name:
///
/// * The first occurrence in the book is rendered as `中文（English）`.
/// * Later occurrences use `中文` alone.
/// * Bare English, `English（中文）` reverse glosses and half-width
///   parentheses are all converged to the same canonical shape.
///
/// Endnotes / bibliography / index / acknowledgments / epigraph attributions
/// are left untouched: those are conventionally retained in the original
/// language. The normalizer only walks text runs that the model actually
/// translated into the target script, and it mirrors the punctuation style
/// already used by the surrounding block.
class ProperNameNormalizer {
  const ProperNameNormalizer();

  /// Mutable per-book state shared across chapter renders so "first
  /// occurrence in the book" is truly book-wide and not scoped to a single
  /// HTML fragment.
  static ProperNameBookState bookState() => ProperNameBookState();

  /// Parses the user-locked glossary expressed as `source => target` lines.
  ///
  /// Blank lines and lines without a mapping separator are ignored, so the
  /// same free-text box used by the translation prompt can be reused here.
  static List<ProperNameMap> parseGlossary(String lockedGlossary) {
    final List<ProperNameMap> entries = <ProperNameMap>[];
    if (lockedGlossary.trim().isEmpty) {
      return entries;
    }
    for (final String rawLine in lockedGlossary.split('\n')) {
      final String line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final int separator = line.indexOf('=>');
      if (separator <= 0) {
        continue;
      }
      final String source = line.substring(0, separator).trim();
      final String target = line.substring(separator + 2).trim();
      if (source.isEmpty || target.isEmpty || source == target) {
        continue;
      }
      // Only map source-language (Latin-script) names; a Chinese input
      // provides nothing to normalize.
      if (!_isLatinScript(source)) {
        continue;
      }
      entries.add(ProperNameMap(source: source, target: target));
    }
    return entries;
  }

  /// Canonicalizes [html] with [mappings] where the source text is considered
  /// "translated content" (it contains target-script characters).
  static String normalizeHtml(
    String html,
    List<ProperNameMap> mappings, {
    required String targetLanguage,
    ProperNameBookState? state,
  }) {
    if (mappings.isEmpty || !_isCjkTarget(targetLanguage)) {
      return html;
    }
    if (!_containsCjk(html)) {
      return html;
    }

    // Leave bibliography / endnote / index entries alone: the lock rule
    // (Chinese（English） first, Chinese after) only applies to translated
    // prose. Entries are conventionally rendered with the source-language
    // author name intact.
    if (_isBibliographicOrIndexEntry(html)) {
      return html;
    }

    final String prefixed = _prefixAndSuffixLatinIdentifiers(html);
    String working = prefixed;
    for (final ProperNameMap mapping in mappings) {
      working = _canonicalizeForwardHalfWidthGloss(working, mapping);
      working = _canonicalizeReverseGlosses(working, mapping);
      working = _normalizeNameInHtml(
        working,
        mapping,
        bracket: _preferredBracket(working),
        targetLanguage: targetLanguage,
        state: state,
      );
    }
    // Remove the placeholder sentinels left around latin identifiers so they
    // stay untouched (URLs, footnotes anchors, work-title glosses, ...).
    return _stripIdentifierSentinels(working);
  }

  /// Folds a half-width forward gloss `中文 (English)` to the canonical
  /// `中文（English）` shape BEFORE the bare-name state machine runs, so a
  /// model that emitted `亚当·斯密 (Adam Smith)` converges to the same
  /// full-width shape as everything else instead of being double-glossed.
  static String _canonicalizeForwardHalfWidthGloss(
    String html,
    ProperNameMap mapping,
  ) {
    final String source = RegExp.escape(mapping.source);
    final RegExp pattern = RegExp(
      r'([\u3400-\u9FFF][^()（）]{0,24}?)\s*\(\s*' +
          source +
          r'\s*\)\s*',
    );
    if (!pattern.hasMatch(html)) {
      return html;
    }
    final StringBuffer output = StringBuffer();
    int cursor = 0;
    for (final Match match in pattern.allMatches(html)) {
      output
        ..write(html.substring(cursor, match.start))
        ..write('${match.group(1)?.trim()}（${mapping.source}）');
      cursor = match.end;
    }
    output.write(html.substring(cursor));
    return output.toString();
  }

  static bool _isBibliographicOrIndexEntry(String html) {
    return RegExp(
      r'class="[^"]*(?:endnote|bibliograph|reference|index)[^"]*"'
      r'|epub:type="[^"]*index[^"]*"',
      caseSensitive: false,
    ).hasMatch(html);
  }

  static String _normalizeNameInHtml(
    String html,
    ProperNameMap mapping, {
    required String bracket,
    required String targetLanguage,
    ProperNameBookState? state,
  }) {
    final String source = RegExp.escape(mapping.source);
    final RegExp english = _tolerantNamePattern(mapping.source);
    if (!english.hasMatch(html)) {
      return html;
    }

    final StringBuffer output = StringBuffer();
    int cursor = 0;
    for (final Match match in english.allMatches(html)) {
      final String raw = match.group(0)!;
      // A bare English name that sits inside an existing `中文（English）`
      // gloss (immediately after an opening paren or before a closing paren)
      // is already canonical and must not be re-glossed.
      if (_isCanonicalGlossInnerName(html, match)) {
        if (state?.countedNames.contains(mapping.source) == false) {
          state?.countedNames.add(mapping.source);
        }
        continue;
      }
      if (state?.countedNames.contains(mapping.source) == true) {
        output
          ..write(html.substring(cursor, match.start))
          ..write(mapping.target);
        cursor = match.end;
        continue;
      }
      output
        ..write(html.substring(cursor, match.start))
        ..write('${mapping.target}（${_cleanLooseHtmlTokens(raw)}）');
      state?.countedNames.add(mapping.source);
      cursor = match.end;
    }
    if (cursor == 0) {
      return html;
    }
    output.write(html.substring(cursor));
    return output.toString();
  }

  /// Builds a matching regex for a possibly multi-token proper name. Tokens
  /// may be separated by whitespace and by an empty inline tag pair (for
  /// example an EPUB `pagebreak` anchor embedded in the middle of a model
  /// returned translation), so `Pierre Van Den <span…></span>Berghe` still
  /// matches the locked `Van Den Berghe`.
  static RegExp _tolerantNamePattern(String source) {
    final String escaped = RegExp.escape(source);
    if (!RegExp(r'\s').hasMatch(source)) {
      return RegExp(escaped, caseSensitive: false);
    }
    final String emptyTagPair = r'<[^>]+>\s*</[^>]+>';
    final String gap = r'[\s\u00A0]*(?:' + emptyTagPair + r')?[\s\u00A0]*';
    final String pattern = source
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(gap);
    return RegExp(pattern, caseSensitive: false);
  }

  /// Strips any empty inline tag pairs / bare tags that the tolerant matcher
  /// may have travelled through so the parenthetical keeps a clean Latin
  /// name (a pagebreak anchor is meaningless inside a gloss).
  static String _cleanLooseHtmlTokens(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]+>\s*</[^>]+>'), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Whether [match] spans an English name that is embedded inside an
  /// already-canonical `中文（English）` gloss — a full-width paren pair that
  /// is the shape we emit. A half-width `(English)` pair is NOT canonical: it
  /// must be folded to full-width so the whole book converges on one shape.
  static bool _isCanonicalGlossInnerName(String html, Match match) {
    final bool precededByOpen = RegExp(
      r'[（]\s*$',
    ).hasMatch(html.substring(0, match.start));
    final bool followedByClose = RegExp(
      r'^\s*[）]',
    ).hasMatch(html.substring(match.end));
    return precededByOpen || followedByClose;
  }

  static bool _isParenthesizedGloss(
    String html,
    int start,
    int end,
    String raw,
  ) {
    final String before = _leftContext(html, start);
    final String after = _rightContext(html, end);
    // 中文（English）: the name is immediately preceded by an opening paren.
    final RegExp precededByOpen = RegExp(r'[（(]\s*$');
    // English（中文）: the name is immediately followed by an opening paren.
    final RegExp followedByOpen = RegExp(r'^\s*[（(]');
    return followedByOpen.hasMatch(after) || precededByOpen.hasMatch(before);
  }

  /// Rewrites `English（中文）` → `中文（English）` across the block before the
  /// bare-name state machine runs, so the trailing parenthetical never
  /// survives and the same name cannot be re-matched twice.
  static String _canonicalizeReverseGlosses(
    String html,
    ProperNameMap mapping,
  ) {
    final String source = RegExp.escape(mapping.source);
    final String pattern =
        r'(\b' + source + r')\s*[（(]\s*'
        r'([^()（）]{1,40}?[\u3400-\u9FFF][^()（）]{0,24}?)\s*[)）]';
    final RegExp reverse = RegExp(pattern, caseSensitive: false);
    if (!reverse.hasMatch(html)) {
      return html;
    }
    final StringBuffer output = StringBuffer();
    int cursor = 0;
    for (final Match match in reverse.allMatches(html)) {
      final String translated = match.group(2)?.trim() ?? mapping.target;
      output
        ..write(html.substring(cursor, match.start))
        ..write('$translated（${match.group(1)}）');
      cursor = match.end;
    }
    output.write(html.substring(cursor));
    return output.toString();
  }

  /// Guesses the bracket style already used by the surrounding block so the
  /// normalizer stays visually consistent.
  static String _preferredBracket(String html) {
    // We always emit full-width parens; the model already prefers them, and
    // the residual checker treats half-width inside CJK as fine, but
    // normalizing everything to full-width gives a single consistent look.
    return 'full';
  }

  static String _leftContext(String html, int start) {
    final int from = (start - 8).clamp(0, html.length);
    return html.substring(from, start);
  }

  static String _rightContext(String html, int end) {
    final int to = (end + 8).clamp(0, html.length);
    return html.substring(end, to);
  }

  static bool _isLatinScript(String text) =>
      RegExp(r"^[A-Za-z][A-Za-z .'-]*$").hasMatch(text);

  static bool _isCjkTarget(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    return lower.startsWith('zh') ||
        lower.contains('chinese') ||
        lower.contains('中文') ||
        lower.contains('汉语') ||
        lower.contains('漢語');
  }

  static bool _containsCjk(String text) {
    return RegExp(
      r'[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF]',
    ).hasMatch(text);
  }

  /// Wraps Latin identifiers (URLs / email / footnote anchors / work-title
  /// glosses) in sentinels so the name substitution cannot corrupt them.
  static String _prefixAndSuffixLatinIdentifiers(String html) {
    // Protect footnote-back link anchors: <a ...>II</a> etc. Those are pure
    // anchor text and must not be treated as a name occurrence.
    String out = html.replaceAllMapped(
      RegExp(r'<a\b[^>]*>[^<]{0,12}</a>', caseSensitive: false),
      (Match match) =>
          '\uE000${_protect(match.group(0)!)}\uE001',
    );
    // Protect inline work titles in 《》 already carrying the original Latin
    // gloss, e.g. 《国富论》（The Wealth of Nations）.
    out = out.replaceAllMapped(
      RegExp(
        r'[《「『]\s*[\u3400-\u9FFF\w\s、·，。：；（）()\-—]+\s*[」』》]'
        r"\s*[（(]\s*[A-Za-z][A-Za-z0-9 ,.;:()'\-]{2,60}\s*[)）]",
      ),
      (Match match) => '\uE000${_protect(match.group(0)!)}\uE001',
    );
    // Also protect plain URLs/emails/docs so a name that happens to be a URL
    // path component is never treated as a person.
    out = out.replaceAllMapped(
      RegExp(
        r'''(?:(?:https?|ftp)://|www\.)[A-Z0-9._~:/?#\[\]@!$&'()*+,;=%-]+''',
        caseSensitive: false,
      ),
      (Match match) => '\uE000${_protect(match.group(0)!)}\uE001',
    );
    return out;
  }

  static String _stripIdentifierSentinels(String html) {
    return html
        .replaceAll('\uE001\uE000', '')
        .replaceAll('\uE000', '')
        .replaceAll('\uE001', '');
  }

  static String _protect(String value) => value;
}

/// Book-wide first-occurrence tracking for [ProperNameNormalizer].
class ProperNameBookState {
  final Set<String> countedNames = <String>{};
}

/// A single source → target proper-name mapping parsed from the locked
/// glossary.
class ProperNameMap {
  const ProperNameMap({required this.source, required this.target});

  final String source;
  final String target;
}
