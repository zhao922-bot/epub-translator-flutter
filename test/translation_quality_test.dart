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

    test('allows a standalone matching i work title', () {
      const String html = '<p><i>A Brief History of Time</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    for (final String title in <String>['This Is Water', 'We Were Liars']) {
      test('allows the explicit cite work title $title', () {
        final String html = '<p><cite>$title</cite></p>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      });
    }

    test('allows a short standalone i title with sentence-like words', () {
      const String html = '<p><i>This Is Water</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    for (final String emphasizedProse in <String>[
      'System Maintenance Will Begin Shortly',
      'This Change Will Affect Everyone',
    ]) {
      test('rejects title-cased emphasized prose: $emphasizedProse', () {
        final String html = '<p><em>$emphasizedProse</em></p>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });
    }

    test('allows a matching i work title after a neutral preposition', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>In <i>The Sovereign Individual</i>, Davidson argues for change.</p>',
        translatedHtml: '<p>在<i>The Sovereign Individual</i>中，戴维森主张变革。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('allows a matching i work title after descriptive prose', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>His celebrated <i>The Sovereign Individual</i> changed the debate.</p>',
        translatedHtml: '<p>他广受赞誉的<i>The Sovereign Individual</i>改变了这场讨论。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('allows a matching work title in a bibliography entry', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<li>Davidson, James Dale. <em>The Sovereign Individual</em>. 1997.</li>',
        translatedHtml:
            '<li>詹姆斯·戴尔·戴维森：<em>The Sovereign Individual</em>，1997 年。</li>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
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

    test('finds source citation context through an anchor wrapper', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Authors of <a href="#"><i>The 500-Year Delta: What Happens After What Comes Next</i></a> agree.</p>',
        translatedHtml:
            '<p>《五百年跃迁》的作者<a href="#"><i>The 500-Year Delta: What Happens After What Comes Next</i></a>表示赞同。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('finds source citation context through a span wrapper', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Read <span><em>The Shape of Things Yet to Come</em></span>.</p>',
        translatedHtml:
            '<p>阅读<span><em>The Shape of Things Yet to Come</em></span>。</p>',
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

    test('flags a short changed English cite title', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><cite>A Brief History</cite></p>',
            translatedHtml: '<p><cite>A Short History</cite></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('flags a short English cite added only to the translation', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>一本书</p>',
            translatedHtml: '<p><cite>A Brief History</cite></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('flags a short English inline with a changed tag', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><i>A Brief History</i></p>',
            translatedHtml: '<p><em>A Brief History</em></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows an inline work title translated fully into Chinese', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><cite>A Brief History</cite></p>',
            translatedHtml: '<p><cite>简史</cite></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('flags a source cite whose tag was dropped around preserved text', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><cite>A Brief History</cite></p>',
            translatedHtml: '<p>A Brief History</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows a matching nested cite and em title as one candidate', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<p>Read <cite><em>A Brief History of Time</em></cite>.</p>',
            translatedHtml:
                '<p>阅读<cite><em>A Brief History of Time</em></cite>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a matching title whose text is wrapped below i', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Authors of <i><span>The 500-Year Delta: What Happens After What Comes Next</span></i> agree.</p>',
        translatedHtml:
            '<p>《五百年跃迁》的作者<i><span>The 500-Year Delta: What Happens After What Comes Next</span></i>表示赞同。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('does not partially exempt candidates when counts differ', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Read <i>A Brief History of Time</i> and <cite>The Shape of Things Yet to Come</cite>.</p>',
        translatedHtml: '<p>阅读<i>A Brief History of Time</i>。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('only exempts the nested cite subtree inside emphasized prose', () {
      const String sourceHtml =
          '<p><em><cite>A Brief History</cite> Please Read All Instructions</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: sourceHtml,
            translatedHtml: sourceHtml,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects short untranslated prose outside an exempt cite title', () {
      const String html =
          '<p>Read <cite>A Brief History of Time</cite> right now.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects unchanged short prose around an exempt cite title', () {
      const String html =
          '<p>Markets shape <cite>A Brief History of Time</cite> society.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects an unchanged title-like phrase in ordinary prose', () {
      const String html = '<p>A Brief History of Time</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects a short source-owned English instruction in prose', () {
      const String html = '<p>Please try again now.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects a lowercase short clause with a finite verb', () {
      const String html = '<p>users need more time.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows a short retained lowercase technical phrase', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Use the machine learning model in production.</p>',
            translatedHtml: '<p>在生产中采用 machine learning model。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a four-word lowercase technical noun phrase', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<p>The system improves large language model inference.</p>',
            translatedHtml: '<p>系统改进了 large language model inference。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    for (final ({String phrase, String sourceHtml, String translatedHtml})
        example
        in <({String phrase, String sourceHtml, String translatedHtml})>[
          (
            phrase: 'change management process',
            sourceHtml:
                '<p>A reliable change management process reduces risk.</p>',
            translatedHtml: '<p>可靠的 change management process 可以降低风险。</p>',
          ),
          (
            phrase: 'mean time between failures',
            sourceHtml:
                '<p>The mean time between failures remains important.</p>',
            translatedHtml: '<p>mean time between failures 这一指标依然重要。</p>',
          ),
        ]) {
      test('allows the embedded technical term ${example.phrase}', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: example.sourceHtml,
              translatedHtml: example.translatedHtml,
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      });
    }

    test('allows retained brands and four-letter technical terms', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>OpenAI API sends data to https://example.com or support@example.com.</p>',
        translatedHtml:
            '<p>OpenAI API 将 data 发送到 https://example.com，或联系 support@example.com。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('allows a retained multi-word brand outside inline markup', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>International Business Machines Corporation announced the product.</p>',
        translatedHtml:
            '<p>International Business Machines Corporation 发布了该产品。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('does not treat the preposition in as a title citation cue', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Sign in <em>Please Read All Instructions Before Continuing</em></p>',
        translatedHtml:
            '<p>登录<em>Please Read All Instructions Before Continuing</em></p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('flags changed English text when a source cite is removed', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><cite>A Brief History</cite></p>',
            translatedHtml: '<p>A Short History</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not inherit a read cue from the previous paragraph', () {
      const String html =
          '<p>This paragraph ends with Read</p><p><em>Please Read All Instructions Before Continuing</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects lightly rewritten prose beside a nested cite', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p><i><cite>A Brief History</cite><em>Please Read This</em></i></p>',
        translatedHtml:
            '<p><i><cite>A Brief History</cite><em>Please Open This</em></i></p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows a retained three-word design credit after by', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Book design by <em>Rodrigo Corral Design</em>.</p>',
            translatedHtml: '<p>书籍设计：<em>Rodrigo Corral Design</em>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a retained two-word credit after by', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Cover design by <em>Ralph Fowler</em>.</p>',
            translatedHtml: '<p>封面设计：<em>Ralph Fowler</em>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a retained credit containing an initial after by', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Edited by <em>Maarten W. Bos</em>.</p>',
            translatedHtml: '<p>编辑：<em>Maarten W. Bos</em>。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('does not allow title-cased prose without a by credit cue', () {
      const String html = '<p><em>Please Read This</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not treat start by as a credit role', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p>Start by <em>Please Read This</em>.</p>',
            translatedHtml: '<p>先从<em>Please Read This</em>开始。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('allows multiple retained names in one credit list', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Written by <em>John Smith</em> and <em>Mary Jane Watson</em>.</p>',
        translatedHtml:
            '<p>作者：<em>John Smith</em>、<em>Mary Jane Watson</em>。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('does not treat destroyed by as a credit role', () {
      const String html = '<p>Destroyed by <em>Please Read This</em></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: html,
            translatedHtml: html,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    group('CJK-adjacent lowercase English leaks', () {
      test('flags entitlement directly before Chinese text', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>As boundaries disappear, the concept of entitlement collapses.</p>',
          translatedHtml: '<p>随着边界消失，entitlement概念随之瓦解。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'entitlement');
      });

      test('flags associated directly after Chinese text', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>People are entitled to the associated economic advantages.</p>',
          translatedHtml: '<p>有权享有associated的经济优势。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'associated');
      });

      for (final ({String name, String translatedHtml}) example
          in <({String name, String translatedHtml})>[
            (name: 'PayPal', translatedHtml: '<p>使用PayPal支付。</p>'),
            (name: 'Microsoft', translatedHtml: '<p>由Microsoft提供。</p>'),
            (name: 'UN', translatedHtml: '<p>由UN发布。</p>'),
            (
              name: 'URL',
              translatedHtml: '<p>访问https://example.com/path获取详情。</p>',
            ),
            (
              name: 'email address',
              translatedHtml: '<p>联系support@example.com获取帮助。</p>',
            ),
            (
              name: 'spaced lowercase word',
              translatedHtml: '<p>讨论 cyberspace 概念。</p>',
            ),
          ]) {
        test('allows ${example.name}', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>Source text for ${example.name}.</p>',
                translatedHtml: example.translatedHtml,
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        });
      }

      test('does not apply the adjacency rule to non-CJK targets', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>As boundaries disappear, the concept of entitlement collapses.</p>',
          translatedHtml:
              '<p>Cuando desaparecen los límites, entitlement概念 cambia.</p>',
          targetLanguage: 'Spanish',
        );

        expect(finding, isNull);
      });

      test('ignores lowercase words inside an exempt source-owned title', () {
        const String sourceHtml =
            '<p>Read <cite>The Future and Global Digital Rights of entitlement</cite>.</p>';

        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml: sourceHtml,
          translatedHtml:
              '<p>阅读<cite>The Future and Global Digital Rights of entitlement</cite>。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding, isNull);
      });

      for (final String targetLanguage in <String>[
        '中文',
        '日本語',
        '한국어',
        'zh_Hans',
        'ja_JP',
        'ko_KR',
      ]) {
        test('supports the CJK target name $targetLanguage', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml:
                    '<p>As boundaries disappear, entitlement changes.</p>',
                translatedHtml: '<p>边界消失后，entitlement概念改变。</p>',
                targetLanguage: targetLanguage,
              );

          expect(
            finding?.kind,
            TranslationResidualKind.cjkAdjacentLowercaseWord,
          );
          expect(finding?.token, 'entitlement');
        });
      }

      for (final String token in <String>["don't", 'don’t', 'co-op']) {
        test('flags the complete lowercase token $token beside CJK', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml:
                    '<p>The source contains a missed English token.</p>',
                translatedHtml: '<p>译文$token这样保留。</p>',
                targetLanguage: 'Chinese',
              );

          expect(
            finding?.kind,
            TranslationResidualKind.cjkAdjacentLowercaseWord,
          );
          expect(finding?.token, token);
        });
      }

      test(
        'does not match a lowercase substring inside an alphanumeric token',
        () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>The device uses an MP3 player.</p>',
                translatedHtml: '<p>连接mp3player设备。</p>',
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        },
      );

      for (final String token in <String>[
        '--beta',
        "'open",
        'beta--',
        'a-b-c',
      ]) {
        test('allows malformed or too-short token $token beside CJK', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>The source contains an inline marker.</p>',
                translatedHtml: '<p>中文$token内容。</p>',
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        });
      }

      for (final String token in <String>['beta', 'open', 'mode', 'data']) {
        test('allows four-letter lowercase token $token beside CJK', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml:
                    '<p>The source contains a short technical term.</p>',
                translatedHtml: '<p>使用$token接口。</p>',
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        });
      }

      for (final String url in <String>[
        'https://example.com/archive,part/entitlement',
        "https://example.com/archive'part/entitlement",
      ]) {
        test('allows RFC3986 punctuation inside URL $url', () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>Visit the linked resource.</p>',
                translatedHtml: '<p>访问$url内容。</p>',
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        });
      }

      test('continues checking after a URL followed by Chinese punctuation', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>Visit the site, where the entitlement concept is explained.</p>',
          translatedHtml: '<p>访问https://example.com，entitlement概念。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'entitlement');
      });
    });
  });
}
