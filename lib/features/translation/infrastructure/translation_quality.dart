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
      allowTitleLikeRun: _looksLikeBibliographicCitation(sourceText),
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
  }) {
    if (!shouldCheckResidual(targetLanguage)) {
      return null;
    }
    final Document sourceDocument = html_parser.parse(sourceHtml);
    final Document translatedDocument = html_parser.parse(translatedHtml);
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
            _hasWorkTitleSemantics(sourceDocument, sourceCandidate, sourceText);
        if (canExempt) {
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
        if (_looksLikeEnglishWorkTitle(sourceText)) {
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

    _clearMatchingAuditedForeignTerms(sourceDocument, translatedDocument);
    _clearMatchingInvertedIndexPersonNames(sourceDocument, translatedDocument);
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
    if (normalized.isEmpty || normalized.length > 140) {
      return false;
    }
    // Source HTML often keeps a trailing period inside italicized titles
    // ("The Great Reckoning.") without making them ordinary sentences.
    final String titleCore = normalized.replaceFirst(RegExp(r'[.!?。！？]+$'), '');
    if (titleCore.isEmpty ||
        titleCore.length > 140 ||
        RegExp(r'[.!?。！？]').hasMatch(titleCore) ||
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

  static String _sourceTextAfterNode(Document document, Node target) {
    final StringBuffer followingText = StringBuffer();
    bool foundTarget = false;

    void collectAfterTarget(Node node) {
      if (identical(node, target)) {
        foundTarget = true;
        return;
      }
      if (foundTarget && node.nodeType == Node.TEXT_NODE) {
        followingText.write(' ${node.text ?? ''}');
        return;
      }
      for (final Node child in node.nodes) {
        collectAfterTarget(child);
      }
    }

    collectAfterTarget(
      _nearestSemanticBlock(target) ?? document.body ?? document,
    );
    return _normalizeText(followingText.toString());
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
    String title,
  ) {
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
    return _hasExplicitWorkReferenceContext(document, element) ||
        _hasAttributedWorkContext(document, element) ||
        _hasDescriptiveWorkContext(document, element) ||
        _hasBibliographicContext(document, element, title) ||
        _hasSubjectWorkContext(document, element) ||
        _hasNamedPublicationContext(document, element) ||
        _hasSerialWorkTitleContext(document, element, title) ||
        _isOnlyTitleInSemanticBlock(element, title);
  }

  static bool _hasExplicitWorkReferenceContext(
    Document document,
    Element element,
  ) {
    final String precedingText = _sourceTextBeforeNode(
      document,
      element,
    ).toLowerCase();
    return RegExp(
      r'(?:\bauthors?\s+of|\bwriters?\s+of|\b(?:book|novel|work|essay|article|report|study|volume|memoir|guide|paper|newsletter|magazine|journal)(?:\s+(?:called|named|titled))?|\b(?:read|reading)|\bwent\s+into)\s*(?:[:\-–—]\s*)?$',
    ).hasMatch(precedingText);
  }

  static bool _hasAttributedWorkContext(Document document, Element element) {
    final String precedingText = _sourceTextBeforeNode(
      document,
      element,
    ).toLowerCase();
    if (!RegExp(r'(?:^|\s)(?:in|within)\s*$').hasMatch(precedingText)) {
      return false;
    }
    final String followingText = _sourceTextAfterNode(document, element);
    return RegExp(
      r"^[,;:]?\s*[A-Z][A-Za-z'’\-]*(?:\s+[A-Z][A-Za-z'’\-]*){0,3}\s+(?:argues?|contends?|describes?|explains?|maintains?|notes?|observes?|proposes?|writes?)\b",
    ).hasMatch(followingText);
  }

  static bool _hasDescriptiveWorkContext(Document document, Element element) {
    final String precedingText = _sourceTextBeforeNode(
      document,
      element,
    ).toLowerCase();
    return RegExp(
      r"(?:\b(?:his|her|their|the)\s+)?(?:acclaimed|award-winning|best-selling|celebrated|classic|famous|influential|landmark|seminal)(?:\s+(?:book|essay|memoir|novel|report|study|work))?\s*$",
    ).hasMatch(precedingText);
  }

  static bool _hasSubjectWorkContext(Document document, Element element) {
    final String followingText = _sourceTextAfterNode(document, element);
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

  static bool _hasNamedPublicationContext(Document document, Element element) {
    final String precedingText = _sourceTextBeforeNode(
      document,
      element,
    ).toLowerCase();
    return RegExp(
      r'(?:\b(?:our|the|his|her|their)\s+)?(?:newsletter|magazine|journal|newspaper|column|periodical|publication|bulletin|digest)\b[,:\s]*$',
    ).hasMatch(precedingText);
  }

  static void _clearMatchingAuditedForeignTerms(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    const Set<String> auditedTerms = <String>{'patricius'};
    final List<Element> sourceInline = sourceDocument.querySelectorAll('i, em');
    final List<Element> translatedInline = translatedDocument.querySelectorAll(
      'i, em',
    );
    if (sourceInline.length != translatedInline.length) {
      return;
    }

    for (int index = 0; index < sourceInline.length; index += 1) {
      final Element sourceElement = sourceInline[index];
      final Element translatedElement = translatedInline[index];
      final String sourceText = _normalizeText(sourceElement.text);
      final String translatedText = _normalizeText(translatedElement.text);
      if (sourceElement.localName != translatedElement.localName ||
          _taggedElementStructurePath(sourceElement) !=
              _taggedElementStructurePath(translatedElement) ||
          sourceElement.children.isNotEmpty ||
          translatedElement.children.isNotEmpty ||
          sourceElement.text != translatedElement.text ||
          sourceText != translatedText ||
          !RegExp(r"^[A-Za-z][A-Za-z'-]*$").hasMatch(sourceText) ||
          !auditedTerms.contains(sourceText.toLowerCase())) {
        continue;
      }
      sourceElement.text = '';
      translatedElement.text = '';
    }
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
    Document document,
    Element element,
    String title,
  ) {
    final String precedingText = _sourceTextBeforeNode(
      document,
      element,
    ).toLowerCase();
    if (!RegExp(r'\b(?:and|or)\s*$').hasMatch(precedingText)) {
      return false;
    }
    final Element? block = _nearestSemanticBlock(element);
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
    Document document,
    Element element,
    String title,
  ) {
    final Element? block = _nearestSemanticBlock(element);
    if (block == null) {
      return false;
    }
    final String blockText = _normalizeText(block.text);
    if (blockText == title) {
      return false;
    }
    final String before = _sourceTextBeforeNode(
      document,
      element,
      maxLength: null,
    );
    final String after = _sourceTextAfterNode(document, element);
    final bool hasYearOrIdentifier = RegExp(
      r'\b(?:18|19|20)\d{2}\b|\bISBN\b|(?:(?:https?|ftp)://|www\.)',
      caseSensitive: false,
    ).hasMatch('$before $after');
    final bool hasAuthorLikePrefix = RegExp(
      r"(?:^|[.;])\s*[A-Z][A-Za-z'’\-]+,\s*(?:[A-Z][A-Za-z'’\-]*\s*){1,4}[.:]?\s*$",
    ).hasMatch(before);
    return hasYearOrIdentifier && hasAuthorLikePrefix;
  }

  static bool _isOnlyTitleInSemanticBlock(Element element, String title) {
    final Element? block = _nearestSemanticBlock(element);
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

  static bool _hasRemainingTranslatedInlineResidual(Document document) {
    return document
        .querySelectorAll('i, em, cite')
        .any(
          (Element element) =>
              _looksLikeEnglishWorkTitle(_normalizeText(element.text)),
        );
  }

  static bool _hasSourceOwnedShortEnglishProse(
    Document sourceDocument,
    Document translatedDocument,
  ) {
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
        return true;
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
      final bool allLowercase = run.every(
        (String word) => word == word.toLowerCase(),
      );
      final double sourceCoverage = run.length / sourceWords.length;
      if (hasTargetLanguageContext && allLowercase && sourceCoverage < 0.75) {
        continue;
      }
      return true;
    }
    return false;
  }

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
