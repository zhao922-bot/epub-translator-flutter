import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

String normalize(
  String input, {
  bool later = false,
  String source = 'Smith',
  String target = '斯密',
}) {
  final state = ProperNameNormalizer.bookState();
  if (later) state.countedNames.add(source);
  return ProperNameNormalizer.normalizeHtml(
    input,
    [ProperNameMap(source: source, target: target)],
    targetLanguage: 'Chinese',
    state: state,
  );
}

void main() {
  test(
    'all nested wrapper positions preserve styled characters and unique IDs',
    () {
      const text = 'Smith（斯密）';
      var variants = 0;
      for (var a = 0; a < text.length; a++) {
        for (var b = a + 1; b <= text.length; b++) {
          for (var c = a; c < b; c++) {
            for (var d = c + 1; d <= b; d++) {
              final input = StringBuffer('<p>前文');
              for (var i = 0; i <= text.length; i++) {
                if (i == d) input.write('</strong>');
                if (i == b) input.write('</em>');
                if (i == a) input.write('<em id="a" class="a">');
                if (i == c) input.write('<strong id="b" class="b">');
                if (i < text.length) input.write(text[i]);
              }
              input.write('后文。</p>');
              for (final later in [false, true]) {
                final output = normalize(input.toString(), later: later);
                final doc = XmlDocument.parse(output);
                final elements = doc.descendants
                    .whereType<XmlElement>()
                    .toList();
                expect(
                  doc.rootElement.innerText,
                  later ? '前文斯密后文。' : '前文斯密（Smith）后文。',
                  reason: input.toString(),
                );
                for (final spec in [(a, b, 'a'), (c, d, 'b')]) {
                  expect(
                    elements.where((e) => e.getAttribute('id') == spec.$3),
                    hasLength(1),
                    reason: output,
                  );
                  final permutation = later
                      ? [6, 7]
                      : [6, 7, 5, 0, 1, 2, 3, 4, 8];
                  final expected = permutation
                      .where((i) => i >= spec.$1 && i < spec.$2)
                      .map((i) => text[i])
                      .join();
                  final actual = elements
                      .where((e) => e.getAttribute('class') == spec.$3)
                      .map((e) => e.innerText)
                      .join();
                  expect(
                    actual,
                    expected,
                    reason: '${input.toString()} => $output',
                  );
                }
              }
              variants++;
            }
          }
        }
      }
      expect(variants, 495);
    },
  );

  for (final prefix in [
    'é',
    '&#233;',
    '<em>é</em>',
    '\u0301',
    '&#769;',
    '\u{10780}',
    '\u{1DF00}',
    '５',
  ]) {
    test('Unicode word scalar before and after a name: $prefix', () {
      for (final input in [
        '<p>中文 ${prefix}Smith（斯密）继续。</p>',
        '<p>中文 Smith$prefix继续。</p>',
      ]) {
        expect(normalize(input), input);
      }
    });
  }
  for (final prefix in ['中', '\u{20000}', '😀', '×', '。']) {
    test('CJK and punctuation still delimit valid names: $prefix', () {
      expect(
        XmlDocument.parse(
          normalize('<p>${prefix}Smith（斯密）继续。</p>'),
        ).rootElement.innerText,
        '$prefix斯密（Smith）继续。',
      );
    });
  }
  for (final count in [10, 11]) {
    test('formatted short-link cutoff uses decoded visible length: $count', () {
      for (final name in ['Li', '<em>Li</em>']) {
        for (final suffix in ['文', '😀', '&#x1F600;']) {
          final input = '<p><a href="#n">$name${suffix * count}</a>中文</p>';
          final output = normalize(input, source: 'Li', target: '李');
          if (count == 10) {
            expect(output, input);
          } else {
            expect(
              XmlDocument.parse(output).rootElement.innerText,
              '李（Li）${(suffix == '文' ? '文' : '😀') * count}中文',
            );
          }
        }
      }
    });
  }
  test('supplementary text in short anchors uses Unicode scalars', () {
    for (final label in [
      '<em>Li</em>${'&#x1F600;' * 6}',
      'Li${'😀' * 6}',
      'Li${'😀' * 10}',
    ]) {
      final input = '<p><a href="#n">$label</a>中文</p>';
      expect(normalize(input, source: 'Li', target: '李'), input);
    }
  });
  test('formatted whitespace anchor is transparent to a forward gloss', () {
    const input = '<p>亚当·斯密（Adam<a id="space"><em>&#32;</em></a>Smith）继续。</p>';
    final result = normalize(
      input,
      later: true,
      source: 'Adam Smith',
      target: '亚当·斯密',
    );
    final doc = XmlDocument.parse(result);
    expect(doc.rootElement.innerText, '亚当·斯密继续。');
    expect(doc.findAllElements('a').single.getAttribute('id'), 'space');
  });
  test('source and target styles move separately without copying identities', () {
    const input =
        '<p><em id="en" lang="en">Smith</em>（<strong id="zh">斯密</strong>）继续。</p>';
    expect(
      normalize(input),
      '<p><strong id="zh">斯密</strong>（<em id="en" lang="en">Smith</em>）继续。</p>',
    );
  });
  test('split styles preserve attributes but emit each identity once', () {
    const input =
        '<p><span id="one" xml:id="two" name="three" class="style" title=" id=\'keep\' > value">Smith（斯</span>密）继续。</p>';
    final result = normalize(input);
    final spans = XmlDocument.parse(result).findAllElements('span').toList();
    expect(spans, hasLength(2));
    expect(spans.map((e) => e.innerText).join(), '斯（Smith');
    for (final attr in ['id', 'name']) {
      expect(spans.where((e) => e.getAttribute(attr) != null), hasLength(1));
    }
    expect(
      spans.where((e) => e.attributes.any((a) => a.name.qualified == 'xml:id')),
      hasLength(1),
    );
    expect(
      spans.every((e) => e.getAttribute('title') == " id='keep' > value"),
      isTrue,
    );
    expect(spans.every((e) => e.getAttribute('class') == 'style'), isTrue);
  });
  test('reverse gloss keeps empty anchors, comments and outside styles', () {
    const input =
        '<p><em id="outer">前文 Sm<span id="page"/>ith（斯</em>密）后文<!--keep--><span id="tail"/></p>';
    final result = normalize(input);
    final doc = XmlDocument.parse(result);
    expect(doc.rootElement.innerText, '前文 斯密（Smith）后文');
    for (final id in ['outer', 'page', 'tail']) {
      expect(
        doc.descendants.whereType<XmlElement>().where(
          (e) => e.getAttribute('id') == id,
        ),
        hasLength(1),
      );
    }
    expect(
      doc.findAllElements('em').map((e) => e.innerText).join(),
      '前文 斯（Smith',
    );
    expect(result, contains('<!--keep-->'));
  });
  test('formatted reverse source retains canonical whitespace', () {
    const input = '<p>Adam  <em>Smith</em>（亚当·斯密）继续。</p>';
    final result = normalize(input, source: 'Adam Smith', target: '亚当·斯密');
    final doc = XmlDocument.parse(result);
    expect(doc.rootElement.innerText, '亚当·斯密（Adam Smith）继续。');
    expect(doc.findAllElements('em').single.innerText, 'Smith');
  });
}
