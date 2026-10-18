import 'dart:async';
import 'dart:math';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  testWidgets('dispose submits a revert while the older commit is pending', (
    tester,
  ) async {
    final first = Completer<bool>();
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTextField(
            fieldKey: const ValueKey('recheck-field'),
            value: 'original',
            onChanged: (_) {},
            onCommit: (text) {
              writes.add(text);
              return writes.length == 1 ? first.future : Future.value(true);
            },
            decoration: const InputDecoration(),
            strings: const AppStrings(UiLanguage.english),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('recheck-field')),
      'pending',
    );
    await tester.pump(const Duration(milliseconds: 801));
    expect(writes, ['pending']);
    await tester.enterText(
      find.byKey(const ValueKey('recheck-field')),
      'original',
    );
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    first.complete(true);
    await tester.pump();
    expect(writes, ['pending', 'original']);
    expect(tester.takeException(), isNull);
  });
  final laterCases = <String, String>{
    'plain': '<p>后来，亚当·斯密（Adam Smith）继续。</p>',
    'empty anchor': '<p>后来，亚当·斯密（Adam<span id="anchor"></span> Smith）继续。</p>',
    'long target markup':
        '<p>后来，亚当<span data-note="${'x' * 300}">·斯密</span>（Adam Smith）继续。</p>',
    'wrapped half-width gloss': '<p>后来，亚当·斯密 (<em>Adam Smith</em>) 继续。</p>',
    'wrapped gloss': '<p>后来，亚当·斯密（<em id="gloss">Adam Smith</em>）继续。</p>',
    'overlapping wrapper': '<p>后来，<em>亚当·斯密（Adam Smith</em>）继续。</p>',
  };
  for (final entry in laterCases.entries) {
    test(
      'later name gloss preserves structure and removes only the annotation: ${entry.key}',
      () {
        final state = ProperNameNormalizer.bookState();
        final mappings = ProperNameNormalizer.parseGlossary(
          'Adam Smith => 亚当·斯密',
        );
        ProperNameNormalizer.normalizeHtml(
          '<p>最初，Adam Smith写作。</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        final result = ProperNameNormalizer.normalizeHtml(
          entry.value,
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        final xml = XmlDocument.parse(result);
        expect(xml.rootElement.innerText.replaceAll(' ', ''), '后来，亚当·斯密继续。');
        final before = XmlDocument.parse(entry.value).descendants
            .whereType<XmlElement>()
            .map(
              (e) =>
                  e.name.toString() +
                  e.attributes.map((a) => a.toString()).join(),
            )
            .toList();
        final after = xml.descendants
            .whereType<XmlElement>()
            .map(
              (e) =>
                  e.name.toString() +
                  e.attributes.map((a) => a.toString()).join(),
            )
            .toList();
        expect(
          after,
          before,
          reason: 'Formatting elements and owned anchors must remain intact.',
        );
      },
    );
  }
  test(
    'first formatted half-width gloss keeps markup and canonicalizes punctuation',
    () {
      final state = ProperNameNormalizer.bookState();
      final mappings = ProperNameNormalizer.parseGlossary(
        'Adam Smith => 亚当·斯密',
      );
      final result = ProperNameNormalizer.normalizeHtml(
        '<p>亚当·斯密 (<em id="first">Adam Smith</em>)写作。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      final doc = XmlDocument.parse(result);
      expect(doc.rootElement.innerText, '亚当·斯密 （Adam Smith）写作。');
      expect(doc.findAllElements('em').single.getAttribute('id'), 'first');
      expect(
        ProperNameNormalizer.normalizeHtml(
          '<p>亚当·斯密（Adam Smith）继续。</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        ),
        '<p>亚当·斯密继续。</p>',
      );
    },
  );
  for (final input in [
    '<p>另一个人（Adam Smith）继续。</p>',
    '<p>亚当·斯密<code>let x = 1;</code>（Adam Smith）继续。</p>',
  ]) {
    test(
      'a name in unrelated parentheses or across protected content is retained: $input',
      () {
        final state = ProperNameNormalizer.bookState();
        final mappings = ProperNameNormalizer.parseGlossary(
          'Adam Smith => 亚当·斯密',
        );
        ProperNameNormalizer.normalizeHtml(
          '<p>Adam Smith写作。</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(
          ProperNameNormalizer.normalizeHtml(
            input,
            mappings,
            targetLanguage: 'Chinese',
            state: state,
          ),
          input,
        );
      },
    );
  }
  test(
    'original gloss index agrees with the boundary specification on 1000 seeded samples',
    () {
      const cjk = r'\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\u{20000}-\u{2FA1F}';
      const token = 'foo bar';
      final filler = '\\s.,;:，；：、–—\\-$cjk';
      final reference = RegExp(
        '[$cjk]\\s*[（(][$filler]*$token[$filler]*[）)]|'
        '$token\\s*[（(][^）)]*[$cjk][^）)]*[）)]',
        unicode: true,
      );
      final random = Random(170029);
      const atoms = [
        'foo bar',
        'foo',
        'bar',
        ' ',
        '\u00a0',
        '\u3000',
        '中',
        '𠀀',
        '가',
        '（',
        '）',
        '(',
        ')',
        '.',
        'x',
        '😀',
        '\n',
      ];
      for (var sample = 0; sample < 1000; sample++) {
        final text = List.generate(
          20,
          (_) => atoms[random.nextInt(atoms.length)],
        ).join();
        expect(
          TranslationQuality.isParenthesizedTermGlossForTest(text, token),
          reference.hasMatch(text),
          reason: 'sample $sample: $text',
        );
      }
    },
  );
}
