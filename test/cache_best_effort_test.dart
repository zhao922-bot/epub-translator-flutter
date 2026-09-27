import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCacheStore extends TranslationCacheStore {
  final List<String> writtenKeys = <String>[];

  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    writtenKeys.add(cacheKey);
  }
}

class _FailingCacheStore extends TranslationCacheStore {
  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    throw const FileSystemException('disk is full (test double)');
  }
}

void main() {
  test('putBlockCacheErrorForTest returns null when the write succeeds', () async {
    final _RecordingCacheStore store = _RecordingCacheStore();
    final Object? error = await EpubChapterTranslator.putBlockCacheErrorForTest(
      store,
      'cache-key-1',
      '<p>译文</p>',
    );
    // null means success: this is the signal the write counters use.
    expect(error, isNull);
    expect(store.writtenKeys, <String>['cache-key-1']);
  });

  test('putBlockCacheErrorForTest swallows failures and returns the error',
      () async {
    final Object? error = await EpubChapterTranslator.putBlockCacheErrorForTest(
      _FailingCacheStore(),
      'cache-key-1',
      '<p>译文</p>',
    );
    // A non-null result means the failure was swallowed: callers must not
    // count this write as successful in the final report.
    expect(error, isA<FileSystemException>());
  });
}
