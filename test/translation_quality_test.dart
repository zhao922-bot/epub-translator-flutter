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
    test(
      'allows a retained epigraph attribution name after punctuation localization',
      () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '''
<blockquote class="epigraph">
  <p class="noindent"><i>“The future is disorder. A door like this has cracked open five or six times since we got up on our hind legs. It is the best possible time to be alive, when almost everything you thought you knew is wrong.”</i></p>
  <p class="epi-att"><i>—Tom Stoppard,</i> Arcadia</p>
</blockquote>
''',
              translatedHtml: '''
<blockquote class="epigraph">
  <p class="noindent"><i>“未来就是混乱。自我们直立行走以来，这样的门已经裂开过五六次了。这是一个活着再好不过的时代，因为你所知的一切几乎都是错的。”</i></p>
  <p class="epi-att"><i>——Tom Stoppard，</i>《阿卡迪亚》</p>
</blockquote>
''',
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      },
    );

    test('allows an explicitly classified author signature name', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p class="sig">Peter Thiel</p>',
            translatedHtml: '<p class="sig">Peter Thiel</p>',
            targetLanguage: 'Chinese',
            allowRetainedAuthorSignature: true,
          );

      expect(finding, isNull);
    });

    test('allows a classified author signature translated into Chinese', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p class="sig">Peter Thiel</p>',
            translatedHtml: '<p class="sig">彼得·蒂尔</p>',
            targetLanguage: 'Chinese',
            allowRetainedAuthorSignature: true,
          );

      expect(finding, isNull);
    });

    test('continues checking residual prose after a translated signature', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p class="sig">Peter Thiel</p>',
        translatedHtml:
            '<p class="sig">彼得·蒂尔 This sentence remains untranslated in the final output.</p>',
        targetLanguage: 'Chinese',
        allowRetainedAuthorSignature: true,
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('rejects a classified signature changed to another English name', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p class="sig">Peter Thiel</p>',
            translatedHtml: '<p class="sig">Thomas Thiel</p>',
            targetLanguage: 'Chinese',
            allowRetainedAuthorSignature: true,
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not retain the same name without signature classification', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p class="sig">Peter Thiel</p>',
            translatedHtml: '<p class="sig">Peter Thiel</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test(
      'does not classify a standalone signature-class place as an author',
      () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p class="sig">Los Angeles</p>',
              translatedHtml: '<p class="sig">Los Angeles</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      },
    );

    test('does not exempt nested markup in a classified author signature', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p class="sig"><em>Peter Thiel</em></p>',
            translatedHtml: '<p class="sig"><em>Peter Thiel</em></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test(
      'still rejects an untranslated epigraph with a retained attribution',
      () {
        const String html = '''
<blockquote class="epigraph">
  <p><i>“The future is disorder. A door like this has cracked open five or six times since we got up on our hind legs.”</i></p>
  <p class="epi-att"><i>—Tom Stoppard,</i> Arcadia</p>
</blockquote>
''';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      },
    );

    test('still rejects a partly untranslated epigraph quotation', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '''
<blockquote class="epigraph">
  <p><i>“The future is disorder. A door like this has cracked open five or six times since we got up on our hind legs.”</i></p>
  <p class="epi-att"><i>—Tom Stoppard,</i> Arcadia</p>
</blockquote>
''',
            translatedHtml: '''
<blockquote class="epigraph">
  <p><i>“未来就是混乱。A door like this has cracked open five or six times since we got up on our hind legs.”</i></p>
  <p class="epi-att"><i>——Tom Stoppard，</i>《阿卡迪亚》</p>
</blockquote>
''',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt a changed epigraph attribution name', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '''
<blockquote class="epigraph">
  <p><i>“The future is disorder.”</i></p>
  <p class="epi-att"><i>—Tom Stoppard,</i> Arcadia</p>
</blockquote>
''',
            translatedHtml: '''
<blockquote class="epigraph">
  <p><i>“未来就是混乱。”</i></p>
  <p class="epi-att"><i>——Thomas Stoppard，</i>《阿卡迪亚》</p>
</blockquote>
''',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not treat a normal paragraph as an epigraph attribution', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '<p><i>—Tom Stoppard,</i> wrote the play.</p>',
            translatedHtml: '<p><i>——Tom Stoppard，</i>创作了这部戏剧。</p>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test(
      'does not exempt an epigraph inline that also contains a work title',
      () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '''
<blockquote><p><i>“The future is disorder.”</i></p><p><i>—Tom Stoppard, Arcadia</i></p></blockquote>
''',
              translatedHtml: '''
<blockquote><p><i>“未来就是混乱。”</i></p><p><i>——Tom Stoppard, Arcadia</i></p></blockquote>
''',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      },
    );

    test('does not mistake a dashed work title for an attribution name', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '''
<blockquote><p><i>“The future is disorder.”</i></p><p><i>—The Sovereign Individual,</i> Arcadia</p></blockquote>
''',
            translatedHtml: '''
<blockquote><p><i>“未来就是混乱。”</i></p><p><i>——The Sovereign Individual，</i>《阿卡迪亚》</p></blockquote>
''',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test(
      'does not infer an attribution name without an explicit attribution class',
      () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '''
<blockquote><p><i>“The future is disorder.”</i></p><p><i>—Strategic Investment,</i> Arcadia</p></blockquote>
''',
              translatedHtml: '''
<blockquote><p><i>“未来就是混乱。”</i></p><p><i>——Strategic Investment，</i>《阿卡迪亚》</p></blockquote>
''',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      },
    );

    test('does not exempt an attribution without a preceding quotation', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<blockquote><p><i>—Tom Stoppard,</i> Arcadia</p></blockquote>',
            translatedHtml:
                '<blockquote><p><i>——Tom Stoppard，</i>《阿卡迪亚》</p></blockquote>',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    test('does not exempt an attribution name wrapped in a nested span', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: '''
<blockquote><p><i>“The future is disorder.”</i></p><p><i>—<span>Tom Stoppard</span>,</i> Arcadia</p></blockquote>
''',
            translatedHtml: '''
<blockquote><p><i>“未来就是混乱。”</i></p><p><i>——<span>Tom Stoppard</span>，</i>《阿卡迪亚》</p></blockquote>
''',
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

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

    test('allows acknowledgments titles used as subjects and newsletter names', () {
      const String sourceHtml =
          '<p>It is the third we have done together. '
          '<i class="calibre3">The Sovereign Individual</i> builds upon research '
          'that went into <i class="calibre3">Blood in the Streets</i> and '
          '<i class="calibre3">The Great Reckoning.</i> Our special thanks go to '
          'Bill Bonner for our newsletter, <i class="calibre3">Strategic Investment.</i></p>';
      const String translatedHtml =
          '<p>这是我们合作完成的第三本书。'
          '<i class="calibre3">The Sovereign Individual</i> 建立在此前写入 '
          '<i class="calibre3">Blood in the Streets</i> 与 '
          '<i class="calibre3">The Great Reckoning.</i> 的研究之上。我们特别感谢 '
          'Bill Bonner，以及我们的通讯 <i class="calibre3">Strategic Investment.</i></p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: sourceHtml,
            translatedHtml: translatedHtml,
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test('allows a retained two-word italic title with trailing period', () {
      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<p>He edits the newsletter, <i>Strategic Investment.</i></p>',
            translatedHtml: '<p>他主编这份通讯，<i>Strategic Investment.</i></p>',
            targetLanguage: 'Chinese',
          );

      expect(finding, isNull);
    });

    test(
      'still rejects untranslated acknowledgments prose that keeps titles',
      () {
        const String sourceHtml =
            '<p><i>The Sovereign Individual</i> builds upon research that went into '
            '<i>Blood in the Streets</i> and <i>The Great Reckoning.</i></p>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: sourceHtml,
              translatedHtml: sourceHtml,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      },
    );

    test(
      'allows a translated acknowledgments name list with retained English names',
      () {
        const String sourceHtml =
            '<p class="indent">We also acknowledge the special friendship of '
            'Alan Lindsay; Brian, Donald, and Scott Lines; Robert Lloyd George; '
            'Jane Collis; Carter Beese; Andy Miller; Scott Hill; Nils Taube; '
            'Gilbert de Botton; Michael Geltner; Mark Ford; David Keating; '
            'Pete Sepp; Curtin Winsor, III; V. Harwood Bocker, III; '
            'Guillermo Cervino; Eduardo Maschwitz; Michael Reynal; Jorge Gamarci; '
            'Jackie Locke; Douglas Reid; Jose Pascar; Luis Kenny; '
            'Robert Lawrence, III; Ken Klein; Kim Saull; Jim Moloney; '
            'Mike Geltner; Lee Euler; Tom Crema; Nancy Lazar; Greg Barnhill; '
            'Becky Mangus; Nancy Oppenlander; Wayne Livingstone; Hans Kuppers; '
            'Michael Baybak; Allan Zschlag; David Hale; Lisa Eden; Mel Lieberman; '
            'Glenn Blaugh; Sir Roger Douglas; Michael Smorch; Jimmie Rogers; '
            'Ambrose Evans-Pritchard; Chris Wood; Marc Faber; Ronnie Chan; '
            'William F. Nicklin; Lenny Smith; Jack Wheeler; Jim Bennett; '
            'Gordon Tullock; Jay Bernstein; Gary Vernier; Jenny Mitchel; '
            'Julia Guth; Lisa Young; Mia; Mark Frasier; Lisa Bernard; '
            'Rita Smith; Ruth Lyons; Yarah Chiekh; Fabian Dilaimy; Tim Hoese; '
            'and our families.</p>';
        const String translatedHtml =
            '<p class="indent">我们也感谢这些特别的朋友：'
            'Alan Lindsay；Brian、Donald 和 Scott Lines；Robert Lloyd George；'
            'Jane Collis；Carter Beese；Andy Miller；Scott Hill；Nils Taube；'
            'Gilbert de Botton；Michael Geltner；Mark Ford；David Keating；'
            'Pete Sepp；Curtin Winsor, III；V. Harwood Bocker, III；'
            'Guillermo Cervino；Eduardo Maschwitz；Michael Reynal；Jorge Gamarci；'
            'Jackie Locke；Douglas Reid；Jose Pascar；Luis Kenny；'
            'Robert Lawrence, III；Ken Klein；Kim Saull；Jim Moloney；'
            'Mike Geltner；Lee Euler；Tom Crema；Nancy Lazar；Greg Barnhill；'
            'Becky Mangus；Nancy Oppenlander；Wayne Livingstone；Hans Kuppers；'
            'Michael Baybak；Allan Zschlag；David Hale；Lisa Eden；Mel Lieberman；'
            'Glenn Blaugh；Sir Roger Douglas；Michael Smorch；Jimmie Rogers；'
            'Ambrose Evans-Pritchard；Chris Wood；Marc Faber；Ronnie Chan；'
            'William F. Nicklin；Lenny Smith；Jack Wheeler；Jim Bennett；'
            'Gordon Tullock；Jay Bernstein；Gary Vernier；Jenny Mitchel；'
            'Julia Guth；Lisa Young；Mia；Mark Frasier；Lisa Bernard；'
            'Rita Smith；Ruth Lyons；Yarah Chiekh；Fabian Dilaimy；Tim Hoese；'
            '以及我们的家人。</p>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: sourceHtml,
              translatedHtml: translatedHtml,
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      },
    );

    test('still rejects an untranslated acknowledgments name list', () {
      const String sourceHtml =
          '<p class="indent">We also acknowledge the special friendship of '
          'Alan Lindsay; Brian, Donald, and Scott Lines; Robert Lloyd George; '
          'Jane Collis; Carter Beese; Andy Miller; Scott Hill; Nils Taube; '
          'Gilbert de Botton; Michael Geltner; Mark Ford; David Keating; '
          'Pete Sepp; Curtin Winsor, III; and our families.</p>';

      final TranslationResidualFinding? finding =
          TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml: sourceHtml,
            translatedHtml: sourceHtml,
            targetLanguage: 'Chinese',
          );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
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

    for (final ({String sourceHtml, String translatedHtml}) example
        in <({String sourceHtml, String translatedHtml})>[
          (
            sourceHtml: '<p>machine learning model</p>',
            translatedHtml: '<p>machine learning model（机器学习模型）</p>',
          ),
          (
            sourceHtml: '<p>OpenAI API</p>',
            translatedHtml: '<p>OpenAI API 接口</p>',
          ),
        ]) {
      test('allows a retained source term with a Chinese explanation', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: example.sourceHtml,
              translatedHtml: example.translatedHtml,
              targetLanguage: 'Chinese',
            );

        expect(finding, isNull);
      });
    }

    for (final ({String sourceHtml, String translatedHtml}) example
        in <({String sourceHtml, String translatedHtml})>[
          (
            sourceHtml: '<p>This Change Will Affect Everyone</p>',
            translatedHtml:
                '<p>This Change Will Affect Everyone 这项变化会影响所有人</p>',
          ),
          (
            sourceHtml: '<p>Please Read This</p>',
            translatedHtml: '<p>Please Read This 请阅读此内容</p>',
          ),
          (
            sourceHtml: '<p>Markets Shape Society.</p>',
            translatedHtml: '<p>Markets Shape Society. 市场塑造社会。</p>',
          ),
          (
            sourceHtml: '<p>Technology Changes Everything.</p>',
            translatedHtml: '<p>Technology Changes Everything. 技术改变一切。</p>',
          ),
        ]) {
      test('rejects retained title-case prose despite a Chinese gloss', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: example.sourceHtml,
              translatedHtml: example.translatedHtml,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });
    }

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

    test('allows a retained person name with a lowercase name particle', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>In the words of the Y2K expert Peter de Jager, “If we lose the ability to make a phone call, then we lose everything. We lose electronic fund transfers, we lose trading, we lose branch banking.” And the follow-on consequences of Y2K failures could come to more than that.</p>',
        translatedHtml:
            '<p>用 Y2K 专家 Peter de Jager 的话说：“如果我们失去拨打电话的能力，那么我们将失去一切。我们将失去电子资金转账，失去交易，失去分行银行业务。”而 Y2K 故障的连锁后果恐怕远不止于此。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding, isNull);
    });

    test('still rejects an untranslated quote after a retained person name', () {
      final TranslationResidualFinding?
      finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>In the words of the Y2K expert Peter de Jager, “If we lose the ability to make a phone call, then we lose everything. We lose electronic fund transfers, we lose trading, we lose branch banking.” And the follow-on consequences of Y2K failures could come to more than that.</p>',
        translatedHtml:
            '<p>用 Y2K 专家 Peter de Jager 的话说：“If we lose the ability to make a phone call, then we lose everything. We lose electronic fund transfers, we lose trading, we lose branch banking.”而 Y2K 故障的连锁后果恐怕远不止于此。</p>',
        targetLanguage: 'Chinese',
      );

      expect(finding?.kind, TranslationResidualKind.longSourceText);
    });

    group('audited retained foreign terms', () {
      test('allows matching italic Latin patricius in translated prose', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>Odoacer governed Italy as Zeno\'s <i class="calibre3">patricius</i>.</p>',
          translatedHtml:
              '<p>奥多亚塞以芝诺的<i class="calibre3">patricius</i>身份治理意大利。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding, isNull);
      });

      test(
        'allows matching emphasized Latin patricius in translated prose',
        () {
          final TranslationResidualFinding? finding =
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>Odoacer served as <em>patricius</em>.</p>',
                translatedHtml: '<p>奥多亚塞担任<em>patricius</em>官职。</p>',
                targetLanguage: 'Chinese',
              );

          expect(finding, isNull);
        },
      );

      test('still rejects an ordinary emphasized English word', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>This point is <i>important</i>.</p>',
              translatedHtml: '<p>这一点<i>important</i>很关键。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'important');
      });

      test('still rejects patricius outside an italic semantic node', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>Odoacer held the title patricius.</p>',
              translatedHtml: '<p>奥多亚塞担任patricius这一官职。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'patricius');
      });

      test('still rejects a multiword italic residual', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>Odoacer was <i>patricius remains</i>.</p>',
              translatedHtml: '<p>奥多亚塞是<i>patricius remains</i>官员。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
      });

      test('still rejects a nested retained foreign term', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>Odoacer was <i><span>patricius</span></i>.</p>',
              translatedHtml: '<p>奥多亚塞是<i><span>patricius</span></i>官员。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'patricius');
      });

      test('still rejects the term when the inline tag changes', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>Odoacer was <i>patricius</i>.</p>',
              translatedHtml: '<p>奥多亚塞是<em>patricius</em>官员。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'patricius');
      });

      test('still rejects the term when an ancestor tag changes', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml:
                  '<section><p>Odoacer was <i>patricius</i>.</p></section>',
              translatedHtml: '<aside><p>奥多亚塞是<i>patricius</i>官员。</p></aside>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'patricius');
      });

      test('still rejects the term when its raw inline text changes', () {
        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: '<p>Odoacer was <i>patricius</i>.</p>',
              translatedHtml: '<p>奥多亚塞是<i> patricius</i>官员。</p>',
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'patricius');
      });

      test('continues checking after clearing a retained foreign term', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>The <i>patricius</i> retained an entitlement privilege.</p>',
          translatedHtml: '<p><i>patricius</i>官职保留了entitlement特权。</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'entitlement');
      });

      test('still rejects long English prose after a retained foreign term', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>The <i>patricius</i> retained this entire English sentence without translation.</p>',
          translatedHtml:
              '<p><i>patricius</i>官职之后仍有 this entire English sentence without translation.</p>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });
    });

    group('inverted index person names', () {
      for (final ({String inverted, String natural}) example
          in <({String inverted, String natural})>[
            (inverted: 'de Balsac, Robert,', natural: 'Robert de Balsac'),
            (inverted: 'de Fiore, Joachim,', natural: 'Joachim de Fiore'),
            (inverted: 'de Jager, Peter,', natural: 'Peter de Jager'),
            (inverted: 'de Soto, Hernando,', natural: 'Hernando de Soto'),
            (inverted: 'van Creveld, Martin,', natural: 'Martin van Creveld'),
            (
              inverted: 'Van Den Berghe, Pierre,',
              natural: 'Pierre van den Berghe',
            ),
            (inverted: 'Dos Passos, John,', natural: 'John dos Passos'),
          ]) {
        test('allows retained ${example.inverted}', () {
          final TranslationResidualFinding?
          finding = TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<li class="indexmain"><span epub:type="index-term">${example.inverted}</span> <a epub:type="index-locator" href="chapter.xhtml#page">44</a></li>',
            translatedHtml:
                '<li class="indexmain"><span epub:type="index-term">${example.inverted}</span> <a epub:type="index-locator" href="chapter.xhtml#page">44</a></li>',
            targetLanguage: 'Chinese',
          );

          expect(finding, isNull);
        });

        test('allows natural-order ${example.natural}', () {
          final TranslationResidualFinding?
          finding = TranslationQuality.findSuspiciousHtmlResidual(
            sourceHtml:
                '<li class="indexmain"><span epub:type="index-term">${example.inverted}</span> <a epub:type="index-locator" href="chapter.xhtml#page">44</a></li>',
            translatedHtml:
                '<li class="indexmain"><span epub:type="index-term">${example.natural}</span> <a epub:type="index-locator" href="chapter.xhtml#page">44</a></li>',
            targetLanguage: 'Chinese',
          );

          expect(finding, isNull);
        });
      }

      test('does not exempt an inverted name outside an index term', () {
        const String html =
            '<li><span>de Jager, Peter,</span> <a href="#page">44</a></li>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });

      test('does not exempt a non-person index phrase', () {
        const String html =
            '<li><span epub:type="index-term">de facto, rule of law,</span> <a epub:type="index-locator" href="#page">44</a></li>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });

      test('does not exempt a nested index term', () {
        const String html =
            '<li><span epub:type="index-term"><em>de Jager, Peter,</em></span> <a epub:type="index-locator" href="#page">44</a></li>';

        final TranslationResidualFinding? finding =
            TranslationQuality.findSuspiciousHtmlResidual(
              sourceHtml: html,
              translatedHtml: html,
              targetLanguage: 'Chinese',
            );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });

      test('does not exempt an index term when another attribute changes', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<li><span class="source" epub:type="index-term">de Jager, Peter,</span> <a epub:type="index-locator" href="#page">44</a></li>',
          translatedHtml:
              '<li><span class="translated" epub:type="index-term">de Jager, Peter,</span> <a epub:type="index-locator" href="#page">44</a></li>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });

      test('does not exempt an index term when its path changes', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<li><span epub:type="index-term">de Jager, Peter,</span> <a epub:type="index-locator" href="#page">44</a></li>',
          translatedHtml:
              '<li><div><span epub:type="index-term">de Jager, Peter,</span></div> <a epub:type="index-locator" href="#page">44</a></li>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.longSourceText);
      });

      test('continues checking prose outside a retained index name', () {
        final TranslationResidualFinding?
        finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<li><span epub:type="index-term">de Jager, Peter,</span> includes an entitlement discussion.</li>',
          translatedHtml:
              '<li><span epub:type="index-term">Peter de Jager</span>包含entitlement讨论。</li>',
          targetLanguage: 'Chinese',
        );

        expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
        expect(finding?.token, 'entitlement');
      });
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
