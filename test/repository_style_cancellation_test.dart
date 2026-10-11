import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
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
  _Adapter({this.onRequest});
  final void Function()? onRequest;
  final started = Completer<void>();
  final cancelled = Completer<void>();
  CancelToken? token;
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
    token = options.cancelToken;
    if (requestStream != null) await requestStream.drain<void>();
    if (!started.isCompleted) started.complete();
    if (onRequest != null) {
      onRequest!();
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

  test('repository forwards cancellation before source analysis', () async {
    final api = _Api(_Adapter());
    final repository = EpubTranslationRepository(
      translator: EpubChapterTranslator(apiClient: api),
    );
    await expectLater(
      repository.generateStyleProfile(
        config: config,
        chapters: const [],
        isCancelled: () => true,
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(api.builds, 0);
  });

  test('repository callback is rechecked before first API request', () async {
    bool cancelled = false;
    final adapter = _Adapter();
    final api = _Api(adapter, onBuild: () => cancelled = true);
    await expectLater(
      EpubTranslationRepository(
        translator: EpubChapterTranslator(apiClient: api),
      ).generateStyleProfile(
        config: config,
        chapters: _chapters,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(adapter.requests, 0);
  });

  for (final useCallback in [true, false]) {
    test(
      'repository cancels active request via ${useCallback ? 'callback' : 'cancelJob'}',
      () async {
        bool cancelled = false;
        final adapter = _Adapter();
        final repository = EpubTranslationRepository(
          translator: EpubChapterTranslator(apiClient: _Api(adapter)),
        );
        final expectation = expectLater(
          repository
              .generateStyleProfile(
                config: config,
                chapters: _chapters,
                isCancelled: () => cancelled,
              )
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<TranslationCancelledException>()),
        );
        await adapter.started.future;
        if (useCallback) {
          cancelled = true;
        } else {
          await repository.cancelJob('style');
        }
        await expectation;
        await adapter.cancelled.future.timeout(const Duration(seconds: 2));
        expect(adapter.token!.isCancelled, isTrue);
        expect(adapter.requests, 1);
      },
    );
  }

  test(
    'callback changed by failed request prevents retry and cancels token',
    () async {
      bool cancelled = false;
      final adapter = _Adapter(onRequest: () => cancelled = true);
      await expectLater(
        EpubTranslationRepository(
              translator: EpubChapterTranslator(apiClient: _Api(adapter)),
            )
            .generateStyleProfile(
              config: config,
              chapters: _chapters,
              isCancelled: () => cancelled,
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(adapter.requests, 1);
      expect(adapter.token!.isCancelled, isTrue);
    },
  );

  test('repository test seam forwards callback and caller token', () async {
    final token = CancelToken();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/v1'));
    addTearDown(() => dio.close(force: true));
    await expectLater(
      EpubTranslationRepository().generateStyleProfileForTest(
        dio: dio,
        config: config,
        chapters: _chapters,
        cancelToken: token,
        isCancelled: () => true,
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(token.isCancelled, isTrue);
  });
}
