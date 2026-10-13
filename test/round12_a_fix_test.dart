// Round 12, Area A regression tests (14 items).
//
// Each group below covers one review item. The tests use the public
// `*ForTest` hooks; no production behavior is changed by the hooks.

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P2-#6 equal slot counts keep response standalone whitespace', () {
    // 质量-#55: the whitespace under test lives in the RESPONSE, not the
    // source — the old equal-slots path wrote slot texts alone and dropped
    // response-side standalone whitespace, gluing words. The response uses
    // <em> where the source has <i> so the structure mismatches and the
    // equal-slots rebuild path (not the early structure-match return) runs.
    test('whitespace between inline elements is folded, not dropped', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p><b>Hello</b><i>world</i></p>',
        translatedHtml: '<p><b>Bonjour</b> <em>monde</em></p>',
      );
      // The standalone space is appended to the preceding slot's text.
      expect(result, contains('Bonjour </b>'));
      expect(result, contains('<i>monde</i>'));
    });

    test('leading whitespace is prepended to the first slot', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p><b>Hello</b><i>world</i></p>',
        translatedHtml: '<p> <b>Bonjour</b><em>monde</em></p>',
      );
      expect(result, contains('<b> Bonjour</b>'));
    });
  });

  group('P2-#7 protection follows slot identity, not tag names', () {
    test('model-introduced protected-kind text is kept as translation', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>Use <code>foo()</code> today.</p>',
        translatedHtml:
            '<p>今天使用 <code>foo()</code> 外加 <code>bar()</code> 说明。</p>',
      );
      // The second <code> has no source counterpart (ordinal 1 >= source
      // count 1), so its text is real translation content, not protected.
      expect(result, contains('bar()'));
      // The genuine protected slot keeps its source text exactly once.
      expect('foo()'.allMatches(result), hasLength(1));
    });

    test('genuine protected slot still keeps source text', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>Use <code>foo()</code> today.</p>',
        translatedHtml: '<p>今天使用 <code>changed()</code>。</p>',
      );
      expect(result, contains('foo()'));
      expect(result, isNot(contains('changed()')));
    });
  });

  group('P2-#8 single-letter literal whitelist', () {
    test('<T> is a literal, not a tag', () {
      final result = EpubChapterTranslator.cleanBookTitleForTest(
        '类型 <T> 参数',
        checkHtmlTags: false,
      );
      expect(result, contains('<T>'));
    });

    test('lowercase <t> is a literal too', () {
      final result = EpubChapterTranslator.cleanBookTitleForTest(
        '类型 <t> 参数',
        checkHtmlTags: false,
      );
      expect(result, contains('<t>'));
    });

    test('<B> is a real element and stays rejected', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '<B>加粗</B>：副标题',
          checkHtmlTags: false,
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('<b> is a real element and stays rejected', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '<b>中文书名',
          checkHtmlTags: false,
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('unterminated comment is caught', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '书名 <!-- 未闭合注释',
          checkHtmlTags: false,
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });

    test('terminated comment is still caught', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '书名 <!-- 注释 -->',
          checkHtmlTags: false,
        ),
        throwsA(isA<TranslationParseException>()),
      );
    });
  });

  group('P2-#9 first-chapter isolation keeps confirmed style profile', () {
    Map<String, Object?> liveMemory() => {
          'styleProfile': {'tone': 'formal'},
          'styleProfileConfirmed': true,
          'glossary': [
            {'source': 'x', 'target': 'y'},
          ],
          'bookSummary': 'later chapter content',
        };

    test('restored run keeps only the style slice', () {
      final result = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: true,
        timelineIsEmpty: false,
        liveMemory: liveMemory(),
      );
      expect(result, isNotNull);
      expect(result!['styleProfile'], {'tone': 'formal'});
      expect(result['styleProfileConfirmed'], isTrue);
      expect(result.containsKey('glossary'), isFalse);
      expect(result.containsKey('bookSummary'), isFalse);
    });

    test('fresh run still receives the whole live memory', () {
      final live = liveMemory();
      final result = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: false,
        timelineIsEmpty: true,
        liveMemory: live,
      );
      expect(result, same(live));
    });

    test('no style profile means no fallback', () {
      final result = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: true,
        timelineIsEmpty: false,
        liveMemory: {
          'glossary': [
            {'source': 'x', 'target': 'y'},
          ],
        },
      );
      expect(result, isNull);
    });
  });

  group('P2-#10 only a trailing [RETRY] marker is truncated', () {
    Map<String, dynamic> payload(String userContent) => {
          'messages': <Map<String, String>>[
            {
              'role': 'system',
              'content': 'You translate EPUB HTML fragments into Chinese.',
            },
            {'role': 'user', 'content': userContent},
          ],
        };

    test('trailing marker with retry instruction is removed', () {
      final text = EpubChapterTranslator.singleBlockTextForTest(payload(
        'BLOCK TEXT\n\n[RETRY] The previous translation was rejected for this reason: bad',
      ));
      expect(text, 'BLOCK TEXT');
    });

    test('bare trailing marker is removed', () {
      final text = EpubChapterTranslator.singleBlockTextForTest(
          payload('BLOCK TEXT\n\n[RETRY]'));
      expect(text, 'BLOCK TEXT');
    });

    test('literal marker mid-text is kept', () {
      const body = 'log line\n\n[RETRY] some pasted log\nmore text';
      final text =
          EpubChapterTranslator.singleBlockTextForTest(payload(body));
      expect(text, body);
    });

    test('no marker passes through', () {
      final text = EpubChapterTranslator.singleBlockTextForTest(
          payload('PLAIN BLOCK'));
      expect(text, 'PLAIN BLOCK');
    });
  });

  group('P2-#11 single-letter words count as all-caps', () {
    test('"THIS IS A TEST" is a sentence, not citation metadata', () {
      expect(
        TranslationQuality.isPureCitationMetadata('THIS IS A TEST'),
        isFalse,
      );
    });

    test('lone all-caps surname stays allowed', () {
      expect(
        TranslationQuality.isPureCitationMetadata('YARDENI'),
        isTrue,
      );
    });

    test('ibid stays allowed', () {
      expect(
        TranslationQuality.isPureCitationMetadata('Ibid.'),
        isTrue,
      );
    });
  });

  group('P2-#12 denylist strips boundary punctuation', () {
    test('"no smoking:" is recognized', () {
      expect(
        TranslationQuality.isCommonInstructionPhraseForTest('no smoking:'),
        isTrue,
      );
    });

    test('"keep out;" is recognized', () {
      expect(
        TranslationQuality.isCommonInstructionPhraseForTest('keep out;'),
        isTrue,
      );
    });

    test('plain phrase still recognized', () {
      expect(
        TranslationQuality.isCommonInstructionPhraseForTest('do not enter'),
        isTrue,
      );
    });

    test('non-phrase is not recognized', () {
      expect(
        TranslationQuality.isCommonInstructionPhraseForTest(
            'the quick brown fox'),
        isFalse,
      );
    });
  });

  group('P2-#13 slot occurrence stays within slot boundaries', () {
    test('needle inside another slot does not steal the occurrence', () {
      final blockText =
          '${'a' * 700} Hello world ${'b' * 700} world ${'c' * 700}';
      final block = ExtractedBlock(
        id: 'b0',
        tagName: 'p',
        sourceHtml: '<p>block</p>',
        sourceText: blockText,
      );
      final summary = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'world',
        slotIndex: 1,
        slotTexts: const ['Hello world', 'world'],
      );
      // Centered on the second slot's own "world": the window reaches the
      // trailing c-run, not the leading a-run the old indexOf hit.
      expect(summary, contains('ccc'));
      expect(summary, isNot(contains('aaa')));
    });
  });

  group('性能-#42 protection state is decided once per slot', () {
    test('nested protected elements merge correctly in one pass', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>A <code>x</code> B <code>y</code> C</p>',
        translatedHtml: '<p>甲 <code>x</code> 乙 <code>y</code> 丙</p>',
      );
      expect(result, contains('x'));
      expect(result, contains('y'));
      expect(result, contains('甲'));
      expect(result, contains('乙'));
      expect(result, contains('丙'));
      expect('x'.allMatches(result), hasLength(1));
      expect('y'.allMatches(result), hasLength(1));
    });
  });

  group('性能-#50 cached normalized slot texts', () {
    test('cached slot texts match recomputed ones', () {
      const block = ExtractedBlock(
        id: 'b0',
        tagName: 'p',
        sourceHtml: '<p>block</p>',
        sourceText: 'Alpha beta gamma. Alpha beta gamma.',
      );
      final cached = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 1,
        slotTexts: const ['Alpha beta gamma.', 'Alpha beta gamma.'],
        normalizedSlotTexts: const [
          'Alpha beta gamma.',
          'Alpha beta gamma.',
        ],
      );
      final recomputed = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 1,
        slotTexts: const ['Alpha beta gamma.', 'Alpha beta gamma.'],
      );
      expect(cached, recomputed);
      expect(cached, isNotEmpty);
    });
  });

  group('性能-#51 gloss regexes are linear scans', () {
    test('glossed token starts: adversarial paren run finishes fast',
        timeout: const Timeout(Duration(seconds: 30)), () {
      final text = '中（${'-' * 2000}';
      final starts =
          TranslationQuality.glossedTermTokenStartsForTest(text);
      expect(starts, isEmpty);
    });

    test('parenthesized gloss check: adversarial run finishes fast',
        timeout: const Timeout(Duration(seconds: 30)), () {
      final text = 'mafia（${'中' * 2000}';
      final result =
          TranslationQuality.isParenthesizedTermGlossForTest(text, 'mafia');
      expect(result, isFalse);
    });

    test('clean glosses are still detected', () {
      expect(
        TranslationQuality.glossedTermTokenStartsForTest(
            '伐林开垦（assarting）是术语'),
        isNotEmpty,
      );
      expect(
        TranslationQuality.isParenthesizedTermGlossForTest(
            'job-coachman（临时马车夫）出现', 'job-coachman'),
        isTrue,
      );
      expect(
        TranslationQuality.isParenthesizedTermGlossForTest(
            '伐林开垦（assarting）是术语', 'assarting'),
        isTrue,
      );
    });
  });

  group('性能-#52 timeline write cursor', () {
    test('forward positions append, re-records drop', () {
      bool should(int? position, int max) =>
          EpubChapterTranslator.shouldRecordMemoryTimelineEntryForTest(
            position: position,
            maxRecordedPosition: max,
          );
      expect(should(0, -1), isTrue);
      expect(should(1, 0), isTrue);
      expect(should(5, 1), isTrue);
      // Re-recording the newest or an earlier chapter drops.
      expect(should(1, 1), isFalse);
      expect(should(0, 1), isFalse);
      expect(should(null, 1), isFalse);
    });
  });

  group('质量-#56 second-person rule is relationship-based', () {
    test('instruction chooses by speaker/addressee relationship', () {
      final instruction =
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
        config: TranslationConfig.defaults(),
        normalizedTargetLanguage: 'zh',
      );
      expect(instruction, contains('relationship'));
      expect(instruction, contains('您'));
      expect(instruction, contains('你'));
      expect(instruction, isNot(contains('use 您 throughout')));
    });

    test('non-Chinese targets get no instruction', () {
      final instruction =
          EpubChapterTranslator.chineseSecondPersonInstructionForTest(
        config: TranslationConfig.defaults(),
        normalizedTargetLanguage: 'en',
      );
      expect(instruction, isEmpty);
    });
  });
}
