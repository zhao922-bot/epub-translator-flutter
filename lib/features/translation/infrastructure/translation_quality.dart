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
    if (_englishWordCount(sourceText) < 6) {
      return false;
    }
    final String text = translatedText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      return false;
    }

    final int englishWords = _englishWordCount(text);
    if (englishWords < 7) {
      return false;
    }
    if (_maxConsecutiveEnglishWords(text) >= 7) {
      return true;
    }

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
    return englishWords >= 10 && englishLetters / languageChars >= 0.65;
  }

  static int _englishWordCount(String text) {
    return RegExp(r"[A-Za-z][A-Za-z'-]*").allMatches(text).length;
  }

  static int _maxConsecutiveEnglishWords(String text) {
    int current = 0;
    int maximum = 0;
    for (final RegExpMatch match in RegExp(
      r"[A-Za-z][A-Za-z'-]*|[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]",
    ).allMatches(text)) {
      final String token = match.group(0) ?? '';
      if (RegExp(r"^[A-Za-z][A-Za-z'-]*$").hasMatch(token)) {
        current += 1;
        maximum = current > maximum ? current : maximum;
      } else {
        current = 0;
      }
    }
    return maximum;
  }
}
