import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enables residual checks for CJK and similar targets', () {
    expect(TranslationQuality.shouldCheckResidual('Chinese'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('日本語'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('Korean'), isTrue);
    expect(TranslationQuality.shouldCheckResidual('English'), isFalse);
  });

  test('flags long English residuals in Chinese translations', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'Once upon a time there was a long English sentence that should be translated carefully.',
        translatedText:
            'Once upon a time there was a long English sentence that should be translated carefully.',
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });

  test('allows Chinese labels followed by preserved English proper names', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'Book design by Ralph Fowler. Graphics by Rodrigo Corral Design. Illustrations by Matt Buck. Cover design by Michael Nagin.',
        translatedText:
            '书籍设计：Ralph Fowler；图形设计：Rodrigo Corral Design；插图：Matt Buck；封面设计：Michael Nagin。',
        targetLanguage: 'Chinese',
      ),
      isFalse,
    );
  });

  test('still flags a long English sentence after a short Chinese prefix', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'This entire sentence should have been translated into Chinese but was left in English.',
        translatedText:
            '译文：This entire sentence should have been translated into Chinese but was left in English.',
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });

  test('allows translated bibliography entries with preserved names and URL', () {
    const String source =
        '* Lulu Garcia-Navarro, “The Interview: A Conversation with JD Vance,” '
        'New York Times Magazine, October 12, 2024, '
        'https://www.nytimes.com/2024/10/12/magazine/jd-vance-interview.html.';

    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText: source,
        translatedText:
            '* Lulu Garcia-Navarro，《访谈：与 JD Vance 的对话》，'
            '《New York Times Magazine》，2024年10月12日，'
            'https://www.nytimes.com/2024/10/12/magazine/jd-vance-interview.html。',
        targetLanguage: 'Chinese',
      ),
      isFalse,
    );
  });

  test('still rejects a completely untranslated bibliography entry', () {
    const String source =
        '* Lulu Garcia-Navarro, “The Interview: A Conversation with JD Vance,” '
        'New York Times Magazine, October 12, 2024, '
        'https://www.nytimes.com/2024/10/12/magazine/jd-vance-interview.html.';

    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText: source,
        translatedText: source,
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });

  test('does not treat a preserved URL-only block as untranslated prose', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'https://example.com/a/very/long/english/path/that/must/remain/unchanged',
        translatedText:
            'https://example.com/a/very/long/english/path/that/must/remain/unchanged',
        targetLanguage: 'Chinese',
      ),
      isFalse,
    );
  });

  test(
    'allows a translated citation with a preserved English journal title',
    () {
      const String source =
          '* Adrian F. Ward, Kristen Duke, Ayelet Gneezy, and Maarten W. Bos, '
          '“Brain Drain: The Mere Presence of One’s Own Smartphone Reduces '
          'Available Cognitive Capacity,” Journal of the Association for '
          'Consumer Research 2, no. 2 (2017): 140–54, '
          'https://www.journals.uchicago.edu/doi/full/10.1086/691462.';

      expect(
        TranslationQuality.hasSuspiciousSourceResidual(
          sourceText: source,
          translatedText:
              '* Adrian F. Ward、Kristen Duke、Ayelet Gneezy 和 Maarten W. Bos，'
              '《脑力流失：仅仅是自己的智能手机在场就会降低可用认知能力》，'
              'Journal of the Association for Consumer Research，'
              '第2卷第2期（2017）：140–54，'
              'https://www.journals.uchicago.edu/doi/full/10.1086/691462。',
          targetLanguage: 'Chinese',
        ),
        isFalse,
      );
    },
  );

  test('still rejects a sentence-case English clause in translated prose', () {
    expect(
      TranslationQuality.hasSuspiciousSourceResidual(
        sourceText:
            'The mere presence of one’s own smartphone reduces available '
            'cognitive capacity and makes difficult tasks harder.',
        translatedText:
            '这句话的开头已经翻译，the mere presence of one’s own '
            'smartphone reduces available cognitive capacity and makes '
            'difficult tasks harder.',
        targetLanguage: 'Chinese',
      ),
      isTrue,
    );
  });

  group('HTML-aware residual checks', () {
    test('allows a source-owned English work title in matching i elements', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Authors of <i>The 500-Year Delta: What Happens After What Comes Next</i> see a change.</p>',
        translatedHtml:
            '<p>《五百年跃迁》的作者<i>The 500-Year Delta: What Happens After What Comes Next</i>看到了变化。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('still flags an entire untranslated sentence wrapped in i', () {
      const String html =
          '<p><i>This entire sentence should still be translated into Chinese for the reader.</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
      expect(
        finding?.messageForBlock('block-7'),
        'Possible untranslated source-language text remains in block block-7.',
      );
    });

    test('does not exempt a title-cased imperative in em', () {
      const String html =
          '<p><em>Please Read All Instructions Before Continuing</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt a longer title-cased user notice', () {
      const String html =
          '<p><i>Important Safety Information For All New Device Owners Today</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt an unlisted title-cased imperative', () {
      const String html = '<p><em>Open Settings And Restart The App</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt short emphasized inline prose', () {
      const String html = '<p><em>Please Read This First</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt an i title without source citation context', () {
      const String html = '<p><i>A Brief History of Time</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows an i title after a source citation cue', () {
      const String sourceHtml = '<p>Read <i>A Brief History of Time</i>.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: sourceHtml,
            translatedHtml: '<p>阅读<i>A Brief History of Time</i>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('does not exempt a title added only by the model', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Authors of The 500-Year Delta: What Happens After What Comes Next see a change.</p>',
        translatedHtml:
            '<p>作者发现了变化：<i>The 500-Year Delta: What Happens After What Comes Next</i></p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    for (final ({String tag, String title}) example
        in <({String tag, String title})>[
          (tag: 'em', title: 'The Shape of Things Yet to Come'),
          (tag: 'cite', title: 'A Brief History of Time and Space'),
        ]) {
      test('allows a matching source-owned title in ${example.tag}', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>Read <${example.tag}>${example.title}</${example.tag}> today.</p>',
          translatedHtml:
              '<p>今日阅读<${example.tag}>${example.title}</${example.tag}>。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding, isNull);
      });
    }

    test('allows a matching Latin title with a curly apostrophe in i', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Read <i>The Fiancée’s Guide to Everything</i>.</p>',
            translatedHtml:
                '<p>阅读<i>The Fiancée’s Guide to Everything</i>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a matching accented Latin title in cite', () {
      const String html =
          '<p><cite>Émile’s Journey Through Time and Memory</cite></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test(
      'allows a referenced title with Latin Extended Additional letters',
      () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml:
                  '<p>Read <i>The Ứng Đặng Guide to Time and Memory</i>.</p>',
              translatedHtml:
                  '<p>阅读<i>The Ứng Đặng Guide to Time and Memory</i>。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      },
    );

    test('allows a cite title with a combining Latin accent', () {
      const String html =
          '<p><cite>The Cafe\u0301 Guide to Every City</cite></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('does not exempt corresponding title elements with different text', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Read <i>The 500-Year Delta: What Happens After What Comes Next</i>.</p>',
        translatedHtml:
            '<p>阅读<i>The 500-Year Delta: What Happens Long After What Comes Next</i>。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });
  });
}
