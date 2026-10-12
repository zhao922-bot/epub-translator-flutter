import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/connection_diagnostic.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const client = TranslationApiClient();
  final invalidChoices = <String, Map<String, dynamic>>{
    'missing message': {},
    'wrong message type': {'message': 'OK'},
    'missing content': {'message': <String, dynamic>{}},
    'empty content': {
      'message': {'content': ''},
    },
    'whitespace content': {
      'message': {'content': ' \n '},
    },
    'wrong content type': {
      'message': {'content': 123},
    },
    'empty content parts': {
      'message': {'content': <dynamic>[]},
    },
    'invalid content parts': {
      'message': {
        'content': [123],
      },
    },
    'reasoning only': {
      'message': {'content': '<think>Internal</think>'},
    },
  };

  for (final language in UiLanguage.values) {
    for (final entry in invalidChoices.entries) {
      test('HTTP 200 ${entry.key} reports parsing error ($language)', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [entry.value],
            }),
          );
          await request.response.close();
        });
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'test-key',
          model: 'test-model',
          uiLanguage: language,
        );
        final expected = AppStrings(language).connectionResponseParseError;
        try {
          await expectLater(
            client.testConnection(config: config),
            throwsA(
              isA<TranslationParseException>()
                  .having(
                    (error) => error.message,
                    'localized error',
                    contains(expected),
                  )
                  .having(
                    (error) => ConnectionDiagnostic.fromError(
                      error,
                      config: config,
                    ).message,
                    'settings diagnostic',
                    contains(expected),
                  ),
            ),
          );
        } finally {
          await subscription.cancel();
          await server.close(force: true);
        }
      });
    }
  }

  test('valid string and text-parts responses preserve visible content', () {
    for (final content in <dynamic>[
      ' OK ',
      [
        {'type': 'text', 'text': ' O'},
        {'type': 'text', 'text': 'K '},
      ],
    ]) {
      expect(
        client.extractMessageContent({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
        }),
        'OK',
      );
    }
  });
}
