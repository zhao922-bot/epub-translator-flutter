import 'quality_residual_models.dart';

/// Core text-level residual and locked-glossary detection routines.
class QualityResidualDetector {
  const QualityResidualDetector._();

  static const int lockedTermRulesCacheLimit = 8;
  static final Map<String, List<RegExp>> lockedTermRulesCache = {};

  static String stripLockedTerms(String text, String glossary) {
    if (glossary.trim().isEmpty) return text;
    for (final rule in lockedTermRules(glossary)) {
      text = text.replaceAll(rule, ' ');
    }
    return text;
  }

  static List<RegExp> lockedTermRules(String glossary) {
    final cached = lockedTermRulesCache[glossary];
    if (cached != null) return cached;
    final terms = <String>{};
    for (final line in glossary.split('\n')) {
      // The prompt accepts free text; only explicit, nonempty mappings grant
      // an exemption. Support the => and = forms used by existing configs.
      final separator = RegExp(r'=>|=').firstMatch(line);
      if (separator == null) continue;
      final source = line.substring(0, separator.start).trim();
      final target = line.substring(separator.end).trim();
      if (source.isNotEmpty && target.isNotEmpty) terms.add(source);
    }
    final ordered = terms.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final rules = List<RegExp>.unmodifiable([
      for (final term in ordered)
        RegExp(
          '(?<![A-Za-z0-9_\u00C0-\u02AF\u0300-\u036F])'
          '${RegExp.escape(term)}'
          '(?![A-Za-z0-9_\u00C0-\u02AF\u0300-\u036F])',
          unicode: true,
        ),
    ]);
    // Insertion-ordered, bounded cache: discard the oldest glossary when
    // settings change rather than rebuilding these rules for every node.
    if (lockedTermRulesCache.length >= lockedTermRulesCacheLimit) {
      lockedTermRulesCache.remove(lockedTermRulesCache.keys.first);
    }
    lockedTermRulesCache[glossary] = rules;
    return rules;
  }

  static String stripLockedTermsForTest(String text, String glossary) =>
      stripLockedTerms(text, glossary);

  static List<RegExp> lockedTermRulesForTest(String glossary) =>
      lockedTermRules(glossary);

  static bool hasNonLatinSourceResidual(
    String source,
    String translated,
    String targetLanguage,
  ) {
    final target = targetLanguage.trim().toLowerCase();
    if (target.isEmpty) return false;
    // Only Lo/Lm letters in the kana blocks count, not punctuation, symbols,
    // combining marks or unassigned code points.
    const kanaLetters =
        r'[\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF]';
    // Require a substantial verbatim source run in a script foreign to the
    // target. Shared Han characters across CJK languages are not evidence.
    final patterns = <RegExp>[
      if (!QualityScriptUtils.isCjkTargetLanguage(target))
        RegExp(
          '(?:$kanaLetters|'
          r'[\u3400-\u9FFF\uAC00-\uD7AF\u{20000}-\u{2FA1F}]){8,}',
          unicode: true,
        ),
      if (!RegExp(r'^ru(?:[-_]|$)').hasMatch(target) &&
          !QualityScriptUtils.matchesLanguageName(target, 'russian') &&
          !target.contains('русский') &&
          !target.contains('俄'))
        RegExp(r'[\u0400-\u04FF]{4,}(?:\s+[\u0400-\u04FF]{2,}){2,}'),
      if (!RegExp(r'^ar(?:[-_]|$)').hasMatch(target) &&
          !QualityScriptUtils.matchesLanguageName(target, 'arabic') &&
          !target.contains('العربية') &&
          !target.contains('阿拉伯'))
        RegExp(r'[\u0600-\u06FF]{4,}(?:\s+[\u0600-\u06FF]{2,}){2,}'),
    ];
    source = QualityScriptUtils.normalizeText(
      QualityScriptUtils.stripNonLinguisticTokens(source),
    );
    translated = QualityScriptUtils.normalizeText(
      QualityScriptUtils.stripNonLinguisticTokens(translated),
    );
    final foreignScriptLetters = <RegExp>[
      if (!QualityScriptUtils.isJapaneseTargetLanguage(target))
        RegExp(kanaLetters, unicode: true),
      if (!QualityScriptUtils.isKoreanTargetLanguage(target))
        RegExp(r'[\uAC00-\uD7A3]', unicode: true),
    ];
    final windows = <String>{};
    for (final letters in foreignScriptLetters) {
      final matches = letters.allMatches(translated).toList();
      for (int index = 7; index < matches.length; index++) {
        final start = matches[index - 7].start;
        final end = matches[index].end;
        // Eight letters in at most 32 UTF-16 units give >=25% local evidence.
        // Han, spaces and punctuation may separate them, but the entire
        // window must still occur verbatim in the source.
        if (end - start <= 32) {
          windows.add(translated.substring(start, end));
        }
      }
    }
    if (windows.isNotEmpty &&
        SourceResidualWindowMatcher(windows).hasMatch(source)) {
      return true;
    }
    return patterns.any(
      (pattern) => pattern
          .allMatches(translated)
          .any((match) => source.contains(match.group(0)!)),
    );
  }

  static bool shouldCheckResidual(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    if (lower.isEmpty) {
      return false;
    }
    if (QualityScriptUtils.isCjkTargetLanguage(lower)) {
      return true;
    }
    // Languages where long source-script residuals are usually wrong.
    const Set<String> residualTargets = <String>{
      'zh',
      'chinese',
      '中文',
      '汉语',
      '漢語',
      'ja',
      'japanese',
      '日本語',
      '日语',
      '日語',
      'ko',
      'korean',
      '한국어',
      '韩语',
      '韓語',
      'ru',
      'russian',
      'русский',
      '俄语',
      '俄語',
      'ar',
      'arabic',
      'العربية',
      '阿拉伯语',
      '阿拉伯語',
    };
    if (residualTargets.any(
      (name) => QualityScriptUtils.matchesLanguageName(lower, name),
    )) {
      return true;
    }
    if (RegExp(r'^(?:zh|ja|ko|ru|ar)(?:[-_]|$)').hasMatch(lower)) {
      return true;
    }
    return false;
  }

  static bool hasSuspiciousSourceResidual({
    required String sourceText,
    required String translatedText,
    required String targetLanguage,
    Set<String> sourceWorkTitles = const <String>{},
    String lockedGlossary = '',
  }) {
    sourceText = stripLockedTerms(sourceText, lockedGlossary);
    translatedText = stripLockedTerms(translatedText, lockedGlossary);
    if (hasNonLatinSourceResidual(sourceText, translatedText, targetLanguage)) {
      return true;
    }
    if (!shouldCheckResidual(targetLanguage)) {
      return false;
    }
    final String source = QualityScriptUtils.stripNonLinguisticTokens(
      sourceText,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (QualityScriptUtils.englishWordCount(source) < 6) {
      return false;
    }
    final String text = QualityScriptUtils.stripNonLinguisticTokens(
      translatedText,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      return false;
    }

    final int englishWords = QualityScriptUtils.englishWordCount(text);
    if (englishWords < 7) {
      return false;
    }

    final List<String> englishWordValues = RegExp(
      r"[A-Za-z][A-Za-z'-]*",
    ).allMatches(text).map((RegExpMatch match) => match.group(0)!).toList();
    final int englishLetters = RegExp(r'[A-Za-z]').allMatches(text).length;
    final int nonLatinChars = RegExp(
      r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).allMatches(text).length;
    final int languageChars = englishLetters + nonLatinChars;
    if (languageChars == 0) {
      return false;
    }
    final int properNameLikeWords = englishWordValues.where((String word) {
      final int first = word.codeUnitAt(0);
      return first >= 0x41 && first <= 0x5A;
    }).length;
    // Acknowledgments-style name lists keep long English proper-name runs
    // inside otherwise-translated CJK prose. Evaluate this before the raw
    // English-run detector so retained names are not treated as untranslated
    // sentences.
    final bool mostlyProperNames =
        nonLatinChars >= 4 &&
        englishWords >= 4 &&
        properNameLikeWords / englishWords >= 0.65;
    if (mostlyProperNames) {
      return false;
    }
    if (hasSuspiciousEnglishRun(
      text,
      allowTitleLikeRun:
          looksLikeBibliographicCitation(sourceText) ||
          sourceWorkTitles.isNotEmpty,
    )) {
      return true;
    }

    if (englishLetters >= 40 && nonLatinChars == 0) {
      return true;
    }
    return englishWords >= 10 && englishLetters / languageChars >= 0.65;
  }

  static String? findCjkAdjacentLowercaseWord(
    String text, {
    required String targetLanguage,
    required String sourceText,
  }) {
    if (!QualityScriptUtils.isCjkTargetLanguage(targetLanguage)) {
      return null;
    }
    final String strippedText = QualityScriptUtils.stripNonLinguisticTokens(
      text,
    );
    // P2-#18 + 性能-#39: collect the glossed token occurrences in a single
    // pass. The exemption then applies only to the glossed occurrence
    // itself — not to other bare tokens sharing the paragraph (or the same
    // parentheses) — and no per-token whole-text scan is needed.
    final Set<int> glossedTokenStarts =
        QualityScriptUtils.glossedTermTokenStarts(strippedText);
    final sourceWords = RegExp(
      r"[A-Za-z0-9'’\-]+",
    ).allMatches(sourceText).map((m) => m[0]!.toLowerCase()).toSet();
    for (final RegExpMatch match in RegExp(
      r"[A-Za-z0-9'’\-]+",
    ).allMatches(strippedText)) {
      final String token = match.group(0) ?? '';
      final int latinLetterCount = RegExp(r'[A-Za-z]').allMatches(token).length;
      if (token.length < 5 ||
          latinLetterCount < 4 ||
          !RegExp(r'^[A-Za-z].*[A-Za-z]$').hasMatch(token) ||
          RegExp(r'[0-9]').hasMatch(token) ||
          token != token.toLowerCase()) {
        continue;
      }
      var before = match.start, after = match.end;
      while (before > 0 &&
          QualityScriptUtils.isGlossSpaceRune(
            strippedText.codeUnitAt(before - 1),
          )) {
        before--;
      }
      while (after < strippedText.length &&
          QualityScriptUtils.isGlossSpaceRune(strippedText.codeUnitAt(after))) {
        after++;
      }
      final int? precedingRune = QualityScriptUtils.runeBefore(
        strippedText,
        before,
      );
      final int? followingRune = QualityScriptUtils.runeAt(strippedText, after);
      // Whitespace alone does not make the boundary word of a retained
      // multi-word technical phrase a stray English word.
      final spaced = before != match.start || after != match.end;
      final directBefore = QualityScriptUtils.runeBefore(
        strippedText,
        match.start,
      );
      final directAfter = QualityScriptUtils.runeAt(strippedText, match.end);
      final directCjk =
          (directBefore != null &&
              QualityScriptUtils.isCjkRune(directBefore)) ||
          (directAfter != null && QualityScriptUtils.isCjkRune(directAfter));
      if (!directCjk && !sourceWords.contains(token)) continue;
      if (spaced &&
          !directCjk &&
          ((precedingRune != null &&
                  QualityScriptUtils.isLatinLetterRune(precedingRune)) ||
              (followingRune != null &&
                  QualityScriptUtils.isLatinLetterRune(followingRune)))) {
        continue;
      }
      if ((precedingRune != null &&
              QualityScriptUtils.isCjkRune(precedingRune)) ||
          (followingRune != null &&
              QualityScriptUtils.isCjkRune(followingRune))) {
        if (glossedTokenStarts.contains(match.start)) {
          continue;
        }
        return token;
      }
    }
    return null;
  }

  /// Start offsets (in [text]) of latin token occurrences that sit inside a
  /// clean term gloss, computed in a single pass (性能-#39).
  ///
  /// A clean gloss is `CJK（term）` / `CJK(term)` whose parentheses hold
  /// nothing but the term (plus CJK, whitespace and punctuation), a quoted
  /// term label whose quotes hold nothing but the term (plus target-script
  /// context, e.g. `“agoric开放系统”`), or `term（CJK…）`. P2-#18: looking
  /// the offsets up per token keeps the exemption tied to the glossed
  /// occurrence instead of exempting other bare words that merely share
  /// the paragraph or the parentheses.
  ///
  /// 性能-#51: the parenthesized directions are linear rune scans, not
  /// regexes. The old direction-1 pattern
  /// `([$cjkRange]\s*[（(](?:[$nonLatin]*))($latinToken)...` was cubic on
  /// long unclosed paren runs (measured ~6s at n=800): `-` sits in both the
  /// filler class and the token class, so the two stars and the token split
  /// the same run three ways. Direction-2's
  /// `(?:[$nonLatin]*)[$cjkRange](?:[$nonLatin]*)` was quadratic for the
  /// same reason (adjacent stars around one CJK char). Each rune below is
  /// visited a constant number of times.
  // Parens delimiting a term gloss: （ U+FF08 / ( U+0028, ） U+FF09 / ) U+0029.

  static bool hasSuspiciousEnglishRun(
    String text, {
    required bool allowTitleLikeRun,
  }) {
    final List<String> current = <String>[];

    bool currentRunIsSuspicious() {
      return current.length >= 7 &&
          !(allowTitleLikeRun && looksLikeEnglishTitleOrName(current));
    }

    for (final RegExpMatch match in RegExp(
      r"[A-Za-z][A-Za-z'-]*|[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]",
    ).allMatches(text)) {
      final String token = match.group(0) ?? '';
      if (RegExp(r"^[A-Za-z][A-Za-z'-]*$").hasMatch(token)) {
        current.add(token);
      } else {
        if (currentRunIsSuspicious()) {
          return true;
        }
        current.clear();
      }
    }
    return currentRunIsSuspicious();
  }

  static bool looksLikeBibliographicCitation(String sourceText) {
    final String text = sourceText.trim();
    final bool hasUrl = RegExp(
      r'(?:(?:https?|ftp)://|www\.)',
      caseSensitive: false,
    ).hasMatch(text);
    final bool hasYear = RegExp(r'\b(?:18|19|20)\d{2}\b').hasMatch(text);
    final bool hasCitationMarker =
        text.startsWith('*') ||
        text.contains('“') ||
        text.contains('”') ||
        text.contains('"');
    return hasUrl && hasYear && hasCitationMarker;
  }

  static bool looksLikeEnglishTitleOrName(List<String> words) {
    const Set<String> connectors = <String>{
      'a',
      'an',
      'and',
      'as',
      'at',
      'by',
      'd',
      'del',
      'for',
      'from',
      'in',
      'l',
      'n',
      'o',
      'of',
      'on',
      'or',
      'the',
      'to',
      'with',
    };
    int significantWords = 0;
    int titleCaseWords = 0;
    for (final String word in words) {
      // Split European-style apostrophe connectives (Coeur d'Alene -> d +
      // Alene) so the short lowercase particle (d', l', …) is treated as a
      // connector instead of a significant lowercase word.
      final List<String> parts = _splitApostropheConnective(word);
      if (parts.length == 2) {
        if (connectors.contains(parts[0].toLowerCase())) {
          final String second = parts[1];
          if (_isTitleCaseWord(second)) {
            titleCaseWords += 1;
          }
          significantWords += 1;
          continue;
        }
      }
      if (connectors.contains(word.toLowerCase())) {
        continue;
      }
      significantWords += 1;
      if (_isTitleCaseWord(word)) {
        titleCaseWords += 1;
      }
    }
    return significantWords >= 2 && titleCaseWords / significantWords >= 0.8;
  }

  /// Whether [words] form a legal citation shape `X v. Y` (for example
  /// `Roe v. Wade`), optionally embedded as `X v. Y案` by the translator.
  /// `v.` may be tokenized as `v` (the period is stripped by the word
  /// tokenizer). Both parties must be title-case proper names of 1-3 words.
  static bool looksLikeLegalCaseName(List<String> words) {
    final int vIndex = words.indexWhere((String word) {
      final String normalized = word.replaceAll(RegExp(r'[.\s]'), '');
      return normalized.toLowerCase() == 'v' ||
          normalized.toLowerCase() == 'vs';
    });
    if (vIndex <= 0 || vIndex >= words.length - 1) {
      return false;
    }
    final List<String> plaintiff = words.sublist(0, vIndex);
    final List<String> defendant = words.sublist(vIndex + 1);
    if (plaintiff.isEmpty ||
        defendant.isEmpty ||
        plaintiff.length > 3 ||
        defendant.length > 3) {
      return false;
    }
    bool allTitleCaseWords(List<String> parts) =>
        parts.isNotEmpty &&
        parts.every((String word) {
          final String stripped = word.replaceAll(RegExp(r'[.!.,]'), '');
          if (stripped.isEmpty) {
            return false;
          }
          final String first = String.fromCharCode(stripped.runes.first);
          return first == first.toUpperCase() && first != first.toLowerCase();
        });
    return allTitleCaseWords(plaintiff) && allTitleCaseWords(defendant);
  }

  /// Debug-only probe: applies [TranslationQuality.looksLikeEnglishTitleOrName]
  /// to the English words of a mixed-CJK inline node.
  static bool debugLooksLikeEnglishTitleOrName(String text) {
    return looksLikeEnglishTitleOrName(
      QualityScriptUtils.englishWorkTitleWords(text),
    );
  }

  /// Splits a word like `d'Alene` into `['d', 'Alene']` when the leading
  /// apostrophe particle is a 1-2 lowercase-letter connective. Returns the
  /// original word unchanged when it is not such a form.
  static List<String> _splitApostropheConnective(String word) {
    final RegExpMatch? match = RegExp(
      r"^([a-z]{1,2})'([A-Z][A-Za-z'\-]*)$",
    ).firstMatch(word);
    if (match == null) {
      return <String>[word];
    }
    return <String>[match.group(1)!, match.group(2)!];
  }

  static bool _isTitleCaseWord(String word) {
    final String first = String.fromCharCode(word.runes.first);
    return first == first.toUpperCase() && first != first.toLowerCase();
  }
}
