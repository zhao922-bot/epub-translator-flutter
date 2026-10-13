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
      RegExp(
        r'(Proxy-Authorization\s*[:=]\s*[A-Za-z][A-Za-z0-9_-]*[ \t]+)[^\r\n]+',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}[redacted]',
    );
    redacted = redacted.replaceAllMapped(
      RegExp(
        r'''([?&](?:key|api_key|apikey|token|access_token|access-token|auth_token|secret|client_secret|password|passwd|pwd)=)[^&#\s"'<>]*''',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}***',
    );
    redacted = redacted.replaceAllMapped(
      // Query credentials are already masked; don't consume their neighbours.
      RegExp(
        r'(api[_-]?key\s*[:=]\s*)(?!\*\*\*)[^\s,\}\]]+',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}[redacted]',
    );
    redacted = redacted.replaceAll(
      RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}\b'),
      'sk-[redacted]',
    );
    redacted = redacted.replaceAllMapped(
      RegExp(r'(https?://)[^\s/]+@', caseSensitive: false),
      (Match match) => '${match.group(1)}[redacted]@',
    );
    redacted = redacted.replaceAllMapped(
      RegExp(
        r'''(^|[\s"'(<>=])[^\s:/@"'<>]+:[^\s/"'<>]+@(?=(?:[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+|\[[0-9A-Fa-f:]+\]|[A-Za-z0-9_-]+(?=:\d+|/)))''',
      ),
      (Match match) => '${match.group(1)}[redacted]@',
    );
    return redacted;
  }
}
