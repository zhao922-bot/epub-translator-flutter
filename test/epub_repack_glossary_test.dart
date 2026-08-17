import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('repack applies locked proper-name glossary across chapters', () {
    test('first chapter annotates once, later chapter drops the gloss', () {
      InspectedChapter chapter(String id, String html, String translated) {
        return InspectedChapter(
          path: 'text/ch_$id.html',
          title: 'Chapter $id',
          body: 'body',
          originalHtml: html,
          blocks: <ExtractedBlock>[
            ExtractedBlock(
              id: 'b-$id',
              tagName: 'p',
              sourceHtml: '<p>source</p>',
              sourceText: 'source',
              translatedHtml: translated,
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        );
      }

      final ProperNameBookState state = ProperNameNormalizer.bookState();
      final EpubRepacker repacker = EpubRepacker();

      final String ch1 = repacker.renderTranslatedChapter(
        chapter: chapter(
          '1',
          '<html><body><p>a</p></body></html>',
          '<p>Adam Smith的著作。</p>',
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
        lockedGlossary: 'Adam Smith => 亚当·斯密',
        properNameState: state,
      );
      final String ch2 = repacker.renderTranslatedChapter(
        chapter: chapter(
          '2',
          '<html><body><p>a</p></body></html>',
          '<p>Adam Smith是经济学家。</p>',
        ),
        bilingual: false,
        targetLanguage: 'Chinese',
        lockedGlossary: 'Adam Smith => 亚当·斯密',
        properNameState: state,
      );

      expect(ch1, contains('亚当·斯密（Adam Smith）的著作'));
      expect(ch2, contains('亚当·斯密是经济学家'));
      expect(ch2, isNot(contains('（Adam Smith）')));
    });
  });
}
