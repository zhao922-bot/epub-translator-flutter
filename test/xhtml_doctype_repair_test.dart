import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart' as xml;

/// Regression tests for the doctype keyword repair in
/// [XhtmlHtmlCompatibility.normalizeForXhtmlOutput].
///
/// Found by the live full-chapter E2E test (2026-10-05, SiliconFlow
/// DeepSeek-V4-Flash, Project Gutenberg "The Yellow Wallpaper"):
/// `package:html` parses `<!DOCTYPE html PUBLIC '...' '...'>` correctly but
/// its serializer drops the PUBLIC keyword, emitting
/// `<!DOCTYPE html "..." "...">` — invalid XML (`">" expected` at the first
/// quoted string). The app's own repack validator then rejected every
/// rebuilt chapter, so books with such doctypes could never finish
/// translating. The repair reinserts the keyword deterministically.
void main() {
  group('doctype keyword repair', () {
    test('prolog comment example is preserved before real PUBLIC doctype', () {
      const comment =
          '<!-- example: <!DOCTYPE html "example" "example.dtd"> -->';
      const source =
          '$comment<!DOCTYPE html PUBLIC "public-id" "real.dtd">'
          '<html><body><p>x</p></body></html>';
      final serialized = html_parser.parse(source).outerHtml;
      final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(serialized);
      expect(output, contains(comment));
      expect(output, contains('<!DOCTYPE html PUBLIC "public-id" "real.dtd">'));
      expect(() => xml.XmlDocument.parse(output), returnsNormally);
    });

    test('PI, CDATA and script examples are not doctypes', () {
      const source =
          '<?example <!DOCTYPE html "pi"> ?>'
          '<![CDATA[<!DOCTYPE html "cdata">]]>'
          '<!DOCTYPE html "real.dtd"><html><script>'
          '<!DOCTYPE html "script"></script></html>';
      final output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(source);
      expect(output, contains('<?example <!DOCTYPE html "pi"> ?>'));
      expect(output, contains('<![CDATA[<!DOCTYPE html "cdata">]]>'));
      expect(output, contains('<!DOCTYPE html SYSTEM "real.dtd">'));
      expect(output, contains('<!DOCTYPE html "script">'));
    });
    test('two identifiers without keyword become PUBLIC', () {
      // Exactly what package:html emits for an XHTML 1.1 doctype.
      const String broken =
          '<!DOCTYPE html "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
          '<html><body><p>x</p></body></html>';
      final String fixed = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
        broken,
      );
      expect(
        fixed,
        startsWith(
          '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">',
        ),
      );
      expect(() => xml.XmlDocument.parse(fixed), returnsNormally);
    });

    test('single identifier without keyword becomes SYSTEM', () {
      const String broken =
          '<!DOCTYPE html "about:legacy-compat"><html><body><p>x</p></body></html>';
      final String fixed = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
        broken,
      );
      expect(fixed, startsWith('<!DOCTYPE html SYSTEM "about:legacy-compat">'));
      expect(() => xml.XmlDocument.parse(fixed), returnsNormally);
    });

    test('already-correct doctypes are untouched', () {
      const String publicDoctype =
          '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
          '<html><body><p>x</p></body></html>';
      expect(
        XhtmlHtmlCompatibility.normalizeForXhtmlOutput(publicDoctype),
        startsWith('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"'),
      );

      const String html5Doctype =
          '<!DOCTYPE html><html><body><p>x</p></body></html>';
      expect(
        XhtmlHtmlCompatibility.normalizeForXhtmlOutput(html5Doctype),
        startsWith('<!DOCTYPE html>'),
      );
    });

    test('full round trip: parse Gutenberg-style head, serialize, repair', () {
      // Mirrors renderTranslatedChapter: html5 parse -> outerHtml ->
      // normalizeForXhtmlOutput must yield XML-parseable XHTML.
      const String source =
          "<?xml version='1.0' encoding='utf-8'?>\n"
          "<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.1//EN' 'http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd'>\n"
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
          '<body><p>Hello world</p></body></html>';
      final dom.Document document = html_parser.parse(
        XhtmlHtmlCompatibility.normalizeForHtmlParser(source),
      );
      final String output = XhtmlHtmlCompatibility.normalizeForXhtmlOutput(
        document.outerHtml,
      );
      expect(
        output,
        contains('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"'),
      );
      expect(() => xml.XmlDocument.parse(output), returnsNormally);
    });
  });
}
