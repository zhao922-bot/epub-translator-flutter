import 'epub_html_extractor.dart';

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
    final prose = _maskNonProse(html);
    if (!_containsCjk(prose)) {
      return html;
    }

    // Leave bibliography / endnote / index entries alone: the lock rule
    // (Chinese（English） first, Chinese after) only applies to translated
    // prose. Entries are conventionally rendered with the source-language
    // author name intact.
    if (_isBibliographicOrIndexEntry(prose)) {
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

  /// Applies [pattern] to the markup-masked copy of [html] and splices the
  /// [buildReplacement] results back into the original HTML at the same
  /// offsets (the mask is length-preserving, so match offsets stay valid).
  ///
  /// Capture-group slices are taken from the ORIGINAL [html], so text-flow
  /// markup between the matched parts is preserved exactly as before.
  /// Matches are impossible inside tag names or attribute values: those
  /// regions are fully masked, and neither gloss pattern can anchor there
  /// (the forward gloss needs a CJK character, the reverse gloss a Latin
  /// name start, and masked regions contain neither).
  static String _rewriteOnMaskedText(
    String html,
    RegExp pattern,
    String Function(String html, String masked, Match maskedMatch)
    buildReplacement,
  ) {
    final String masked = _maskHtmlMarkup(html);
    if (!pattern.hasMatch(masked)) {
      return html;
    }
    final StringBuffer output = StringBuffer();
    int cursor = 0;
    bool changed = false;
    for (final Match match in pattern.allMatches(masked)) {
      output
        ..write(html.substring(cursor, match.start))
        ..write(buildReplacement(html, masked, match));
      cursor = match.end;
      changed = true;
    }
    if (!changed) {
      return html;
    }
    output.write(html.substring(cursor));
    return output.toString();
  }

  /// Maps a [maskedText] slice -- taken from the masked copy at [maskedStart]
  /// -- back to the original HTML. The mask is length-preserving, so every
  /// maximal mask run maps 1:1 onto the original substring at the same
  /// offsets; everything else is copied through unchanged.
  static String _unmaskSlice(String html, String maskedText, int maskedStart) {
    final StringBuffer out = StringBuffer();
    int cursor = 0;
    final RegExp runs = RegExp(r'[\uE002\uE003]+');
    for (final Match run in runs.allMatches(maskedText)) {
      out.write(maskedText.substring(cursor, run.start));
      out.write(html.substring(maskedStart + run.start, maskedStart + run.end));
      cursor = run.end;
    }
    out.write(maskedText.substring(cursor));
    return out.toString();
  }

  /// Folds a half-width forward gloss `中文 (English)` to the canonical
  /// `中文（English）` shape BEFORE the bare-name state machine runs, so a
  /// model that emitted `亚当·斯密 (Adam Smith)` converges to the same
  /// full-width shape as everything else instead of being double-glossed.
  ///
  /// Runs on the markup-masked text: attribute values such as
  /// `alt="亚当 (Adam Smith) pic"` are metadata and are never canonicalized.
  static String _canonicalizeForwardHalfWidthGloss(
    String html,
    ProperNameMap mapping,
  ) {
    final String source = RegExp.escape(mapping.source);
    final RegExp pattern = RegExp(
      r'([\u3400-\u9FFF][^()（）]{0,24}?)\s*\(\s*' + source + r'\s*\)\s*',
    );
    return _rewriteOnMaskedText(html, pattern, (
      String original,
      String masked,
      Match match,
    ) {
      // Group 1 opens the match, so its masked offsets map 1:1 back onto
      // the original HTML.
      final String head = _unmaskSlice(
        original,
        match.group(1)!,
        match.start,
      ).trim();
      return '$head（${mapping.source}）';
    });
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
    final RegExp english = _tolerantNamePattern(mapping.source);
    // Match against a markup-masked copy: tag names and attribute values are
    // invisible to the pattern, so a locked `Li` can never rewrite `<li>`
    // into `<李（li）>` or corrupt `id="li-note"`. The mask is
    // length-preserving, so match offsets stay valid for splicing the
    // original HTML back together.
    final String masked = _maskHtmlMarkup(html);
    if (!english.hasMatch(masked)) {
      return html;
    }
    // Identifier spans (URLs, emails, footnote anchors, …) wrapped in
    // `\uE000…\uE001` are off-limits: the sentinel characters read as word
    // boundaries, so the boundary check alone cannot protect them — without
    // this skip a locked `Li` would rewrite `https://example.com/li`.
    final List<(int, int)> identifierSpans = _identifierSentinelSpans(masked);

    final StringBuffer output = StringBuffer();
    int cursor = 0;
    for (final Match match in english.allMatches(masked)) {
      if (_inSpans(identifierSpans, match.start, match.end)) {
        continue;
      }
      // "alliance" must not match a locked `Li`; "blacksmith" must not
      // match a locked `Smith`.
      if (!_hasNameWordBoundary(masked, match)) {
        continue;
      }
      final String raw = match.group(0)!;
      // A bare English name that sits inside an existing `中文（English）`
      // gloss (between an opening paren and its closing paren) is already
      // canonical and must not be re-glossed.
      if (_isCanonicalGlossInnerName(masked, match)) {
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

  /// Spans wrapped in `\uE000…\uE001` identifier sentinels inside [masked].
  /// Nesting (an email match inside an already-wrapped URL) collapses to
  /// the outermost span.
  static List<(int, int)> _identifierSentinelSpans(String masked) {
    final List<(int, int)> spans = <(int, int)>[];
    int depth = 0;
    int spanStart = 0;
    for (int i = 0; i < masked.length; i++) {
      final String char = masked[i];
      if (char == '\uE000') {
        if (depth == 0) {
          spanStart = i;
        }
        depth++;
      } else if (char == '\uE001' && depth > 0) {
        depth--;
        if (depth == 0) {
          spans.add((spanStart, i + 1));
        }
      }
    }
    return spans;
  }

  static bool _inSpans(List<(int, int)> spans, int start, int end) {
    for (final (int, int) span in spans) {
      if (start < span.$2 && end > span.$1) {
        return true;
      }
    }
    return false;
  }

  /// Masks every HTML tag with a same-length run of mask characters so the
  /// bare-name matcher can only ever see text content: tag names and
  /// attribute values become invisible to it.
  ///
  /// Empty tag pairs (`<span …></span>`, e.g. a pagebreak anchor) are masked
  /// with a distinct character (`\uE003`): the tolerant name matcher
  /// deliberately matches a name split by an empty inline tag, and the
  /// word-boundary check looks through the `\uE003` run — so
  /// `Adam<span></span>Smith` still matches while `Li<span></span>mited`
  /// no longer gains a fake word boundary.
  ///
  /// A `<` only starts markup when followed by a tag-name character, `!`
  /// (comment/doctype), `?` (processing instruction) or `/` (close tag):
  /// unescaped prose such as `Tom < Jerry > Spike` stays visible as text
  /// instead of being swallowed as a tag.
  ///
  /// The mask is length-preserving, so match offsets stay valid for
  /// splicing the original HTML back together.
  static String _maskHtmlMarkup(String html) {
    html = _maskNonProse(html);
    final StringBuffer out = StringBuffer();
    int cursor = 0;
    final RegExp markup = RegExp(
      r'</?[A-Za-z!?/][^>]*>\s*</[A-Za-z][^>]*>|</?[A-Za-z!?/][^>]*>',
    );
    for (final Match match in markup.allMatches(html)) {
      out.write(html.substring(cursor, match.start));
      final String tag = match.group(0)!;
      // An empty tag pair (open tag immediately followed by its close tag)
      // is transparent to the tolerant matcher; everything else is opaque.
      final bool isEmptyPair = RegExp(
        r'^</?[A-Za-z!?/][^>]*>\s*</[A-Za-z][^>]*>$',
      ).hasMatch(tag);
      out.write(isEmptyPair ? '\uE003' * tag.length : '\uE002' * tag.length);
      cursor = match.end;
    }
    out.write(html.substring(cursor));
    return out.toString();
  }

  /// Keep source-owned subtrees opaque to every glossary rewrite, without
  /// serializing the DOM or changing offsets in the original HTML.
  static String _maskNonProse(String html) {
    final tokens = RegExp(
      r'''<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<(/?)([A-Za-z][\w:.-]*)(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>''',
    );
    final out = StringBuffer();
    var cursor = 0;
    String? root;
    var depth = 0;
    var start = 0;
    for (final token in tokens.allMatches(html)) {
      final tag = token.group(2)?.toLowerCase();
      if (tag == null) continue;
      final closing = token.group(1) == '/';
      final selfClosing = token.group(0)!.endsWith('/>');
      if (root == null) {
        if (closing || !EpubHtmlExtractor.nonTextAncestors.contains(tag)) {
          continue;
        }
        out.write(html.substring(cursor, token.start));
        start = token.start;
        root = tag;
        depth = 1;
      } else if (tag == root) {
        if (closing) {
          depth--;
        } else if (!selfClosing && root != 'script' && root != 'style') {
          depth++;
        }
      }
      if (depth == 0 ||
          (start == token.start &&
              (selfClosing || const {'img', 'link', 'meta'}.contains(tag)))) {
        out.write('\uE002' * (token.end - start));
        cursor = token.end;
        root = null;
      }
    }
    if (root != null) {
      out.write('\uE002' * (html.length - start));
    } else {
      out.write(html.substring(cursor));
    }
    return out.toString();
  }

  /// Word-boundary check tuned for mixed CJK/Latin prose: a bare name must
  /// not be glued to ASCII letters, digits or `_` on either side, so a
  /// locked `Li` never fires inside "alliance" and a locked `Smith` never
  /// fires inside "blacksmith". CJK characters, punctuation, whitespace,
  /// the opaque mask (`\uE002`) and the identifier sentinels all count as
  /// boundaries; the empty-tag mask (`\uE003`) is transparent and looked
  /// through, so `Li<span></span>mited` is seen as the glued word it is.
  static bool _hasNameWordBoundary(String masked, Match match) {
    bool isWordChar(String char) => RegExp(r'[A-Za-z0-9_]').hasMatch(char);
    int start = match.start;
    while (start > 0 && masked[start - 1] == '\uE003') {
      start--;
    }
    int end = match.end;
    while (end < masked.length && masked[end] == '\uE003') {
      end++;
    }
    if (start > 0 && isWordChar(masked[start - 1])) {
      return false;
    }
    if (end < masked.length && isWordChar(masked[end])) {
      return false;
    }
    return true;
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
    // The empty-tag mask character (\uE003) is transparent to the matcher,
    // just like whitespace: a pagebreak anchor between name tokens must not
    // break the match.
    final String gap =
        r'[\s\u00A0\uE003]*(?:' + emptyTagPair + r')?[\s\u00A0\uE003]*';
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
        .replaceAll(RegExp(r'[\uE002\uE003]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Whether [match] spans an English name that is embedded inside an
  /// already-canonical `中文（English）` gloss — a full-width paren pair that
  /// is the shape we emit. A half-width `(English)` pair is NOT canonical: it
  /// must be folded to full-width so the whole book converges on one shape.
  ///
  /// Both parens must be present: an unmatched `）` (or `（`) is ordinary
  /// prose punctuation, not a gloss, and the name next to it still needs
  /// its first-occurrence annotation.
  static bool _isCanonicalGlossInnerName(String html, Match match) {
    final bool precededByOpen = RegExp(
      r'[（]\s*$',
    ).hasMatch(html.substring(0, match.start));
    final bool followedByClose = RegExp(
      r'^\s*[）]',
    ).hasMatch(html.substring(match.end));
    return precededByOpen && followedByClose;
  }

  /// Rewrites `English（中文）` → `中文（English）` across the block before the
  /// bare-name state machine runs, so the trailing parenthetical never
  /// survives and the same name cannot be re-matched twice.
  ///
  /// Runs on the markup-masked text: attribute values such as
  /// `title="Adam Smith（亚当）"` are metadata and are never canonicalized.
  static String _canonicalizeReverseGlosses(
    String html,
    ProperNameMap mapping,
  ) {
    final String source = RegExp.escape(mapping.source);
    final String pattern =
        r'(\b'
        '$source'
        r')\s*[（(]\s*'
        r'([^()（）]{1,40}?[\u3400-\u9FFF][^()（）]{0,24}?)\s*[)）]';
    final RegExp reverse = RegExp(pattern, caseSensitive: false);
    return _rewriteOnMaskedText(html, reverse, (
      String original,
      String masked,
      Match match,
    ) {
      final String name = _unmaskSlice(original, match.group(1)!, match.start);
      // Group 2 follows `name` + `\\s*[（(]\\s*`; locate it in the masked
      // copy so its offsets map 1:1 back onto the original HTML.
      final int afterName = match.start + match.group(1)!.length;
      final Match? separator = RegExp(
        r'\s*[（(]\s*',
      ).matchAsPrefix(masked, afterName);
      final int group2Start = separator?.end ?? afterName;
      final String translated = _unmaskSlice(
        original,
        match.group(2)!,
        group2Start,
      ).trim();
      return '$translated（$name）';
    });
  }

  /// Guesses the bracket style already used by the surrounding block so the
  /// normalizer stays visually consistent.
  static String _preferredBracket(String html) {
    // We always emit full-width parens; the model already prefers them, and
    // the residual checker treats half-width inside CJK as fine, but
    // normalizing everything to full-width gives a single consistent look.
    return 'full';
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
    return RegExp(r'[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF]').hasMatch(text);
  }

  /// Wraps Latin identifiers (URLs / email / footnote anchors / work-title
  /// glosses) in sentinels so the name substitution cannot corrupt them.
  static String _prefixAndSuffixLatinIdentifiers(String html) {
    // Protect footnote-back link anchors: <a ...>II</a> etc. Those are pure
    // anchor text and must not be treated as a name occurrence.
    String out = html.replaceAllMapped(
      RegExp(r'<a\b[^>]*>[^<]{0,12}</a>', caseSensitive: false),
      (Match match) => '\uE000${_protect(match.group(0)!)}\uE001',
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
    // Email addresses: the local part is a Latin identifier that must not
    // be rewritten even when it equals a locked name (`li@example.com`
    // with `Li` locked).
    out = out.replaceAllMapped(
      RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
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
