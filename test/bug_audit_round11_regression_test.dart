// Round-11 bug-audit regressions (2026-09-30): follow-up check after the
// round-10 fixes. Six new minor issues were found and fixed here; each test
// below fails on the pre-fix code and passes after.
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

String _normalizeAdam(String html) => ProperNameNormalizer.normalizeHtml(
  html,
  const <ProperNameMap>[ProperNameMap(source: 'Adam Smith', target: '亚当·斯密')],
  targetLanguage: 'zh',
  state: ProperNameNormalizer.bookState(),
);

void main() {
  group('round-11 regressions', () {
    test('stale lang echo: verbatim-kept sibling is not misjudged', () {
      // Source has two <em lang="en"> elements; the model translated one and
      // kept the other verbatim. The old code judged the verbatim one stale
      // because it met the *translated* sibling first in document order.
      final String rendered = EpubRepacker().renderTranslatedChapter(
        chapter: InspectedChapter(
          path: 'OEBPS/ch1.xhtml',
          title: 'Chapter 1',
          body: 'Chapter 1',
          originalHtml:
              '<html><body><p>She said <em lang="en">Hello</em> and <em lang="en">World</em> loudly</p></body></html>',
          blocks: const <ExtractedBlock>[
            ExtractedBlock(
              id: 'p-1',
              tagName: 'p',
              sourceHtml:
                  '<p>She said <em lang="en">Hello</em> and <em lang="en">World</em> loudly</p>',
              sourceText: 'She said Hello and World loudly',
              translatedHtml:
                  '<p>她说<em lang="en">你好</em>和<em lang="en">World</em>很大声</p>',
            ),
          ],
          category: ChapterCategory.content,
          recommendedForTranslation: true,
          includeInTranslation: true,
        ),
        bilingual: false,
      );
      // 'World' kept verbatim: its lang="en" must survive for TTS/readers.
      expect(rendered, contains('lang="en">World</em>'));
      expect(rendered, isNot(contains('lang="zh">World</em>')));
      // '你好' was translated: the stale echo takes the target language.
      expect(rendered, contains('>你好</em>'));
    });

    test('gloss paren sees through an empty inline tag', () {
      expect(
        _normalizeAdam('<p>Adam Smith<span></span>（亚当·斯密）写中文。</p>'),
        '<p>Adam Smith<span></span>（亚当·斯密）写中文。</p>',
      );
    });

    test('gloss paren in half-width brackets is not double-glossed', () {
      expect(
        _normalizeAdam('<p>Adam Smith(亚当)写中文。</p>'),
        '<p>Adam Smith(亚当)写中文。</p>',
      );
    });

    test('nested gloss parens are not double-glossed', () {
      expect(
        _normalizeAdam('<p>Adam Smith（亚当（字幼常））说中文。</p>'),
        '<p>Adam Smith（亚当（字幼常））说中文。</p>',
      );
    });

    test('half-width parens without CJK still receive the gloss', () {
      // 他在北京 (Adam Smith): strict forward rule leaves it alone, and the
      // bare-name machine must still gloss the name (no CJK inside).
      expect(
        _normalizeAdam('<p>他在北京 (Adam Smith) 讲学。</p>'),
        '<p>他在北京 (亚当·斯密（Adam Smith）) 讲学。</p>',
      );
    });

    test(
      'work title with a non-exact latin span still normalizes the name',
      () {
        expect(
          _normalizeAdam('<p>《国富论》(by Adam Smith) 的作者。</p>'),
          '<p>《国富论》(by 亚当·斯密（Adam Smith）) 的作者。</p>',
        );
      },
    );

    test('work title with an unrelated latin gloss stays protected', () {
      expect(
        _normalizeAdam('<p>《国富论》(The Wealth of Nations) 的作者。</p>'),
        '<p>《国富论》(The Wealth of Nations) 的作者。</p>',
      );
    });
  });
}
