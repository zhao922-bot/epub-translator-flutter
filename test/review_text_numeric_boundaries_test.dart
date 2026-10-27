import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/review_text_patch.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';

const ns = 'http://www.w3.org/1999/xhtml';

void main() {
  for (final prefix in ['', 'x:', '_x:', '书:']) {
    final declaration = prefix.isEmpty
        ? 'xmlns="$ns"'
        : 'xmlns:${prefix.substring(0, prefix.length - 1)}="$ns"';
    for (final tag in ['td', 'th', 'caption']) {
      test(
        'patch preserves $prefix$tag wrapper, attributes and node identity',
        () {
          final draft =
              '<$prefix$tag $declaration id="cell" class="entry"> \n<!-- note --><${prefix}em>同词</${prefix}em> <${prefix}b>同词</${prefix}b><${prefix}sup>9</${prefix}sup></$prefix$tag>';
          final segments = ReviewTextPatch.segments(draft);
          expect(segments.map((e) => e['text']), ['同词', '同词']);
          final changed = ReviewTextPatch.apply(draft, [
            {'node': segments.last['node'], 'before': '同词', 'after': '新词'},
          ]);
          final root = XmlDocument.parse(
            XhtmlHtmlCompatibility.normalizeForXhtmlOutput(changed),
          ).rootElement;
          expect(root.name.local, tag);
          expect(root.namespaceUri, ns);
          expect(root.getAttribute('id'), 'cell');
          expect(root.getAttribute('class'), 'entry');
          expect(root.childElements.map((e) => e.innerText), ['同词', '新词', '9']);
          expect(root.children.whereType<XmlComment>().single.value, ' note ');
          expect(
            ReviewTextPatch.segments(changed).map((e) => e['node']),
            segments.map((e) => e['node']),
          );
          expect(
            () => ReviewTextPatch.apply(draft, [
              {'before': '同词', 'after': '新词'},
            ]),
            throwsFormatException,
          );
        },
      );
    }
    test('protected $prefix content is neither editable nor meaning evidence', () {
      final children = [
        for (final tag in ['code', 'pre', 'var', 'kbd', 'samp', 'sup'])
          '<$prefix$tag><${prefix}em>PROTECTED 987</${prefix}em></$prefix$tag>',
      ].join();
      final source =
          '<${prefix}div $declaration>Ordinary text.$children<svg xmlns="http://www.w3.org/2000/svg"><text>PROTECTED 987</text></svg><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>PROTECTED 987</mi></math><${prefix}span translate="NO">987</${prefix}span><${prefix}span class="notranslate">987</${prefix}span></${prefix}div>';
      expect(ReviewTextPatch.segments(source).map((s) => s['text']), [
        'Ordinary text.',
      ]);
      expect(TranslationConsistencyChecker.text(source), 'Ordinary text.');
      expect(const TranslationConsistencyChecker().riskScore(source, []), 0);
      expect(
        () => ReviewTextPatch.apply(source, [
          {'before': 'PROTECTED 987', 'after': 'changed'},
        ]),
        throwsFormatException,
      );
    });
    if (prefix.isNotEmpty) {
      test('prefixed foreign roots $prefix stay protected', () {
        final declarationName =
            'xmlns:${prefix.substring(0, prefix.length - 1)}';
        final source =
            '<p>Ordinary text.<${prefix}svg $declarationName="http://www.w3.org/2000/svg"><${prefix}text>PROTECTED 987</${prefix}text></${prefix}svg><${prefix}math $declarationName="http://www.w3.org/1998/Math/MathML"><${prefix}mi>PROTECTED 987</${prefix}mi></${prefix}math></p>';
        expect(ReviewTextPatch.segments(source).map((s) => s['text']), [
          'Ordinary text.',
        ]);
        expect(TranslationConsistencyChecker.text(source), 'Ordinary text.');
        expect(
          () => ReviewTextPatch.apply(source, [
            {'before': 'PROTECTED 987', 'after': 'changed'},
          ]),
          throwsFormatException,
        );
      });
    }
    test(
      'formatting $prefix risks use elements, not attribute or comment text',
      () {
        final source =
            '<${prefix}p $declaration title="&lt;em&gt;">The sky was blue.<!-- <em> --></${prefix}p>';
        expect(const TranslationConsistencyChecker().riskScore(source, []), 0);
        final formatted =
            '<${prefix}p $declaration>The sky was <${prefix}em>blue</${prefix}em>.</${prefix}p>';
        expect(
          const TranslationConsistencyChecker().riskScore(formatted, []),
          1,
        );
      },
    );
  }
  test('patch preserves CDATA text and empty anchors/breaks', () {
    const source =
        '<p xmlns:x="$ns"><![CDATA[前<文]]><a id="mark"/><x:br/>后文</p>';
    final segments = ReviewTextPatch.segments(source);
    expect(segments.map((s) => s['text']), ['前<文', '后文']);
    final output = ReviewTextPatch.apply(source, [
      {'node': segments.last['node'], 'before': '后文', 'after': '末文'},
    ]);
    final root = XmlDocument.parse(
      XhtmlHtmlCompatibility.normalizeForXhtmlOutput(output),
    ).rootElement;
    expect(root.innerText, '前<文末文');
    expect(root.childElements.every((e) => e.children.isEmpty), isTrue);
    expect(root.childElements.first.getAttribute('id'), 'mark');
  });
  test('patch cannot inject markup or edit a protected node by shifted id', () {
    const source = '<p>正文<code>保留</code><em>末文</em></p>';
    final output = ReviewTextPatch.apply(source, [
      {'node': 'n1', 'before': '末文', 'after': '<script>text</script>'},
    ]);
    final root = XmlDocument.parse(output).rootElement;
    expect(root.findAllElements('script'), isEmpty);
    expect(root.findAllElements('code').single.innerText, '保留');
    expect(
      root.findAllElements('em').single.innerText,
      '<script>text</script>',
    );
  });
  test('depth guard rejects pathological patch input', () {
    final source = '${'<span>' * 140}text${'</span>' * 140}';
    expect(() => ReviewTextPatch.segments(source), throwsFormatException);
    expect(
      () => ReviewTextPatch.apply(source, [
        {'before': 'text', 'after': 'new'},
      ]),
      throwsFormatException,
    );
  });

  for (final text in [
    '她十分开心。',
    '她是十分开心的。',
    '意见一致。',
    '以防万一下雨。',
    '这是统一安排。',
    '这是唯一机会。',
    '他一一说明。',
    '两难境地。',
    '千方百计。',
    '一切如常。',
    '一向如此。',
    '一点也不。',
  ]) {
    test(
      'ordinary lexical use is not a deterministic numeric claim: $text',
      () {
        expect(
          TranslationConsistencyChecker.numbers(
            text,
            chinese: true,
            requireQuantitySyntax: true,
          ),
          isEmpty,
        );
        expect(
          TranslationConsistencyChecker.introducedNumbers(
            sourceHtml: '<p>Ordinary prose.</p>',
            beforeHtml: '<p>正文。</p>',
            afterHtml: '<p>$text</p>',
          ),
          isEmpty,
        );
      },
    );
  }
  for (final (text, expected) in [
    ('三个人', {'3'}),
    ('十二美元', {'12'}),
    ('负二十元', {'-20'}),
    ('五百公斤', {'500'}),
    ('第二章', {'2'}),
    ('她哭了九百八十七次。', {'987'}),
    ('十分。', {'10'}),
    ('十分钟', {'10'}),
    ('十分之一', {'10', '1'}),
    ('十一点一美元', {'11.1'}),
    ('十一点一刻', {'11', '1'}),
    ('四个世纪', {'400'}),
    ('版权所有二〇二六', {'2026'}),
    ('共三十', {'30'}),
    ('一千二百', {'1200'}),
    ('万名观众', {'10000'}),
    ('数值为百', {'100'}),
    ('四百年过去了。', {'400'}),
  ]) {
    test('actual Chinese quantity remains protected: $text', () {
      expect(
        TranslationConsistencyChecker.numbers(text, chinese: true),
        expected,
      );
      expect(
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: '<p>No amount stated.</p>',
          beforeHtml: '<p>正文。</p>',
          afterHtml: '<p>$text</p>',
        ),
        expected,
      );
    });
  }
  test(
    'supported numeric spelling and unchanged quantities remain allowed',
    () {
      expect(
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: 'Four hundred years passed.',
          beforeHtml: '许多年过去了。',
          afterHtml: '四百年过去了。',
        ),
        isEmpty,
      );
      expect(
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: 'A count was stated.',
          beforeHtml: '共三十人。',
          afterHtml: '总计三十人。',
        ),
        isEmpty,
      );
      expect(
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: 'Twenty dollars.',
          beforeHtml: '二十美元。',
          afterHtml: '三十美元。',
        ),
        {'30'},
      );
      expect(TranslationConsistencyChecker.numbers('他赢了五', chinese: true), {
        '5',
      });
      expect(
        TranslationConsistencyChecker.numbers('词汇一五一十', chinese: true),
        isNotEmpty,
      );
      expect(
        TranslationConsistencyChecker.introducedNumbers(
          sourceHtml: 'Explain fully.',
          beforeHtml: '说明。',
          afterHtml: '他一五一十地说明。',
        ),
        isEmpty,
      );
    },
  );
}
