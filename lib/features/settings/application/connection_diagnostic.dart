import '../../../shared/security/sensitive_text.dart';
import '../../translation/domain/models/translation_config.dart';

class ConnectionDiagnostic {
  const ConnectionDiagnostic(this.message);

  final String message;

  static ConnectionDiagnostic fromError(
    Object error, {
    required TranslationConfig config,
  }) {
    final String raw = SensitiveText.redact(
      error.toString(),
      configuredApiKey: config.apiKey,
    );
    final String lower = raw.toLowerCase();
    final String host = _hostFromConfig(config);

    if (error is FormatException ||
        lower.contains('required before testing the connection')) {
      return const ConnectionDiagnostic(
        'Fill in the Base URL, API key, and model before testing the connection.',
      );
    }

    final int? statusCode = _httpStatusCode(raw);
    if (statusCode == 401) {
      return ConnectionDiagnostic(
        'HTTP 401 authentication failed for $host. Check that the API key is valid, active, and copied without extra spaces.',
      );
    }
    if (statusCode == 403) {
      return ConnectionDiagnostic(
        'HTTP 403 permission denied for $host. Check whether this API key can use ${config.model} and whether the account has access.',
      );
    }
    if (statusCode == 404) {
      return ConnectionDiagnostic(
        'HTTP 404 from $host. Check the Base URL, keep only the provider root or /v1 path, and verify that ${config.model} exists.',
      );
    }
    if (statusCode == 429) {
      return ConnectionDiagnostic(
        'HTTP 429 rate limit from $host. Lower concurrency, wait for quota to recover, or check the provider billing/rate limit page.',
      );
    }
    if (statusCode != null && statusCode >= 500) {
      return ConnectionDiagnostic(
        'HTTP $statusCode from $host. The provider is returning a server error; retry later or test the same key in the provider console.',
      );
    }

    if (lower.contains('tls handshake') || lower.contains('handshake')) {
      return ConnectionDiagnostic(
        'TLS handshake failed for $host. Check the endpoint, proxy/VPN, device date, and whether this network intercepts certificates.',
      );
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('dns')) {
      return ConnectionDiagnostic(
        'DNS lookup failed for $host. Check the Base URL spelling and whether the current network or VPN can resolve the provider host.',
      );
    }
    if (lower.contains('timeout') ||
        lower.contains('connection timed out') ||
        lower.contains('receive timeout') ||
        lower.contains('send timeout')) {
      return ConnectionDiagnostic(
        'Connection to $host timed out. Try a longer timeout, a more stable network, or a reachable proxy/VPN.',
      );
    }
    if (lower.contains('model') &&
        (lower.contains('not found') || lower.contains('does not exist'))) {
      return ConnectionDiagnostic(
        'The provider did not recognize ${config.model}. Check the model name exactly as listed by the API provider.',
      );
    }

    return ConnectionDiagnostic(
      'Connection test failed for $host. Details: $raw',
    );
  }

  static int? _httpStatusCode(String raw) {
    final RegExpMatch? match = RegExp(r'HTTP\s+(\d{3})').firstMatch(raw);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  static String _hostFromConfig(TranslationConfig config) {
    try {
      final String value = config.apiBaseUrl.trim();
      final Uri uri = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      return uri.host.isEmpty ? 'the API host' : uri.host;
    } catch (_) {
      return 'the API host';
    }
  }
}
