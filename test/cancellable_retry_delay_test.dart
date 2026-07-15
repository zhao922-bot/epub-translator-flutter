import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cancellable retry delay', () {
    test(
      'delayUnlessCancelled aborts immediately when token is cancelled',
      () async {
        final CancelToken token = CancelToken();
        final Stopwatch watch = Stopwatch()..start();
        final Future<void> delayFuture =
            TranslationApiClient.delayUnlessCancelled(
              const Duration(seconds: 30),
              cancelToken: token,
            );
        // Cancel shortly after starting; must not wait for the full 30s.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        token.cancel('test-cancel');

        await expectLater(
          delayFuture,
          throwsA(isA<TranslationCancelledException>()),
        );
        watch.stop();
        expect(watch.elapsedMilliseconds, lessThan(2000));
      },
    );

    test(
      'delayUnlessCancelled completes normally when not cancelled',
      () async {
        final CancelToken token = CancelToken();
        final Stopwatch watch = Stopwatch()..start();
        await TranslationApiClient.delayUnlessCancelled(
          const Duration(milliseconds: 40),
          cancelToken: token,
        );
        watch.stop();
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(30));
        expect(token.isCancelled, isFalse);
      },
    );

    test(
      'runRetried passes cancel into the retry wait and exits early',
      () async {
        final CancelToken token = CancelToken();
        final TranslationApiClient client = const TranslationApiClient();
        int attempts = 0;
        final Stopwatch watch = Stopwatch()..start();

        final Future<String> run = client.runRetried<String>(
          config: TranslationConfig.defaults().copyWith(
            maxRetries: 5,
            retryDelaySeconds: 30,
          ),
          cancelToken: token,
          operation: () async {
            attempts += 1;
            throw StateError('transient');
          },
        );

        await Future<void>.delayed(const Duration(milliseconds: 30));
        token.cancel('abort-retry');

        await expectLater(run, throwsA(isA<TranslationCancelledException>()));
        watch.stop();
        expect(attempts, 1);
        expect(watch.elapsedMilliseconds, lessThan(2000));
      },
    );
  });
}
