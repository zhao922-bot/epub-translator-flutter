import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/cancellable_fingerprint.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/cancellation_listener.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';

void main() {
  test('completed retries detach listeners from a long-lived token', () async {
    final token = CancelToken();
    for (var i = 0; i < 100; i++) {
      await TranslationApiClient.delayUnlessCancelled(
        const Duration(microseconds: 1),
        cancelToken: token,
      );
      expect(CancellationListener.activeListenerCount(token), 0);
    }
    token.cancel();
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('cancelling long Retry-After removes its timer', (tester) async {
    final token = CancelToken();
    final delay = TranslationApiClient.delayUnlessCancelled(
      const Duration(days: 1),
      cancelToken: token,
    );
    final assertion = expectLater(
      delay,
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(CancellationListener.activeListenerCount(token), 1);
    token.cancel();
    await tester.pump();
    await assertion;
    expect(CancellationListener.activeListenerCount(token), 0);
    // The widget-test binding asserts no Timer remains at test completion.
  });

  test(
    'fingerprint closes a stalled upstream stream on cancellation',
    () async {
      var closed = false;
      final stream = StreamController<List<int>>(onCancel: () => closed = true);
      final token = CancelToken();
      final result = cancellableFingerprint(stream.stream, cancelToken: token);
      final assertion = expectLater(
        result,
        throwsA(isA<TranslationCancelledException>()),
      );
      stream.add(List<int>.filled(64 * 1024, 42));
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await assertion.timeout(const Duration(seconds: 1));
      expect(closed, isTrue);
      expect(CancellationListener.activeListenerCount(token), 0);
      await stream.close();
    },
  );

  test(
    'callback cancellation closes a stream without waiting for data',
    () async {
      var cancelled = false;
      var closed = false;
      final stream = StreamController<List<int>>(onCancel: () => closed = true);
      final result = cancellableFingerprint(
        stream.stream,
        cancelToken: CancelToken(),
        throwIfCancelled: () {
          if (cancelled) throw const TranslationCancelledException();
        },
      );
      final assertion = expectLater(
        result,
        throwsA(isA<TranslationCancelledException>()),
      );
      cancelled = true;
      await assertion.timeout(const Duration(seconds: 1));
      expect(closed, isTrue);
      await stream.close();
    },
  );

  test('fingerprint preserves digest and detaches after normal EOF', () async {
    final bytes = utf8.encode('EPUB content across chunk boundaries');
    final token = CancelToken();
    final digest = await cancellableFingerprint(
      Stream.fromIterable([bytes.sublist(0, 7), bytes.sublist(7)]),
      cancelToken: token,
    );
    expect(digest, sha256.convert(bytes));
    expect(CancellationListener.activeListenerCount(token), 0);
  });
}
