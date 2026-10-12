import '../../../shared/security/sensitive_text.dart';
import '../../../shared/localization/app_strings.dart';
import '../../translation/domain/models/translation_config.dart';
import '../../translation/infrastructure/epub/translation_api_client.dart';

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
    final strings = AppStrings(config.uiLanguage);
    final String host = _hostFromConfig(config);

    if (error is TranslationParseException) {
      final message = AppStrings(
        config.uiLanguage,
      ).connectionResponseParseError;
      final detail = SensitiveText.redact(
        error.message,
        configuredApiKey: config.apiKey,
      );
      return ConnectionDiagnostic(
        detail.startsWith(message) ? detail : '$message $detail',
      );
    }

    if (error is MissingApiConfigurationException ||
        lower.contains('required before testing the connection')) {
      return ConnectionDiagnostic(strings.connectionMissingConfiguration);
    }

    final int? statusCode = _httpStatusCode(raw);
    if (statusCode == 401) {
      return ConnectionDiagnostic(strings.connectionAuthError(host));
    }
    if (statusCode == 403) {
      return ConnectionDiagnostic(
        strings.connectionForbiddenError(host, config.model),
      );
    }
    if (statusCode == 404) {
      return ConnectionDiagnostic(
        strings.connectionNotFoundError(host, config.model),
      );
    }
    if (statusCode == 429) {
      return ConnectionDiagnostic(strings.connectionRateLimitError(host));
    }
    if (statusCode != null && statusCode >= 500) {
      return ConnectionDiagnostic(
        strings.connectionServerError(host, statusCode),
      );
    }

    if (lower.contains('tls handshake') || lower.contains('handshake')) {
      return ConnectionDiagnostic(strings.connectionTlsError(host));
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('dns')) {
      return ConnectionDiagnostic(strings.connectionDnsError(host));
    }
    if (lower.contains('timeout') ||
        lower.contains('connection timed out') ||
        lower.contains('receive timeout') ||
        lower.contains('send timeout')) {
      return ConnectionDiagnostic(strings.connectionTimeoutError(host));
    }
    if (lower.contains('model') &&
        (lower.contains('not found') || lower.contains('does not exist'))) {
      return ConnectionDiagnostic(strings.connectionModelError(config.model));
    }

    return ConnectionDiagnostic(strings.connectionFallbackError(host, raw));
  }

  static int? _httpStatusCode(String raw) {
    final RegExpMatch? match = RegExp(r'HTTP\s+(\d{3})').firstMatch(raw);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  static String _hostFromConfig(TranslationConfig config) {
    final fallback = AppStrings(config.uiLanguage).connectionApiHost;
    try {
      final String value = config.apiBaseUrl.trim();
      final Uri uri = Uri.parse(
        value.contains('://') ? value : 'https://$value',
      );
      return uri.host.isEmpty ? fallback : uri.host;
    } catch (_) {
      return fallback;
    }
  }
}
