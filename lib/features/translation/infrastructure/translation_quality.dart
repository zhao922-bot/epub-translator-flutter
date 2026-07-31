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
    final Document sourceDocument = html_parser.parse(sourceHtml);
    final Document translatedDocument = html_parser.parse(translatedHtml);
    final List<Element> sourceTitles = sourceDocument.querySelectorAll(
      'i, em, cite',
    );
    final List<Element> translatedTitles = translatedDocument.querySelectorAll(
      'i, em, cite',
    );

    if (sourceTitles.length == translatedTitles.length) {
      for (int index = 0; index < sourceTitles.length; index += 1) {
        final Element sourceTitle = sourceTitles[index];
        final Element translatedTitle = translatedTitles[index];
        final String sourceText = _normalizeText(sourceTitle.text);
        final String translatedText = _normalizeText(translatedTitle.text);
        if (sourceTitle.localName == translatedTitle.localName &&
            sourceText == translatedText &&
            _looksLikeEnglishWorkTitle(sourceText)) {
          sourceTitle.text = '';
          translatedTitle.text = '';
        }
      }
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

  static int _englishWordCount(String text) {
    return RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(text).length;
  }

  static String _normalizeText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
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
    final List<String> words = RegExp(r"[A-Za-z][A-Za-z'-]*")
        .allMatches(normalized)
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    return words.length >= 3 &&
        words.length <= 16 &&
        _looksLikeEnglishTitleOrName(words);
  }

  static String _stripNonLinguisticTokens(String text) {
    return text
        .replaceAll(
          RegExp(
            r'''(?:(?:https?|ftp)://|www\.)[^\s<>"']+''',
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
      final int first = word.codeUnitAt(0);
      if (first >= 0x41 && first <= 0x5A) {
        titleCaseWords += 1;
      }
    }
    return significantWords >= 3 && titleCaseWords / significantWords >= 0.8;
  }
}
