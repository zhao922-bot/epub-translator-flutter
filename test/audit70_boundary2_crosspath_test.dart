import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'support/review_baseline_fixture.dart';

List<String> _tags(String html) => XmlDocument.parse(html).descendants
    .whereType<XmlElement>()
    .map((e) => '${e.name} ${e.attributes.join(' ')}')
    .toList();

String _text(String html) => XmlDocument.parse(html).rootElement.innerText;

Map<String, dynamic> _twoChapters(String output) {
  final rendering = writeReviewBaselineFixture(output);
  const source = '<html><body><p>The second chapter.</p></body></html>';
  const draft = '<p>第二章。</p>';
  const base = '<html><body>$draft</body></html>';
  final archive = ZipDecoder().decodeBytes(File(output).readAsBytesSync());
  archive.add(ArchiveFile.string('second.xhtml', base));
  archive.add(
    ArchiveFile.string(
      'book.opf',
      '<package><manifest>'
          '<item id="s" href="story.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="t" href="second.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine><itemref idref="s"/><itemref idref="t"/></spine></package>',
    ),
  );
  File(output).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  (rendering['chapters'] as Map)['second.xhtml'] = {
    'originalHtml': source,
    'translations': {'p-1': draft},
    'baseHtmlSha256': sha256.convert(utf8.encode(base)).toString(),
    'countedNames': <String>[],
    'degraded': <String>[],
  };
  return rendering;
}

void main() {
  for (final input in [
    '<p>中文 &#97;Smith（斯密）继续。</p>',
    '<p>中文 a<em>Smith（斯密）</em>继续。</p>',
    '<p>中文 <em>a</em>Smith（斯密）继续。</p>',
    '<p>中文 aSmith（斯密）继续。</p>',
    '<p>中文 Smith<em>sonian</em>（斯密）继续。</p>',
  ]) {
    test('reverse prepass also respects visible word boundaries: $input', () {
      final state = ProperNameNormalizer.bookState();
      expect(
        ProperNameNormalizer.normalizeHtml(
          input,
          const [ProperNameMap(source: 'Smith', target: '斯密')],
          targetLanguage: 'Chinese',
          state: state,
        ),
        input,
      );
      expect(state.countedNames, isEmpty);
    });
  }

  for (final input in [
    '<p>Smith（斯<em id="style">密</em>）继续。</p>',
    '<p>Smith（<em id="style">斯密</em>）继续。</p>',
    '<p><em id="style">Smith（斯密</em>）继续。</p>',
  ]) {
    for (final later in [false, true]) {
      test('reverse formatted target retains tags, later=$later: $input', () {
        final state = ProperNameNormalizer.bookState();
        if (later) state.countedNames.add('Smith');
        final result = ProperNameNormalizer.normalizeHtml(
          input,
          const [ProperNameMap(source: 'Smith', target: '斯密')],
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(_tags(result), _tags(input));
        expect(_text(result), later ? '斯密继续。' : '斯密（Smith）继续。');
        expect(state.countedNames, {'Smith'});
      });
    }
  }

  for (final suffix in ['&#32;', '<em> </em>', '<span/>']) {
    test('independent reverse gloss keeps a following separator: $suffix', () {
      final input = '<p>Smith（斯密）$suffix继续。</p>';
      final result = ProperNameNormalizer.normalizeHtml(
        input,
        const [ProperNameMap(source: 'Smith', target: '斯密')],
        targetLanguage: 'Chinese',
        state: ProperNameNormalizer.bookState(),
      );
      expect(result, '<p>斯密（Smith）$suffix继续。</p>');
      expect(_tags(result), _tags(input));
    });
  }

  test('reverse gloss preserves every single inline wrapper placement', () {
    const name = 'Smith（斯密）';
    for (var start = 0; start < name.length; start++) {
      for (var end = start + 1; end <= name.length; end++) {
        final input =
            '<p>${name.substring(0, start)}<em id="style">'
            '${name.substring(start, end)}</em>${name.substring(end)}继续。</p>';
        for (final later in [false, true]) {
          final state = ProperNameNormalizer.bookState();
          if (later) state.countedNames.add('Smith');
          final result = ProperNameNormalizer.normalizeHtml(
            input,
            const [ProperNameMap(source: 'Smith', target: '斯密')],
            targetLanguage: 'Chinese',
            state: state,
          );
          final doc = XmlDocument.parse(result);
          final styles = doc.findAllElements('em').toList();
          expect(
            styles.where((e) => e.getAttribute('id') == 'style'),
            hasLength(1),
          );
          // A wrapper crossing the two names must split to keep the style on
          // its original characters. Verify those characters, not just tags.
          final order = later ? [6, 7] : [6, 7, 5, 0, 1, 2, 3, 4, 8];
          final expectedStyle = order
              .where((i) => i >= start && i < end)
              .map((i) => name[i])
              .join();
          expect(
            styles.map((e) => e.innerText).join(),
            expectedStyle,
            reason: input,
          );
          expect(
            _text(result),
            later ? '斯密继续。' : '斯密（Smith）继续。',
            reason: input,
          );
          expect(state.countedNames, {'Smith'});
        }
      }
    }
  });

  test('encoded reverse source and parentheses retain first/later order', () {
    const input = '<p>&#83;m<em>ith&#40;斯密</em>&#41;继续。</p>';
    final state = ProperNameNormalizer.bookState();
    for (final later in [false, true]) {
      final result = ProperNameNormalizer.normalizeHtml(
        input,
        const [ProperNameMap(source: 'Smith', target: '斯密')],
        targetLanguage: 'Chinese',
        state: state,
      );
      final styles = XmlDocument.parse(result).findAllElements('em');
      expect(styles.map((e) => e.innerText).join(), later ? '斯密' : '斯密（ith');
      expect(_text(result), later ? '斯密继续。' : '斯密（Smith）继续。');
    }
  });

  for (final input in [
    '<p>中文 <code>Sm<em>ith（斯密）</em></code></p>',
    '<p title="Smith（斯密）">中文</p>',
    '<p>中文 <a href="#n">Smith（斯密）</a></p>',
    '<p>中文 <a href="#n">Sm&#105;th（斯密）</a></p>',
    '<p>中文 <a href="#n">斯密 (Smith)</a></p>',
    '<p>中文 <a href="#n">斯&#23494; (Smith)</a></p>',
    '<p class="bibliography">Sm<em>ith（斯密）</em></p>',
  ]) {
    test('gloss preprocessing retains protected contents: $input', () {
      final state = ProperNameNormalizer.bookState();
      expect(
        ProperNameNormalizer.normalizeHtml(
          input,
          const [ProperNameMap(source: 'Smith', target: '斯密')],
          targetLanguage: 'Chinese',
          state: state,
        ),
        input,
      );
      expect(state.countedNames, isEmpty);
    });
  }

  test('single-character reverse target and mixed occurrences share order', () {
    final state = ProperNameNormalizer.bookState();
    final result = ProperNameNormalizer.normalizeHtml(
      '<p>&#76;i&#40;李&#41;继续。李（Li）继续。Li继续。</p>',
      const [ProperNameMap(source: 'Li', target: '李')],
      targetLanguage: 'Chinese',
      state: state,
    );
    expect(_text(result), '李（Li）继续。李继续。李继续。');
    expect(state.countedNames, {'Li'});
  });

  for (final mode in [
    'healthy repeated block ids',
    'healthy legacy optional flags',
    'healthy partial chapters',
    'unknown id in second chapter',
    'invalid include flag in second chapter',
    'invalid translations in second chapter',
    'second chapter changes after load',
    'report changes after load',
  ]) {
    test('legacy validation across chapters and reload: $mode', () async {
      final dir = await Directory.systemTemp.createTemp('review-crosspath-');
      addTearDown(() => dir.delete(recursive: true));
      final output = '${dir.path}/book.epub';
      final rendering = _twoChapters(output);
      final snapshots = rendering['chapters'] as Map;
      final second = snapshots['second.xhtml'] as Map;
      switch (mode) {
        case 'healthy legacy optional flags':
          rendering.remove('completeSnapshot');
          rendering.remove('residualQualityCheck');
          second.remove('includeInTranslation');
        case 'healthy partial chapters':
          snapshots.remove('second.xhtml');
        case 'unknown id in second chapter':
          (second['translations'] as Map)['not-a-block'] = '<p>漏掉。</p>';
        case 'invalid include flag in second chapter':
          second['includeInTranslation'] = 0;
        case 'invalid translations in second chapter':
          second['translations'] = <String, Object>{'p-1': false};
      }
      final report = File('$output.quality.json');
      final data = <String, dynamic>{
        'version': 2,
        'outputPath': output,
        'corrections': <Object>[],
        'rendering': rendering,
      };
      await report.writeAsString(jsonEncode(data));
      const store = TranslationReviewStore();
      if (mode.endsWith('after load')) {
        final loaded = await store.load(
          report.path,
          expectedOutputPath: output,
        );
        expect(await store.manualBlocks(loaded), hasLength(2));
        if (mode == 'second chapter changes after load') {
          final archive = ZipDecoder().decodeBytes(
            await File(output).readAsBytes(),
          );
          archive.add(
            ArchiveFile.string(
              'second.xhtml',
              '<html><body><p>别的译本。</p></body></html>',
            ),
          );
          await File(output).writeAsBytes(ZipEncoder().encodeBytes(archive));
        } else {
          (second['translations'] as Map)['not-a-block'] = '<p>漏掉。</p>';
          await report.writeAsString(jsonEncode(data));
        }
      }
      final reportBefore = await report.readAsString();
      final epubBefore = await File(output).readAsBytes();
      if (mode.startsWith('healthy')) {
        final loaded = await store.load(
          report.path,
          expectedOutputPath: output,
        );
        final blocks = await store.manualBlocks(loaded);
        expect(blocks, hasLength(mode == 'healthy partial chapters' ? 1 : 2));
        expect(blocks.map((b) => b['key']).toSet(), hasLength(blocks.length));
        for (var attempt = 0; attempt < 2; attempt++) {
          final exported = await store.export(
            reportPath: report.path,
            baseOutputPath: output,
            accepted: {},
          );
          final archive = ZipDecoder().decodeBytes(
            await File(exported).readAsBytes(),
          );
          expect(
            _text(
              utf8.decode(
                archive.findFile('story.xhtml')!.content as List<int>,
              ),
            ),
            contains('她喜极而泣。'),
          );
          expect(
            _text(
              utf8.decode(
                archive.findFile('second.xhtml')!.content as List<int>,
              ),
            ),
            contains('第二章。'),
          );
          final reloaded = await store.load(
            report.path,
            expectedOutputPath: output,
          );
          expect(await store.manualBlocks(reloaded), hasLength(blocks.length));
        }
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
        expect(await report.readAsString(), reportBefore);
        expect(
          dir.listSync().whereType<File>().where(
            (f) => f.path.contains('_reviewed_'),
          ),
          isEmpty,
        );
      }
      expect(await File(output).readAsBytes(), epubBefore);
    });
  }
}
