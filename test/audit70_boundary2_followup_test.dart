import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'support/review_baseline_fixture.dart';

List<String> _tags(String input) => XmlDocument.parse(input).descendants
    .whereType<XmlElement>()
    .map((e) => '${e.name} ${e.attributes.join(' ')}')
    .toList();

void main() {
  for (final input in [
    '<p>中文 Li&#109;ited。</p>',
    '<p>中文 &#97;Li。</p>',
    '<p>中文 Li<em>mited</em>。</p>',
    '<p>中文 <em>a</em>Li。</p>',
    '<p>中文 Li<span id="page"></span>&#109;ited。</p>',
    '<p>中文 L<em> </em>i。</p>',
    '<div>中文 L<p></p>i。</div>',
  ]) {
    test('visible word boundaries protect adjacent letters: $input', () {
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
  }

  test('visible spaces still separate valid names and preserve book order', () {
    const input = '<p>中文 Li&#32;said. Li<em> </em>said.</p>';
    final state = ProperNameNormalizer.bookState();
    final result = ProperNameNormalizer.normalizeHtml(
      input,
      const [ProperNameMap(source: 'Li', target: '李')],
      targetLanguage: 'Chinese',
      state: state,
    );
    expect(_tags(result), _tags(input));
    expect(
      XmlDocument.parse(result).rootElement.innerText,
      '中文 李（Li） said. 李 said.',
    );
    expect(state.countedNames, {'Li'});
  });

  for (final input in [
    '<p title="&#20013;&#25991;">Adam Smith said.</p>',
    '<div><code>&#20013;&#25991;</code><p>Adam Smith said.</p></div>',
    '<p class="bibliography">&#20013;&#25991; Adam Smith, 1776.</p>',
    '<p>&#20013;&#25991; <a href="#n">&#76;i</a></p>',
  ]) {
    test('encoded text still respects protected content: $input', () {
      final state = ProperNameNormalizer.bookState();
      expect(
        ProperNameNormalizer.normalizeHtml(
          input,
          const [
            ProperNameMap(source: 'Adam Smith', target: '亚当·斯密'),
            ProperNameMap(source: 'Li', target: '李'),
          ],
          targetLanguage: 'Chinese',
          state: state,
        ),
        input,
      );
      expect(state.countedNames, isEmpty);
    });
  }

  for (final entry in {
    'fully encoded CJK':
        '<p>&#20122;&#24403;&#183;&#26031;&#23494;（Ad<em>am Smith</em>）</p>',
    'encoded whitespace anchor':
        '<p>亚当·斯密（Adam<a id="page">&#32;</a>Smith）</p>',
    'encoded target anchor':
        '<p>亚当<a id="page">&#160;</a>·斯密（Ad<em>am Smith</em>）</p>',
  }.entries) {
    for (final later in [false, true]) {
      test('${entry.key} ${later ? 'later' : 'first'}', () {
        final state = ProperNameNormalizer.bookState();
        if (later) state.countedNames.add('Adam Smith');
        final result = ProperNameNormalizer.normalizeHtml(
          entry.value,
          const [ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(_tags(result), _tags(entry.value));
        expect(
          XmlDocument.parse(
            result,
          ).rootElement.innerText.replaceAll(RegExp(r'\s'), ''),
          later ? '亚当·斯密' : '亚当·斯密（AdamSmith）',
        );
        expect(state.countedNames, contains('Adam Smith'));
      });
    }
  }

  for (final mode in [
    'healthy without suggestions',
    'healthy missing optional flags',
    'unknown draft without suggestions',
    'unknown extra draft with suggestion',
    'bad residual flag',
    'bad include flag',
  ]) {
    test('all snapshot drafts and optional settings: $mode', () async {
      final dir = await Directory.systemTemp.createTemp('boundary2-followup-');
      addTearDown(() => dir.delete(recursive: true));
      final output = '${dir.path}/book.epub';
      final rendering = writeReviewBaselineFixture(output);
      final snapshot = (rendering['chapters'] as Map)['story.xhtml'] as Map;
      final item = {
        'chapter': 'story.xhtml',
        'id': 'p-1',
        'sourceHtml': '<p>Alas, she cried.</p>',
        'beforeHtml': '<p>她喜极而泣。</p>',
        'afterHtml': '<p>她悲伤地哭了。</p>',
        'issues': <String>[],
      };
      final corrections = <Map<String, Object>>[];
      switch (mode) {
        case 'healthy missing optional flags':
          rendering.remove('completeSnapshot');
        case 'unknown draft without suggestions':
          snapshot['translations'] = {'missing': '<p>她喜极而泣。</p>'};
        case 'unknown extra draft with suggestion':
          (snapshot['translations'] as Map)['missing'] = '<p>无对应原文。</p>';
          corrections.add(item);
        case 'bad residual flag':
          rendering['residualQualityCheck'] = 'false';
        case 'bad include flag':
          snapshot['includeInTranslation'] = 'false';
      }
      final report = File('$output.quality.json');
      final original = jsonEncode({
        'version': 2,
        'outputPath': output,
        'rendering': rendering,
        'corrections': corrections,
      });
      await report.writeAsString(original);
      final base = await File(output).readAsBytes();
      const store = TranslationReviewStore();
      if (mode.startsWith('healthy')) {
        final loaded = await store.load(
          report.path,
          expectedOutputPath: output,
        );
        expect(await store.manualBlocks(loaded), hasLength(1));
        final exported = await store.export(
          reportPath: report.path,
          baseOutputPath: output,
          accepted: {},
        );
        final zip = ZipDecoder().decodeBytes(
          await File(exported).readAsBytes(),
        );
        final text = XmlDocument.parse(
          utf8.decode(zip.findFile('story.xhtml')!.content as List<int>),
        ).rootElement.innerText;
        expect(text, contains('她喜极而泣。'));
        expect(text, isNot(contains('Alas')));
      } else {
        await expectLater(
          store.load(report.path, expectedOutputPath: output),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          store.export(
            reportPath: report.path,
            baseOutputPath: output,
            accepted: {},
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await report.readAsString(), original);
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
