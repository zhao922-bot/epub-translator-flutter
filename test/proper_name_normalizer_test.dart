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
      expect(
        RegExp(r'(?<!（)Adam Smith(?!）)').hasMatch(out),
        isFalse,
      );
    });

    test('half-width forward gloss folds to full-width on first occurrence', () {
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
    });

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
      expect(
        out,
        contains('即Pierre 范登·伯格（Van Den Berghe）所称的'),
      );
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
  });
}
