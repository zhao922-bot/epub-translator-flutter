import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

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

/// Residual / quality checks for translated blocks (multi-language targets).
class TranslationQuality {
  const TranslationQuality._();

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
    if (residualTargets.any(lower.contains)) {
      return true;
    }
    if (lower.startsWith('zh') ||
        lower.startsWith('ja') ||
        lower.startsWith('ko') ||
        lower.startsWith('ru') ||
        lower.startsWith('ar')) {
      return true;
    }
    return false;
  }

  static bool hasSuspiciousSourceResidual({
    required String sourceText,
    required String translatedText,
    required String targetLanguage,
  }) {
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
    if (_hasSuspiciousEnglishRun(
      text,
      allowTitleLikeRun: _looksLikeBibliographicCitation(sourceText),
    )) {
      return true;
    }

    final List<String> englishWordValues = RegExp(
      r"[A-Za-z][A-Za-z'-]*",
    ).allMatches(text).map((RegExpMatch match) => match.group(0)!).toList();
    final int englishLetters = RegExp(r'[A-Za-z]').allMatches(text).length;
    final int nonLatinChars = RegExp(
      r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).allMatches(text).length;
    if (englishLetters >= 40 && nonLatinChars == 0) {
      return true;
    }
    final int languageChars = englishLetters + nonLatinChars;
    if (languageChars == 0) {
      return false;
    }
    final int properNameLikeWords = englishWordValues.where((String word) {
      final int first = word.codeUnitAt(0);
      return first >= 0x41 && first <= 0x5A;
    }).length;
    final bool mostlyProperNames =
        nonLatinChars >= 4 &&
        englishWords >= 4 &&
        properNameLikeWords / englishWords >= 0.65;
    if (mostlyProperNames) {
      return false;
    }
    return englishWords >= 10 && englishLetters / languageChars >= 0.65;
  }

  static TranslationResidualFinding? findSuspiciousHtmlResidual({
    required String sourceHtml,
    required String translatedHtml,
    required String targetLanguage,
  }) {
    if (!shouldCheckResidual(targetLanguage)) {
      return null;
    }
    final Document sourceDocument = html_parser.parse(sourceHtml);
    final Document translatedDocument = html_parser.parse(translatedHtml);
    final List<Element> sourceCandidates = _outermostWorkTitleCandidates(
      sourceDocument,
    );
    final List<Element> translatedCandidates = _outermostWorkTitleCandidates(
      translatedDocument,
    );
    final List<int> exemptedCandidateIndexes = <int>[];
    final List<String> unexemptedSourceTexts = <String>[];

    if (sourceCandidates.length == translatedCandidates.length) {
      for (int index = 0; index < sourceCandidates.length; index += 1) {
        final Element sourceCandidate = sourceCandidates[index];
        final Element translatedCandidate = translatedCandidates[index];
        final String sourceText = _normalizeText(sourceCandidate.text);
        final String translatedText = _normalizeText(translatedCandidate.text);
        final bool canExempt =
            sourceCandidate.localName == translatedCandidate.localName &&
            _elementStructurePath(sourceCandidate) ==
                _elementStructurePath(translatedCandidate) &&
            sourceText == translatedText &&
            _looksLikeEnglishWorkTitle(sourceText) &&
            !_looksLikeInstructionOrNotice(sourceText);
        if (canExempt) {
          exemptedCandidateIndexes.add(index);
          continue;
        }
        if (_englishWorkTitleWords(sourceText).length >= 3) {
          unexemptedSourceTexts.add(sourceText);
        }
      }
    } else {
      for (final Element sourceCandidate in sourceCandidates) {
        final String sourceText = _normalizeText(sourceCandidate.text);
        if (_englishWorkTitleWords(sourceText).length >= 3) {
          unexemptedSourceTexts.add(sourceText);
        }
      }
      final String translatedVisibleText = _normalizeText(
        translatedDocument.body?.text ?? translatedDocument.text ?? '',
      );
      if (_englishWorkTitleWords(translatedVisibleText).length >= 3) {
        return const TranslationResidualFinding(
          kind: TranslationResidualKind.longSourceText,
        );
      }
    }

    for (final int index in exemptedCandidateIndexes) {
      sourceCandidates[index].text = '';
      translatedCandidates[index].text = '';
    }

    _clearRetainedProperNames(sourceDocument, translatedDocument);

    final String? adjacentLowercaseWord = _findCjkAdjacentLowercaseWord(
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
      targetLanguage: targetLanguage,
    );
    if (adjacentLowercaseWord != null) {
      return TranslationResidualFinding(
        kind: TranslationResidualKind.cjkAdjacentLowercaseWord,
        token: adjacentLowercaseWord,
      );
    }

    if (_hasRemainingTranslatedInlineResidual(translatedDocument)) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    if (_hasSourceOwnedShortEnglishProse(sourceDocument, translatedDocument)) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final String translatedVisibleText = _normalizeText(
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
    );
    if (unexemptedSourceTexts.any(translatedVisibleText.contains)) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final bool hasLongSourceText = hasSuspiciousSourceResidual(
      sourceText: sourceDocument.body?.text ?? sourceDocument.text ?? '',
      translatedText:
          translatedDocument.body?.text ?? translatedDocument.text ?? '',
      targetLanguage: targetLanguage,
    );
    if (hasLongSourceText) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    return null;
  }

  static String? _findCjkAdjacentLowercaseWord(
    String text, {
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage)) {
      return null;
    }
    final String strippedText = _stripNonLinguisticTokens(text);
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
        return token;
      }
    }
    return null;
  }

  static bool _isCjkTargetLanguage(String targetLanguage) {
    final String lower = targetLanguage.trim().toLowerCase();
    return RegExp(r'^(?:zh|ja|ko)(?:[-_]|$)').hasMatch(lower) ||
        lower.contains('chinese') ||
        lower.contains('japanese') ||
        lower.contains('korean') ||
        lower.contains('中文') ||
        lower.contains('汉语') ||
        lower.contains('漢語') ||
        lower.contains('日本語') ||
        lower.contains('日语') ||
        lower.contains('日語') ||
        lower.contains('한국어') ||
        lower.contains('韩语') ||
        lower.contains('韓語');
  }

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
    return text.substring(offset).runes.first;
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
    if (normalized.isEmpty ||
        normalized.length > 140 ||
        RegExp(r'[.!?。！？]$').hasMatch(normalized) ||
        RegExp(
          r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
        ).hasMatch(normalized)) {
      return false;
    }
    final List<String> words = _englishWorkTitleWords(normalized);
    return words.length >= 3 &&
        words.length <= 16 &&
        _looksLikeEnglishTitleOrName(words);
  }

  static bool _looksLikeInstructionOrNotice(String text) {
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
    return words.length >= 2 &&
        words[0] == 'important' &&
        const <String>{
          'information',
          'notice',
          'safety',
          'warning',
        }.contains(words[1]);
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
      if (sourceElement.localName == translatedElement.localName &&
          sourceText == _normalizeText(translatedElement.text) &&
          sourceElement.querySelector('i, em, cite') == null &&
          translatedElement.querySelector('i, em, cite') == null &&
          _looksLikeRetainedProperName(sourceText) &&
          _hasRetainedProperNameContext(
            sourceDocument,
            sourceElement,
            precedingRetainedNames,
          )) {
        retainedNameIndexes.add(index);
        precedingRetainedNames.add(sourceText);
      }
    }
    for (final int index in retainedNameIndexes) {
      sourceInline[index].text = '';
      translatedInline[index].text = '';
    }
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

  static bool _hasRemainingTranslatedInlineResidual(Document document) {
    return document
        .querySelectorAll('i, em, cite')
        .any(
          (Element element) => _englishWorkTitleWords(element.text).length >= 3,
        );
  }

  static bool _hasSourceOwnedShortEnglishProse(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    final List<String> sourceWords = _englishWorkTitleWords(
      _stripNonLinguisticTokens(
        sourceDocument.body?.text ?? sourceDocument.text ?? '',
      ),
    );
    final List<String> translatedWords = _englishWorkTitleWords(
      _stripNonLinguisticTokens(
        translatedDocument.body?.text ?? translatedDocument.text ?? '',
      ),
    );
    if (sourceWords.length < 3 || translatedWords.length < 3) {
      return false;
    }

    for (int start = 0; start <= translatedWords.length - 3; start += 1) {
      for (int end = translatedWords.length; end >= start + 3; end -= 1) {
        final List<String> candidate = translatedWords.sublist(start, end);
        if (!_containsWordSequenceIgnoreCase(sourceWords, candidate)) {
          continue;
        }
        if (_looksLikeResidualProse(candidate)) {
          return true;
        }
      }
    }
    return false;
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

  static bool _looksLikeResidualProse(List<String> words) {
    if (_looksLikeEnglishTitleOrName(words) &&
        !_looksLikeInstructionOrNotice(words.join(' '))) {
      return false;
    }
    if (words.length >= 4) {
      return true;
    }
    const Set<String> proseCues = <String>{
      'again',
      'are',
      'be',
      'do',
      'does',
      'is',
      'must',
      'now',
      'please',
      'read',
      'right',
      'should',
      'this',
      'that',
      'try',
      'was',
      'were',
      'will',
    };
    return words
        .map((String word) => word.toLowerCase())
        .any(proseCues.contains);
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
        (rune >= 0x10780 && rune <= 0x107BF) ||
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
      'for',
      'from',
      'in',
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
      if (connectors.contains(word.toLowerCase())) {
        continue;
      }
      significantWords += 1;
      final String first = String.fromCharCode(word.runes.first);
      if (first == first.toUpperCase() && first != first.toLowerCase()) {
        titleCaseWords += 1;
      }
    }
    return significantWords >= 2 && titleCaseWords / significantWords >= 0.8;
  }
}
