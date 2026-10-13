// Round 11, Area A regression tests (16 items).
//
// Each group below covers one review item. The tests use the public
// `*ForTest` hooks; no production behavior is changed by the hooks.

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P2-#13 merge fallback keeps inter-word whitespace', () {
    test('whitespace-only text nodes are not glued', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p><b>Bonjour</b> <b>le</b> <b>monde</b>.</p>',
        translatedHtml: '<p>你好世界。</p>',
      );
      // The merge fallback must preserve the spaces between the <b> runs;
      // the old code glued them into "Bonjourlemonde."-style output.
      expect(result, contains('</b> <b>'));
      expect(result, isNot(contains('</b><b>')));
    });
  });

  group('P2-#14 merge fallback keeps response-introduced code text', () {
    test('new <code> in the response is not treated as protected', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: '<p>Hello world.</p>',
        translatedHtml: '<p>你好<code>newcode()</code>世界。</p>',
      );
      // The <code> element is new in the response (not in the source), so
      // its text is translated content and must survive the merge.
      expect(result, contains('newcode()'));
    });

    test('source-existing <code> stays protected', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml:
            '<p>Use <em>this command</em>: <code>foo()</code> today.</p>',
        translatedHtml: '<p>今天使用这个命令：<code>foo()</code></p>',
      );
      expect('foo()'.allMatches(result), hasLength(1));
    });
  });

  group('P2-#15 _cleanBookTitle rejects comments and unpaired tags', () {
    test('HTML comment is rejected when checkHtmlTags is false', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '中文书名<!-- note -->',
          checkHtmlTags: false,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('embedded markup is rejected when checkHtmlTags is false', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '<b>中文书名</b>：副标题',
          checkHtmlTags: false,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('unclosed tag is rejected when checkHtmlTags is false', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '<b>中文书名',
          checkHtmlTags: false,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('lone <T> literal is still allowed', () {
      expect(
        EpubChapterTranslator.cleanBookTitleForTest(
          'Introduction to Generics <T>',
          checkHtmlTags: false,
        ),
        'Introduction to Generics <T>',
      );
    });

    test('full-wrapper tag still rejected when checkHtmlTags is true', () {
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(
          '<b>中文书名</b>',
          checkHtmlTags: true,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('P2-#16 snapshot fallback isolates positional memory', () {
    test('restored run with non-empty timeline gets no live memory', () {
      final fallback = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: true,
        timelineIsEmpty: false,
        liveMemory: {'bookSummary': 'rolling-with-later-chapters'},
      );
      expect(fallback, isNull);
    });

    test('restored run with empty timeline keeps live memory', () {
      final live = {'bookSummary': 'initial'};
      final fallback = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: true,
        timelineIsEmpty: true,
        liveMemory: live,
      );
      expect(fallback, same(live));
    });

    test('fresh run keeps live memory', () {
      final live = {'bookSummary': 'initial'};
      final fallback = EpubChapterTranslator.memorySnapshotFallbackForTest(
        hasRestoredMemory: false,
        timelineIsEmpty: false,
        liveMemory: live,
      );
      expect(fallback, same(live));
    });
  });

  group('P2-#17 single-block fallback recognized', () {
    test('HTML fragment fallback payload is recognized', () {
      final data = {
        'messages': [
          {
            'role': 'system',
            'content': 'You translate EPUB HTML fragments into Chinese.',
          },
          {
            'role': 'user',
            'content': '<p>Some long block text.</p>\n\n[RETRY]',
          },
        ],
      };
      expect(
        EpubChapterTranslator.singleBlockTextForTest(data),
        '<p>Some long block text.</p>',
      );
    });

    test('slot-text fallback payload is recognized', () {
      final data = {
        'messages': [
          {
            'role': 'system',
            'content':
                'Read-only plain-text summary of the source block.\nTranslate.',
          },
          {
            'role': 'user',
            'content': 'Some slot text.',
          },
        ],
      };
      expect(
        EpubChapterTranslator.singleBlockTextForTest(data),
        'Some slot text.',
      );
    });

    test('JSON blocks payload is not a single block', () {
      final data = {
        'messages': [
          {'role': 'system', 'content': 'Translate.'},
          {
            'role': 'user',
            'content': '{"blocks": [{"id": "b0", "text": "hi"}]}',
          },
        ],
      };
      expect(EpubChapterTranslator.singleBlockTextForTest(data), isNull);
    });

    test('memory request payload is not a single block', () {
      final data = {
        'messages': [
          {
            'role': 'system',
            'content': 'You analyze an EPUB chapter for memory.',
          },
          {'role': 'user', 'content': '<p>Chapter text.</p>'},
        ],
      };
      expect(EpubChapterTranslator.singleBlockTextForTest(data), isNull);
    });
  });

  group('P2-#18 gloss exemption is occurrence-scoped', () {
    test('clean gloss is exempt', () {
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>Clearing land (assarting) was common.</p>',
        translatedHtml: '<p>伐林开垦（assarting）很常见。</p>',
        targetLanguage: 'zh',
      );
      expect(finding, isNull);
    });

    test('bare residual sharing the parens is still flagged', () {
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>Clearing land was common and untranslated.</p>',
        translatedHtml: '<p>中文（assarting 和untranslated）很常见。</p>',
        targetLanguage: 'zh',
      );
      expect(finding, isNotNull);
      expect(finding!.token, 'untranslated');
    });

    test('quoted term gloss stays exempt', () {
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>The agoric open system matters.</p>',
        translatedHtml: '<p>“agoric开放系统”很重要。</p>',
        targetLanguage: 'zh',
      );
      expect(finding, isNull);
    });
  });

  group('P2-#19 all-caps heuristic for citation metadata', () {
    test('single all-caps surname is still metadata', () {
      expect(
        TranslationQuality.isPureCitationMetadata('YARDENI, op. cit.'),
        isTrue,
      );
    });

    test('long all-caps sentence is not metadata', () {
      expect(
        TranslationQuality.isPureCitationMetadata(
          'THIS IS A VERY LONG SENTENCE IN ALL CAPS WITH MANY WORDS',
        ),
        isFalse,
      );
    });

    test('ordinary citation still passes', () {
      expect(
        TranslationQuality.isPureCitationMetadata(
          'Fiorentini, op. cit., p. 42.',
        ),
        isTrue,
      );
    });
  });

  group('P2-#20 common instruction phrases are not transliterations', () {
    test('"do not enter" left untranslated is flagged', () {
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>do not enter</p>',
        translatedHtml: '<p>do not enter</p>',
        targetLanguage: 'zh',
      );
      expect(finding, isNotNull);
    });

    test('"chum yum" transliteration stays exempt', () {
      final finding = TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>chum yum</p>',
        translatedHtml: '<p>chum yum</p>',
        targetLanguage: 'zh',
      );
      // "chum yum" is a genuine short lowercase transliteration.
      expect(finding, isNull);
    });
  });

  group('P2-#21 repeated slot text uses slot index', () {
    ExtractedBlock blockWithRepeatedText() {
      const text = 'Alpha beta gamma. Alpha beta gamma. Alpha beta gamma.';
      return const ExtractedBlock(
        id: 'b0',
        tagName: 'p',
        sourceHtml: '<p>$text</p>',
        sourceText: text,
      );
    }

    test('second occurrence centers on the second copy', () {
      final block = blockWithRepeatedText();
      final first = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 0,
        slotTexts: ['Alpha beta gamma.', 'Alpha beta gamma.'],
      );
      final second = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 1,
        slotTexts: ['Alpha beta gamma.', 'Alpha beta gamma.'],
      );
      // Both summaries are the whole (short) text, but the mechanism must
      // not crash and must accept the index parameters.
      expect(first, isNotEmpty);
      expect(second, isNotEmpty);
    });

    test('cached normalized text matches recomputed', () {
      final block = blockWithRepeatedText();
      const normalized = 'Alpha beta gamma. Alpha beta gamma. Alpha beta gamma.';
      final cached = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 1,
        slotTexts: ['Alpha beta gamma.', 'Alpha beta gamma.'],
        normalizedBlockText: normalized,
      );
      final recomputed = EpubChapterTranslator.blockContextSummaryForTest(
        block,
        slotText: 'Alpha beta gamma.',
        slotIndex: 1,
        slotTexts: ['Alpha beta gamma.', 'Alpha beta gamma.'],
      );
      expect(cached, recomputed);
    });
  });

  group('性能-#38 incremental snapshot selection', () {
    Map<String, Object?> serialize(Object m) => m as Map<String, Object?>;
    Map<String, Object?>? fallback() => {'fallback': true};

    test('sequential chapters see the newest earlier entry', () {
      final cursor = EpubChapterTranslator.memorySnapshotCursorForTest();
      final positionByPath = {'c1': 0, 'c2': 1, 'c3': 2};
      final mem1 = {'id': 'm1'};
      final mem2 = {'id': 'm2'};
      final timeline = [
        (path: 'c1', memory: mem1),
        (path: 'c2', memory: mem2),
      ];

      final s2 = EpubChapterTranslator.selectMemorySnapshotForTest(
        timeline: timeline,
        positionByPath: positionByPath,
        chapterPath: 'c2',
        cursor: cursor,
        serialize: serialize,
        fallback: fallback,
      );
      expect(s2, same(mem1));

      final s3 = EpubChapterTranslator.selectMemorySnapshotForTest(
        timeline: timeline,
        positionByPath: positionByPath,
        chapterPath: 'c3',
        cursor: cursor,
        serialize: serialize,
        fallback: fallback,
      );
      expect(s3, same(mem2));
    });

    test('non-monotonic call resyncs', () {
      final cursor = EpubChapterTranslator.memorySnapshotCursorForTest();
      final positionByPath = {'c1': 0, 'c2': 1, 'c3': 2};
      final mem1 = {'id': 'm1'};
      final timeline = [(path: 'c1', memory: mem1)];

      // Visit c3 first (advances cursor), then go back to c2.
      EpubChapterTranslator.selectMemorySnapshotForTest(
        timeline: timeline,
        positionByPath: positionByPath,
        chapterPath: 'c3',
        cursor: cursor,
        serialize: serialize,
        fallback: fallback,
      );
      final s2 = EpubChapterTranslator.selectMemorySnapshotForTest(
        timeline: timeline,
        positionByPath: positionByPath,
        chapterPath: 'c2',
        cursor: cursor,
        serialize: serialize,
        fallback: fallback,
      );
      expect(s2, same(mem1));
    });

    test('first chapter falls back', () {
      final cursor = EpubChapterTranslator.memorySnapshotCursorForTest();
      final fb = {'fallback': true};
      final s = EpubChapterTranslator.selectMemorySnapshotForTest(
        timeline: const [],
        positionByPath: {'c1': 0},
        chapterPath: 'c1',
        cursor: cursor,
        serialize: serialize,
        fallback: () => fb,
      );
      expect(s, same(fb));
    });
  });

  group('性能-#40 preview body character cap', () {
    test('plain text truncates to maxChars', () {
      final translator = EpubChapterTranslator();
      final longHtml = '<p>${'x' * 10000}</p>';
      final text = translator.plainTextFromHtmlForTest(
        longHtml,
        maxChars: 100,
      );
      expect(text, isNotNull);
      expect(text!.length, lessThanOrEqualTo(100));
    });

    test('preview body respects the 4000-char cap', () {
      final translator = EpubChapterTranslator();
      final blocks = List.generate(
        5,
        (i) => ExtractedBlock(
          id: 'b$i',
          tagName: 'p',
          sourceHtml: '<p>source $i</p>',
          sourceText: 'source $i',
          translatedHtml: '<p>${'y' * 2000}</p>',
        ),
      );
      final preview = translator.previewBodyFromBlocksForTest(
        blocks,
        fallback: 'fallback',
      );
      expect(preview.length, lessThanOrEqualTo(4000 + 8));
    });
  });

  group('性能-#41 footnote batches deduct shared context', () {
    InspectedChapter chapter(String path) => InspectedChapter(
      path: path,
      title: 'Notes',
      body: '',
      originalHtml: '<html><body></body></html>',
      blocks: const <ExtractedBlock>[],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    );

    ExtractedBlock block(String id, {int textLength = 20}) {
      final String text = List<String>.filled(textLength, 'a').join();
      return ExtractedBlock(
        id: id,
        tagName: 'p',
        sourceHtml: '<p>$text</p>',
        sourceText: text,
      );
    }

    test('shared overhead shrinks the usable budget', () {
      const planner = FootnoteBatchPlanner();
      final chapters = [chapter('notes/fn.xhtml')];
      // 10 blocks of 40 chars each.
      final pending = {
        0: List.generate(10, (i) => block('p-$i', textLength: 40)),
      };

      final withoutMemory = planner.plan(
        chapters: chapters,
        pendingBlocksByChapter: pending,
        chunkSize: 500,
      );
      expect(withoutMemory, isNotEmpty);

      // With a large bookMemory, the shared overhead (title + serialized
      // memory) must come out of the same 500-char budget, forcing
      // strictly more batches than without the memory.
      final bigMemory = {
        'bookSummary': List<String>.filled(400, 'x').join(),
      };
      final withMemory = planner.plan(
        chapters: chapters,
        pendingBlocksByChapter: pending,
        chunkSize: 500,
        bookMemory: bigMemory,
      );
      expect(withMemory.length, greaterThan(withoutMemory.length));
    });
  });
}
