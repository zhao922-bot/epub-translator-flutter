/// Redacts API keys and common secret patterns from log / error text.
class SensitiveText {
  const SensitiveText._();

  /// Removes configured keys and common secret shapes from [text].
  static String redact(String text, {String? configuredApiKey}) {
    String redacted = text;
    final String configuredKey = configuredApiKey?.trim() ?? '';
    if (configuredKey.isNotEmpty) {
      redacted = redacted.replaceAll(configuredKey, '[redacted]');
    }
    redacted = redacted.replaceAllMapped(
      RegExp(
        r'(Authorization\s*[:=]\s*Bearer\s+)[^\s,\}\]]+',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}[redacted]',
    );
    redacted = redacted.replaceAllMapped(
      RegExp(r'(api[_-]?key\s*[:=]\s*)[^\s,\}\]]+', caseSensitive: false),
      (Match match) => '${match.group(1)}[redacted]',
    );
    redacted = redacted.replaceAll(
      RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}\b'),
      'sk-[redacted]',
    );
    return redacted;
  }
}
