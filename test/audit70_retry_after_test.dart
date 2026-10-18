import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';

void main() {
  for (final seconds in ['86400', '9223372036855', '18446744073710']) {
    test(
      'oversized Retry-After $seconds fails instead of becoming a short delay',
      () {
        final options = RequestOptions(path: 'https://offline.invalid');
        final error = DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: options,
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': [seconds],
            }),
          ),
        );
        final parsed = TranslationApiClient.retryAfterDelay(error);
        debugPrint(
          'AUDIT Retry-After seconds=$seconds parsedMicroseconds=${parsed?.inMicroseconds}',
        );
        expect(
          () => TranslationApiClient.retryDelayForError(
            TranslationConfig.defaults(),
            error,
            1,
          ),
          throwsStateError,
          reason:
              'Every value above the 10-minute server cooldown limit must fail without arithmetic wraparound',
        );
      },
    );
  }
}
