import 'package:epub_translator_flutter/features/translation/infrastructure/epub/protected_anchor_text_slots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  group('ProtectedAnchorTextSlots', () {
    test('excludes supported short protected markers from stable slots', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>Before '
        '<a id="footnote_ref_1" href="notes.xhtml#note-1">*</a>'
        ' middle '
        '<a role="doc-backlink navigation" href="chapter.xhtml#ref-1">[1]</a>'
        ' and '
        '<a role="doc-noteref" href="#note-2">1</a>'
        ' plus '
        '<a epub:type="noteref" href="#note-3">[2]</a>'
        ' read <a href="https://example.com" title="site">this site</a>.</p>',
      );

      expect(template.slotTexts, <String>[
        'Before ',
        ' middle ',
        ' and ',
        ' plus ',
        ' read ',
        'this site',
        '.',
      ]);
    });

    test('protects cross-file marker classes on anchors and descendants', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>Start'
        '<a href="notes.xhtml#one"><span class="footnote_ref">*</span></a>'
        '<a class="footnote_num" href="chapter.xhtml#two">1</a>'
        'End</p>',
      );

      expect(template.slotTexts, <String>['Start', 'End']);
    });

    test('protects common alphabetic roman and superscript markers', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>One '
        '<a id="footnote_ref_a" href="notes.xhtml#a">a</a>'
        ' two '
        '<a role="doc-backlink" href="chapter.xhtml#iv">iv</a>'
        ' three '
        '<a epub:type="noteref" href="#superscript">¹</a>'
        ' four '
        '<a href="notes.xhtml#capital"><span class="footnote_ref">A</span></a>'
        ' five</p>',
      );

      expect(template.slotTexts, <String>[
        'One ',
        ' two ',
        ' three ',
        ' four ',
        ' five',
      ]);
      expect(
        template.render(<String>['Un', ' deux', ' trois', ' quatre', ' cinq']),
        '<p>Un '
        '<a id="footnote_ref_a" href="notes.xhtml#a">a</a>'
        ' deux '
        '<a role="doc-backlink" href="chapter.xhtml#iv">iv</a>'
        ' trois '
        '<a epub:type="noteref" href="#superscript">¹</a>'
        ' quatre '
        '<a href="notes.xhtml#capital"><span class="footnote_ref">A</span></a>'
        ' cinq</p>',
      );
    });

    test('keeps prose links and non-marker semantic links translatable', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p><a href="#section">Introduction</a> and '
        '<a role="doc-noteref" href="#note">See the note</a>.</p>',
      );

      expect(template.slotTexts, <String>[
        'Introduction',
        ' and ',
        'See the note',
        '.',
      ]);
    });

    test(
      'renders from the source skeleton and preserves anchor attributes',
      () {
        final ProtectedAnchorTextSlots template =
            ProtectedAnchorTextSlots.parse(
              '<p class="lead">Hello '
              '<a id="footnote_ref_7" class="ref" href="n.xhtml#n7" '
              'data-origin="book"><span class="footnote_ref">[1]</span></a>'
              ' world.</p>',
            );

        final String rendered = template.render(<String>['Bonjour', ' monde.']);
        final element = html_parser.parseFragment(rendered).children.single;
        final anchor = element.querySelector('a')!;

        expect(element.localName, 'p');
        expect(element.attributes['class'], 'lead');
        expect(anchor.attributes, <Object, String>{
          'id': 'footnote_ref_7',
          'class': 'ref',
          'href': 'n.xhtml#n7',
          'data-origin': 'book',
        });
        expect(
          anchor.outerHtml,
          contains('<span class="footnote_ref">[1]</span>'),
        );
        expect(element.text, 'Bonjour [1] monde.');
      },
    );

    test('renders supplied markup only as escaped text', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p data-safe="yes">Original <em>text</em>.</p>',
      );

      final String rendered = template.render(<String>[
        '<script>alert(1)</script><img src=x>',
        '<span onclick="evil()">safe</span>',
        '<b>!</b>',
      ]);
      final element = html_parser.parseFragment(rendered).children.single;

      expect(element.querySelectorAll('script, img, span, b'), isEmpty);
      expect(element.querySelectorAll('em'), hasLength(1));
      expect(element.attributes, <Object, String>{'data-safe': 'yes'});
      expect(
        element.text,
        '<script>alert(1)</script><img src=x> '
        '<span onclick="evil()">safe</span><b>!</b>',
      );
      expect(rendered, contains('&lt;script&gt;'));
      expect(rendered, contains('&lt;img src=x&gt;'));
    });

    test('never exposes raw-text element contents as translatable slots', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<div>Before<script>sourceScript()</script>'
        '<style>.source { color: red; }</style>After</div>',
      );

      expect(template.slotTexts, <String>['Before', 'After']);

      final String rendered = template.render(<String>[
        'Safe',
        '</script><img src=x onerror=evil()>',
      ]);
      final element = html_parser.parseFragment(rendered).children.single;

      expect(element.querySelectorAll('script'), hasLength(1));
      expect(element.querySelector('script')!.text, 'sourceScript()');
      expect(element.querySelectorAll('style'), hasLength(1));
      expect(element.querySelector('style')!.text, '.source { color: red; }');
      expect(element.querySelectorAll('img'), isEmpty);
      expect(
        element.text,
        'SafesourceScript().source { color: red; }'
        '</script><img src=x onerror=evil()>',
      );
    });

    test('requires exactly one translation for every slot', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>One <em>two</em> three</p>',
      );

      expect(() => template.render(<String>['Uno']), throwsArgumentError);
      expect(
        () => template.render(<String>['Uno', 'dos', 'tres', 'extra']),
        throwsArgumentError,
      );
    });

    test('preserves source boundary whitespace when translations omit it', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>Hello <em>brave</em> world'
        '<a id="footnote_ref_1" href="notes.xhtml#one">*</a> again</p>',
      );

      expect(
        template.render(<String>['Bonjour', 'courageux', 'monde', 'encore']),
        '<p>Bonjour <em>courageux</em> monde'
        '<a id="footnote_ref_1" href="notes.xhtml#one">*</a> encore</p>',
      );
    });

    test('preserves an ordinary source element skeleton without anchors', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<blockquote cite="source"><p>Alpha <strong>beta</strong>.</p></blockquote>',
      );

      expect(
        template.render(<String>['A', 'B', '!']),
        '<blockquote cite="source"><p>A <strong>B</strong>!</p></blockquote>',
      );
    });

    test('preserves each source marker exactly across repeated renders', () {
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        '<p>A<a id="footnote_ref_1" href="n.xhtml#1">*</a>'
        'B<a role="doc-backlink" href="c.xhtml#2">[1]</a>'
        'C<a epub:type="noteref" href="#3">1</a>D</p>',
      );

      expect(
        template.render(<String>['W', 'X', 'Y', 'Z']),
        '<p>W<a id="footnote_ref_1" href="n.xhtml#1">*</a>'
        'X<a role="doc-backlink" href="c.xhtml#2">[1]</a>'
        'Y<a epub:type="noteref" href="#3">1</a>Z</p>',
      );
      expect(
        template.render(<String>['1', '2', '3', '4']),
        '<p>1<a id="footnote_ref_1" href="n.xhtml#1">*</a>'
        '2<a role="doc-backlink" href="c.xhtml#2">[1]</a>'
        '3<a epub:type="noteref" href="#3">1</a>4</p>',
      );
    });

    test('rejects fragments without exactly one root element', () {
      expect(
        () => ProtectedAnchorTextSlots.parse('<p>One</p><p>Two</p>'),
        throwsFormatException,
      );
      expect(
        () => ProtectedAnchorTextSlots.parse('text only'),
        throwsFormatException,
      );
    });
  });
}
