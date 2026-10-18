import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'support/review_baseline_fixture.dart';

List<String> _tags(String input) => XmlDocument.parse(input).descendants
    .whereType<XmlElement>()
    .map((e) => '${e.name} ${e.attributes.join(' ')}')
    .toList();

void main() {
  const forms = {
    'encoded space': '<p>后来，亚当·斯密（Ad<em>am&#160;Smith</em>）继续。</p>',
    'encoded letter': '<p>后来，亚当·斯密（<em>&#65;dam Smith</em>）继续。</p>',
    'encoded parentheses': '<p>后来，亚当·斯密&#40;<em>Adam Smith</em>&#41;继续。</p>',
    'empty target anchor': '<p>后来，亚当<a id="page"></a>·斯密（Adam Smith）继续。</p>',
    'empty source anchor': '<p>后来，亚当·斯密（Ad<a id="page"></a>am Smith）继续。</p>',
    'self closing marker': '<p>后来，亚当·斯密（Ad<span id="page"/>am Smith）继续。</p>',
  };
  for (final entry in forms.entries) {
    for (final later in [false, true]) {
      test('formatted names ${later ? 'later' : 'first'}: ${entry.key}', () {
        final state = ProperNameNormalizer.bookState();
        if (later) state.countedNames.add('Adam Smith');
        final out = ProperNameNormalizer.normalizeHtml(
          entry.value,
          const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(_tags(out), _tags(entry.value));
        final visible = XmlDocument.parse(
          out,
        ).rootElement.innerText.replaceAll(RegExp(r'\s'), '');
        expect(visible, later ? '后来，亚当·斯密继续。' : '后来，亚当·斯密（AdamSmith）继续。');
        expect(state.countedNames, contains('Adam Smith'));
      });
    }
  }
  for (final input in [
    '<p>后来，亚当·斯密（Adam<em>Smith</em>）继续。</p>',
    '<p>后来，亚当·斯密（Ad<code>am</code> Smith）继续。</p>',
    '<p>后来，<a href="#note">Adam Smith</a>注释。</p>',
    '<p>后来，亚当·斯密（Adam <em>Smithson</em>）继续。</p>',
  ]) {
    test(
      'formatted names leave protected or unmatched text intact: $input',
      () {
        expect(
          ProperNameNormalizer.normalizeHtml(
            input,
            const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
            targetLanguage: 'Chinese',
            state: ProperNameNormalizer.bookState(),
          ),
          input,
        );
      },
    );
  }

  test(
    'entity spellings are not bare proper names and are not decoded twice',
    () {
      const input = '<p>中文 &amp; &amp;lt; &lt;tag&gt;。</p>';
      final state = ProperNameNormalizer.bookState();
      final out = ProperNameNormalizer.normalizeHtml(
        input,
        const [ProperNameMap(source: 'amp', target: '安普')],
        targetLanguage: 'Chinese',
        state: state,
      );
      expect(out, input);
      expect(state.countedNames, isEmpty);
      expect(
        ProperNameNormalizer.normalizeHtml('<p>中文 &lt;tag&gt;。</p>', const [
          ProperNameMap(source: 'lt', target: '艾尔'),
        ], targetLanguage: 'Chinese'),
        '<p>中文 &lt;tag&gt;。</p>',
      );
      const nested = '<p>亚当&amp;amp;斯密（Ad<em>am Smith</em>）继续。</p>';
      expect(
        ProperNameNormalizer.normalizeHtml(
          nested,
          const [ProperNameMap(source: 'Adam Smith', target: '亚当&斯密')],
          targetLanguage: 'Chinese',
          state: ProperNameNormalizer.bookState()
            ..countedNames.add('Adam Smith'),
        ),
        nested,
        reason:
            'A literal &amp; in visible text must not be decoded a second time to match the locked target.',
      );
    },
  );

  test(
    'encoded characters and arbitrary inline boundaries retain raw offsets in 200 seeded variants',
    () {
      final random = Random(20304);
      const chars = '亚当·斯密（Adam Smith）';
      for (var sample = 0; sample < 200; sample++) {
        final from = random.nextInt(chars.length),
            to = random.nextInt(chars.length);
        final low = min(from, to), high = max(from, to) + 1;
        final encoded = random.nextInt(chars.length);
        final input = StringBuffer('<p>😀后来，');
        for (var i = 0; i < chars.length; i++) {
          if (i == low) input.write('<em id="m$sample">');
          input.write(i == encoded ? '&#${chars.codeUnitAt(i)};' : chars[i]);
          if (i + 1 == high) input.write('</em>');
        }
        input.write('继续。</p>');
        final state = ProperNameNormalizer.bookState();
        for (final later in [false, true]) {
          final result = ProperNameNormalizer.normalizeHtml(
            input.toString(),
            const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
            targetLanguage: 'Chinese',
            state: state,
          );
          expect(_tags(result), _tags(input.toString()));
          expect(
            XmlDocument.parse(result).rootElement.innerText,
            later ? '😀后来，亚当·斯密继续。' : '😀后来，亚当·斯密（Adam Smith）继续。',
            reason: 'sample $sample: $input',
          );
        }
      }
    },
  );

  test(
    'apostrophe entities inside formatted names retain first gloss and remove later gloss',
    () {
      const input = '<p>奥布莱恩（O<em>&apos;Brien</em>）继续。</p>';
      final state = ProperNameNormalizer.bookState();
      const mapping = [ProperNameMap(source: "O'Brien", target: '奥布莱恩')];
      for (final later in [false, true]) {
        final output = ProperNameNormalizer.normalizeHtml(
          input,
          mapping,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(_tags(output), _tags(input));
        expect(
          XmlDocument.parse(output).rootElement.innerText,
          later ? '奥布莱恩继续。' : "奥布莱恩（O'Brien）继续。",
        );
      }
    },
  );

  testWidgets(
    'inconsistent suggestion recovers before the review page displays it',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('boundary2-review-ui-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final output = '${dir.path}/book.epub';
      final report = File('$output.quality.json');
      report.writeAsStringSync(
        jsonEncode({
          'version': 2,
          'outputPath': output,
          'rendering': writeReviewBaselineFixture(output),
          'corrections': [
            {
              'chapter': 'story.xhtml',
              'id': 'unknown',
              'sourceHtml': '<p>Alas, she cried.</p>',
              'beforeHtml': '<p>她喜极而泣。</p>',
              'afterHtml': '<p>不应显示的建议</p>',
              'issues': <String>[],
            },
          ],
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationReviewPage(
            reportPath: report.path,
            outputPath: output,
            isChinese: false,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Could not read the review report'),
        findsOneWidget,
      );
      expect(find.textContaining('不应显示的建议'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in [
    'healthy partial',
    'unknown id',
    'missing draft',
    'mismatched draft',
    'mismatched source',
    'source block missing',
    'bad originalHtml',
    'bad translations',
    'nonstring draft',
    'bad countedNames',
    'bad degraded',
    'bad target language',
    'bad glossary',
    'bad complete flag',
  ]) {
    test('report suggestion and rendering consistency: $mode', () async {
      final dir = await Directory.systemTemp.createTemp('boundary2-report-');
      addTearDown(() => dir.delete(recursive: true));
      final output = '${dir.path}/book.epub';
      final rendering =
          jsonDecode(jsonEncode(writeReviewBaselineFixture(output)))
              as Map<String, dynamic>;
      final item = <String, dynamic>{
        'chapter': 'story.xhtml',
        'id': 'p-1',
        'sourceHtml': '<p>Alas, she cried.</p>',
        'beforeHtml': '<p>她喜极而泣。</p>',
        'afterHtml': '<p>她悲伤地哭了。</p>',
        'issues': <String>['meaning'],
      };
      final snapshot = (rendering['chapters'] as Map)['story.xhtml'] as Map;
      switch (mode) {
        case 'unknown id':
          item['id'] = 'missing';
        case 'missing draft':
          (snapshot['translations'] as Map).clear();
        case 'mismatched draft':
          item['beforeHtml'] = '<p>不属于这个译本。</p>';
        case 'mismatched source':
          item['sourceHtml'] = '<p>Different source.</p>';
        case 'source block missing':
          snapshot['originalHtml'] = '<html><body></body></html>';
        case 'bad originalHtml':
          snapshot['originalHtml'] = 42;
        case 'bad translations':
          snapshot['translations'] = [];
        case 'nonstring draft':
          snapshot['translations']['p-1'] = 42;
        case 'bad countedNames':
          snapshot['countedNames'] = [42];
        case 'bad degraded':
          snapshot['degraded'] = {};
        case 'bad target language':
          rendering['targetLanguage'] = 42;
        case 'bad glossary':
          rendering['lockedGlossary'] = [];
        case 'bad complete flag':
          rendering['completeSnapshot'] = 'true';
      }
      final report = File('$output.quality.json');
      await report.writeAsString(
        jsonEncode({
          'version': 2,
          'outputPath': output,
          'rendering': rendering,
          'corrections': [item],
        }),
      );
      final before = await report.readAsString();
      final base = await File(output).readAsBytes();
      const store = TranslationReviewStore();
      if (mode == 'healthy partial') {
        final loaded = await store.load(
          report.path,
          expectedOutputPath: output,
        );
        expect(await store.manualBlocks(loaded), hasLength(1));
        final exported = await store.export(
          reportPath: report.path,
          baseOutputPath: output,
          accepted: {TranslationReviewStore.suggestionKey(item)},
        );
        final archive = ZipDecoder().decodeBytes(
          await File(exported).readAsBytes(),
        );
        final text = XmlDocument.parse(
          utf8.decode(archive.findFile('story.xhtml')!.content as List<int>),
        ).rootElement.innerText;
        expect(text, contains('她悲伤地哭了。'));
      } else {
        await expectLater(
          store.load(report.path, expectedOutputPath: output),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          store.export(
            reportPath: report.path,
            baseOutputPath: output,
            accepted: {TranslationReviewStore.suggestionKey(item)},
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await report.readAsString(), before);
        expect(
          dir.listSync().whereType<File>().where(
            (f) => f.path.contains('_reviewed_'),
          ),
          isEmpty,
        );
      }
      expect(await File(output).readAsBytes(), base);
    });
  }
}
