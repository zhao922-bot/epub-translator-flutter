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
