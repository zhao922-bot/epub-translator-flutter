import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'bug_audit_round4_regression_test.dart' as fixture;

void main() {
  for (final protected in [
    '<code>Adam Smith</code>',
    '<CODE title=">">亚当 (Adam Smith)</CODE>',
    '<pre><code><span>Adam Smith</span></code></pre>',
    '<samp>print("Adam Smith")</samp>',
    '<svg><text>Adam Smith</text></svg>',
    '<script>const name = "Adam Smith";</script>',
    '<style>.name::before { content: "Adam Smith"; }</style>',
  ]) {
    test(
      'glossary skips protected subtree and reserves first prose mention: $protected',
      () {
        final state = ProperNameNormalizer.bookState();
        final mappings = ProperNameNormalizer.parseGlossary(
          'Adam Smith => 亚当·斯密',
        );
        final first = ProperNameNormalizer.normalizeHtml(
          '<div>示例：$protected</div>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(first, '<div>示例：$protected</div>');
        expect(state.countedNames, isEmpty);
        final second = ProperNameNormalizer.normalizeHtml(
          '<p>Adam Smith的著作</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(second, '<p>亚当·斯密（Adam Smith）的著作</p>');
      },
    );
  }
  for (final sourceLanguages in [
    <String>[],
    ['en', 'fr'],
    ['en', 'zh-CN', 'en', 'ZH-cn'],
  ]) {
    test('bilingual metadata preserves distinct languages: $sourceLanguages', () {
      final archive = <String, List<int>>{
        'META-INF/container.xml': utf8.encode(
          '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        ),
        'OPS/book.opf': utf8.encode(
          '<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">${sourceLanguages.map((value) => '<dc:language>$value</dc:language>').join()}</metadata><manifest/><spine/></package>',
        ),
      };
      for (var pass = 0; pass < 2; pass++) {
        final result = EpubIsolateWorker.renderNavigationMetadata(
          archiveFiles: archive,
          labelsByPath: {},
          languageTag: 'zh-CN',
          bilingual: true,
        );
        archive['OPS/book.opf'] = utf8.encode(result['OPS/book.opf']!);
      }
      final opf = XmlDocument.parse(utf8.decode(archive['OPS/book.opf']!));
      final values = opf.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'language')
          .map((e) => e.innerText.toLowerCase())
          .toList();
      expect(values.toSet(), {
        ...sourceLanguages.map((v) => v.toLowerCase()),
        'zh-cn',
      });
      expect(values.length, values.toSet().length);
    });
  }
  for (final bilingual in [false, true]) {
    for (final glossary in ['', 'Adam Smith => 亚当·斯密']) {
      test(
        'export preserves restored code with glossary=$glossary, bilingual=$bilingual',
        () {
          const block = '<p>Run <code>print("Adam Smith")</code> now.</p>';
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'OPS/chapter.xhtml',
            bytes: utf8.encode('<html><body>$block</body></html>'),
          );
          final restored = EpubChapterTranslator.lockHtmlStructureForTest(
            sourceHtml: block,
            translatedHtml: '<p>现在运行 <code>打印("亚当")</code>。</p>',
          );
          expect(
            html.parseFragment(restored).querySelector('code')!.text,
            'print("Adam Smith")',
          );
          final result = EpubRepacker().renderTranslatedChapter(
            chapter: chapter.copyWith(
              blocks: [
                chapter.blocks.single.copyWith(translatedHtml: restored),
              ],
            ),
            bilingual: bilingual,
            lockedGlossary: glossary,
          );
          expect(
            html.parse(result).querySelectorAll('code').map((e) => e.text),
            everyElement('print("Adam Smith")'),
          );
        },
      );
    }
  }
  for (final attribute in ['id', 'name']) {
    test('bilingual export keeps a unique legacy anchor: $attribute', () {
      final block =
          '<p><a $attribute="section1"></a><input name="field" />Hello world.</p>';
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: 'OPS/chapter.xhtml',
        bytes: utf8.encode('<html><body>$block</body></html>'),
      );
      final result = EpubRepacker().renderTranslatedChapter(
        chapter: chapter.copyWith(
          blocks: [
            chapter.blocks.single.copyWith(
              translatedHtml:
                  '<p><a $attribute="section1"></a><input name="field" />你好世界。</p>',
            ),
          ],
        ),
        bilingual: true,
      );
      expect(
        html.parse(result).querySelectorAll('a[$attribute="section1"]'),
        hasLength(1),
      );
      expect(
        html.parse(result).querySelectorAll('input[name="field"]'),
        hasLength(2),
      );
    });
  }
  for (final bilingual in [false, true]) {
    test(
      'real archive export has correct publication languages: bilingual=$bilingual',
      () async {
        final dir = await Directory.systemTemp.createTemp('epub-audit8-');
        addTearDown(() => dir.delete(recursive: true));
        final source = await fixture.writeBook(
          dir,
          body: '<p>Hello world.</p>',
        );
        final inspected = await EpubInspector().inspect(
          inputPath: source.path,
          outputDirectory: dir.path,
          cancelToken: CancelToken(),
        );
        final chapter = inspected.chapters.single;
        final output = '${dir.path}/output.epub';
        await EpubRepacker().writeTranslatedEpub(
          inputPath: source.path,
          outputFilePath: output,
          config: TranslationConfig.defaults().copyWith(bilingual: bilingual),
          chapters: [
            chapter.copyWith(
              blocks: [
                chapter.blocks.single.copyWith(translatedHtml: '<p>你好世界。</p>'),
              ],
            ),
          ],
        );
        final files = await EpubInspector.openArchiveFiles(output);
        final body = html
            .parse(utf8.decode(files['OPS/chapter.xhtml']!))
            .body!
            .text;
        expect(body, contains('你好世界。'));
        if (bilingual) expect(body, contains('Hello world.'));
        final opf = XmlDocument.parse(utf8.decode(files['OPS/content.opf']!));
        final languages = opf.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'language')
            .map((e) => e.innerText)
            .toSet();
        expect(languages, contains('zh-CN'));
        if (bilingual) expect(languages, contains('en'));
      },
    );
  }
}
