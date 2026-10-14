import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _xhtmlNamespace = 'http://www.w3.org/1999/xhtml';
const _compatibilityStyleTitle = 'EPUB Translator CJK compatibility';
const _extractor = EpubHtmlExtractor();

InspectedChapter _translatedChapter(String body) {
  final chapter = _extractor.inspectChapterBytes(
    chapterPath: 'OPS/prefixed.xhtml',
    bytes: utf8.encode(
      '<x:html xmlns:x="$_xhtmlNamespace"><x:head>'
      '<x:title>Book</x:title></x:head><x:body class="chapter">'
      '$body</x:body></x:html>',
    ),
  );
  expect(chapter.blocks, isNotEmpty);
  return chapter.copyWith(
    blocks: [
      for (final block in chapter.blocks)
        block.copyWith(
          translatedHtml: block.sourceHtml.replaceAll('Hello', '你好'),
        ),
    ],
  );
}

XmlElement _render(InspectedChapter chapter, {required bool bilingual}) =>
    XmlDocument.parse(
      EpubRepacker().renderTranslatedChapter(
        chapter: chapter,
        bilingual: bilingual,
        targetLanguage: 'Chinese',
      ),
    ).rootElement;

Iterable<XmlElement> _elements(XmlElement root, String tag) => root.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == tag);

void main() {
  test(
    'structure restoration preserves prefixed footnotes and inline code',
    () {
      const source =
          '<x:p xmlns:x="$_xhtmlNamespace">Read'
          '<x:a href="#note">1</x:a><x:code>KEEP</x:code> now.</x:p>';
      final restored = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: source,
        translatedHtml: source
            .replaceAll('Read', '阅读')
            .replaceAll('>1<', '>一<')
            .replaceAll('KEEP', '改动')
            .replaceAll('now.', '现在。'),
      );
      expect(
        restored,
        '<x:p xmlns:x="$_xhtmlNamespace">阅读'
        '<x:a href="#note">1</x:a><x:code>KEEP</x:code> 现在。</x:p>',
      );
    },
  );

  test('structure restoration aligns protected slots across tag prefixes', () {
    final restored = EpubChapterTranslator.lockHtmlStructureForTest(
      sourceHtml:
          '<x:p xmlns:x="$_xhtmlNamespace">Read'
          '<x:a href="#note">1</x:a><x:code>KEEP</x:code> now.</x:p>',
      translatedHtml: '<p>阅读<a href="#note">二</a><code>CHANGED</code> 现在。</p>',
    );
    expect(
      restored,
      '<x:p xmlns:x="$_xhtmlNamespace">阅读'
      '<x:a href="#note">1</x:a><x:code>KEEP</x:code> 现在。</x:p>',
    );
  });

  for (final tag in ['script', 'style']) {
    test('structure restoration excludes introduced prefixed $tag text', () {
      final restored = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<x:p xmlns:x="$_xhtmlNamespace">Read now.</x:p>',
        translatedHtml:
            '<x:p xmlns:x="$_xhtmlNamespace">阅读'
            '<x:$tag>DROP</x:$tag>现在。</x:p>',
      );
      expect(restored, '<x:p xmlns:x="$_xhtmlNamespace">阅读现在。</x:p>');
    });
  }

  test('prefixed protection uses a new block cache identity', () {
    final config = TranslationConfig.defaults();
    const block = ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml:
          '<x:p xmlns:x="$_xhtmlNamespace">Read'
          '<x:a href="#note">1</x:a><x:code>KEEP</x:code> now.</x:p>',
      sourceText: 'Read now.',
    );
    String key(String qualitySchema) => sha256
        .convert(
          utf8.encode(
            [
              'v17-structure-repair',
              qualitySchema,
              const TranslationApiClient().normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.lockedGlossary.trim(),
              config.chunkSize,
              config.residualQualityCheck,
              config.styleProfileEnabled,
              'none',
              'test-book',
              'OPS/prefixed.xhtml',
              block.id,
              block.sourceHtml,
            ].join('|'),
          ),
        )
        .toString();
    final current = EpubChapterTranslator.blockCacheKeyForTest(
      config: config,
      block: block,
      chapterPath: 'OPS/prefixed.xhtml',
    );
    expect(current, key(EpubChapterTranslator.qualityCacheSchemaVersion));
    expect(current, isNot(key('v17-quality-script-residual')));
  });

  test('memory checkpoints reject the previous protection schema', () async {
    final temp = await Directory.systemTemp.createTemp('round14_d_memory_');
    addTearDown(() => temp.delete(recursive: true));
    final cache = TranslationCacheStore(cacheRoot: temp);
    const jobKey = 'prefixed-protection';
    const chunkSize = 3000;
    await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
      cacheStore: cache,
      jobKey: jobKey,
      chunkSize: chunkSize,
      memory: {},
      schema: 'v17-quality-script-residual',
    );
    expect(
      await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: jobKey,
        chunkSize: chunkSize,
      ),
      isNull,
    );
    await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
      cacheStore: cache,
      jobKey: jobKey,
      chunkSize: chunkSize,
      memory: {},
    );
    expect(
      await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: jobKey,
        chunkSize: chunkSize,
      ),
      isNotNull,
    );
  });

  for (final bilingual in [false, true]) {
    test(
      'prefixed Chinese ${bilingual ? 'bilingual' : 'monolingual'} export retains compatibility styles',
      () {
        final chapter = _translatedChapter(
          '<x:p>Hello<x:a id="marker"></x:a> world</x:p>',
        );
        final root = _render(chapter, bilingual: bilingual);
        expect(root.name.qualified, 'x:html');
        expect(root.namespaceUri, _xhtmlNamespace);
        final body = _elements(root, 'body').single;
        expect(
          body.getAttribute('class')!.split(' '),
          containsAll(['chapter', 'epub-translator-cjk']),
        );
        final style = _elements(root, 'style').single;
        expect(style.parentElement, _elements(root, 'head').single);
        expect(style.name.qualified, 'x:style');
        expect(style.namespaceUri, _xhtmlNamespace);
        expect(style.getAttribute('title'), _compatibilityStyleTitle);
        expect(style.getAttribute('type'), 'text/css');
        expect(style.innerText, contains('body.epub-translator-cjk'));
        for (final anchor in _elements(body, 'a')) {
          expect(
            anchor.getAttribute('class')!.split(' '),
            contains('epub-translator-anchor-marker'),
          );
        }
        expect(_elements(body, 'a'), hasLength(bilingual ? 2 : 1));
        expect(body.innerText, contains('你好'));
      },
    );
  }

  for (final span in ['colspan', 'rowspan']) {
    test('prefixed bilingual table retains one cell and its $span', () {
      final chapter = _translatedChapter(
        '<x:table><x:tr><x:td $span="2">Hello table</x:td>'
        '</x:tr></x:table>',
      );
      final root = _render(chapter, bilingual: true);
      final cell = _elements(root, 'td').single;
      expect(cell.name.qualified, 'x:td');
      expect(cell.namespaceUri, _xhtmlNamespace);
      expect(cell.getAttribute(span), '2');
      expect(cell.parentElement, _elements(root, 'tr').single);
      expect(cell.innerText, contains('Hello table'));
      final translation = cell.childElements.single;
      expect(translation.name.qualified, 'x:div');
      expect(translation.namespaceUri, _xhtmlNamespace);
      expect(translation.getAttribute('data-translation'), 'true');
      expect(translation.getAttribute(span), isNull);
      expect(translation.innerText, '你好 table');
    });
  }

  test('prefixed bilingual list retains its items and numbering', () {
    final chapter = _translatedChapter(
      '<x:ol><x:li value="3">Hello first</x:li>'
      '<x:li>Hello second</x:li></x:ol>',
    );
    final root = _render(chapter, bilingual: true);
    final items = _elements(root, 'li').toList();
    expect(items, hasLength(2));
    expect(items.first.getAttribute('value'), '3');
    for (final item in items) {
      expect(item.name.qualified, 'x:li');
      final translation = item.childElements.single;
      expect(translation.name.qualified, 'x:div');
      expect(translation.namespaceUri, _xhtmlNamespace);
      expect(translation.getAttribute('data-translation'), 'true');
      expect(translation.getAttribute('value'), isNull);
      expect(translation.innerText, startsWith('你好'));
    }
  });

  test('prefixed bilingual summary contains a span translation', () {
    final chapter = _translatedChapter(
      '<x:details><x:summary>Hello summary</x:summary></x:details>',
    );
    final root = _render(chapter, bilingual: true);
    final summary = _elements(root, 'summary').single;
    final translation = summary.childElements.single;
    expect(translation.name.qualified, 'x:span');
    expect(translation.namespaceUri, _xhtmlNamespace);
    expect(translation.getAttribute('data-translation'), 'true');
    expect(translation.innerText, '你好 summary');
  });
}
