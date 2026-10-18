import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const smith = [ProperNameMap(source: 'Smith', target: '斯密')];

String normalize(String input, ProperNameBookState state) =>
    ProperNameNormalizer.normalizeHtml(
      input,
      smith,
      targetLanguage: 'Chinese',
      state: state,
    );

void main() {
  test('formatted Roman numeral footnote is not a person name', () {
    const input = '<p>参见<a href="#note51"><sup>LI</sup></a>。</p>';
    final state = ProperNameNormalizer.bookState();
    final result = ProperNameNormalizer.normalizeHtml(
      input,
      const [ProperNameMap(source: 'Li', target: '李')],
      targetLanguage: 'Chinese',
      state: state,
    );
    expect(result, input);
    expect(state.countedNames, isEmpty);
  });
  test('a real accented name does not match a locked ASCII prefix', () {
    const input = '<p>René（雷内）继续。</p>';
    final state = ProperNameNormalizer.bookState();
    final result = ProperNameNormalizer.normalizeHtml(
      input,
      const [ProperNameMap(source: 'Ren', target: '任')],
      targetLanguage: 'Chinese',
      state: state,
    );
    expect(result, input);
    expect(state.countedNames, isEmpty);
  });
  final protected = <String, String>{
    'plain reverse anchor control': '<p>中文 <a href="#n">Smith（斯密）</a></p>',
    'plain forward anchor control': '<p>中文 <a href="#n">斯密 (Smith)</a></p>',
    'formatted reverse anchor': '<p>中文 <a href="#n"><em>Smith（斯密）</em></a></p>',
    'formatted forward anchor':
        '<p>中文 <a href="#n"><em>斯密 (Smith)</em></a></p>',
    'split reverse anchor': '<p>中文 <a href="#n">Sm<em>ith（斯密）</em></a></p>',
    'split forward anchor': '<p>中文 <a href="#n">斯密 (Sm<em>ith</em>)</a></p>',
    'prefixed reverse anchor':
        '<p xmlns:x="http://www.w3.org/1999/xhtml">中文 <x:a href="#n">Smith（斯密）</x:a></p>',
    'prefixed forward anchor':
        '<p xmlns:x="http://www.w3.org/1999/xhtml">中文 <x:a href="#n">斯密 (Smith)</x:a></p>',
    'quoted greater-than reverse anchor':
        '<p>中文 <a title="a > b" href="#n">Smith（斯密）</a></p>',
    'quoted greater-than forward anchor':
        '<p>中文 <a title="a > b" href="#n">斯密 (Smith)</a></p>',
  };
  for (final entry in protected.entries) {
    test(entry.key, () {
      final state = ProperNameNormalizer.bookState();
      final result = normalize(entry.value, state);
      final following = normalize('<p>Smith继续。</p>', state);
      expect(result, entry.value);
      expect(following, '<p>斯密（Smith）继续。</p>');
    });
  }
  for (final input in [
    '<p><em id="style">Smith</em>（斯密）继续。</p>',
    '<p>Sm<em id="style">ith</em>（斯密）继续。</p>',
    '<p><em id="style">Smith（</em>斯密）继续。</p>',
    '<p>Smith（<em id="style">斯密</em>）继续。</p>',
  ]) {
    test('source or target emphasis retains visible content: $input', () {
      final result = normalize(input, ProperNameNormalizer.bookState());
      final doc = XmlDocument.parse(result);
      expect(doc.rootElement.innerText, '斯密（Smith）继续。');
      final styled = doc.findAllElements('em').single;
      expect(
        styled.innerText,
        isNotEmpty,
        reason:
            'The name must retain visible emphasis, not just an empty em element.',
      );
    });
  }
  for (final input in [
    '<p>中文 aSmith（斯密）继续。</p>',
    '<p>中文 &#97;Smith（斯密）继续。</p>',
    '<p>中文 éSmith（斯密）继续。</p>',
    '<p>中文 &#233;Smith（斯密）继续。</p>',
    '<p>中文 <em>é</em>Smith（斯密）继续。</p>',
    '<p>中文 Smithé继续。</p>',
  ]) {
    test('visible Unicode word boundary: $input', () {
      final state = ProperNameNormalizer.bookState();
      final result = normalize(input, state);
      expect(result, input);
      expect(state.countedNames, isEmpty);
    });
  }
}
