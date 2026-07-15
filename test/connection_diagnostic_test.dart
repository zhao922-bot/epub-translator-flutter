import 'package:epub_translator_flutter/features/settings/application/connection_diagnostic.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final TranslationConfig config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://api.example.com/v1',
    model: 'example-model',
  );

  test('explains authentication failures with an API key action', () {
    final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
      StateError(
        'Connection test failed for api.example.com with HTTP 401: Unauthorized',
      ),
      config: config,
    );

    expect(diagnostic.message, contains('API key'));
    expect(diagnostic.message, contains('401'));
  });

  test('explains rate limits with a concurrency or quota action', () {
    final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
      StateError(
        'Connection test failed for api.example.com with HTTP 429: Too Many Requests',
      ),
      config: config,
    );

    expect(diagnostic.message, contains('rate limit'));
    expect(diagnostic.message, contains('concurrency'));
  });

  test('explains DNS failures with endpoint and network actions', () {
    final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
      StateError('SocketException: Failed host lookup: api.example.com'),
      config: config,
    );

    expect(diagnostic.message, contains('DNS'));
    expect(diagnostic.message, contains('Base URL'));
  });

  test('explains missing required settings before making a request', () {
    final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
      const FormatException(
        'API base URL, API key, and model are required before testing the connection.',
      ),
      config: config.copyWith(apiKey: ''),
    );

    expect(diagnostic.message, contains('Fill in'));
    expect(diagnostic.message, contains('API key'));
  });

  test('redacts API keys from fallback error details', () {
    final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
      StateError(
        'Proxy rejected request headers={Authorization: Bearer sk-live-secret1234567890} api_key=sk-query-secret',
      ),
      config: config.copyWith(apiKey: 'sk-config-secret'),
    );

    expect(diagnostic.message, contains('[redacted]'));
    expect(diagnostic.message, isNot(contains('sk-live-secret')));
    expect(diagnostic.message, isNot(contains('sk-query-secret')));
    expect(diagnostic.message, isNot(contains('sk-config-secret')));
  });
}
