import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:epub_translator_flutter/features/settings/presentation/widgets/settings_fields.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'support/review_baseline_fixture.dart';

List<String> _structure(String markup) => XmlDocument.parse(markup).descendants
    .whereType<XmlElement>()
    .map((e) => '${e.name} ${e.attributes.join(' ')}')
    .toList();

void main() {
  for (final outcome in ['success', 'false', 'throw']) {
    testWidgets('RC01 dispose revert survives older save $outcome', (
      tester,
    ) async {
      final gate = Completer<bool>();
      final writes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTextField(
              fieldKey: const ValueKey('field'),
              value: 'original',
              onChanged: (_) {},
              onCommit: (text) {
                writes.add(text);
                return writes.length == 1 ? gate.future : true;
              },
              decoration: const InputDecoration(),
              strings: const AppStrings(UiLanguage.english),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('field')), 'pending');
      await tester.pump(const Duration(milliseconds: 801));
      await tester.enterText(find.byKey(const ValueKey('field')), 'original');
      await tester.pumpWidget(const SizedBox.shrink());
      if (outcome == 'throw') {
        gate.completeError(StateError('older save failed'));
      } else {
        gate.complete(outcome == 'success');
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(writes, ['pending', 'original']);
      expect(tester.takeException(), isNull);
    });
  }
  for (final mode in ['same pending', 'disabled', 'preset reset']) {
    testWidgets('RC01 dispose avoids extra writes after $mode', (tester) async {
      final gate = Completer<bool>();
      final writes = <String>[];
      Future<void> field({bool enabled = true, int reset = 0}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SettingsTextField(
                  fieldKey: const ValueKey('field'),
                  value: reset == 0 ? 'original' : 'preset',
                  enabled: enabled,
                  resetKey: reset,
                  onChanged: (_) {},
                  onCommit: (text) {
                    writes.add(text);
                    return gate.future;
                  },
                  decoration: const InputDecoration(),
                  strings: const AppStrings(UiLanguage.english),
                ),
              ),
            ),
          );
      await field();
      await tester.enterText(find.byKey(const ValueKey('field')), 'pending');
      await tester.pump(const Duration(milliseconds: 801));
      if (mode == 'disabled') await field(enabled: false);
      if (mode == 'preset reset') await field(reset: 1);
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete(true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(writes, ['pending']);
      expect(tester.takeException(), isNull);
    });
  }

  const forms = {
    'short target wrapper': '<p>亚当<em>·斯密</em> (Adam Smith) 继续。</p>',
    'target crosses wrapper': '<p><em>亚当·斯密</em> (Adam Smith) 继续。</p>',
    'target empty anchor': '<p>亚当<i id="a"></i>·斯密 (Adam Smith) 继续。</p>',
    'source split formatting': '<p>亚当·斯密（Adam <em id="e">Smith</em>）继续。</p>',
    'source split inside word': '<p>亚当·斯密（Ad<em id="e">am Smi</em>th）继续。</p>',
    'source and target formatting': '<p>亚当<em>·斯密 (Adam </em>Smith) 继续。</p>',
  };
  for (final entry in forms.entries) {
    for (final later in [false, true]) {
      test('RC03 ${later ? 'later' : 'first'} ${entry.key} retains markup', () {
        final state = ProperNameNormalizer.bookState();
        if (later) state.countedNames.add('Adam Smith');
        final result = ProperNameNormalizer.normalizeHtml(
          entry.value,
          const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(_structure(result), _structure(entry.value));
        expect(
          XmlDocument.parse(result).rootElement.innerText.replaceAll(' ', ''),
          later ? '亚当·斯密继续。' : '亚当·斯密（AdamSmith）继续。',
        );
        expect(state.countedNames, contains('Adam Smith'));
      });
    }
  }

  test(
    'RC03 inline markup preserves first-occurrence order across 200 seeded variants',
    () {
      final random = Random(40103);
      for (var sample = 0; sample < 200; sample++) {
        final half = sample.isEven;
        final text = '亚当·斯密${half ? '(' : '（'}Adam Smith${half ? ')' : '）'}';
        final start = random.nextInt(text.length),
            end = random.nextInt(text.length);
        final low = min(start, end), high = max(start, end) + 1;
        final name =
            '${text.substring(0, low)}<em id="g$sample">${text.substring(low, high)}</em>${text.substring(high)}';
        final source = '<p>$name继续。</p>';
        final state = ProperNameNormalizer.bookState();
        const mapping = [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')];
        final first = ProperNameNormalizer.normalizeHtml(
          source,
          mapping,
          targetLanguage: 'Chinese',
          state: state,
        );
        final later = ProperNameNormalizer.normalizeHtml(
          source,
          mapping,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(
          _structure(first),
          _structure(source),
          reason: 'first sample $sample',
        );
        expect(
          _structure(later),
          _structure(source),
          reason: 'later sample $sample',
        );
        expect(
          XmlDocument.parse(first).rootElement.innerText,
          '亚当·斯密（Adam Smith）继续。',
          reason: source,
        );
        expect(
          XmlDocument.parse(later).rootElement.innerText,
          '亚当·斯密继续。',
          reason: source,
        );
      }
    },
  );
  test(
    'RC03 formatted and bare names share document order and keep protected text',
    () {
      const source =
          '<p>Adam Smith先写作。亚当·斯密（Ad<em>am Smith</em>）继续。</p>'
          '<p>亚当·斯密（<code>Adam Smith</code>）和另一个人（Adam <em>Smith</em>）。</p>'
          '<p>亚当·斯密（Adam <em>Smithson</em>）。</p>';
      final result = ProperNameNormalizer.normalizeHtml(
        source,
        const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
        targetLanguage: 'Chinese',
        state: ProperNameNormalizer.bookState(),
      );
      expect(result, contains('亚当·斯密（Adam Smith）先写作。亚当·斯密<em></em>继续。'));
      expect(result, contains('<code>Adam Smith</code>'));
      expect(result, contains('另一个人（Adam <em>Smith</em>）'));
      expect(result, contains('Adam <em>Smithson</em>'));
    },
  );

  for (final mode in [
    'healthy partial',
    'healthy missing flag',
    'empty chapters',
    'missing chapter for suggestion',
    'invalid snapshot',
    'missing digest',
    'wrong digest',
    'wrong output',
  ]) {
    test('RC04 report baseline validation: $mode', () async {
      final dir = await Directory.systemTemp.createTemp('boundary4-report-');
      addTearDown(() => dir.delete(recursive: true));
      final output = '${dir.path}/book.epub';
      final rendering =
          jsonDecode(jsonEncode(writeReviewBaselineFixture(output)))
              as Map<String, dynamic>;
      final data = <String, dynamic>{
        'version': 2,
        'outputPath': output,
        'rendering': rendering,
        'corrections': <Map<String, dynamic>>[
          {
            'chapter': 'story.xhtml',
            'id': 'p-1',
            'sourceHtml': '<p>Alas, she cried.</p>',
            'beforeHtml': '<p>她喜极而泣。</p>',
            'afterHtml': '<p>她哭了。</p>',
            'issues': <String>[],
          },
        ],
      };
      final chapters = rendering['chapters'] as Map;
      switch (mode) {
        case 'healthy missing flag':
          rendering.remove('completeSnapshot');
        case 'empty chapters':
          chapters.clear();
        case 'missing chapter for suggestion':
          (data['corrections'] as List).single['chapter'] = 'missing.xhtml';
        case 'invalid snapshot':
          chapters['story.xhtml'] = 'broken';
        case 'missing digest':
          (chapters['story.xhtml'] as Map).remove('baseHtmlSha256');
        case 'wrong digest':
          chapters['story.xhtml']['baseHtmlSha256'] = '0' * 64;
        case 'wrong output':
          data['outputPath'] = '${dir.path}/another.epub';
      }
      final report = File('$output.quality.json');
      await report.writeAsString(jsonEncode(data));
      final loading = const TranslationReviewStore().load(
        report.path,
        expectedOutputPath: output,
      );
      if (mode.startsWith('healthy')) {
        final loaded = await loading;
        expect((loaded['corrections'] as List).length, 1);
        expect(
          await const TranslationReviewStore().manualBlocks(loaded),
          hasLength(1),
        );
      } else {
        await expectLater(loading, throwsA(isA<FormatException>()));
        await expectLater(
          const TranslationReviewStore().export(
            reportPath: report.path,
            baseOutputPath: output,
            accepted: const {'story.xhtml\u0000p-1'},
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          dir.listSync().whereType<File>().where(
            (f) => f.path.contains('_reviewed_'),
          ),
          isEmpty,
        );
      }
    });
  }
}
