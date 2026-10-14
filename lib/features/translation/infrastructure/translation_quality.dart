import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'epub/epub_html_extractor.dart';

enum TranslationResidualKind { longSourceText, cjkAdjacentLowercaseWord }

class TranslationResidualFinding {
  const TranslationResidualFinding({required this.kind, this.token});

  final TranslationResidualKind kind;
  final String? token;

  String messageForBlock(String blockId) {
    return switch (kind) {
      TranslationResidualKind.longSourceText =>
        'Possible untranslated source-language text remains in block $blockId.',
      TranslationResidualKind.cjkAdjacentLowercaseWord =>
        'Possible untranslated source-language token "${token ?? ''}" '
            'remains adjacent to CJK text in block $blockId.',
    };
  }
}

/// Rune-level view of a string: the rune at each index plus the UTF-16
/// offset where it starts, so linear scans can navigate by rune while
/// reporting UTF-16 offsets (what the RegExp-based callers used).
/// Backs the backtracking-free gloss scans (性能-#51).
class _RuneCursor {
  _RuneCursor(String text) {
    int offset = 0;
    while (offset < text.length) {
      final int unit = text.codeUnitAt(offset);
      int rune = unit;
      int width = 1;
      if (unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < text.length) {
        final int low = text.codeUnitAt(offset + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          rune = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
          width = 2;
        }
      }
      offsets.add(offset);
      runes.add(rune);
      offset += width;
    }
  }

  final List<int> offsets = <int>[];
  final List<int> runes = <int>[];

  /// Rune index containing UTF-16 [offset] (binary search). Callers pass
  /// `String.indexOf` hits, which always sit on a rune boundary.
  int runeIndexAt(int offset) {
    int lo = 0;
    int hi = offsets.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (offsets[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }
}

// One traversal per semantic block. Candidate-specific context must stay
// distinct: a book title and an instruction can occupy the same paragraph.
class _WorkTitleBlockContext {
  _WorkTitleBlockContext(Node root) {
    final buffer = StringBuffer();
    void collect(Node node) {
      final start = buffer.length;
      if (node is Text) buffer.write(' ${node.data}');
      for (final child in node.nodes) {
        collect(child);
      }
      spans[node] = (start, buffer.length);
    }

    collect(root);
    text = buffer.toString();
  }

  late final String text;
  final Map<Node, (int, int)> spans = Map.identity();
}

class _SourceResidualWindowNode {
  // Most trie nodes have one outgoing edge. Store it inline rather than
  // allocating a Map for every code unit of every distinct window.
  int unit = -1;
  int next = 0;
  Map<int, int>? branches;
  int failure = 0;
  bool isMatch = false;

  int? transition(int codeUnit) =>
      codeUnit == unit ? next : branches?[codeUnit];

  void addTransition(int codeUnit, int state) {
    if (unit < 0) {
      unit = codeUnit;
      next = state;
    } else {
      (branches ??= <int, int>{})[codeUnit] = state;
    }
  }
}

/// Aho-Corasick matcher for residual windows of at most 32 UTF-16 units.
/// Preparation is linear in the total bounded window length; scanning the
/// source once avoids a full source search for every translated window.
/// Code units preserve String.contains semantics, including surrogate pairs
/// and unpaired surrogates between the unicode RegExp letter boundaries.
class _SourceResidualWindowMatcher {
  _SourceResidualWindowMatcher(Iterable<String> windows) {
    for (final window in windows) {
      var state = 0;
      for (var index = 0; index < window.length; index++) {
        final unit = window.codeUnitAt(index);
        final next = _nodes[state].transition(unit);
        if (next == null) {
          final nextState = _nodes.length;
          _nodes[state].addTransition(unit, nextState);
          _nodes.add(_SourceResidualWindowNode());
          state = nextState;
        } else {
          state = next;
        }
      }
      _nodes[state].isMatch = true;
    }

    // Breadth-first order makes every shorter failure state available before
    // its children, including matches that are suffixes of another window.
    final root = _nodes[0];
    final queue = <int>[
      if (root.unit >= 0) root.next,
      ...?root.branches?.values,
    ];
    for (var index = 0; index < queue.length; index++) {
      final node = _nodes[queue[index]];
      if (node.unit >= 0) {
        _enqueueChild(node, node.unit, node.next, queue);
      }
      final branches = node.branches;
      if (branches != null) {
        for (final edge in branches.entries) {
          _enqueueChild(node, edge.key, edge.value, queue);
        }
      }
    }
  }

  final List<_SourceResidualWindowNode> _nodes = [_SourceResidualWindowNode()];

  void _enqueueChild(
    _SourceResidualWindowNode parent,
    int unit,
    int state,
    List<int> queue,
  ) {
    var fallback = parent.failure;
    var next = _nodes[fallback].transition(unit);
    while (fallback != 0 && next == null) {
      fallback = _nodes[fallback].failure;
      next = _nodes[fallback].transition(unit);
    }
    final child = _nodes[state];
    child.failure = next ?? 0;
    child.isMatch = child.isMatch || _nodes[child.failure].isMatch;
    queue.add(state);
  }

  bool hasMatch(String source) {
    var state = 0;
    for (var index = 0; index < source.length; index++) {
      final unit = source.codeUnitAt(index);
      var next = _nodes[state].transition(unit);
      while (state != 0 && next == null) {
        state = _nodes[state].failure;
        next = _nodes[state].transition(unit);
      }
      state = next ?? 0;
      if (_nodes[state].isMatch) return true;
    }
    return false;
  }
}

/// Residual / quality checks for translated blocks (multi-language targets).
class TranslationQuality {
  const TranslationQuality._();

  static bool _matchesLanguageName(String value, String name) => RegExp(
    '(?:^|[^\\p{L}\\p{N}])${RegExp.escape(name)}(?=\$|[^\\p{L}\\p{N}])',
    unicode: true,
  ).hasMatch(value);

  static const int _lockedTermRulesCacheLimit = 8;
  static final Map<String, List<RegExp>> _lockedTermRulesCache = {};

  static String _stripLockedTerms(String text, String glossary) {
    if (glossary.trim().isEmpty) return text;
    for (final rule in _lockedTermRules(glossary)) {
      text = text.replaceAll(rule, ' ');
    }
    return text;
  }

  static List<RegExp> _lockedTermRules(String glossary) {
    final cached = _lockedTermRulesCache[glossary];
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
    if (_lockedTermRulesCache.length >= _lockedTermRulesCacheLimit) {
      _lockedTermRulesCache.remove(_lockedTermRulesCache.keys.first);
    }
    _lockedTermRulesCache[glossary] = rules;
    return rules;
  }

  @visibleForTesting
  static String stripLockedTermsForTest(String text, String glossary) =>
      _stripLockedTerms(text, glossary);

  @visibleForTesting
  static List<RegExp> lockedTermRulesForTest(String glossary) =>
      _lockedTermRules(glossary);

  static bool _hasNonLatinSourceResidual(
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
      if (!_isCjkTargetLanguage(target))
        RegExp(
          '(?:$kanaLetters|'
          r'[\u3400-\u9FFF\uAC00-\uD7AF\u{20000}-\u{2FA1F}]){8,}',
          unicode: true,
        ),
      if (!RegExp(r'^ru(?:[-_]|$)').hasMatch(target) &&
          !_matchesLanguageName(target, 'russian') &&
          !target.contains('русский') &&
          !target.contains('俄'))
        RegExp(r'[\u0400-\u04FF]{4,}(?:\s+[\u0400-\u04FF]{2,}){2,}'),
      if (!RegExp(r'^ar(?:[-_]|$)').hasMatch(target) &&
          !_matchesLanguageName(target, 'arabic') &&
          !target.contains('العربية') &&
          !target.contains('阿拉伯'))
        RegExp(r'[\u0600-\u06FF]{4,}(?:\s+[\u0600-\u06FF]{2,}){2,}'),
    ];
    source = _normalizeText(_stripNonLinguisticTokens(source));
    translated = _normalizeText(_stripNonLinguisticTokens(translated));
    final foreignScriptLetters = <RegExp>[
      if (!_isJapaneseTargetLanguage(target))
        RegExp(kanaLetters, unicode: true),
      if (!_isKoreanTargetLanguage(target))
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
        _SourceResidualWindowMatcher(windows).hasMatch(source)) {
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
    if (_isCjkTargetLanguage(lower)) {
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
    if (residualTargets.any((name) => _matchesLanguageName(lower, name))) {
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
    sourceText = _stripLockedTerms(sourceText, lockedGlossary);
    translatedText = _stripLockedTerms(translatedText, lockedGlossary);
    if (_hasNonLatinSourceResidual(
      sourceText,
      translatedText,
      targetLanguage,
    )) {
      return true;
    }
    if (!shouldCheckResidual(targetLanguage)) {
      return false;
    }
    final String source = _stripNonLinguisticTokens(
      sourceText,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_englishWordCount(source) < 6) {
      return false;
    }
    final String text = _stripNonLinguisticTokens(
      translatedText,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      return false;
    }

    final int englishWords = _englishWordCount(text);
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
    if (_hasSuspiciousEnglishRun(
      text,
      allowTitleLikeRun:
          _looksLikeBibliographicCitation(sourceText) ||
          sourceWorkTitles.isNotEmpty,
    )) {
      return true;
    }

    if (englishLetters >= 40 && nonLatinChars == 0) {
      return true;
    }
    return englishWords >= 10 && englishLetters / languageChars >= 0.65;
  }

  static TranslationResidualFinding? findSuspiciousHtmlResidual({
    required String sourceHtml,
    required String translatedHtml,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) {
    final Document sourceDocument = html_parser.parse(sourceHtml);
    final Document translatedDocument = html_parser.parse(translatedHtml);
    return _findSuspiciousDocumentResidual(
      sourceDocument: sourceDocument,
      translatedDocument: translatedDocument,
      targetLanguage: targetLanguage,
      allowRetainedAuthorSignature: allowRetainedAuthorSignature,
      allowBibliographicRetention: allowBibliographicRetention,
      lockedGlossary: lockedGlossary,
    );
  }

  /// DOM entry point for the response pipeline. Quality rules clear exempted
  /// content, so operate on clones rather than changing the source/output DOM.
  static TranslationResidualFinding? findSuspiciousFragmentResidual({
    required DocumentFragment sourceFragment,
    required DocumentFragment translatedFragment,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) {
    Document qualityDocument(DocumentFragment fragment) {
      final document = Document();
      final html = Element.tag('html');
      final body = Element.tag('body');
      document.append(html);
      html.append(body);
      for (final node in fragment.nodes) {
        body.append(node.clone(true));
      }
      return document;
    }

    return _findSuspiciousDocumentResidual(
      sourceDocument: qualityDocument(sourceFragment),
      translatedDocument: qualityDocument(translatedFragment),
      targetLanguage: targetLanguage,
      allowRetainedAuthorSignature: allowRetainedAuthorSignature,
      allowBibliographicRetention: allowBibliographicRetention,
      lockedGlossary: lockedGlossary,
    );
  }

  static TranslationResidualFinding? _findSuspiciousDocumentResidual({
    required Document sourceDocument,
    required Document translatedDocument,
    required String targetLanguage,
    required bool allowRetainedAuthorSignature,
    required bool allowBibliographicRetention,
    required String lockedGlossary,
  }) {
    // Capture before any exemption clears source nodes. Previously these
    // heuristics reparsed the original source HTML each time they ran.
    final sourceAuditedCores = _sourceAuditedForeignTermCores(sourceDocument);
    // Source-owned code/formula text is intentionally retained. Exempt only
    // identical subtrees, so newly introduced code wrappers cannot hide prose.
    final selector = EpubHtmlExtractor.nonTextAncestors.join(',');
    final sourceNonProse = sourceDocument.querySelectorAll(selector);
    final translatedNonProse = translatedDocument.querySelectorAll(selector);
    if (sourceNonProse.length == translatedNonProse.length) {
      for (var index = sourceNonProse.length - 1; index >= 0; index--) {
        if (sourceNonProse[index].outerHtml ==
            translatedNonProse[index].outerHtml) {
          sourceNonProse[index].nodes.clear();
          translatedNonProse[index].nodes.clear();
        }
      }
    }
    if (lockedGlossary.trim().isNotEmpty) {
      for (final document in [sourceDocument, translatedDocument]) {
        for (final node in _textNodes(document)) {
          node.data = _stripLockedTerms(node.data, lockedGlossary);
        }
      }
    }
    if (_hasNonLatinSourceResidual(
      sourceDocument.body?.text ?? '',
      translatedDocument.body?.text ?? '',
      targetLanguage,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    if (!shouldCheckResidual(targetLanguage)) return null;
    // Capture source inline work titles BEFORE any clearing below empties the
    // `<i>/<em>/<cite>` nodes, so retained work titles can be recognised later
    // even when the source copy was scrubbed by term/name handling.
    final Set<String> sourceInlineWorkTitles = _sourceInlineWorkTitles(
      sourceDocument,
    );
    if (allowRetainedAuthorSignature &&
        !_prepareAuthorSignatureForResidualCheck(
          sourceDocument,
          translatedDocument,
          targetLanguage: targetLanguage,
        )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    final List<Element> sourceCandidates = _outermostWorkTitleCandidates(
      sourceDocument,
    );
    final List<Element> translatedCandidates = _outermostWorkTitleCandidates(
      translatedDocument,
    );
    final Set<String> sourceWorkTitles = sourceCandidates
        .map((Element candidate) => _normalizedWorkTitleText(candidate.text))
        .where(_looksLikeEnglishWorkTitle)
        .toSet();
    final List<int> exemptedCandidateIndexes = <int>[];
    final List<String> unexemptedSourceTexts = <String>[];
    final Map<Node, _WorkTitleBlockContext> workTitleContexts = Map.identity();

    if (sourceCandidates.length == translatedCandidates.length) {
      // 性能-#39: the whole translated body text is scanned once here, not
      // once per candidate. Clearing a retained title below only removes the
      // title text inside the brackets, so the bracket presence observed
      // here stays valid for every candidate.
      final bool hasChineseTitleMarker = RegExp(
        r'[《「『〈》」』〉]',
      ).hasMatch(translatedDocument.body?.text ?? '');
      for (int index = 0; index < sourceCandidates.length; index += 1) {
        final Element sourceCandidate = sourceCandidates[index];
        final Element translatedCandidate = translatedCandidates[index];
        final String sourceText = _normalizeText(sourceCandidate.text);
        final String translatedText = _normalizeText(translatedCandidate.text);
        final bool canExempt =
            sourceCandidate.localName == translatedCandidate.localName &&
            _elementStructurePath(sourceCandidate) ==
                _elementStructurePath(translatedCandidate) &&
            _normalizedWorkTitleText(sourceText) ==
                _normalizedWorkTitleText(translatedText) &&
            _looksLikeEnglishWorkTitle(sourceText) &&
            (_hasWorkTitleSemantics(
                  sourceDocument,
                  sourceCandidate,
                  sourceText,
                  contexts: workTitleContexts,
                ) ||
                hasChineseTitleMarker);
        final bool canExemptCjkGloss =
            !canExempt &&
            _clearCjkMarkedWorkTitleGloss(
              translatedDocument,
              sourceText,
              targetLanguage: targetLanguage,
            );
        if (canExempt || canExemptCjkGloss) {
          if (canExemptCjkGloss) {
            // The HTML lock may leave an empty emphasis wrapper at the end of
            // the block while the model moves the original title into plain
            // CJK book-title marks. Clear only the quality-check copy; the
            // rendered translation remains untouched.
            sourceCandidate.text = '';
            // Later candidates must see this mutation, just as they did
            // with uncached context walks.
            workTitleContexts.clear();
          }
          exemptedCandidateIndexes.add(index);
          continue;
        }
        if (_looksLikeEnglishWorkTitle(sourceText)) {
          unexemptedSourceTexts.add(sourceText);
        }
      }
    } else {
      for (final Element sourceCandidate in sourceCandidates) {
        final String sourceText = _normalizeText(sourceCandidate.text);
        if (!_looksLikeEnglishWorkTitle(sourceText) ||
            isAuditedForeignTermNodeText(sourceText)) {
          continue;
        }
        final Element? matchingTranslated = translatedCandidates
            .where(
              (Element candidate) =>
                  _normalizedWorkTitleText(candidate.text) ==
                      _normalizedWorkTitleText(sourceText) &&
                  _looksLikeEnglishWorkTitle(
                    _normalizedWorkTitleText(candidate.text),
                  ),
            )
            .firstOrNull;
        if (matchingTranslated != null) {
          // The model kept the original English work title and supplied a
          // translated gloss elsewhere in the block; this is the same
          // retention accepted when wrapper counts match.
          sourceCandidate.text = '';
          matchingTranslated.text = '';
          continue;
        }
        // The model may instead render the book title as a bilingual gloss in
        // a single node: 《中文书名》（English original title）. The English
        // original is retained only as a parenthetical gloss, exactly like
        // the separate-node form handled above, so treat it as matched too.
        final bool translatedGlossRetained = translatedCandidates.any(
          (Element candidate) =>
              _isWorkTitleGlossRetention(candidate.text, sourceText),
        );
        if (translatedGlossRetained) {
          sourceCandidate.text = '';
          continue;
        }
        unexemptedSourceTexts.add(_normalizedWorkTitleText(sourceText));
      }
      final String translatedVisibleText = _normalizeText(
        _stripSourceAuditedForeignTermsFromText(
          sourceAuditedCores,
          translatedDocument.body?.text ?? translatedDocument.text ?? '',
        ),
      );
      final bool hasChineseTitleMarker =
          RegExp(r'[《「『〈]').hasMatch(translatedVisibleText) ||
          RegExp(r'[》」』〉]').hasMatch(translatedVisibleText) ||
          translatedCandidates.any(
            (Element candidate) => RegExp(
              r'[\u3400-\u9FFF\u{20000}-\u{2FA1F}]',
              unicode: true,
            ).hasMatch(candidate.text),
          );
      for (final String unexempted in unexemptedSourceTexts) {
        // An unretained source work title that is neither kept verbatim nor
        // translated into a Chinese title (marked with 《》 etc.) means the
        // model dropped it entirely instead of translating the block.
        if (!translatedVisibleText.contains(unexempted) &&
            !hasChineseTitleMarker) {
          return const TranslationResidualFinding(
            kind: TranslationResidualKind.longSourceText,
          );
        }
      }
    }

    for (final int index in exemptedCandidateIndexes) {
      sourceCandidates[index].text = '';
      translatedCandidates[index].text = '';
    }

    if (!_clearMatchingAuditedForeignTerms(
      sourceDocument,
      translatedDocument,
      targetLanguage: targetLanguage,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    _clearMatchingInvertedIndexPersonNames(sourceDocument, translatedDocument);
    _clearRetainedProperNames(sourceDocument, translatedDocument);

    final String? adjacentLowercaseWord = _findCjkAdjacentLowercaseWord(
      _stripSourceAuditedForeignTermsFromText(
        sourceAuditedCores,
        translatedDocument.body?.text ?? translatedDocument.text ?? '',
      ),
      targetLanguage: targetLanguage,
    );
    if (adjacentLowercaseWord != null) {
      return TranslationResidualFinding(
        kind: TranslationResidualKind.cjkAdjacentLowercaseWord,
        token: adjacentLowercaseWord,
      );
    }

    if (_hasRemainingTranslatedInlineResidual(
      translatedDocument,
      sourceInlineWorkTitles: sourceInlineWorkTitles,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    if (allowBibliographicRetention &&
        isPureCitationMetadata(
          sourceDocument.body?.text ?? sourceDocument.text ?? '',
        )) {
      // Pure citation / index metadata (author names, page numbers, locators,
      // `Ibid.` / `op. cit.` cross-references) is conventionally retained
      // verbatim. The per-node short-English-prose check below would mistake
      // these retained fields for untranslated sentences even when the entry
      // is a pure metadata line with nothing to translate, so exempt it here
      // the same way the translation-time validation does.
    } else if (_hasSourceOwnedShortEnglishProse(
      sourceDocument,
      translatedDocument,
      isBibliographicEntry: allowBibliographicRetention,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final String translatedVisibleText = _normalizeText(
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
    );
    if (!allowBibliographicRetention &&
        unexemptedSourceTexts.any(translatedVisibleText.contains)) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final bool hasLongSourceText = hasSuspiciousSourceResidual(
      sourceText: sourceDocument.body?.text ?? sourceDocument.text ?? '',
      translatedText:
          translatedDocument.body?.text ?? translatedDocument.text ?? '',
      targetLanguage: targetLanguage,
      sourceWorkTitles: sourceWorkTitles,
    );
    if (hasLongSourceText) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    return null;
  }

  /// Whether [text] is a pure citation-metadata endnote with no translatable
  /// natural-language sentence, e.g. `Ibid.` or `Yardeni, op. cit., p. 62.`
  ///
  /// Such entries conventionally stay verbatim in translated works, since
  /// `op. cit.` / `ibid.` / `loc. cit.` are standard scholarly abbreviations
  /// and any surrounding words are author/journal names or page numbers.
  static bool isPureCitationMetadata(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Remove the leading footnote number (`14.`) and the entry's number anchor
    // text if the extractor included it (`14`) at the start.
    var body = normalized.replaceFirst(RegExp(r'^\d+\s*\.?\s*'), '');
    // Strip any quoted/curly-quoted article or book titles — a quoted title is
    // translatable natural-language content, so its presence disqualifies the
    // entry from being treated as pure metadata.
    if (RegExp(r'[“”"«»]').hasMatch(body)) {
      return false;
    }
    // Strip trailing sentence-final punctuation then split into words.
    body = body.replaceFirst(RegExp(r'[.!?]+\s*$'), '');
    final wordPattern = RegExp(r"[A-Za-z][A-Za-z'’\-]*|\d+");
    // Numbers and citation cues cannot exempt letters the tokenizer did not
    // consume. Check before every affirmative metadata branch.
    if (RegExp(r'\p{L}', unicode: true).hasMatch(body.replaceAll(wordPattern, ''))) {
      return false;
    }
    final List<String> words = wordPattern
        .allMatches(body)
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    if (words.isEmpty) {
      return true;
    }
    const Set<String> citationTokens = <String>{
      'a',
      'al',
      'ben',
      'bin',
      'and',
      'by',
      'cit',
      'da',
      'de',
      'del',
      'der',
      'des',
      'di',
      'du',
      'ed',
      'eds',
      'el',
      'et',
      'for',
      'ibid',
      'in',
      'la',
      'le',
      'loc',
      'n',
      'no',
      'of',
      'op',
      'p',
      'pp',
      'rev',
      'sd',
      'st',
      'ten',
      'ter',
      'the',
      'trans',
      'van',
      'vol',
      'von',
      'see',
      'quoted',
    };
    for (final String word in words) {
      if (RegExp(r'^\d+$').hasMatch(word)) {
        continue;
      }
      final String lower = word.toLowerCase();
      if (citationTokens.contains(lower)) {
        continue;
      }
      final String first = word.substring(0, 1);
      // Allow title-cased author/journal words (Fiorentini, Peltzman,
      // Washington, New) but reject ordinary lowercase sentence words.
      if (first == first.toUpperCase() && first != first.toLowerCase()) {
        continue;
      }
      return false;
    }
    // P2-#19: an all-caps run of sentence length is body prose, not
    // metadata. A lone all-caps surname (YARDENI) or acronym stays allowed,
    // but several all-caps words in a row are a sentence that must not be
    // exempted as "pure citation metadata".
    int allCapsWords = 0;
    for (final String word in words) {
      // P2-#11: single-letter words count too — "THIS IS A TEST" is a
      // four-word all-caps sentence, not citation metadata.
      if (word.isNotEmpty &&
          word == word.toUpperCase() &&
          RegExp(r'[A-Z]').hasMatch(word)) {
        allCapsWords++;
      }
    }
    if (allCapsWords >= 4) {
      return false;
    }
    // Capitalization alone does not distinguish a heading from metadata.
    // Preserve the established lone-surname case and require citation shape
    // for multiword entries (cross-reference, locator, or author/year).
    return words.length == 1 ||
        RegExp(
          r'\b(?:ibid|(?:op|loc)\.\s*cit)\b',
          caseSensitive: false,
        ).hasMatch(body) ||
        RegExp(
          r'(?:[,:(]\s*\d+|\b(?:p|pp|vol|no)\.\s*\d+)',
          caseSensitive: false,
        ).hasMatch(body);
  }

  static bool _prepareAuthorSignatureForResidualCheck(
    Document sourceDocument,
    Document translatedDocument, {
    required String targetLanguage,
  }) {
    final List<Element> sourceElements =
        sourceDocument.body?.children ?? const <Element>[];
    final List<Element> translatedElements =
        translatedDocument.body?.children ?? const <Element>[];
    if (sourceElements.length != 1 || translatedElements.length != 1) {
      return false;
    }
    final Element sourceElement = sourceElements.single;
    final Element translatedElement = translatedElements.single;
    final String sourceText = _normalizeText(sourceElement.text);
    final String translatedText = _normalizeText(translatedElement.text);
    if (sourceElement.localName != 'p' ||
        translatedElement.localName != 'p' ||
        !_hasSignatureSemantics(sourceElement) ||
        !_hasSignatureSemantics(translatedElement) ||
        sourceElement.children.isNotEmpty ||
        translatedElement.children.isNotEmpty ||
        _canonicalRetainedPersonName(sourceText) == null) {
      return false;
    }

    if (sourceText == translatedText) {
      sourceElement.text = '';
      translatedElement.text = '';
      return true;
    }

    // A translated or transliterated signature is already safe. Keep it in
    // the normal residual pipeline so any unrelated English text is still
    // checked. A different all-Latin name, however, is not an acceptable
    // retained signature and must be retried.
    if (!_hasTargetScript(translatedText, targetLanguage: targetLanguage) ||
        RegExp(r'[A-Za-z]').hasMatch(translatedText)) {
      return false;
    }
    return true;
  }

  static bool _hasTargetScript(String text, {required String targetLanguage}) {
    final String lower = targetLanguage.trim().toLowerCase();
    if (_isCjkTargetLanguage(lower)) {
      return RegExp(
        r'[\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
      ).hasMatch(text);
    }
    if (lower.startsWith('ru') || lower.contains('russian')) {
      return RegExp(r'[\u0400-\u04FF]').hasMatch(text);
    }
    if (lower.startsWith('ar') || lower.contains('arabic')) {
      return RegExp(r'[\u0600-\u06FF]').hasMatch(text);
    }
    return false;
  }

  static bool _hasSignatureSemantics(Element paragraph) {
    const Set<String> recognizedClasses = <String>{
      'author-signature',
      'sig',
      'signature',
    };
    return paragraph.classes
        .map((String token) => token.toLowerCase())
        .any(recognizedClasses.contains);
  }

  static String? _findCjkAdjacentLowercaseWord(
    String text, {
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage)) {
      return null;
    }
    final String strippedText = _stripNonLinguisticTokens(text);
    // P2-#18 + 性能-#39: collect the glossed token occurrences in a single
    // pass. The exemption then applies only to the glossed occurrence
    // itself — not to other bare tokens sharing the paragraph (or the same
    // parentheses) — and no per-token whole-text scan is needed.
    final Set<int> glossedTokenStarts = _glossedTermTokenStarts(strippedText);
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
      final int? precedingRune = _runeBefore(strippedText, match.start);
      final int? followingRune = _runeAt(strippedText, match.end);
      if ((precedingRune != null && _isCjkRune(precedingRune)) ||
          (followingRune != null && _isCjkRune(followingRune))) {
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
  static const int _glossOpenFull = 0xFF08;
  static const int _glossOpenAscii = 0x28;
  static const int _glossCloseFull = 0xFF09;
  static const int _glossCloseAscii = 0x29;

  /// One filler rune inside a clean gloss: whitespace, CJK, or the
  /// punctuation the old `[$nonLatin]` class allowed
  /// (`.,;:，；：、-–—`). O(1), no backtracking.
  static bool _isGlossFillerRune(int rune) {
    if (_isGlossSpaceRune(rune) || _isCjkRune(rune)) {
      return true;
    }
    switch (rune) {
      case 0x2E: // .
      case 0x2C: // ,
      case 0x3B: // ;
      case 0x3A: // :
      case 0xFF0C: // ，
      case 0xFF1B: // ；
      case 0xFF1A: // ：
      case 0x3001: // 、
      case 0x2D: // -
      case 0x2013: // –
      case 0x2014: // —
        return true;
    }
    return false;
  }

  /// `\s` with unicode semantics, matching what the old patterns used.
  static bool _isGlossSpaceRune(int rune) {
    switch (rune) {
      case 0x09: // \t
      case 0x0A: // \n
      case 0x0B: // \v
      case 0x0C: // \f
      case 0x0D: // \r
      case 0x20: // space
      case 0xA0: // nbsp
      case 0x1680:
      case 0x2000:
      case 0x2001:
      case 0x2002:
      case 0x2003:
      case 0x2004:
      case 0x2005:
      case 0x2006:
      case 0x2007:
      case 0x2008:
      case 0x2009:
      case 0x200A:
      case 0x2028:
      case 0x2029:
      case 0x202F:
      case 0x205F:
      case 0x3000:
      case 0xFEFF:
        return true;
    }
    return false;
  }

  /// One rune of a latin token: `[A-Za-z0-9'’\-]`.
  static bool _isLatinTokenRune(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || // A-Z
      (rune >= 0x61 && rune <= 0x7A) || // a-z
      (rune >= 0x30 && rune <= 0x39) || // 0-9
      rune == 0x27 || // '
      rune == 0x2019 || // ’
      rune == 0x2D; // -

  static Set<int> _glossedTermTokenStarts(String text) {
    final _RuneCursor cursor = _RuneCursor(text);
    final Set<int> starts = <int>{};
    _collectGlossDirection1(cursor, starts);
    _collectGlossDirection2(cursor, starts);
    // Quoted term labels with target-script context, e.g. “agoric开放系统”.
    // Bound the lookahead and filler scans: repeated opening quotes without
    // a closer must not rescan an unbounded suffix at every position.
    const String cjkRange =
        r'\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\u{20000}-\u{2FA1F}';
    const String latinToken = r"[A-Za-z0-9'’\-]+";
    final RegExp quotedPattern = RegExp(
      '([“「『"](?=[^”」』"]{0,256}[$cjkRange])(?:[^”」』"A-Za-z0-9\'’\\-]{0,256}))'
      '($latinToken)(?:[^”」』"A-Za-z0-9\'’\\-]{0,256})[”」』"]',
      unicode: true,
    );
    for (final RegExpMatch match in quotedPattern.allMatches(text)) {
      starts.add(match.start + (match.group(1)?.length ?? 0));
    }
    return starts;
  }

  /// Direction 1: `CJK（term）` / `CJK(term)` — the parens hold the token
  /// plus only filler (CJK, whitespace, punctuation). Records the token's
  /// UTF-16 start offset.
  static void _collectGlossDirection1(_RuneCursor cursor, Set<int> starts) {
    final List<int> runes = cursor.runes;
    int i = 0;
    while (i < runes.length) {
      if (runes[i] != _glossOpenAscii && runes[i] != _glossOpenFull) {
        i++;
        continue;
      }
      // The open paren must be preceded (through whitespace) by CJK.
      int j = i - 1;
      while (j >= 0 && _isGlossSpaceRune(runes[j])) {
        j--;
      }
      if (j < 0 || !_isCjkRune(runes[j])) {
        i++;
        continue;
      }
      // Filler*, token+, filler*, closer. `-` is both filler and a token
      // rune, so remember the last filler `-`: if no token follows the
      // greedy filler run, the old regex backtracked exactly one step and
      // let the token start there (e.g. `中(中文-：)` glosses `-`). One
      // step suffices: an earlier `-` start extends the same maximal latin
      // run, so its post-token check is identical.
      int k = i + 1;
      int lastDash = -1;
      while (k < runes.length && _isGlossFillerRune(runes[k])) {
        if (runes[k] == 0x2D) {
          lastDash = k;
        }
        k++;
      }
      int tokenStart = k;
      while (k < runes.length && _isLatinTokenRune(runes[k])) {
        k++;
      }
      if (k == tokenStart && lastDash >= 0) {
        tokenStart = lastDash;
        k = lastDash;
        while (k < runes.length && _isLatinTokenRune(runes[k])) {
          k++;
        }
      }
      if (k == tokenStart) {
        i++;
        continue;
      }
      while (k < runes.length && _isGlossFillerRune(runes[k])) {
        k++;
      }
      if (k < runes.length &&
          (runes[k] == _glossCloseAscii || runes[k] == _glossCloseFull)) {
        starts.add(cursor.offsets[tokenStart]);
        i = k + 1;
      } else {
        i++;
      }
    }
  }

  /// Direction 2: `term（CJK…）` — the token precedes the paren and the
  /// parens hold filler with at least one CJK char. Records the token's
  /// UTF-16 start offset.
  static void _collectGlossDirection2(_RuneCursor cursor, Set<int> starts) {
    final List<int> runes = cursor.runes;
    int i = 0;
    while (i < runes.length) {
      if (!_isLatinTokenRune(runes[i])) {
        i++;
        continue;
      }
      final int tokenStart = i;
      while (i < runes.length && _isLatinTokenRune(runes[i])) {
        i++;
      }
      int k = i;
      while (k < runes.length && _isGlossSpaceRune(runes[k])) {
        k++;
      }
      if (k >= runes.length ||
          (runes[k] != _glossOpenAscii && runes[k] != _glossOpenFull)) {
        continue;
      }
      k++;
      bool seenCjk = false;
      bool ok = true;
      while (k < runes.length &&
          runes[k] != _glossCloseAscii &&
          runes[k] != _glossCloseFull) {
        if (!_isGlossFillerRune(runes[k])) {
          ok = false;
          break;
        }
        if (_isCjkRune(runes[k])) {
          seenCjk = true;
        }
        k++;
      }
      if (ok && seenCjk && k < runes.length) {
        starts.add(cursor.offsets[tokenStart]);
      }
    }
  }

  /// Test hook for 性能-#51: the linear gloss scans.
  @visibleForTesting
  static Set<int> glossedTermTokenStartsForTest(String text) =>
      _glossedTermTokenStarts(text);

  /// Test hook for 性能-#51: the linear parenthesized-gloss check.
  @visibleForTesting
  static bool isParenthesizedTermGlossForTest(String text, String token) =>
      _isParenthesizedTermGloss(text, token);

  /// Whether [token] appears inside parentheses/quotes that are immediately
  /// preceded by CJK context, i.e. a translator gloss such as
  /// `伐林开垦（assarting）` or `伐林开垦(assarting)`. Such a retained term is
  /// a deliberate first-occurrence gloss rather than bare untranslated text,
  /// so it should be allowed to stay next to Chinese.
  static bool _isParenthesizedTermGloss(String text, String token) {
    if (token.isEmpty) {
      return false;
    }
    // 性能-#51: linear rune scans. The old direction-2 regex
    // `token\s*[（(][^）)]*<CJK>[^）)]*[）)]` backtracked quadratically on
    // long unclosed parenthesized runs (measured 233ms at n=1600 for a
    // single hasMatch — the two [^）)]* split the same run around each CJK
    // char); direction-1 shared the shape around the token, and hasMatch
    // retried at every position. indexOf finds occurrences natively and
    // each is checked with one bounded walk.
    final _RuneCursor cursor = _RuneCursor(text);
    final int tokenRuneLength = token.runes.length;
    int from = 0;
    while (true) {
      final int occurrence = text.indexOf(token, from);
      if (occurrence < 0) {
        return false;
      }
      final int start = cursor.runeIndexAt(occurrence);
      final int end = start + tokenRuneLength;
      if (_glossParensAfterToken(cursor, end) ||
          _glossParensBeforeToken(cursor, start, end)) {
        return true;
      }
      from = occurrence + 1;
    }
  }

  /// Direction 2 of [_isParenthesizedTermGloss]: [tokenEnd] is followed by
  /// optional whitespace and an open paren whose content (up to the close
  /// paren) holds at least one CJK char. Each rune is visited once.
  static bool _glossParensAfterToken(_RuneCursor cursor, int tokenEnd) {
    final List<int> runes = cursor.runes;
    int i = tokenEnd;
    while (i < runes.length && _isGlossSpaceRune(runes[i])) {
      i++;
    }
    if (i >= runes.length ||
        (runes[i] != _glossOpenAscii && runes[i] != _glossOpenFull)) {
      return false;
    }
    i++;
    bool seenCjk = false;
    while (i < runes.length &&
        runes[i] != _glossCloseAscii &&
        runes[i] != _glossCloseFull) {
      if (_isCjkRune(runes[i])) {
        seenCjk = true;
      }
      i++;
    }
    return seenCjk && i < runes.length;
  }

  /// Direction 1 of [_isParenthesizedTermGloss]: an open paren preceded
  /// (through whitespace) by CJK sits immediately before the token, with
  /// only gloss filler between the paren and the token, and filler plus a
  /// close paren after the token.
  static bool _glossParensBeforeToken(
    _RuneCursor cursor,
    int tokenStart,
    int tokenEnd,
  ) {
    final List<int> runes = cursor.runes;
    int i = tokenStart - 1;
    while (i >= 0 && _isGlossFillerRune(runes[i])) {
      i--;
    }
    if (i < 0 || (runes[i] != _glossOpenAscii && runes[i] != _glossOpenFull)) {
      return false;
    }
    i--;
    while (i >= 0 && _isGlossSpaceRune(runes[i])) {
      i--;
    }
    if (i < 0 || !_isCjkRune(runes[i])) {
      return false;
    }
    int j = tokenEnd;
    while (j < runes.length && _isGlossFillerRune(runes[j])) {
      j++;
    }
    return j < runes.length &&
        (runes[j] == _glossCloseAscii || runes[j] == _glossCloseFull);
  }

  static bool _isCjkTargetLanguage(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    return _isChineseTargetLanguage(lower) ||
        _isJapaneseTargetLanguage(lower) ||
        _isKoreanTargetLanguage(lower);
  }

  static bool _isChineseTargetLanguage(String lower) =>
      RegExp(r'^zh(?:[-_]|$)').hasMatch(lower) ||
      _matchesLanguageName(lower, 'chinese') ||
      lower.contains('中文') ||
      lower.contains('汉语') ||
      lower.contains('漢語');

  static bool _isJapaneseTargetLanguage(String lower) =>
      RegExp(r'^ja(?:[-_]|$)').hasMatch(lower) ||
      _matchesLanguageName(lower, 'japanese') ||
      lower.contains('日本語') ||
      lower.contains('日语') ||
      lower.contains('日語');

  static bool _isKoreanTargetLanguage(String lower) =>
      RegExp(r'^ko(?:[-_]|$)').hasMatch(lower) ||
      _matchesLanguageName(lower, 'korean') ||
      lower.contains('한국어') ||
      lower.contains('韩语') ||
      lower.contains('韓語');

  static int? _runeBefore(String text, int offset) {
    if (offset <= 0) {
      return null;
    }
    final int lastCodeUnit = text.codeUnitAt(offset - 1);
    if (lastCodeUnit >= 0xDC00 && lastCodeUnit <= 0xDFFF && offset >= 2) {
      return String.fromCharCodes(<int>[
        text.codeUnitAt(offset - 2),
        lastCodeUnit,
      ]).runes.first;
    }
    return lastCodeUnit;
  }

  static int? _runeAt(String text, int offset) {
    if (offset >= text.length) {
      return null;
    }
    final int high = text.codeUnitAt(offset);
    if (high >= 0xD800 && high <= 0xDBFF && offset + 1 < text.length) {
      final int low = text.codeUnitAt(offset + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        return 0x10000 + ((high - 0xD800) << 10) + low - 0xDC00;
      }
    }
    return high;
  }

  static bool _isCjkRune(int rune) {
    return (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x3400 && rune <= 0x9FFF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x20000 && rune <= 0x2FA1F);
  }

  static int _englishWordCount(String text) {
    return RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(text).length;
  }

  static String _normalizeText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<Element> _outermostWorkTitleCandidates(Document document) {
    return document.querySelectorAll('i, em, cite').where((Element candidate) {
      if (candidate.localName == 'cite') {
        return !_hasAncestorWithTag(candidate, const <String>{'cite'});
      }
      return !_hasAncestorWithTag(candidate, const <String>{
            'i',
            'em',
            'cite',
          }) &&
          candidate.querySelector('cite') == null;
    }).toList();
  }

  static bool _hasAncestorWithTag(Element element, Set<String> tags) {
    Node? ancestor = element.parentNode;
    while (ancestor != null) {
      if (ancestor is Element && tags.contains(ancestor.localName)) {
        return true;
      }
      ancestor = ancestor.parentNode;
    }
    return false;
  }

  static String _elementStructurePath(Element element) {
    final List<int> indexes = <int>[];
    Node? current = element;
    while (current is Element && current.localName != 'body') {
      final Node? parent = current.parentNode;
      if (parent == null) {
        break;
      }
      indexes.add(parent.children.indexOf(current));
      current = parent;
    }
    return indexes.reversed.join('/');
  }

  static bool _looksLikeEnglishWorkTitle(String text) {
    final String normalized = _normalizeText(text);
    if (normalized.isEmpty || normalized.length > 140) {
      return false;
    }
    // Source HTML often keeps a trailing period inside italicized titles
    // ("The Great Reckoning.") without making them ordinary sentences.
    final String titleCore = normalized.replaceFirst(RegExp(r'[.!?。！？]+$'), '');
    if (titleCore.isEmpty || titleCore.length > 140) {
      return false;
    }
    // Short abbreviations inside a title (for example `Alt. Abracadabra`)
    // are not sentence punctuation. Remove those abbreviation periods before
    // checking for punctuation that should disqualify a title candidate.
    final String withoutAbbreviationPeriods = titleCore
        .replaceAll(RegExp(r'\b(?:[A-Za-z]\.){2,}(?=\s|$)'), '')
        .replaceAll(RegExp(r'\b[A-Za-z]{1,3}\.(?=\s+[A-Z])'), '');
    if (RegExp(r'[.!?。！？]').hasMatch(withoutAbbreviationPeriods) ||
        RegExp(
          r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
        ).hasMatch(titleCore)) {
      return false;
    }
    final List<String> words = _englishWorkTitleWords(titleCore);
    // Two-word title-case names are common for books and newsletters
    // ("Strategic Investment", "Blade Runner").
    return words.length >= 2 &&
        words.length <= 16 &&
        _looksLikeEnglishTitleOrName(words);
  }

  static bool _looksLikeSentenceOrInstruction(String text) {
    final List<String> words = _englishWorkTitleWords(
      text,
    ).map((String word) => word.toLowerCase()).toList(growable: false);
    if (words.isEmpty) {
      return false;
    }
    const Set<String> commandOpeners = <String>{
      'click',
      'close',
      'continue',
      'do',
      "don't",
      'enter',
      'follow',
      'never',
      'open',
      'please',
      'press',
      'read',
      'restart',
      'select',
      'sign',
      'start',
      'stop',
      'tap',
      'turn',
      'wait',
    };
    if (commandOpeners.contains(words.first)) {
      return true;
    }
    const Set<String> sentenceSubjects = <String>{
      'he',
      'i',
      'it',
      'she',
      'that',
      'these',
      'they',
      'this',
      'those',
      'we',
      'you',
    };
    if (sentenceSubjects.contains(words.first)) {
      return true;
    }
    const Set<String> auxiliariesAndModals = <String>{
      'am',
      'are',
      'can',
      'could',
      'did',
      'do',
      'does',
      'had',
      'has',
      'have',
      'is',
      'may',
      'might',
      'must',
      'shall',
      'should',
      'was',
      'were',
      'will',
      'would',
    };
    if (words.any(auxiliariesAndModals.contains)) {
      return true;
    }
    return words.length >= 2 &&
        words[0] == 'important' &&
        const <String>{
          'information',
          'notice',
          'safety',
          'warning',
        }.contains(words[1]);
  }

  static bool _looksLikeImperativeOrNotice(String text) {
    final List<String> words = _englishWorkTitleWords(
      text,
    ).map((String word) => word.toLowerCase()).toList(growable: false);
    if (words.isEmpty) {
      return false;
    }
    const Set<String> imperativeOpeners = <String>{
      'click',
      'close',
      'continue',
      'do',
      "don't",
      'enter',
      'follow',
      'never',
      'open',
      'please',
      'press',
      'read',
      'restart',
      'select',
      'sign',
      'start',
      'stop',
      'tap',
      'turn',
      'wait',
    };
    return imperativeOpeners.contains(words.first) ||
        (words.length >= 2 &&
            words.first == 'important' &&
            const <String>{
              'information',
              'notice',
              'safety',
              'warning',
            }.contains(words[1]));
  }

  static String _sourceTextBeforeNode(
    Document document,
    Node target, {
    int? maxLength = 120,
  }) {
    final StringBuffer precedingText = StringBuffer();

    bool collectUntilTarget(Node node) {
      if (identical(node, target)) {
        return true;
      }
      if (node.nodeType == Node.TEXT_NODE) {
        precedingText.write(' ${node.text ?? ''}');
        return false;
      }
      for (final Node child in node.nodes) {
        if (collectUntilTarget(child)) {
          return true;
        }
      }
      return false;
    }

    collectUntilTarget(
      _nearestSemanticBlock(target) ?? document.body ?? document,
    );
    final String normalized = _normalizeText(precedingText.toString());
    return maxLength == null || normalized.length <= maxLength
        ? normalized
        : normalized.substring(normalized.length - maxLength);
  }

  static Element? _nearestSemanticBlock(Node target) {
    const Set<String> semanticBlockTags = <String>{
      'p',
      'li',
      'blockquote',
      'dd',
      'dt',
      'figcaption',
      'caption',
      'summary',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'td',
      'th',
    };
    Node? ancestor = target.parentNode;
    while (ancestor != null) {
      if (ancestor is Element &&
          semanticBlockTags.contains(ancestor.localName)) {
        return ancestor;
      }
      ancestor = ancestor.parentNode;
    }
    return null;
  }

  static bool _hasWorkTitleSemantics(
    Document document,
    Element element,
    String title, {
    required Map<Node, _WorkTitleBlockContext> contexts,
  }) {
    final Element? semanticBlock = _nearestSemanticBlock(element);
    if (semanticBlock != null && _hasSignatureSemantics(semanticBlock)) {
      return false;
    }
    if (element.localName == 'cite' || element.querySelector('cite') != null) {
      return true;
    }
    if (_looksLikeImperativeOrNotice(title)) {
      return false;
    }
    // 性能-#39: the text around the candidate is traversed once here and
    // shared by every context check below, instead of re-traversed per
    // check (O(checks × text)). The 120-char window is a suffix of the
    // full preceding text, so one traversal serves both.
    final root = semanticBlock ?? document.body ?? document;
    final context = contexts.putIfAbsent(
      root,
      () => _WorkTitleBlockContext(root),
    );
    final span = context.spans[element]!;
    final String precedingFull = _normalizeText(
      context.text.substring(0, span.$1),
    );
    final String precedingText = precedingFull.length <= 120
        ? precedingFull
        : precedingFull.substring(precedingFull.length - 120);
    final String followingText = _normalizeText(
      context.text.substring(span.$2),
    );
    return _hasExplicitWorkReferenceContext(precedingText) ||
        _hasAttributedWorkContext(precedingText, followingText) ||
        _hasDescriptiveWorkContext(precedingText) ||
        _hasBibliographicContext(
          precedingFull,
          followingText,
          semanticBlock,
          title,
        ) ||
        _hasSubjectWorkContext(followingText) ||
        _hasNamedPublicationContext(precedingText) ||
        _hasSerialWorkTitleContext(
          element,
          precedingText,
          semanticBlock,
          title,
        ) ||
        _isOnlyTitleInSemanticBlock(semanticBlock, title);
  }

  static bool _hasExplicitWorkReferenceContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r'(?:\bauthors?\s+of|\bwriters?\s+of|\b(?:book|novel|work|essay|article|report|study|volume|memoir|guide|paper|newsletter|magazine|journal)(?:\s+(?:called|named|titled))?|\b(?:read|reading)|\bwent\s+into)\s*(?:[:\-–—]\s*)?$',
    ).hasMatch(lower);
  }

  static bool _hasAttributedWorkContext(
    String precedingText,
    String followingText,
  ) {
    final String lower = precedingText.toLowerCase();
    if (!RegExp(r'(?:^|\s)(?:in|within)\s*$').hasMatch(lower)) {
      return false;
    }
    return RegExp(
      r"^[,;:]?\s*[A-Z][A-Za-z'’\-]*(?:\s+[A-Z][A-Za-z'’\-]*){0,3}\s+(?:argues?|contends?|describes?|explains?|maintains?|notes?|observes?|proposes?|writes?)\b",
    ).hasMatch(followingText);
  }

  static bool _hasDescriptiveWorkContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r"(?:\b(?:his|her|their|the)\s+)?(?:acclaimed|award-winning|best-selling|celebrated|classic|famous|influential|landmark|seminal)(?:\s+(?:book|essay|memoir|novel|report|study|work))?\s*$",
    ).hasMatch(lower);
  }

  static bool _hasSubjectWorkContext(String followingText) {
    return RegExp(
      r'^(?:[,;:]?\s*)?(?:'
      r'builds?\s+upon|draws?\s+(?:on|from)|is\s+based\s+on|'
      r'explores?|examines?|argues?|contends?|describes?|chronicles?|'
      r'recounts?|presents?|offers?|provides?|remains?|became|becomes|'
      r'changed|continues?|develops?|extends?|follows?|'
      r'is\s+a|was\s+a|were|are\s+a'
      r')\b',
      caseSensitive: false,
    ).hasMatch(followingText);
  }

  static bool _hasNamedPublicationContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r'(?:\b(?:our|the|his|her|their)\s+)?(?:newsletter|magazine|journal|newspaper|column|periodical|publication|bulletin|digest)\b[,:\s]*$',
    ).hasMatch(lower);
  }

  static bool _clearMatchingAuditedForeignTerms(
    Document sourceDocument,
    Document translatedDocument, {
    required String targetLanguage,
  }) {
    const Map<String, Set<String>> auditedNodeTexts = auditedForeignTermNodes;
    final List<Element> sourceInline = sourceDocument.querySelectorAll('i, em');
    final List<Element> translatedInline = translatedDocument.querySelectorAll(
      'i, em',
    );
    if (sourceInline.length != translatedInline.length) {
      // A model may fully translate an audited foreign term into the target
      // language and drop the italic wrapper entirely (for example
      // <i>—de facto</i> -> “实际上”), or it may keep the audited term as
      // plain text without the italic wrapper (for example
      // <i>politique,</i> -> “politique”). Both are acceptable: the term
      // itself is approved for retention; the wrapper is presentation only.
      final String translatedVisibleText = _normalizeText(
        translatedDocument.body?.text ?? translatedDocument.text ?? '',
      );
      for (final Element element in sourceInline) {
        if (element.children.isNotEmpty ||
            !auditedNodeTexts.containsKey(element.text)) {
          continue;
        }
        final String core = _auditedCoreText(element.text);
        if (core.isNotEmpty) {
          // Whether the term is translated away or retained verbatim, the
          // source node is no longer a residual to complain about.
          element.text = '';
          if (translatedVisibleText.contains(core)) {
            final List<Element> translatedMatching = translatedDocument
                .querySelectorAll('*')
                .where(
                  (Element candidate) =>
                      candidate.children.isEmpty &&
                      _normalizeText(candidate.text) == core,
                )
                .toList(growable: false);
            for (final Element candidate in translatedMatching) {
              candidate.text = '';
            }
          }
        }
      }
      return true;
    }

    for (int index = 0; index < sourceInline.length; index += 1) {
      final Element sourceElement = sourceInline[index];
      final Element translatedElement = translatedInline[index];
      final Set<String>? allowedTranslations =
          auditedNodeTexts[sourceElement.text];
      if (sourceElement.children.isNotEmpty || allowedTranslations == null) {
        continue;
      }
      if (sourceElement.localName != translatedElement.localName ||
          _taggedElementStructurePath(sourceElement) !=
              _taggedElementStructurePath(translatedElement) ||
          !_sameElementAttributes(sourceElement, translatedElement) ||
          translatedElement.children.isNotEmpty) {
        return false;
      }
      final String normalizedTranslated = _normalizeAuditedTerm(
        translatedElement.text,
      );
      final bool normalizedAllowed = allowedTranslations.any(
        (String candidate) =>
            _normalizeAuditedTerm(candidate) == normalizedTranslated,
      );
      if (!normalizedAllowed) {
        if (translatedElement.text.runes.any(_isLatinLetterRune) ||
            !_hasTargetScript(
              translatedElement.text,
              targetLanguage: targetLanguage,
            )) {
          return false;
        }
        continue;
      }
      sourceElement.text = '';
      translatedElement.text = '';
    }
    return true;
  }

  /// Normalizes only quote variants (curly to straight/absent) and a single
  /// trailing comma or period so audited foreign terms still match when the
  /// model normalizes quotes or drops the audited boundary comma (for example
  /// `“sistema del potere,”` -> `"sistema del potere"`). Any other change --
  /// leading whitespace, a semicolon, an internal edit -- must stay a
  /// rejection, because those unreviewed forms are exactly what the strict
  /// tests require to fail.
  static String _normalizeAuditedTerm(String value) {
    final String withoutQuotes = value.replaceAll(RegExp(r'[“”"„‟«»]'), '');
    return withoutQuotes.replaceFirst(RegExp(r'[,，。.]$'), '');
  }

  /// Normalizes a work-title candidate so trailing punctuation (for example
  /// `The General Crisis of the Seventeenth Century,`) does not prevent
  /// matching the same title retained without that punctuation in the
  /// translation.
  static String _normalizedWorkTitleText(String text) {
    return _normalizeText(text).replaceFirst(RegExp(r'[,;:。，；：.!?！？]+$'), '');
  }

  /// Whether [translatedText] holds [sourceTitle] as an original-title gloss
  /// inside a Chinese book-title wrapper, for example
  /// `《道德与立法原理导论》（An Introduction to the Principles of Morals and
  /// Legislation）`.
  static bool _isWorkTitleGlossRetention(
    String translatedText,
    String sourceTitle,
  ) {
    final String normalizedTranslated = _normalizeText(translatedText);
    if (!RegExp(r'[《「『〈（]').hasMatch(normalizedTranslated)) {
      return false;
    }
    final String normalizedSource = _normalizedWorkTitleText(sourceTitle);
    if (normalizedSource.isEmpty) {
      return false;
    }
    return normalizedTranslated.contains(normalizedSource);
  }

  /// Clears one retained source work title when the model moved it out of its
  /// original inline wrapper and placed it inside CJK book-title/parenthesis
  /// marks (for example `《The Sovereign Individual》`). This only mutates the
  /// parsed quality-check document, never the final HTML returned to callers.
  static bool _clearCjkMarkedWorkTitleGloss(
    Document translatedDocument,
    String sourceTitle, {
    required String targetLanguage,
  }) {
    final String normalizedSource = _normalizedWorkTitleText(sourceTitle);
    if (normalizedSource.isEmpty ||
        _looksLikeSentenceOrInstruction(normalizedSource)) {
      return false;
    }
    final String translatedBody =
        translatedDocument.body?.text ?? translatedDocument.text ?? '';
    if (!_hasTargetScript(translatedBody, targetLanguage: targetLanguage)) {
      return false;
    }
    final RegExp retainedTitle = RegExp(
      r'[《「『〈（]\s*' +
          RegExp.escape(normalizedSource) +
          r'\s*[,.;:，。；：]?\s*[》」』〉）]',
      caseSensitive: false,
    );
    for (final Text node in _textNodes(translatedDocument)) {
      final String data = node.data;
      final RegExpMatch? match = retainedTitle.firstMatch(data);
      if (match == null) {
        continue;
      }
      final String matchedTitle = match.group(0)!;
      final int titleStart = matchedTitle.toLowerCase().indexOf(
        normalizedSource.toLowerCase(),
      );
      if (titleStart < 0) {
        continue;
      }
      final int absoluteStart = match.start + titleStart;
      node.data = data.replaceRange(
        absoluteStart,
        absoluteStart + normalizedSource.length,
        '',
      );
      return true;
    }
    return false;
  }

  /// Audited source-language foreign terms that may legitimately stay in the
  /// translated text (typically historical Latin/Italian expressions).
  static const Map<String, Set<String>> auditedForeignTermNodes =
      <String, Set<String>>{
        'Homo economicus': <String>{'Homo economicus'},
        'agri deserti,': <String>{
          'agri deserti,',
          'agri deserti',
          'agri deserti，',
        },
        'civitas,': <String>{'civitas,', 'civitas', 'civitas，'},
        'cullagium,"': <String>{
          'cullagium,"',
          'cullagium',
          'cullagium,',
          'cullagium，',
          'cullagium,”',
          'cullagium，”',
        },
        'militum perpetuum,': <String>{
          'militum perpetuum,',
          'militum perpetuum',
          'militum perpetuum，',
        },
        'op. cit.,': <String>{
          'op. cit.,',
          'op. cit.',
          'op. cit.，',
          'op. cit',
          '同上引文',
          '前引书',
        },
        'pagus': <String>{'pagus'},
        'patria,': <String>{'patria,', 'patria', 'patria，'},
        'patria': <String>{'patria'},
        'patricius': <String>{'patricius'},
        'politique,': <String>{'politique,', 'politique', 'politique，'},
        'plentitude potestatis': <String>{'plentitude potestatis'},
        '“sistema del potere,”': <String>{
          '“sistema del potere,”',
          'sistema del potere',
          'sistema del potere,',
          '“sistema del potere”',
          'sistema del potere，',
          '“sistema del potere，”',
        },
        'prophetae': <String>{'prophetae'},
        'ultimum refugium,': <String>{
          'ultimum refugium,',
          'ultimum refugium',
          'ultimum refugium，',
        },
        '—de facto': <String>{
          '—de facto',
          '——de facto',
          '–de facto',
          '-de facto',
          '--de facto',
          'de facto',
        },
      };

  /// Whether [nodeText] is an exact audited foreign term source node.
  static bool isAuditedForeignTermNodeText(String nodeText) {
    return auditedForeignTermNodes.containsKey(nodeText);
  }

  /// Removes audited foreign terms that the *source* actually contains from
  /// [text] before heuristic counts (for example work-title word counting and
  /// CJK-adjacent checks) so retained terms such as `patria` or `de facto`
  /// are not mistaken for untranslated English prose. Unreviewed source forms
  /// (for example `agri deserti` without its audited comma form) stay intact
  /// and continue to be flagged.
  static String _stripSourceAuditedForeignTermsFromText(
    Set<String> sourceCores,
    String text,
  ) {
    String stripped = text;
    for (final String core in sourceCores) {
      stripped = stripped.replaceAll(
        RegExp(RegExp.escape(core), caseSensitive: false),
        ' ',
      );
    }
    return stripped;
  }

  static Set<String> _sourceAuditedForeignTermCores(Document sourceDocument) {
    final Set<String> sourceCores = <String>{};
    for (final Element element in sourceDocument.querySelectorAll('i, em')) {
      if (element.children.isNotEmpty ||
          !auditedForeignTermNodes.containsKey(element.text)) {
        continue;
      }
      final String core = _auditedCoreText(element.text);
      if (core.isNotEmpty) {
        sourceCores.add(core);
      }
    }
    return sourceCores;
  }

  /// Strips surrounding punctuation/quotes/whitespace from an audited source
  /// node so we can detect whether the source-language term still appears in
  /// the translated text (for example `—de facto` -> `de facto`).
  static String _auditedCoreText(String value) {
    return value.replaceAll(
      RegExp(r'^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$', unicode: true),
      '',
    );
  }

  static String _taggedElementStructurePath(Element element) {
    final List<String> segments = <String>[];
    Node? current = element;
    while (current is Element && current.localName != 'body') {
      final Node? parent = current.parentNode;
      if (parent == null) {
        break;
      }
      segments.add('${current.localName}:${parent.children.indexOf(current)}');
      current = parent;
    }
    return segments.reversed.join('/');
  }

  static void _clearMatchingInvertedIndexPersonNames(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    final List<Element> sourceTerms = sourceDocument
        .querySelectorAll('span')
        .where(_isLeafIndexTerm)
        .toList(growable: false);
    final List<Element> translatedTerms = translatedDocument
        .querySelectorAll('span')
        .where(_isLeafIndexTerm)
        .toList(growable: false);
    if (sourceTerms.length != translatedTerms.length) {
      return;
    }

    for (int index = 0; index < sourceTerms.length; index += 1) {
      final Element sourceElement = sourceTerms[index];
      final Element translatedElement = translatedTerms[index];
      final String? sourceName = _canonicalInvertedIndexPersonName(
        sourceElement.text,
      );
      final String? translatedName =
          _canonicalInvertedIndexPersonName(translatedElement.text) ??
          _canonicalRetainedPersonName(_normalizeText(translatedElement.text));
      if (sourceName == null ||
          translatedName == null ||
          sourceName != translatedName ||
          !_sameElementAttributes(sourceElement, translatedElement) ||
          _taggedElementStructurePath(sourceElement) !=
              _taggedElementStructurePath(translatedElement)) {
        continue;
      }
      sourceElement.text = '';
      translatedElement.text = '';
    }
  }

  static bool _sameElementAttributes(Element source, Element translated) {
    if (source.attributes.length != translated.attributes.length) {
      return false;
    }
    for (final MapEntry<Object, String> attribute
        in source.attributes.entries) {
      if (translated.attributes[attribute.key] != attribute.value) {
        return false;
      }
    }
    return true;
  }

  static bool _isLeafIndexTerm(Element element) {
    if (element.children.isNotEmpty || element.parent?.localName != 'li') {
      return false;
    }
    return (element.attributes['epub:type'] ?? '')
        .split(RegExp(r'\s+'))
        .map((String token) => token.toLowerCase())
        .contains('index-term');
  }

  static String? _canonicalInvertedIndexPersonName(String text) {
    final String normalized = _normalizeText(text);
    final List<String> commaParts = normalized
        .split(',')
        .map((String part) => part.trim())
        .toList(growable: true);
    if (commaParts.length == 3 && commaParts.last.isEmpty) {
      commaParts.removeLast();
    }
    if (commaParts.length != 2 ||
        commaParts.first.isEmpty ||
        commaParts.last.isEmpty) {
      return null;
    }

    final String surname = commaParts.first;
    final String givenNames = commaParts.last;
    final List<String> surnameWords = _englishWorkTitleWords(surname);
    const Set<String> lowercaseSurnameParticles = <String>{
      'da',
      'de',
      'del',
      'der',
      'di',
      'dos',
      'du',
      'la',
      'le',
      'van',
      'von',
    };
    if (surnameWords.length < 2 ||
        !lowercaseSurnameParticles.contains(surnameWords.first.toLowerCase())) {
      return null;
    }

    final List<String> normalizedSurnameWords = surnameWords
        .map(
          (String word) =>
              lowercaseSurnameParticles.contains(word.toLowerCase())
              ? word.toLowerCase()
              : word,
        )
        .toList(growable: false);

    final String naturalOrder =
        '$givenNames ${normalizedSurnameWords.join(' ')}';
    final List<String> naturalWords = _englishWorkTitleWords(naturalOrder);
    if (naturalWords.length < 3 || naturalWords.length > 6) {
      return null;
    }
    return _canonicalRetainedPersonName(naturalOrder);
  }

  static bool _hasSerialWorkTitleContext(
    Element element,
    String precedingText,
    Element? semanticBlock,
    String title,
  ) {
    final String lower = precedingText.toLowerCase();
    if (!RegExp(r'\b(?:and|or)\s*$').hasMatch(lower)) {
      return false;
    }
    final Element? block = semanticBlock;
    if (block == null) {
      return false;
    }
    for (final Element candidate in block.querySelectorAll('i, em, cite')) {
      if (identical(candidate, element)) {
        continue;
      }
      final String other = _normalizeText(candidate.text);
      if (other != title && _looksLikeEnglishWorkTitle(other)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasBibliographicContext(
    String precedingFull,
    String followingText,
    Element? semanticBlock,
    String title,
  ) {
    final Element? block = semanticBlock;
    if (block == null) {
      return false;
    }
    final String blockText = _normalizeText(block.text);
    if (blockText == title) {
      return false;
    }
    final String before = precedingFull;
    final String after = followingText;
    final bool hasYearOrIdentifier = RegExp(
      r'\b(?:18|19|20)\d{2}\b|\bISBN\b|(?:(?:https?|ftp)://|www\.)',
      caseSensitive: false,
    ).hasMatch('$before $after');
    final bool hasAuthorLikePrefix = RegExp(
      r"(?:^|[.;])\s*[A-Z][A-Za-z'’\-]+,\s*(?:[A-Z][A-Za-z'’\-]*\s*){1,4}[.:]?\s*$",
    ).hasMatch(before);
    return hasYearOrIdentifier && hasAuthorLikePrefix;
  }

  static bool _isOnlyTitleInSemanticBlock(
    Element? semanticBlock,
    String title,
  ) {
    final Element? block = semanticBlock;
    if (block == null || _normalizeText(block.text) != title) {
      return false;
    }
    final int wordCount = _englishWorkTitleWords(title).length;
    return wordCount <= 4 || !_looksLikeSentenceOrInstruction(title);
  }

  static void _clearRetainedProperNames(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    final List<Element> sourceInline = sourceDocument.querySelectorAll(
      'i, em, cite',
    );
    final List<Element> translatedInline = translatedDocument.querySelectorAll(
      'i, em, cite',
    );
    if (sourceInline.length != translatedInline.length) {
      return;
    }
    final List<int> retainedNameIndexes = <int>[];
    final Map<Node, List<String>> retainedNamesByBlock = <Node, List<String>>{};
    for (int index = 0; index < sourceInline.length; index += 1) {
      final Element sourceElement = sourceInline[index];
      final Element translatedElement = translatedInline[index];
      final String sourceText = _normalizeText(sourceElement.text);
      final Node contextRoot =
          _nearestSemanticBlock(sourceElement) ??
          sourceDocument.body ??
          sourceDocument;
      final List<String> precedingRetainedNames = retainedNamesByBlock
          .putIfAbsent(contextRoot, () => <String>[]);
      final bool matchingCreditName =
          sourceText == _normalizeText(translatedElement.text) &&
          _hasRetainedProperNameContext(
            sourceDocument,
            sourceElement,
            precedingRetainedNames,
          );
      final bool matchingEpigraphAttribution = _isMatchingEpigraphAttribution(
        sourceElement,
        translatedElement,
      );
      if (sourceElement.localName == translatedElement.localName &&
          _elementStructurePath(sourceElement) ==
              _elementStructurePath(translatedElement) &&
          sourceElement.children.isEmpty &&
          translatedElement.children.isEmpty &&
          _looksLikeRetainedProperName(sourceText) &&
          (matchingCreditName || matchingEpigraphAttribution)) {
        retainedNameIndexes.add(index);
        precedingRetainedNames.add(sourceText);
      }
    }
    for (final int index in retainedNameIndexes) {
      sourceInline[index].text = '';
      translatedInline[index].text = '';
    }
  }

  static bool _isMatchingEpigraphAttribution(
    Element sourceElement,
    Element translatedElement,
  ) {
    if (!_isEpigraphAttributionLocation(sourceElement) ||
        !_isEpigraphAttributionLocation(translatedElement)) {
      return false;
    }
    final String? sourceName = _epigraphAttributionName(sourceElement.text);
    final String? translatedName = _epigraphAttributionName(
      translatedElement.text,
    );
    return sourceName != null &&
        translatedName != null &&
        sourceName == translatedName;
  }

  static bool _isEpigraphAttributionLocation(Element element) {
    final Node? paragraphNode = element.parentNode;
    if (paragraphNode is! Element || paragraphNode.localName != 'p') {
      return false;
    }
    if (!_hasEpigraphAttributionSemantics(paragraphNode)) {
      return false;
    }
    final Node? blockquoteNode = paragraphNode.parentNode;
    if (blockquoteNode is! Element ||
        blockquoteNode.localName != 'blockquote') {
      return false;
    }
    final List<Element> inlineCandidates = paragraphNode.querySelectorAll(
      'i, em, cite',
    );
    if (inlineCandidates.length != 1 ||
        !identical(inlineCandidates.single, element) ||
        _hasVisibleTextBeforeChild(paragraphNode, element) ||
        !_hasVisibleTextAfterChild(paragraphNode, element)) {
      return false;
    }
    final List<Element> visibleParagraphs = blockquoteNode.children
        .where(
          (Element child) =>
              child.localName == 'p' && _normalizeText(child.text).isNotEmpty,
        )
        .toList(growable: false);
    return visibleParagraphs.length >= 2 &&
        identical(visibleParagraphs.last, paragraphNode);
  }

  static bool _hasEpigraphAttributionSemantics(Element paragraph) {
    final Set<String> classTokens = paragraph.classes
        .map((String token) => token.toLowerCase())
        .toSet();
    const Set<String> recognizedClasses = <String>{
      'attribution',
      'epi-att',
      'epigraph-attribution',
      'epigraph-author',
      'quote-attribution',
      'quote-author',
    };
    return classTokens.any(recognizedClasses.contains);
  }

  static bool _hasVisibleTextBeforeChild(Element parent, Node target) {
    for (final Node child in parent.nodes) {
      if (identical(child, target)) {
        return false;
      }
      if (_normalizeText(child.text ?? '').isNotEmpty) {
        return true;
      }
    }
    return true;
  }

  static bool _hasVisibleTextAfterChild(Element parent, Node target) {
    bool foundTarget = false;
    for (final Node child in parent.nodes) {
      if (identical(child, target)) {
        foundTarget = true;
        continue;
      }
      if (foundTarget && _normalizeText(child.text ?? '').isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static String? _epigraphAttributionName(String text) {
    final String normalized = _normalizeText(text);
    final RegExpMatch? match = RegExp(
      r'^(?:[-\u2012\u2013\u2014\u2015]\s*)+(.+?)[,，;；:：]\s*$',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final String name = _normalizeText(match.group(1) ?? '');
    return _canonicalRetainedPersonName(name);
  }

  static String? _canonicalRetainedPersonName(String name) {
    if (name.isEmpty || _looksLikeSentenceOrInstruction(name)) {
      return null;
    }
    for (final int rune in name.runes) {
      final bool allowedSeparator =
          rune == 0x20 ||
          rune == 0x27 ||
          rune == 0x2D ||
          rune == 0x2E ||
          rune == 0x2018 ||
          rune == 0x2019;
      if (!_isLatinLetterRune(rune) &&
          !_isCombiningDiacriticalMark(rune) &&
          !allowedSeparator) {
        return null;
      }
    }
    final List<String> words = _englishWorkTitleWords(name);
    if (words.length < 2 || words.length > 6) {
      return null;
    }
    if (const <String>{
      'a',
      'an',
      'the',
      'this',
      'these',
      'those',
    }.contains(words.first.toLowerCase())) {
      return null;
    }
    const Set<String> nameParticles = <String>{
      'da',
      'de',
      'del',
      'der',
      'di',
      'dos',
      'du',
      'la',
      'le',
      'van',
      'von',
    };
    for (final String word in words) {
      if (nameParticles.contains(word.toLowerCase())) {
        continue;
      }
      final String first = String.fromCharCode(word.runes.first);
      if (first != first.toUpperCase() || first == first.toLowerCase()) {
        return null;
      }
    }
    return words.join(' ');
  }

  static bool _looksLikeRetainedProperName(String text) {
    final List<String> words = _englishWorkTitleWords(text);
    if (words.length < 2 || words.length > 6) {
      return false;
    }
    const Set<String> nameParticles = <String>{
      'and',
      'da',
      'de',
      'del',
      'der',
      'di',
      'dos',
      'du',
      'la',
      'le',
      'of',
      'the',
      'van',
      'von',
    };
    final List<String> significantWords = words
        .where((String word) => !nameParticles.contains(word.toLowerCase()))
        .toList();
    if (significantWords.isEmpty) {
      return false;
    }
    final int titleCaseOrInitialWords = significantWords.where((String word) {
      final String first = String.fromCharCode(word.runes.first);
      return first == first.toUpperCase() && first != first.toLowerCase();
    }).length;
    return titleCaseOrInitialWords / significantWords.length > 0.5;
  }

  static bool _hasRetainedProperNameContext(
    Document sourceDocument,
    Element sourceElement,
    List<String> precedingRetainedNames,
  ) {
    final String precedingText = _sourceTextBeforeNode(
      sourceDocument,
      sourceElement,
      maxLength: null,
    ).toLowerCase();
    final List<RegExpMatch> creditCues = RegExp(
      r'\b(?:(?:written|edited|designed|illustrated|translated|photographed|compiled|created)\s+by|(?:book|cover|jacket)\s+design\s+by|(?:graphics|illustrations|art)\s+by)\s*(?:[:\-–—]\s*)?',
    ).allMatches(precedingText).toList();
    if (creditCues.isEmpty) {
      return false;
    }
    String remaining = precedingText.substring(creditCues.last.end).trim();
    if (remaining.isEmpty) {
      return true;
    }
    bool consumedRetainedName = false;
    for (final String retainedName in precedingRetainedNames) {
      final String normalizedName = retainedName.toLowerCase();
      if (!_startsWithWholeCreditName(remaining, normalizedName)) {
        continue;
      }
      remaining = remaining.substring(normalizedName.length).trimLeft();
      remaining = remaining.replaceFirst(
        RegExp(r'^(?:(?:and\b|&|[,;])\s*)+'),
        '',
      );
      consumedRetainedName = true;
    }
    return consumedRetainedName && remaining.trim().isEmpty;
  }

  static bool _startsWithWholeCreditName(String text, String name) {
    if (!text.startsWith(name)) {
      return false;
    }
    if (text.length == name.length) {
      return true;
    }
    final String next = text.substring(name.length, name.length + 1);
    return RegExp(r'[\s,&;]').hasMatch(next);
  }

  /// Work titles appearing inside source-language `<i>/<em>/<cite>` nodes.
  /// Computed before any clearing logic, so retained titles can be verified
  /// even after the source copies are scrubbed from the parsed document.
  static Set<String> _sourceInlineWorkTitles(Document document) {
    return document
        .querySelectorAll('i, em, cite')
        .map(
          (Element element) =>
              _normalizedWorkTitleText(_normalizeText(element.text)),
        )
        .where(
          (String title) =>
              title.isNotEmpty && _looksLikeEnglishWorkTitle(title),
        )
        .toSet();
  }

  static bool _hasRemainingTranslatedInlineResidual(
    Document translatedDocument, {
    required Set<String> sourceInlineWorkTitles,
  }) {
    return translatedDocument
        .querySelectorAll('i, em, cite')
        .any(
          (Element element) =>
              _looksLikeEnglishWorkTitle(_normalizeText(element.text)) &&
              !sourceInlineWorkTitles.contains(
                _normalizedWorkTitleText(_normalizeText(element.text)),
              ),
        );
  }

  /// Clears matching retained work-title nodes from `<i>/<em>/<cite>` in both
  /// the source and translated documents, so a title kept verbatim in its own
  /// emphasis node is not later misread as untranslated source prose. A
  /// title-like node in the translation is only cleared when an equivalent
  /// source node exists, keeping genuinely untranslated emphasis prose intact.
  static void _clearInlineEmphasisTitleNodes(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    // Only clear retained title nodes when the surrounding block was actually
    // translated (has target-script context). A block that is still entirely
    // English — for example an untranslated emphasized instruction like
    // `Important Safety Information For All New Device Owners Today` — must
    // not be exempted just because its emphasis text is title-cased.
    final String translatedBody =
        translatedDocument.body?.text ?? translatedDocument.text ?? '';
    final bool hasTargetScriptContext = RegExp(
      r'[\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).hasMatch(translatedBody);
    if (!hasTargetScriptContext) {
      return;
    }
    final List<Element> sourceTitles = sourceDocument
        .querySelectorAll('i, em, cite')
        .where(
          (Element element) =>
              _looksLikeEnglishWorkTitle(_normalizeText(element.text)) &&
              !_looksLikeSentenceOrInstruction(_normalizeText(element.text)),
        )
        .toList(growable: false);
    // Imperative / instruction-like emphasis (for example
    // `Please Read All Instructions Before Continuing`) is never a work title
    // even when it is title-cased, so leave it in place to be caught by the
    // residual checks.
    final List<Element> translatedTitles = translatedDocument
        .querySelectorAll('i, em, cite')
        .where(
          (Element element) =>
              _looksLikeEnglishWorkTitle(_normalizeText(element.text)) &&
              !_looksLikeSentenceOrInstruction(_normalizeText(element.text)),
        )
        .toList(growable: false);
    for (final Element translatedTitle in translatedTitles) {
      final String normalized = _normalizedWorkTitleText(
        _normalizeText(translatedTitle.text),
      );
      if (normalized.isEmpty) {
        continue;
      }
      for (final Element sourceTitle in sourceTitles) {
        if (_normalizedWorkTitleText(_normalizeText(sourceTitle.text)) ==
            normalized) {
          translatedTitle.text = '';
          sourceTitle.text = '';
          break;
        }
      }
    }
  }

  static bool _hasSourceOwnedShortEnglishProse(
    Document sourceDocument,
    Document translatedDocument, {
    bool isBibliographicEntry = false,
  }) {
    if (isBibliographicEntry) {
      // A bibliography / endnote entry conventionally keeps several fields in
      // the original language: author names, journal names, volume/issue/year
      // and page numbers, publisher and city. These retained fields appear as
      // `allSourceEnglishRetained` text nodes that are exactly the same in the
      // source and the translation, so the per-node prose check below would
      // mistake them for untranslated sentences. When the surrounding entry was
      // actually translated (it contains target-script text), skip the per-node
      // check; a completely untranslated entry is still rejected because no
      // target-script context exists to gate this exemption.
      final String translatedBody =
          translatedDocument.body?.text ?? translatedDocument.text ?? '';
      final bool hasTargetScriptContext = RegExp(
        r'[\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
      ).hasMatch(translatedBody);
      if (hasTargetScriptContext) {
        return false;
      }
    }
    // Retained work titles inside their own `<i>/<em>/<cite>` nodes are
    // deliberate (for example the newsletter title <i>Strategic Investment</i>
    // kept verbatim inside otherwise-translated prose). Clear the matching
    // source/translation title nodes before the pairwise text-node comparison
    // so they are not mistaken for untranslated source prose.
    _clearInlineEmphasisTitleNodes(sourceDocument, translatedDocument);
    final List<Text> sourceTextNodes = _textNodes(sourceDocument);
    final List<Text> translatedTextNodes = _textNodes(translatedDocument);
    if (sourceTextNodes.length == translatedTextNodes.length) {
      for (int index = 0; index < sourceTextNodes.length; index += 1) {
        if (_hasSuspiciousSourceOwnedEnglishText(
          sourceTextNodes[index].data,
          translatedTextNodes[index].data,
        )) {
          return true;
        }
      }
      return false;
    }
    return _hasSuspiciousSourceOwnedEnglishText(
      sourceDocument.body?.text ?? sourceDocument.text ?? '',
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
    );
  }

  static List<Text> _textNodes(Document document) {
    final List<Text> result = <Text>[];

    void collect(Node node) {
      if (node is Text) {
        result.add(node);
        return;
      }
      if (node is Element &&
          const <String>{'script', 'style'}.contains(node.localName)) {
        return;
      }
      for (final Node child in node.nodes) {
        collect(child);
      }
    }

    collect(document.body ?? document);
    return result;
  }

  static bool _hasSuspiciousSourceOwnedEnglishText(
    String sourceText,
    String translatedText,
  ) {
    final String strippedSource = _stripNonLinguisticTokens(sourceText);
    final String strippedTranslated = _stripNonLinguisticTokens(translatedText);
    final List<String> sourceWords = _englishWorkTitleWords(strippedSource);
    final List<String> translatedWords = _englishWorkTitleWords(
      strippedTranslated,
    );
    if (sourceWords.length < 2 || translatedWords.length < 2) {
      return false;
    }

    final bool hasTargetLanguageContext = RegExp(
      r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).hasMatch(strippedTranslated);
    final bool allSourceEnglishRetained =
        sourceWords.length == translatedWords.length &&
        _sameWordsIgnoreCase(sourceWords, translatedWords);
    if (allSourceEnglishRetained) {
      if (!hasTargetLanguageContext) {
        // A lone retained epigraph attribution (`—CHARLES TILLY`) is a
        // deliberate retention, not an untranslated sentence. Requiring the
        // leading dash keeps ordinary unmodified `sig` text (for example
        // `Peter Thiel` or `Los Angeles`) out of this exemption.
        if (RegExp(r'^[-–—]').hasMatch(strippedSource.trim())) {
          final String name = _normalizeText(
            strippedSource,
          ).replaceFirst(RegExp(r'^[-–—]\s*'), '');
          if (_canonicalRetainedPersonName(name) != null) {
            return false;
          }
        }
        // A short all-lowercase transliteration/term retained verbatim in
        // both source and translated inline node (for example the pinyin
        // gloss `chum yum`) is a deliberate term retention, not an
        // untranslated sentence. Only very short lowercase runs qualify so
        // title-case proper names such as `Peter Thiel` or `Los Angeles`
        // and full English sentences still fail.
        if (_looksLikeSentenceOrInstruction(strippedTranslated) ||
            _isCommonInstructionPhrase(strippedTranslated) ||
            RegExp(r'[.!?。！？]').hasMatch(strippedTranslated)) {
          return true;
        }
        final bool isShortLowercaseTransliteration =
            translatedWords.isNotEmpty &&
            translatedWords.length <= 4 &&
            translatedWords.every(
              (String word) => word == word.toLowerCase(),
            ) &&
            !RegExp(r'[.!?]').hasMatch(strippedTranslated) &&
            // P2-#20: common instruction/signal phrases ("do not enter")
            // are ordinary untranslated prose, not transliterated terms.
            !_isCommonInstructionPhrase(strippedTranslated);
        if (isShortLowercaseTransliteration) {
          return false;
        }
        return true;
      }
      // A retained English work title inside an otherwise-translated inline
      // node (for example 《道德与立法原理导论》（An Introduction to the
      // Principles of Morals and Legislation）) is a deliberate original-title
      // gloss marked with CJK book-title brackets. Exempt it before the
      // sentence-ending heuristic so a book title whose source ends with a
      // period is not mistaken for a lone untranslated sentence.
      final bool isCjkMarkedTitle =
          _looksLikeEnglishTitleOrName(translatedWords) &&
          RegExp(r'[《「『〈》」』〉]').hasMatch(strippedTranslated);
      if (isCjkMarkedTitle) {
        return false;
      }
      final bool hasSentenceEnding = RegExp(
        r'''[.!?]["'\u2019\u201D)\]]*\s*$''',
      ).hasMatch(strippedSource.trim());
      if (translatedWords.length >= 3 && hasSentenceEnding) {
        return true;
      }
      if (_looksLikeSentenceOrInstruction(strippedSource)) {
        return true;
      }
      if (_looksLikeEnglishTitleOrName(translatedWords)) {
        return false;
      }
      final bool isStandaloneLowercaseTerm =
          translatedWords.every((String word) => word == word.toLowerCase()) &&
          !RegExp(r'[.!?]').hasMatch(strippedSource);
      return !isStandaloneLowercaseTerm;
    }

    for (final List<String> run in _englishRunsSeparatedByTargetScript(
      strippedTranslated,
    )) {
      if (run.length < 2 ||
          !_containsWordSequenceIgnoreCase(sourceWords, run)) {
        continue;
      }
      if (_canonicalRetainedPersonName(run.join(' ')) != null) {
        continue;
      }
      if (_looksLikeEnglishTitleOrName(run)) {
        continue;
      }
      // Legal case names such as `Roe v. Wade` (or the embedded form
      // `Roe v. Wade案`) are conventionally retained verbatim in translated
      // legal/commentary prose. Recognize the `X v. Y` shape so these
      // retentions are not treated as untranslated sentences.
      if (_looksLikeLegalCaseName(run)) {
        continue;
      }
      // An original-term gloss in parentheses after a Chinese translation
      // (for example 南方黑手党（Dixie mafia）) is a deliberate first-use
      // retention. The run may contain a lowercase ordinary word (`mafia`),
      // so it is not title-like, but it still sits inside the parenthesized
      // gloss and must not be treated as untranslated prose.
      final String runText = run.join(' ');
      if (_isParenthesizedTermGloss(strippedTranslated, runText)) {
        continue;
      }
      final bool allLowercase = run.every(
        (String word) => word == word.toLowerCase(),
      );
      final double sourceCoverage = run.length / sourceWords.length;
      if (hasTargetLanguageContext &&
          allLowercase &&
          run.length <= 4 &&
          sourceCoverage < 0.75) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// P2-#20: short lowercase signage/instruction phrases that must never be
  /// mistaken for transliterated terms (e.g. `<p>do not enter</p>` left
  /// untranslated). Compared against the stripped text node.
  /// Test hook for P2-#12: boundary-punctuation stripping before the
  /// common-instruction-phrase denylist lookup.
  @visibleForTesting
  static bool isCommonInstructionPhraseForTest(String text) =>
      _isCommonInstructionPhrase(text);

  static bool _isCommonInstructionPhrase(String text) {
    // P2-#12: strip boundary punctuation before matching, so "no smoking:"
    // and "keep out;" are still recognized instead of being exempted.
    final String normalized = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'^[\p{P}]+|[\p{P}]+$', unicode: true), '');
    return _commonInstructionPhrases.contains(normalized);
  }

  static const Set<String> _commonInstructionPhrases = <String>{
    'do not enter',
    'no entry',
    'no admittance',
    'keep out',
    'do not disturb',
    'no smoking',
    'no trespassing',
    'do not touch',
    'no parking',
    'no photographs',
    'no photos',
    'do not feed',
    'mind the gap',
    'no littering',
    'do not litter',
    'keep off the grass',
    'staff only',
    'no exit',
    'do not cross',
    'do not lean',
    'no loitering',
    'do not block',
    'keep clear',
    'do not use',
    'beware of dog',
    'do not spit',
    'no spitting',
    'keep right',
    'keep left',
    'slow down',
    'give way',
  };

  static bool _sameWordsIgnoreCase(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (int index = 0; index < left.length; index += 1) {
      if (left[index].toLowerCase() != right[index].toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  static List<List<String>> _englishRunsSeparatedByTargetScript(String text) {
    final List<List<String>> runs = <List<String>>[];
    List<String> current = <String>[];

    void finishRun() {
      if (current.isNotEmpty) {
        runs.add(current);
        current = <String>[];
      }
    }

    for (final RegExpMatch match in RegExp(
      r"[A-Za-z][A-Za-z'’\-]*|[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]",
    ).allMatches(text)) {
      final String token = match.group(0) ?? '';
      if (RegExp(r'^[A-Za-z]').hasMatch(token)) {
        current.add(token.replaceAll('’', "'"));
      } else {
        finishRun();
      }
    }
    finishRun();
    return runs;
  }

  static bool _containsWordSequenceIgnoreCase(
    List<String> words,
    List<String> candidate,
  ) {
    if (candidate.length > words.length) {
      return false;
    }
    for (int start = 0; start <= words.length - candidate.length; start += 1) {
      bool matches = true;
      for (int index = 0; index < candidate.length; index += 1) {
        if (words[start + index].toLowerCase() !=
            candidate[index].toLowerCase()) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }

  static List<String> _englishWorkTitleWords(String text) {
    final List<String> words = <String>[];
    final List<int> current = <int>[];

    void finishWord() {
      while (current.isNotEmpty &&
          (current.last == 0x27 || current.last == 0x2D)) {
        current.removeLast();
      }
      if (current.isNotEmpty) {
        words.add(String.fromCharCodes(current));
        current.clear();
      }
    }

    for (final int rune in text.runes) {
      if (_isLatinLetterRune(rune)) {
        current.add(rune);
        continue;
      }
      final bool followsLetterOrMark =
          current.isNotEmpty &&
          (_isLatinLetterRune(current.last) ||
              _isCombiningDiacriticalMark(current.last));
      if (_isCombiningDiacriticalMark(rune) && followsLetterOrMark) {
        current.add(rune);
        continue;
      }
      if ((rune == 0x27 || rune == 0x2018 || rune == 0x2019) &&
          followsLetterOrMark) {
        current.add(0x27);
        continue;
      }
      if (rune == 0x2D && followsLetterOrMark) {
        current.add(rune);
        continue;
      }
      finishWord();
    }
    finishWord();
    return words;
  }

  static bool _isLatinLetterRune(int rune) {
    return (rune >= 0x0041 && rune <= 0x005A) ||
        (rune >= 0x0061 && rune <= 0x007A) ||
        (rune >= 0x00C0 && rune <= 0x00D6) ||
        (rune >= 0x00D8 && rune <= 0x00F6) ||
        (rune >= 0x00F8 && rune <= 0x02AF) ||
        (rune >= 0x1E00 && rune <= 0x1EFF) ||
        (rune >= 0x2C60 && rune <= 0x2C7F) ||
        (rune >= 0xA720 && rune <= 0xA7FF) ||
        (rune >= 0xAB30 && rune <= 0xAB6F) ||
        (rune >= 0xFF21 && rune <= 0xFF3A) ||
        (rune >= 0xFF41 && rune <= 0xFF5A) ||
        (rune >= 0x10780 && rune <= 0x107BF) ||
        (rune >= 0x1D400 && rune <= 0x1D6A5) ||
        (rune >= 0x1DF00 && rune <= 0x1DFFF);
  }

  static bool _isCombiningDiacriticalMark(int rune) {
    return rune >= 0x0300 && rune <= 0x036F;
  }

  static String _stripNonLinguisticTokens(String text) {
    return text
        .replaceAll(
          RegExp(
            r'''(?:(?:https?|ftp)://|www\.)[A-Z0-9._~:/?#\[\]@!$&'()*+,;=%-]+''',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'''\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b''',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'''\b[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z]{2,})+(?:/[-A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?\b''',
          ),
          ' ',
        );
  }

  static bool _hasSuspiciousEnglishRun(
    String text, {
    required bool allowTitleLikeRun,
  }) {
    final List<String> current = <String>[];

    bool currentRunIsSuspicious() {
      return current.length >= 7 &&
          !(allowTitleLikeRun && _looksLikeEnglishTitleOrName(current));
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

  static bool _looksLikeBibliographicCitation(String sourceText) {
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

  static bool _looksLikeEnglishTitleOrName(List<String> words) {
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
  static bool _looksLikeLegalCaseName(List<String> words) {
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

  /// Debug-only probe: applies [TranslationQuality._looksLikeEnglishTitleOrName]
  /// to the English words of a mixed-CJK inline node.
  static bool debugLooksLikeEnglishTitleOrName(String text) {
    return _looksLikeEnglishTitleOrName(_englishWorkTitleWords(text));
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
