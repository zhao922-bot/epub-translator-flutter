import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _chapters = <InspectedChapter>[
  InspectedChapter(
    path: 'chapter.xhtml',
    title: 'Chapter',
    body: 'A chapter.',
    originalHtml: '<html><body><p>A chapter.</p></body></html>',
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
    blocks: [
      ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml: '<p>A chapter.</p>',
        sourceText: 'A chapter.',
      ),
    ],
  ),
];

class _Adapter implements HttpClientAdapter {
  _Adapter({this.retry = false, this.onFailure});
  final bool retry;
  final void Function()? onFailure;
  final started = Completer<void>();
  final cancelled = Completer<void>();
  int requests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (requestStream != null) await requestStream.drain<void>();
    if (!started.isCompleted) started.complete();
    if (retry) {
      onFailure?.call();
      return ResponseBody.fromString('{}', 500);
    }
    await cancelFuture;
    if (!cancelled.isCompleted) cancelled.complete();
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'cancelled',
    );
  }
}

class _Api extends TranslationApiClient {
  _Api(this.adapter, {this.onBuild});
  final _Adapter adapter;
  final void Function()? onBuild;
  int builds = 0;

  @override
  Dio buildDio(TranslationConfig config) {
    builds++;
    onBuild?.call();
    return Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'))
      ..httpClientAdapter = adapter;
  }
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    styleProfileEnabled: true,
    maxRetries: 3,
    retryDelaySeconds: 5,
  );

  test(
    'already-cancelled callback prevents source validation and Dio creation',
    () async {
      final api = _Api(_Adapter());
      await expectLater(
        EpubChapterTranslator(apiClient: api).generateStyleProfile(
          config: config,
          chapters: const [],
          isCancelled: () => true,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(api.builds, 0);
    },
  );

  test(
    'already-cancelled token wins even when style analysis is disabled',
    () async {
      final token = CancelToken()..cancel();
      await expectLater(
        EpubChapterTranslator().generateStyleProfile(
          config: config.copyWith(styleProfileEnabled: false),
          chapters: const [],
          cancelToken: token,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
    },
  );

  test('callback is checked again before the first request', () async {
    bool cancelled = false;
    final adapter = _Adapter();
    final api = _Api(adapter, onBuild: () => cancelled = true);
    await expectLater(
      EpubChapterTranslator(apiClient: api).generateStyleProfile(
        config: config,
        chapters: _chapters,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(adapter.requests, 0);
  });

  for (final explicitToken in [false, true]) {
    test(
      'runtime callback aborts in-flight Dio request (token: $explicitToken)',
      () async {
        bool cancelled = false;
        final adapter = _Adapter();
        final api = _Api(adapter);
        final token = explicitToken ? CancelToken() : null;
        final result = EpubChapterTranslator(apiClient: api)
            .generateStyleProfile(
              config: config,
              chapters: _chapters,
              cancelToken: token,
              isCancelled: () => cancelled,
            );
        final expectation = expectLater(
          result.timeout(const Duration(seconds: 1)),
          throwsA(isA<TranslationCancelledException>()),
        );
        await adapter.started.future;
        cancelled = true;
        await expectation;
        await adapter.cancelled.future.timeout(const Duration(seconds: 1));
        expect(adapter.requests, 1);
        if (token != null) expect(token.isCancelled, isTrue);
      },
    );
  }

  test('callback aborts retry backoff before another billed request', () async {
    bool cancelled = false;
    final adapter = _Adapter(retry: true);
    final result = EpubChapterTranslator(apiClient: _Api(adapter))
        .generateStyleProfile(
          config: config,
          chapters: _chapters,
          isCancelled: () => cancelled,
        );
    final expectation = expectLater(
      result.timeout(const Duration(seconds: 1)),
      throwsA(isA<TranslationCancelledException>()),
    );
    await adapter.started.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancelled = true;
    await expectation;
    expect(adapter.requests, 1);
  });

  test(
    'callback cancels synchronously before entering retry backoff',
    () async {
      bool cancelled = false;
      final token = CancelToken();
      final adapter = _Adapter(retry: true, onFailure: () => cancelled = true);
      final future = EpubChapterTranslator(apiClient: _Api(adapter))
          .generateStyleProfile(
            config: config,
            chapters: _chapters,
            cancelToken: token,
            isCancelled: () => cancelled,
          );
      final expectation = expectLater(
        future,
        throwsA(isA<TranslationCancelledException>()),
      );
      // Flush request completion without advancing the 25ms callback watcher.
      // Cache lookup now performs real IO; wait for the intended failure event
      // instead of assuming source restoration completed in 20 microtasks.
      await adapter.started.future;
      await pumpEventQueue(times: 20);
      expect(token.isCancelled, isTrue);
      await expectation;
      expect(adapter.requests, 1);
    },
  );
}
