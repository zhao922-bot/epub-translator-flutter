import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('estimates selected chapters, blocks, and API batches', () {
    final String text = List<String>.filled(100, 'a').join();
    final TranslationRunEstimate estimate = TranslationRunEstimate.fromChapters(
      <InspectedChapter>[
        _chapter(
          path: 'chapter-1.xhtml',
          includeInTranslation: true,
          blocks: <ExtractedBlock>[
            _block(id: 'a', text: text),
            _block(id: 'b', text: text),
          ],
        ),
        _chapter(
          path: 'chapter-2.xhtml',
          includeInTranslation: false,
          blocks: <ExtractedBlock>[_block(id: 'c', text: text)],
        ),
        _chapter(
          path: 'chapter-3.xhtml',
          includeInTranslation: true,
          blocks: <ExtractedBlock>[_block(id: 'd', text: text)],
        ),
      ],
      chunkSize: 400,
    );

    expect(estimate.selectedChapters, 2);
    expect(estimate.totalBlocks, 3);
    expect(estimate.estimatedApiBatches, 2);
  });

  test('estimates speed and remaining time from runtime progress', () {
    final String text = List<String>.filled(100, 'a').join();
    final List<InspectedChapter> chapters = <InspectedChapter>[
      _chapter(
        path: 'chapter.xhtml',
        includeInTranslation: true,
        blocks: List<ExtractedBlock>.generate(
          60,
          (int index) => _block(id: '$index', text: text),
        ),
      ),
    ];

    final TranslationRunEstimate estimate = TranslationRunEstimate.fromChapters(
      chapters,
      chunkSize: 400,
      job: const TranslationJob(
        id: 'job-1',
        inputPath: 'book.epub',
        outputPath: 'out.epub',
        status: TranslationJobStatus.running,
        progress: 0.5,
        completedBlocks: 30,
        totalBlocks: 60,
      ),
      elapsed: const Duration(minutes: 2),
    );

    expect(estimate.blocksPerMinute, 15);
    expect(estimate.estimatedRemaining, const Duration(minutes: 2));
  });

  group('estimateInputTokens', () {
    test('weights CJK text about 2.3x higher than Latin text', () {
      final String latin = List<String>.filled(400, 'a').join();
      final String cjk = List<String>.filled(175, '\u4e2d').join();
      final int latinTokens = TranslationRunEstimate.estimateInputTokens(latin);
      final int cjkTokens = TranslationRunEstimate.estimateInputTokens(cjk);
      // 400/4 = 100; 175/1.75 = 100.
      expect(latinTokens, 100);
      expect(cjkTokens, 100);
    });

    test('mixes CJK and Latin proportionally', () {
      final String mixed =
          List<String>.filled(175, '\u4e2d').join() +
          List<String>.filled(400, 'a').join();
      expect(TranslationRunEstimate.estimateInputTokens(mixed), 200);
    });

    test('covers hiragana, katakana, and hangul as CJK', () {
      final String text =
          List<String>.filled(175, '\u3042').join() +
          List<String>.filled(175, '\u30a2').join() +
          List<String>.filled(175, '\uac00').join();
      // 525 / 1.75 = 300.
      expect(TranslationRunEstimate.estimateInputTokens(text), 300);
    });

    test('never returns zero', () {
      expect(TranslationRunEstimate.estimateInputTokens(''), 1);
    });
  });

  test('fromChapters uses CJK-weighted token estimates', () {
    final String cjk = List<String>.filled(1750, '\u4e2d').join();
    final TranslationRunEstimate estimate = TranslationRunEstimate.fromChapters(
      <InspectedChapter>[
        _chapter(
          path: 'chapter-1.xhtml',
          includeInTranslation: true,
          blocks: <ExtractedBlock>[_block(id: 'a', text: cjk)],
        ),
      ],
      chunkSize: 400,
    );
    // 1750 / 1.75 = 1000 (old formula would have said 438).
    expect(estimate.estimatedInputTokens, 1000);
  });
}

InspectedChapter _chapter({
  required String path,
  required bool includeInTranslation,
  required List<ExtractedBlock> blocks,
}) {
  return InspectedChapter(
    path: path,
    title: path,
    body: '',
    originalHtml: '',
    blocks: blocks,
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: includeInTranslation,
  );
}

ExtractedBlock _block({required String id, required String text}) {
  return ExtractedBlock(
    id: id,
    tagName: 'p',
    sourceHtml: text,
    sourceText: text,
  );
}
