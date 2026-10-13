import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _response(String content) => <String, dynamic>{
  'choices': <dynamic>[
    <String, dynamic>{
      'message': <String, dynamic>{'content': content},
    },
  ],
};

DioException _badRequest(String message) {
  final options = RequestOptions(path: '/chat/completions');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: 400,
      data: {
        'error': {'message': message},
      },
    ),
  );
}

void main() {
  const client = TranslationApiClient();

  test('preserves literal think blocks in JSON string values', () {
    const raw = '{"text":"before <think>literal</think> after"}';
    expect(client.extractMessageContent(_response(raw)), raw);
    expect(
      client.decodeBatchJsonPayload(_response(raw))['text'],
      'before <think>literal</think> after',
    );
  });

  test('strips leading reasoning with whitespace, attributes and casing', () {
    expect(
      client.extractMessageContent(
        _response(
          ' \n<THINK mode="reasoning">first\nthought</THINK>\n'
          '<think>second</think> {"text":"visible"}',
        ),
      ),
      '{"text":"visible"}',
    );
  });

  test(
    'strips trailing reasoning without consuming interior literal blocks',
    () {
      const raw = '{"text":"<think>literal</think>"}';
      expect(
        client.extractMessageContent(
          _response(
            '$raw\n<think>afterthought</think> <THINK>another</THINK> \n',
          ),
        ),
        raw,
      );
    },
  );

  test('preserves interior prose and incomplete reasoning tags', () {
    for (final raw in [
      'before <think>literal</think> after',
      '<think>unfinished',
    ]) {
      expect(client.extractMessageContent(_response(raw)), raw);
    }
  });

  test('unsupported max_tokens is a fail-fast configuration error', () {
    for (final message in [
      'Unsupported parameter: max_tokens; use max_completion_tokens instead',
      'Unsupported parameter: max_tokens sets the output token limit',
      'unsupported_parameter: max_tokens',
    ]) {
      final error = _badRequest(message);
      expect(TranslationApiClient.isContextOverflowError(error), isFalse);
      expect(
        TranslationApiClient.shouldFallbackBatchDioException(error),
        isFalse,
      );
      expect(TranslationApiClient.isDeterministicHttpError(error), isTrue);
      expect(TranslationApiClient.shouldRetryBatchError(error), isFalse);
    }
  });

  test('bare max_tokens does not imply overflow', () {
    expect(
      TranslationApiClient.isContextOverflowError(
        _badRequest('Invalid value for max_tokens'),
      ),
      isFalse,
    );
  });

  test('genuine max_tokens length errors still select shrink fallback', () {
    for (final message in [
      'Requested max_tokens 40000 exceeds the model limit of 32768',
      'max_tokens is too large',
      'Limit exceeded for max_tokens',
      'maximum context length exceeded',
    ]) {
      final error = _badRequest(message);
      expect(TranslationApiClient.isContextOverflowError(error), isTrue);
      expect(
        TranslationApiClient.shouldFallbackBatchDioException(error),
        isTrue,
      );
    }
  });

  test('cached regex smoke: whitespace, quote repair and duplicate keys', () {
    for (var i = 0; i < 3; i++) {
      expect(
        client.decodeBatchJsonPayload(
          _response(
            '<think>reason</think>```json\n'
            '{"text" \t\r\n: "say "hello"." \t\r\n}\n```',
          ),
        ),
        {'text': 'say "hello".'},
      );
      expect(
        () => client.decodeJsonObject('{"a" \t\n: 1, "a" \r\n: 2}'),
        throwsFormatException,
      );
    }
  });
}
