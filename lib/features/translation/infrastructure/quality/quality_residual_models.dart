import 'package:html/dom.dart';

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
class RuneCursor {
  RuneCursor(String text) {
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

/// Index the parenthesis boundaries once per text. An unclosed gloss must
/// not rescan the suffix for every occurrence of every retained phrase.
class ParenthesizedTermGlossIndex {
  ParenthesizedTermGlossIndex(this.text) : cursor = RuneCursor(text) {
    final runes = cursor.runes;
    final length = runes.length;
    afterToken = List<bool>.filled(length + 1, false);
    beforeToken = List<bool>.filled(length + 1, false);
    closesAfterToken = List<bool>.filled(length + 1, false);
    final cjkCount = List<int>.filled(length + 1, 0);
    final openAfterCjk = List<bool>.filled(length, false);
    int previousNonSpace = -1;
    int previousNonFiller = -1;
    for (int i = 0; i < length; i++) {
      final rune = runes[i];
      cjkCount[i + 1] =
          cjkCount[i] + (QualityScriptUtils.isCjkRune(rune) ? 1 : 0);
      beforeToken[i] =
          previousNonFiller >= 0 && openAfterCjk[previousNonFiller];
      if (_isOpen(rune)) {
        openAfterCjk[i] =
            previousNonSpace >= 0 &&
            QualityScriptUtils.isCjkRune(runes[previousNonSpace]);
      }
      if (!QualityScriptUtils.isGlossSpaceRune(rune)) previousNonSpace = i;
      if (!QualityScriptUtils.isGlossFillerRune(rune)) previousNonFiller = i;
    }
    int nextClose = length;
    int nextNonSpace = length;
    int nextNonFiller = length;
    for (int i = length - 1; i >= 0; i--) {
      final rune = runes[i];
      if (_isClose(rune)) nextClose = i;
      if (!QualityScriptUtils.isGlossSpaceRune(rune)) nextNonSpace = i;
      if (!QualityScriptUtils.isGlossFillerRune(rune)) nextNonFiller = i;
      closesAfterToken[i] =
          nextNonFiller < length && _isClose(runes[nextNonFiller]);
      afterToken[i] =
          nextNonSpace < length &&
          _isOpen(runes[nextNonSpace]) &&
          nextClose < length &&
          cjkCount[nextClose] > cjkCount[nextNonSpace + 1];
    }
  }

  final String text;
  final RuneCursor cursor;
  late final List<bool> afterToken;
  late final List<bool> beforeToken;
  late final List<bool> closesAfterToken;
  final _results = <String, bool>{};

  static bool _isOpen(int rune) => rune == 0x28 || rune == 0xFF08;
  static bool _isClose(int rune) => rune == 0x29 || rune == 0xFF09;

  bool contains(String token) => _results.putIfAbsent(token, () {
    if (token.isEmpty) return false;
    final tokenLength = token.runes.length;
    int from = 0;
    while (true) {
      final occurrence = text.indexOf(token, from);
      if (occurrence < 0) return false;
      final start = cursor.runeIndexAt(occurrence);
      final end = start + tokenLength;
      if (afterToken[end] || (beforeToken[start] && closesAfterToken[end])) {
        return true;
      }
      from = occurrence + 1;
    }
  });
}

// One traversal per semantic block. Candidate-specific context must stay
// distinct: a book title and an instruction can occupy the same paragraph.
class WorkTitleBlockContext {
  WorkTitleBlockContext(Node root) {
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
class SourceResidualWindowMatcher {
  SourceResidualWindowMatcher(Iterable<String> windows) {
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

/// Shared script, Unicode rune, and whitespace helpers for quality checks.
class QualityScriptUtils {
  const QualityScriptUtils._();

  static const int glossOpenFull = 0xFF08;
  static const int glossOpenAscii = 0x28;
  static const int glossCloseFull = 0xFF09;
  static const int glossCloseAscii = 0x29;

  /// One filler rune inside a clean gloss: whitespace, CJK, or the
  /// punctuation the old `[$nonLatin]` class allowed
  /// (`.,;:，；：、-–—`). O(1), no backtracking.
  static bool isGlossFillerRune(int rune) {
    if (isGlossSpaceRune(rune) || isCjkRune(rune)) {
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
  static bool isGlossSpaceRune(int rune) {
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
  static bool isLatinTokenRune(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || // A-Z
      (rune >= 0x61 && rune <= 0x7A) || // a-z
      (rune >= 0x30 && rune <= 0x39) || // 0-9
      rune == 0x27 || // '
      rune == 0x2019 || // ’
      rune == 0x2D; // -

  static Set<int> glossedTermTokenStarts(String text) {
    final RuneCursor cursor = RuneCursor(text);
    final Set<int> starts = <int>{};
    collectGlossDirection1(cursor, starts);
    collectGlossDirection2(cursor, starts);
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
  static void collectGlossDirection1(RuneCursor cursor, Set<int> starts) {
    final List<int> runes = cursor.runes;
    int i = 0;
    while (i < runes.length) {
      if (runes[i] != glossOpenAscii && runes[i] != glossOpenFull) {
        i++;
        continue;
      }
      // The open paren must be preceded (through whitespace) by CJK.
      int j = i - 1;
      while (j >= 0 && isGlossSpaceRune(runes[j])) {
        j--;
      }
      if (j < 0 || !isCjkRune(runes[j])) {
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
      while (k < runes.length && isGlossFillerRune(runes[k])) {
        if (runes[k] == 0x2D) {
          lastDash = k;
        }
        k++;
      }
      int tokenStart = k;
      while (k < runes.length && isLatinTokenRune(runes[k])) {
        k++;
      }
      if (k == tokenStart && lastDash >= 0) {
        tokenStart = lastDash;
        k = lastDash;
        while (k < runes.length && isLatinTokenRune(runes[k])) {
          k++;
        }
      }
      if (k == tokenStart) {
        i++;
        continue;
      }
      while (k < runes.length && isGlossFillerRune(runes[k])) {
        k++;
      }
      if (k < runes.length &&
          (runes[k] == glossCloseAscii || runes[k] == glossCloseFull)) {
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
  static void collectGlossDirection2(RuneCursor cursor, Set<int> starts) {
    final List<int> runes = cursor.runes;
    int i = 0;
    while (i < runes.length) {
      if (!isLatinTokenRune(runes[i])) {
        i++;
        continue;
      }
      final int tokenStart = i;
      while (i < runes.length && isLatinTokenRune(runes[i])) {
        i++;
      }
      int k = i;
      while (k < runes.length && isGlossSpaceRune(runes[k])) {
        k++;
      }
      if (k >= runes.length ||
          (runes[k] != glossOpenAscii && runes[k] != glossOpenFull)) {
        continue;
      }
      k++;
      bool seenCjk = false;
      bool ok = true;
      while (k < runes.length &&
          runes[k] != glossCloseAscii &&
          runes[k] != glossCloseFull) {
        if (!isGlossFillerRune(runes[k])) {
          ok = false;
          break;
        }
        if (isCjkRune(runes[k])) {
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
  static Set<int> glossedTermTokenStartsForTest(String text) =>
      glossedTermTokenStarts(text);

  /// Test hook for 性能-#51: the linear parenthesized-gloss check.
  static bool isParenthesizedTermGlossForTest(String text, String token) =>
      isParenthesizedTermGloss(text, token);

  /// Whether [token] appears inside parentheses/quotes that are immediately
  /// preceded by CJK context, i.e. a translator gloss such as
  /// `伐林开垦（assarting）` or `伐林开垦(assarting)`. Such a retained term is
  /// a deliberate first-occurrence gloss rather than bare untranslated text,
  /// so it should be allowed to stay next to Chinese.
  static bool isParenthesizedTermGloss(String text, String token) {
    return ParenthesizedTermGlossIndex(text).contains(token);
  }

  static bool hasTargetScript(String text, {required String targetLanguage}) {
    final String lower = targetLanguage.trim().toLowerCase();
    if (isCjkTargetLanguage(lower)) {
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

  static bool isCjkTargetLanguage(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    return isChineseTargetLanguage(lower) ||
        isJapaneseTargetLanguage(lower) ||
        isKoreanTargetLanguage(lower);
  }

  static bool matchesLanguageName(String value, String name) => RegExp(
    '(?:^|[^\\p{L}\\p{N}])${RegExp.escape(name)}(?=\$|[^\\p{L}\\p{N}])',
    unicode: true,
  ).hasMatch(value);

  static bool isChineseTargetLanguage(String lower) =>
      RegExp(r'^zh(?:[-_]|$)').hasMatch(lower) ||
      matchesLanguageName(lower, 'chinese') ||
      lower.contains('中文') ||
      lower.contains('汉语') ||
      lower.contains('漢語');

  static bool isJapaneseTargetLanguage(String lower) =>
      RegExp(r'^ja(?:[-_]|$)').hasMatch(lower) ||
      matchesLanguageName(lower, 'japanese') ||
      lower.contains('日本語') ||
      lower.contains('日语') ||
      lower.contains('日語');

  static bool isKoreanTargetLanguage(String lower) =>
      RegExp(r'^ko(?:[-_]|$)').hasMatch(lower) ||
      matchesLanguageName(lower, 'korean') ||
      lower.contains('한국어') ||
      lower.contains('韩语') ||
      lower.contains('韓語');

  static List<String> englishWorkTitleWords(String text) {
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
      if (isLatinLetterRune(rune)) {
        current.add(rune);
        continue;
      }
      final bool followsLetterOrMark =
          current.isNotEmpty &&
          (isLatinLetterRune(current.last) ||
              isCombiningDiacriticalMark(current.last));
      if (isCombiningDiacriticalMark(rune) && followsLetterOrMark) {
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

  static int? runeBefore(String text, int offset) {
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

  static int? runeAt(String text, int offset) {
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

  static bool isCjkRune(int rune) {
    return (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x3400 && rune <= 0x9FFF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x20000 && rune <= 0x2FA1F);
  }

  static int englishWordCount(String text) {
    return RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(text).length;
  }

  static String normalizeText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static bool isLatinLetterRune(int rune) {
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

  static bool isCombiningDiacriticalMark(int rune) {
    return rune >= 0x0300 && rune <= 0x036F;
  }

  static String stripNonLinguisticTokens(String text) {
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
}
