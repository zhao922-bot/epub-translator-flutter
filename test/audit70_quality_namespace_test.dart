import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/xhtml_html_compatibility.dart';

void main() {
  const title = 'The General Crisis of the Seventeenth Century';
  test('prefixed XHTML diagnostic clones retain source and output markup', () {
    final source = XhtmlHtmlCompatibility.parseFragment(
      '<x:p xmlns:x="http://www.w3.org/1999/xhtml">She read <x:i>$title</x:i> yesterday.</x:p>',
    );
    final translated = XhtmlHtmlCompatibility.parseFragment(
      '<x:p xmlns:x="http://www.w3.org/1999/xhtml">她昨天读了《<x:i>$title</x:i>》。</x:p>',
    );
    final beforeSource = source.outerHtml,
        beforeTranslated = translated.outerHtml;
    expect(
      TranslationQuality.findSuspiciousFragmentResidual(
        sourceFragment: source,
        translatedFragment: translated,
        targetLanguage: 'Chinese',
      ),
      isNull,
    );
    expect(source.outerHtml, beforeSource);
    expect(translated.outerHtml, beforeTranslated);
  });
  test('explicit foreign namespace i does not gain an XHTML title exemption', () {
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>She read <f:i xmlns:f="urn:foreign">$title</f:i> yesterday.</p>',
        translatedHtml: '<p>她读了 <f:i xmlns:f="urn:foreign">$title</f:i>。</p>',
        targetLanguage: 'Chinese',
      ),
      isNotNull,
    );
  });
  test('prefixes do not exempt untranslated italic instructions', () {
    const text =
        '<x:p xmlns:x="http://www.w3.org/1999/xhtml"><x:i>Please Read All Instructions Before Continuing With This Procedure</x:i></x:p>';
    expect(
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: text,
        translatedHtml: text,
        targetLanguage: 'Chinese',
      ),
      isNotNull,
    );
  });
}
