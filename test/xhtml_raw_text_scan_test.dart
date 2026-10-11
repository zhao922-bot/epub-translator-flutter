import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

// Exact pre-fix implementation, retained as a behavioral/performance baseline.
int legacyRawTextEnd(String source, int start, RegExp closing) {
  var cursor = start;
  while (cursor < source.length) {
    final match = closing.allMatches(source, cursor).firstOrNull;
    final end = match?.start ?? source.length;
    final cdata = source.indexOf('<![CDATA[', cursor);
    final comment = source.indexOf('<!--', cursor);
    final special = cdata < 0
        ? comment
        : comment < 0
        ? cdata
        : cdata < comment
        ? cdata
        : comment;
    if (special < 0 || special >= end) return end;
    final terminator = special == cdata ? ']]>' : '-->';
    final specialEnd = source.indexOf(
      terminator,
      special + (special == cdata ? 9 : 4),
    );
    if (specialEnd < 0) return source.length;
    cursor = specialEnd + terminator.length;
  }
  return source.length;
}

void main() {
  for (final tag in [
    'script',
    'style',
    'xmp',
    'iframe',
    'noembed',
    'noframes',
  ]) {
    test('$tag scan preserves legacy boundaries and raw contents', () {
      final closing = RegExp('</$tag\\s*>', caseSensitive: false);
      final bodies = [
        'plain <a/> &nbsp;',
        '<![CDATA["</$tag>" <a/>]]>text',
        '<!-- </$tag> <br> -->text',
        '<![CDATA[</$tag>]]><!-- </$tag> -->tail',
        '<!-- <![CDATA[ </$tag> -->tail',
        '<![CDATA[<!-- </$tag>]]>tail',
      ];
      for (final body in bodies) {
        final source =
            '<$tag>$body</${tag.toUpperCase()} >'
            '<a id="after"/><!-- suffix --><![CDATA[suffix]]>';
        final start = tag.length + 2;
        final end = XhtmlHtmlCompatibility.rawTextEndForTesting(
          source,
          start,
          closing,
        );
        expect(end, legacyRawTextEnd(source, start, closing));
        expect(source.substring(start, end), body);
        final normalized = XhtmlHtmlCompatibility.normalizeForHtmlParser(
          source,
        );
        expect(normalized, contains('<a id="after"></a>'));
        expect(
          XhtmlHtmlCompatibility.normalizeForXhtmlOutput(normalized),
          contains('<$tag>$body</${tag.toUpperCase()} >'),
        );
      }
      for (final body in [
        'no closing tag',
        '<![CDATA[</$tag>',
        '<!-- </$tag>',
      ]) {
        final source = '<$tag>$body';
        expect(
          XhtmlHtmlCompatibility.rawTextEndForTesting(
            source,
            tag.length + 2,
            closing,
          ),
          legacyRawTextEnd(source, tag.length + 2, closing),
        );
      }
    });
  }

  test(
    'many scripts without CDATA/comments match legacy output and benchmark',
    () {
      // Keep routine CI fast; --dart-define=RAW_TEXT_BENCHMARK_NODES=6000
      // reproduces the large-document comparison used for this fix.
      const count = int.fromEnvironment(
        'RAW_TEXT_BENCHMARK_NODES',
        defaultValue: 1000,
      );
      final body = 'var text = "${'x' * 256}<a/>";';
      final node = '<script>$body</script>';
      final source = '${node * count}<p>after</p><a id="end"/>';
      final closing = RegExp(r'</script\s*>', caseSensitive: false);
      List<int> scan(int Function(String, int, RegExp) findEnd) => [
        for (var i = 0; i < count; i++)
          findEnd(source, i * node.length + 8, closing),
      ];

      // Warm both paths; timing is reported, never used as a flaky CI assertion.
      legacyRawTextEnd(node, 8, closing);
      XhtmlHtmlCompatibility.rawTextEndForTesting(node, 8, closing);
      final before = Stopwatch()..start();
      final oldEnds = scan(legacyRawTextEnd);
      before.stop();
      final after = Stopwatch()..start();
      final newEnds = scan(XhtmlHtmlCompatibility.rawTextEndForTesting);
      after.stop();
      expect(newEnds, oldEnds);
      final normalized = XhtmlHtmlCompatibility.normalizeForHtmlParser(source);
      expect(normalized, '${node * count}<p>after</p><a id="end"></a>');
      final document = html_parser.parse(normalized);
      expect(document.querySelectorAll('script'), hasLength(count));
      expect(
        document.querySelectorAll('script').every((s) => s.text == body),
        isTrue,
      );
      expect(document.querySelector('#end'), isNotNull);
      // ignore: avoid_print
      print(
        'Raw-text benchmark: $count scripts, ${source.length} code units; '
        'legacy=${before.elapsedMicroseconds}us, '
        'forward=${after.elapsedMicroseconds}us',
      );
    },
  );
}
