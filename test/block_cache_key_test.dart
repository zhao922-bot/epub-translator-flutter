import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ExtractedBlock block = ExtractedBlock(
    id: 'b1',
    tagName: 'p',
    sourceHtml: '<p>Hello world</p>',
    sourceText: 'Hello world',
  );

  String keyFor(TranslationConfig config) =>
      EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: block,
        chapterPath: 'OEBPS/ch1.xhtml',
      );

  group('block cache key', () {
    test('chunkSize participates in the key', () {
      final String small = keyFor(
        TranslationConfig.defaults().copyWith(chunkSize: 3000),
      );
      final String large = keyFor(
        TranslationConfig.defaults().copyWith(chunkSize: 6000),
      );
      expect(
        small,
        isNot(large),
        reason:
            'batch context changes with chunkSize, so cached translations must not be reused across sizes',
      );
    });

    test('identical configs produce identical keys', () {
      expect(
        keyFor(TranslationConfig.defaults().copyWith(chunkSize: 3000)),
        keyFor(TranslationConfig.defaults().copyWith(chunkSize: 3000)),
      );
    });

    test('other settings still participate in the key', () {
      final String a = keyFor(
        TranslationConfig.defaults().copyWith(model: 'model-a'),
      );
      final String b = keyFor(
        TranslationConfig.defaults().copyWith(model: 'model-b'),
      );
      expect(a, isNot(b));
    });

    test('identical source HTML at different positions gets different keys', () {
      // Block ids are positional within a chapter ("p-3"), and neighbor
      // context feeds the prompt for each position. Two blocks with the
      // same source HTML at different positions must not share a cache
      // entry, or the second would reuse a translation shaped by the wrong
      // context.
      const ExtractedBlock first = ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml: '<p>Hello world</p>',
        sourceText: 'Hello world',
      );
      const ExtractedBlock second = ExtractedBlock(
        id: 'p-2',
        tagName: 'p',
        sourceHtml: '<p>Hello world</p>',
        sourceText: 'Hello world',
      );
      final TranslationConfig config = TranslationConfig.defaults();
      final String firstKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: first,
        chapterPath: 'OEBPS/ch1.xhtml',
      );
      final String secondKey = EpubChapterTranslator.blockCacheKeyForTest(
        config: config,
        block: second,
        chapterPath: 'OEBPS/ch1.xhtml',
      );
      expect(
        firstKey,
        isNot(secondKey),
        reason:
            'same source HTML at p-1 and p-2 must not collide in the block cache',
      );
    });
  });
}
