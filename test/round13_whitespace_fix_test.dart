// Round 13: P2-#6 follow-up regression — whitespace doubling.
//
// The P2-#6 fix folds RESPONSE standalone whitespace into adjacent slot
// texts. But when the SOURCE also has standalone whitespace at the same
// position, the source whitespace node survives (it never becomes a slot),
// so the output ends up with BOTH: the folded space inside the slot text
// plus the retained source whitespace node. Browsers collapse the two,
// but the source is wrong. The fix must skip the fold when the source
// already has whitespace at the corresponding position.

import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'P2-#6 regression: source-side whitespace must not double with fold',
    () {
      // The response uses <em> where the source has <i> so the structure
      // mismatches and the equal-slots rebuild path runs (same setup as
      // the round-12 P2-#6 tests), except the source ALSO has a standalone
      // space between the inline elements.
      test('whitespace on both sides is kept exactly once', () {
        final result = EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p><b>Hello</b> <i>world</i></p>',
          translatedHtml: '<p><b>Bonjour</b> <em>monde</em></p>',
        );
        // Exactly one space between the elements: the source's own
        // whitespace node, retained. The fold must be skipped, so the
        // slot text must not carry a trailing space of its own.
        expect(result, contains('</b> <i>monde</i>'));
        expect(result, isNot(contains('Bonjour </b>')));
      });

      test('leading whitespace on both sides is kept exactly once', () {
        final result = EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p> <b>Hello</b><i>world</i></p>',
          translatedHtml: '<p> <b>Bonjour</b><em>monde</em></p>',
        );
        // The source's leading space is retained; the response's leading
        // space must not be folded (prepended) on top of it.
        expect(result, contains('<p> <b>Bonjour</b>'));
        expect(result, isNot(contains('<b> Bonjour</b>')));
      });

      test('response-only whitespace still folds (P2-#6 behavior kept)', () {
        final result = EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: '<p><b>Hello</b><i>world</i></p>',
          translatedHtml: '<p><b>Bonjour</b> <em>monde</em></p>',
        );
        // No source whitespace to retain, so the fold still applies.
        expect(result, contains('Bonjour </b>'));
        expect(result, contains('<i>monde</i>'));
      });
    },
  );
}
