import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the round-12 M1 fix: the rebuild path in
/// `_lockHtmlStructure` used to map the full slot lists positionally and
/// skip protected *source* slots without advancing past protected
/// *translation* texts, so a footnote marker the model moved to another
/// position (with the total slot count unchanged) silently dropped real
/// translation text and duplicated the marker text into a text slot.
void main() {
  group('bugfix round12 M1: marker-aware rebuild mapping', () {
    test('moved marker does not drop translation text', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>AB<a href="#fn1">[1]</a></p>',
        translatedHtml: '<p><a href="#fn1">[1]</a>译AB</p>',
      );
      // The marker is restored to its source position and the translation
      // text survives; previously this produced '<p>[1]<a ...>[1]</a></p>'.
      expect(result, '<p>译AB<a href="#fn1">[1]</a></p>');
    });

    test('aligned markers keep working as before', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>正文<a href="#fn1">[1]</a>继续</p>',
        translatedHtml: '<p>译文<a href="#fn1">[1]</a>续译</p>',
      );
      expect(result, '<p>译文<a href="#fn1">[1]</a>续译</p>');
    });

    test('swapped markers are restored to source positions', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>A<a href="#f1">[1]</a>B<a href="#f2">[2]</a></p>',
        translatedHtml: '<p>译A<a href="#f2">[2]</a>译B<a href="#f1">[1]</a></p>',
      );
      expect(result, '<p>译A<a href="#f1">[1]</a>译B<a href="#f2">[2]</a></p>');
    });

    test('model-dropped marker falls back instead of losing text', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>A<a href="#fn1">[1]</a></p>',
        translatedHtml: '<p>译A译B</p>',
      );
      // Protected counts no longer line up, so the plain-text fallback runs:
      // the translation text is preserved and the marker keeps its source
      // text. Previously '译B' was silently dropped.
      expect(result.contains('译A译B'), isTrue);
      expect(result.contains('[1]'), isTrue);
    });
  });
}
