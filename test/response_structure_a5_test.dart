import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

String _lock(String source, String reply, Map<String, int> counts) =>
    EpubChapterTranslator.lockHtmlStructureForTest(
      sourceHtml: source,
      translatedHtml: reply,
      instrumentation: counts,
    );

void main() {
  test('fenced reply shares the parsed DOM with structure handling', () {
    final counts = <String, int>{};
    expect(
      _lock('<p>Hello</p>', '```html\n<p>你好</p>\n```', counts),
      '<p>你好</p>',
    );
    expect(counts['parses'], 2);
  });

  for (final reply in [
    '```html\n<p>你好</p>',
    'Translation: <p>你好</p>',
    '<div>Translation: <p>你好</p></div>',
    '<p>你好</p> Explanation.',
    '{"html":"你好"}',
  ]) {
    test('DOM cleaner rejects wrapper: $reply', () {
      expect(() => _lock('<p>Hello</p>', reply, {}), throwsFormatException);
    });
  }

  test(
    'normal structure match parses source/reply once and restores protection',
    () {
      const source =
          '<p id="p1">Hello <em>world</em> '
          '<a href="#n1" role="doc-noteref"><sup>[1]</sup></a> '
          '<span role="doc-pagebreak">iv</span> <code>x()</code></p>';
      const reply =
          '<p id="p1">你好 <em>世界</em> '
          '<a href="#n1" role="doc-noteref"><sup>一</sup></a> '
          '<span role="doc-pagebreak">五</span> <code>changed()</code></p>';
      final counts = <String, int>{};
      final result = _lock(source, reply, counts);
      expect(result, contains('你好 <em>世界</em>'));
      expect(result, contains('<sup>[1]</sup>'));
      expect(result, contains('role="doc-pagebreak">iv</span>'));
      expect(result, contains('<code>x()</code>'));
      expect(
        EpubChapterTranslator.htmlStructureMatchesForTest(
          sourceHtml: source,
          translatedHtml: result,
        ),
        isTrue,
      );
      expect(counts['parses'], 2);
    },
  );

  test(
    'deep normal match indexes nodes linearly with no subtree text reads',
    () {
      Map<String, int> run(int depth) {
        // Each ancestor has its own text: repeated .text here would process
        // quadratically many characters, unlike a chain with a single leaf.
        final source = StringBuffer('<p>');
        final reply = StringBuffer('<p>');
        for (var i = 0; i < depth; i++) {
          source.write('<span>word$i ');
          reply.write('<span>译文$i ');
        }
        source.write('<a href="#n">[2]</a><code>keep</code>');
        reply.write('<a href="#n">二</a><code>改动</code>');
        for (var i = 0; i < depth; i++) {
          source.write('</span>');
          reply.write('</span>');
        }
        source.write('</p>');
        reply.write('</p>');
        final counts = <String, int>{};
        final result = _lock(source.toString(), reply.toString(), counts);
        final root = XhtmlHtmlCompatibility.parseFragment(
          result,
        ).children.single;
        expect(root.querySelectorAll('span'), hasLength(depth));
        expect(root.querySelector('a')!.text, '[2]');
        expect(root.querySelector('code')!.text, 'keep');
        expect(root.text, contains('译文${depth - 1}'));
        expect(root.text, isNot(contains('word')));
        expect(counts['parses'], 2);
        // Only the protected marker needs full subtree text materialized.
        expect(counts['textMaterializations'], 1);
        expect(counts['indexedNodes']!, lessThan(12 * depth + 60));
        expect(counts['protectionChecks']!, lessThan(6 * depth + 30));
        return counts;
      }

      final shallow = run(64);
      final deep = run(384);
      expect(deep['indexedNodes']!, lessThan(shallow['indexedNodes']! * 6));
      expect(
        deep['protectionChecks']!,
        lessThan(shallow['protectionChecks']! * 6),
      );
    },
  );

  test('deep language alignment compares cached ranges linearly', () {
    const depth = 192;
    final source = StringBuffer('<p>');
    final reply = StringBuffer('<p lang="zh">');
    for (var i = 0; i < depth; i++) {
      source.write('<span role="doc-noteref">word$i ');
      reply.write('<span role="doc-noteref" lang="zh">译文$i ');
    }
    source.write('ending');
    reply.write('结尾');
    for (var i = 0; i < depth; i++) {
      source.write('</span>');
      reply.write('</span>');
    }
    source.write('</p>');
    reply.write('</p>');
    final counts = <String, int>{};
    final result = _lock(source.toString(), reply.toString(), counts);
    final root = XhtmlHtmlCompatibility.parseFragment(result).children.single;
    expect(root.querySelectorAll('span[lang="zh"]'), hasLength(depth));
    expect(root.text, contains('译文191'));
    expect(root.text, isNot(contains('word')));
    expect(counts['parses'], 2);
    expect(counts['textMaterializations'] ?? 0, 0);
    expect(counts['alignmentCharacters'], root.text.length);
    expect(counts['indexedNodes']!, lessThan(16 * depth + 60));
  });

  test(
    'anchor overflow reuses DOM and invalidates text before language alignment',
    () {
      final counts = <String, int>{};
      final result = _lock(
        '<p>Read <a href="#n"><sup>[1]</sup></a></p>',
        '<p>阅读 <a href="#n"><sup>[1]补充</sup></a></p>',
        counts,
      );
      final root = XhtmlHtmlCompatibility.parseFragment(result).children.single;
      expect(root.querySelector('a')!.text, '[1]');
      expect(root.text, contains('补充'));
      expect(counts['parses'], 2);

      final languageCounts = <String, int>{};
      final aligned = _lock(
        '<p>Hello <em>world</em></p>',
        '<p lang="zh">你好 <em lang="zh">世界</em></p>',
        languageCounts,
      );
      final alignedRoot = XhtmlHtmlCompatibility.parseFragment(
        aligned,
      ).children.single;
      expect(alignedRoot.attributes['lang'], 'zh');
      expect(alignedRoot.querySelector('em')!.attributes['xml:lang'], 'zh');
      expect(languageCounts['parses'], 2);
    },
  );

  for (final semantic in [false, true]) {
    test(
      'flattened smallcaps keeps content and semantic attributes: $semantic',
      () {
        final counts = <String, int>{};
        final result = _lock(
          '<p>R<span class="smallcaps"${semantic ? ' id="name" lang="en"' : ''}>EES</span> Davies '
              '<a href="#n">[1]</a></p>',
          '<p>里斯·戴维斯 <a href="#n">一</a></p>',
          counts,
        );
        final root = XhtmlHtmlCompatibility.parseFragment(
          result,
        ).children.single;
        expect(root.text, contains('里斯·戴维斯'));
        expect(root.querySelector('a')!.text, '[1]');
        expect(result, isNot(contains('smallcaps')));
        if (semantic) {
          expect(root.querySelector('#name')!.attributes['lang'], 'en');
        } else {
          expect(root.querySelector('span'), isNull);
        }
        expect(counts['parses'], 2);
      },
    );
  }
}
