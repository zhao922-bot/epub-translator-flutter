import 'package:epub_translator_flutter/features/translation/infrastructure/epub/proper_name_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProperNameNormalizer', () {
    const List<ProperNameMap> mappings = <ProperNameMap>[
      ProperNameMap(source: 'Adam Smith', target: '亚当·斯密'),
      ProperNameMap(source: 'Van Den Berghe', target: '范登·伯格'),
    ];

    test('parses source => target glossary lines', () {
      final List<ProperNameMap> parsed = ProperNameNormalizer.parseGlossary(
        'Adam Smith => 亚当·斯密\n\nVan Den Berghe => 范登·伯格\nignored line\n',
      );
      expect(parsed, hasLength(2));
      expect(parsed[0].source, 'Adam Smith');
      expect(parsed[1].target, '范登·伯格');
    });

    test('first bare English becomes Chinese（English）', () {
      final ProperNameBookState state = ProperNameNormalizer.bookState();
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>这是Adam Smith的著作。</p><p>Adam Smith也写过。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      expect(out, contains('亚当·斯密（Adam Smith）的著作'));
      expect(out, contains('亚当·斯密也写过'));
    });

    test('reverse gloss English（中文）is re-ordered', () {
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>作者Adam Smith（亚当·斯密）的观点。</p>',
        mappings,
        targetLanguage: 'Chinese',
      );
      expect(out, contains('作者亚当·斯密（Adam Smith）的观点'));
    });

    test('later occurrences are Chinese only', () {
      final ProperNameBookState state = ProperNameNormalizer.bookState();
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>Adam Smith的著作。</p><p>Adam Smith是经济学家。</p>'
        '<p>Adam Smith的绝对优势理论。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      expect(out, contains('亚当·斯密（Adam Smith）的著作'));
      expect(out, contains('亚当·斯密是经济学家'));
      expect(out, contains('亚当·斯密的绝对优势理论'));
      expect(RegExp(r'(?<!（)Adam Smith(?!）)').hasMatch(out), isFalse);
    });

    test(
      'half-width forward gloss folds to full-width on first occurrence',
      () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>亚当·斯密 (Adam Smith) 的核心思想。</p>'
          '<p>Adam Smith也这样认为。</p>',
          mappings,
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(out, contains('亚当·斯密（Adam Smith）的核心思想'));
        expect(out, contains('亚当·斯密也这样认为'));
        // The half-width pair must not survive anywhere in the block.
        expect(RegExp(r'\bAdam Smith\)').hasMatch(out), isFalse);
        expect(RegExp(r'Adam Smith\s*（').hasMatch(out), isFalse);
        // The Chinese name must not be double-wrapped with its own gloss.
        expect(RegExp(r'亚当·斯密（亚当·斯密').hasMatch(out), isFalse);
      },
    );

    test('name split by a pagebreak anchor still matches and stays clean', () {
      final ProperNameBookState state = ProperNameNormalizer.bookState();
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>即Pierre Van Den <span id="page_281" epub:type="pagebreak" '
        'role="doc-pagebreak" aria-label="281"></span>Berghe所称的。</p>'
        '<p>Van Den Berghe也作此论断。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      expect(out, contains('即Pierre 范登·伯格（Van Den Berghe）所称的'));
      expect(out, contains('范登·伯格也作此论断'));
      // The pagebreak anchor must not survive inside the gloss.
      expect(RegExp(r'<span').hasMatch(out), isFalse);
      // The gloss must not be duplicated on the already-annotated name.
      expect(RegExp(r'范登·伯格（范登·伯格').hasMatch(out), isFalse);
    });

    test('leaves endnotes / bibliography untouched', () {
      final String out = ProperNameNormalizer.normalizeHtml(
        '<li class="endnotes1">Adam Smith，《国富论》（The Wealth of Nations），第8页。</li>',
        mappings,
        targetLanguage: 'Chinese',
      );
      expect(out, contains('Adam Smith，《国富论》（The Wealth of Nations）'));
    });

    test('leaves URLs and pure-Latin blocks untouched', () {
      final String out = ProperNameNormalizer.normalizeHtml(
        '<p>See https://example.com/Adam-Smith for details.</p>',
        mappings,
        targetLanguage: 'Chinese',
      );
      expect(out, contains('https://example.com/Adam-Smith'));
    });

    test('tracks first occurrence across chapters via shared state', () {
      final ProperNameBookState state = ProperNameNormalizer.bookState();
      final String chapterOne = ProperNameNormalizer.normalizeHtml(
        '<p>Adam Smith的著作。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      final String chapterTwo = ProperNameNormalizer.normalizeHtml(
        '<p>Adam Smith是经济学家。</p>',
        mappings,
        targetLanguage: 'Chinese',
        state: state,
      );
      expect(chapterOne, contains('亚当·斯密（Adam Smith）的著作'));
      expect(chapterTwo, contains('亚当·斯密是经济学家'));
      expect(chapterTwo, isNot(contains('（Adam Smith）')));
    });

    group('markup and word boundaries', () {
      const List<ProperNameMap> shortMappings = <ProperNameMap>[
        ProperNameMap(source: 'Li', target: '李'),
        ProperNameMap(source: 'Smith', target: '史密斯'),
      ];

      test('tag names are never rewritten by locked names', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<ul><li>李雷是学生</li></ul>',
          shortMappings,
          targetLanguage: 'Chinese',
        );
        expect(out, '<ul><li>李雷是学生</li></ul>');
      });

      test('attribute values are never rewritten by locked names', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p><a id="li-note" href="#li-note">见注释</a>李雷说。</p>',
          shortMappings,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('id="li-note"'));
        expect(out, contains('href="#li-note"'));
        expect(out, isNot(contains('李（li）')));
      });

      test('a locked name does not fire inside a longer word', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>The alliance won. Li was there. 李雷说。</p>',
          shortMappings,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('alliance'));
        expect(out, isNot(contains('al李')));
        expect(out, contains('李（Li） was there'));
      });

      test('a locked surname does not fire inside a compound word', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>The blacksmith met Smith. 他说。</p>',
          shortMappings,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('blacksmith'));
        expect(out, isNot(contains('black史密斯')));
        expect(out, contains('史密斯（Smith）'));
      });

      test('a name split by an empty tag pair still matches', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>Van Den <span class="pb"></span>Berghe说中文。</p>',
          const <ProperNameMap>[
            ProperNameMap(source: 'Van Den Berghe', target: '范登·伯格'),
          ],
          targetLanguage: 'Chinese',
          state: state,
        );
        expect(out, contains('范登·伯格（Van Den Berghe）说'));
      });
    });

    group('canonical gloss paren pairing', () {
      const List<ProperNameMap> smith = <ProperNameMap>[
        ProperNameMap(source: 'Smith', target: '史密斯'),
      ];

      test('unmatched closing paren does not mark a name as glossed', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>Smith）说中文。</p>',
          smith,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('史密斯（Smith））说'));
      });

      test('unmatched opening paren does not mark a name as glossed', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>（Smith说中文。</p>',
          smith,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('（史密斯（Smith）说'));
      });

      test('a fully paired gloss is still left alone', () {
        final String out = ProperNameNormalizer.normalizeHtml(
          '<p>作者史密斯（Smith）说中文。</p>',
          smith,
          targetLanguage: 'Chinese',
        );
        expect(out, contains('作者史密斯（Smith）说中文'));
        expect(out, isNot(contains('史密斯（史密斯')));
      });
    });

    group('round-12 identifier and markup hardening', () {
      const List<ProperNameMap> liMappings = <ProperNameMap>[
        ProperNameMap(source: 'Li', target: '李'),
      ];

      test('URL path segments are protected while bare text is glossed', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html = '<p>见https://example.com/li的说明，Li说中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          liMappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('https://example.com/li'));
        expect(out, contains('李（Li）说中文'));
      });

      test('email addresses are protected while bare text is glossed', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html = '<p>发邮件到li@example.com，Li说中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          liMappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('li@example.com'));
        expect(out, contains('李（Li）说中文'));
      });

      test('forward gloss canonicalizes body text, not attribute values', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html =
            '<img alt="亚当 (Adam Smith) pic"><p>亚当 (Adam Smith) 写中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          mappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('alt="亚当 (Adam Smith) pic"'));
        expect(out, contains('亚当（Adam Smith）写中文'));
      });

      test('reverse gloss canonicalizes body text, not attribute values', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html =
            '<span title="Adam Smith（亚当）">x</span>'
            '<p>Adam Smith（亚当）写中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          mappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('title="Adam Smith（亚当）"'));
        expect(out, contains('亚当（Adam Smith）写中文'));
      });

      test('spaced angle brackets in prose are not treated as tags', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html = '<p>Tom < Jerry > Spike，Jerry说中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          const <ProperNameMap>[ProperNameMap(source: 'Jerry', target: '杰瑞')],
          targetLanguage: 'zh',
          state: state,
        );
        // The literal brackets survive, and the Jerry between them is real
        // text: it takes the first-occurrence gloss instead of being masked.
        expect(out, contains('Tom < '));
        expect(out, contains(' > Spike'));
        expect(out, contains('杰瑞（Jerry）'));
      });

      test('empty tag pairs do not create fake word boundaries', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html = '<p>Li<span></span>mited是Li。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          liMappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('Li<span></span>mited是李（Li）。'));
      });

      test('multi-token names still match across empty tag pairs', () {
        final ProperNameBookState state = ProperNameNormalizer.bookState();
        const String html = '<p>Van Den <span></span>Berghe说中文。</p>';
        final String out = ProperNameNormalizer.normalizeHtml(
          html,
          mappings,
          targetLanguage: 'zh',
          state: state,
        );
        expect(out, contains('范登·伯格（Van Den Berghe）说中文'));
      });
    });
  });
}
