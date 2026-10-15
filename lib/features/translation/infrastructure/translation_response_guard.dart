/// A conversational API reply must never become book content. Match explicit
/// translation-related replies, not generic first-person prose; books may
/// themselves quote these messages, so source-owned dialogue stays eligible.
class NonTranslationReplyException extends FormatException {
  const NonTranslationReplyException()
    : super(
        'Non-translation response: the model requested input or declined translation.',
      );
}

class TranslationResponseGuard {
  const TranslationResponseGuard._();

  static final _reply = RegExp(
    r"(?:i\s+(?:(?:do not|don't|don’t|cannot|can't|can’t)\s+(?:see|find)|"
    r"(?:have not|haven't|haven’t)\s+received)\b[^.!?\n]{0,140}"
    r"(?:html|fragment|text|content|passage|input))|"
    r"(?:(?:please|kindly)\s+(?:paste|provide|send|supply|share)\b"
    r"[^.!?\n]{0,140}(?:html|fragment|text|content|passage)[^.!?\n]{0,60}"
    r"(?:translat|original|source)?)|"
    r"(?:(?:no|missing)\s+(?:html|source text|text to translate|input text)"
    r"[^.!?\n]{0,80}(?:provided|included|supplied|received))|"
    r"(?:(?:i(?:'m| am|’m)?\s+(?:cannot|can't|can’t|unable|not able)|"
    r"i(?:'m| am|’m)\s+sorry[^.!?\n]{0,80})[^.!?\n]{0,100}"
    r"(?:translat|comply with|assist with))|"
    r"(?:(?:请|烦请)(?:先|重新|再)?(?:提供|粘贴|发送|输入)[^。！？\n]{0,80}"
    r"(?:原文|待译|待翻译|需要翻译|HTML|文本|片段))|"
    r"(?:(?:没有|未|没能)(?:看到|收到|找到)[^。！？\n]{0,80}"
    r"(?:原文|待译|待翻译|HTML|文本|片段))|"
    r"(?:(?:抱歉|对不起)[^。！？\n]{0,100}(?:无法|不能|不能够)"
    r"[^。！？\n]{0,50}(?:翻译|协助|帮助))",
    caseSensitive: false,
  );

  static bool isNonTranslationReply({
    required String sourceText,
    required String translatedText,
  }) {
    // Only inspect a bounded opening. Do not reject quoted dialogue embedded
    // later in otherwise ordinary prose.
    final text = translatedText.trimLeft();
    final opening = text.substring(0, text.length.clamp(0, 640));
    final hit = _reply.firstMatch(opening);
    if (hit == null || hit.start > 48) return false;
    return !_reply.hasMatch(sourceText);
  }
}
