import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const FootnoteBatchPlanner planner = FootnoteBatchPlanner();

  group('FootnoteBatchPlanner', () {
    test('does not include ordinary body chapters', () {
      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: <InspectedChapter>[
          _chapter(path: 'text/chapter-01.xhtml', title: 'Chapter 1'),
          _chapter(path: 'text/chapter-01-fn.xhtml', title: 'Notes'),
        ],
        pendingBlocksByChapter: <int, List<ExtractedBlock>>{
          0: <ExtractedBlock>[_block('p-1')],
          1: <ExtractedBlock>[_block('p-1')],
        },
        chunkSize: 500,
      );

      expect(batches, hasLength(1));
      expect(
        batches.single.references.map(
          (FootnoteBlockReference item) => item.requestId,
        ),
        <String>['f1:p-1'],
      );
    });

    test('does not mistake notebook files or noteworthy titles for notes', () {
      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: <InspectedChapter>[
          _chapter(path: 'text/notebook.xhtml', title: 'Notebook'),
          _chapter(
            path: 'text/chapter-01.xhtml',
            title: 'A Noteworthy Chapter',
          ),
        ],
        pendingBlocksByChapter: <int, List<ExtractedBlock>>{
          0: <ExtractedBlock>[_block('p-1')],
          1: <ExtractedBlock>[_block('p-1')],
        },
        chunkSize: 500,
      );

      expect(batches, isEmpty);
    });

    test(
      'does not treat an ordinary content file titled Notes as standalone',
      () {
        final InspectedChapter chapter = _chapter(
          path: 'text/chapter-10.xhtml',
          title: 'Notes',
        );

        expect(
          FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
          isFalse,
        );
      },
    );

    test('ignores footnote-like text and non-semantic attributes', () {
      final InspectedChapter chapter = _chapter(
        path: 'text/chapter-10.xhtml',
        title: 'Notes',
        originalHtml: '''
<html><body>
  <!-- role="doc-footnote" -->
  <p data-role="footnote"><code>epub:type="endnote"</code></p>
</body></html>
''',
      );

      expect(
        FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
        isFalse,
      );
    });

    test('accepts a Notes document with explicit footnote semantics', () {
      final InspectedChapter chapter = _chapter(
        path: 'text/chapter-10.xhtml',
        title: 'Notes',
        originalHtml:
            '<html><body><aside epub:type="footnote">Note.</aside></body></html>',
      );

      expect(FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter), isTrue);
    });

    test('keeps supported standalone footnote path variants', () {
      final List<InspectedChapter> chapters = <InspectedChapter>[
        _chapter(path: 'text/footnotes.xhtml', title: 'Chapter 1'),
        _chapter(path: 'text/endnotes.xhtml', title: 'Chapter 2'),
        _chapter(path: 'notes/chapter-03.xhtml', title: 'Chapter 3'),
        _chapter(path: 'text/chapter-04-fn.xhtml', title: 'Chapter 4'),
      ];

      for (final InspectedChapter chapter in chapters) {
        expect(
          FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
          isTrue,
        );
      }
    });

    test(
      'assigns globally unique request ids to duplicate footnote block ids',
      () {
        final List<FootnoteTranslationBatch> batches = planner.plan(
          chapters: <InspectedChapter>[
            _chapter(path: 'notes/ch01-fn.xhtml', title: 'Notes'),
            _chapter(path: 'notes/ch02-fn.xhtml', title: 'Notes'),
          ],
          pendingBlocksByChapter: <int, List<ExtractedBlock>>{
            0: <ExtractedBlock>[_block('p-1')],
            1: <ExtractedBlock>[_block('p-1')],
          },
          chunkSize: 500,
        );

        final List<FootnoteBlockReference> references =
            batches.single.references;
        expect(
          references.map((FootnoteBlockReference item) => item.requestId),
          <String>['f0:p-1', 'f1:p-1'],
        );
        expect(references[0].chapter.path, 'notes/ch01-fn.xhtml');
        expect(references[1].chapter.path, 'notes/ch02-fn.xhtml');
        expect(batches.single.context.chapterTitle, '跨文件脚注');
      },
    );

    test('does not batch footnotes across an intervening body chapter', () {
      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: <InspectedChapter>[
          _chapter(path: 'notes/ch01-fn.xhtml', title: 'Notes'),
          _chapter(path: 'text/chapter-01.xhtml', title: 'Chapter 1'),
          _chapter(path: 'notes/ch02-fn.xhtml', title: 'Notes'),
        ],
        pendingBlocksByChapter: <int, List<ExtractedBlock>>{
          0: <ExtractedBlock>[_block('p-1')],
          1: <ExtractedBlock>[_block('p-1')],
          2: <ExtractedBlock>[_block('p-1')],
        },
        chunkSize: 500,
      );

      expect(batches, hasLength(2));
      expect(batches[0].references.single.requestId, 'f0:p-1');
      expect(batches[1].references.single.requestId, 'f2:p-1');
    });

    test('splits batches using the existing block budget', () {
      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: <InspectedChapter>[
          _chapter(path: 'notes/ch01-fn.xhtml', title: 'Notes'),
          _chapter(path: 'notes/ch02-fn.xhtml', title: 'Notes'),
        ],
        pendingBlocksByChapter: <int, List<ExtractedBlock>>{
          0: <ExtractedBlock>[_block('p-1', textLength: 150)],
          1: <ExtractedBlock>[_block('p-1', textLength: 150)],
        },
        chunkSize: 400,
      );

      expect(batches, hasLength(2));
      expect(batches[0].references.single.requestId, 'f0:p-1');
      expect(batches[1].references.single.requestId, 'f1:p-1');
    });

    test('limits a cross-file footnote batch to twelve references', () {
      final List<InspectedChapter> chapters = List<InspectedChapter>.generate(
        13,
        (int index) => _chapter(path: 'notes/$index-fn.xhtml', title: 'Notes'),
      );
      final Map<int, List<ExtractedBlock>> pending =
          <int, List<ExtractedBlock>>{
            for (int index = 0; index < 13; index += 1)
              index: <ExtractedBlock>[_block('p-1')],
          };

      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: chapters,
        pendingBlocksByChapter: pending,
        chunkSize: 5000,
      );

      expect(
        batches.map(
          (FootnoteTranslationBatch batch) => batch.references.length,
        ),
        <int>[12, 1],
      );
    });

    for (final MapEntry<String, String> semantic in <String, String>{
      'epub footnotes': 'epub:type="footnotes"',
      'epub endnotes': 'epub:type="endnotes"',
      'role footnotes': 'role="doc-footnotes"',
      'role endnotes': 'role="doc-endnotes"',
      'role token list': 'role="doc-footnotes note"',
    }.entries) {
      test('accepts collection-level ${semantic.key} semantics', () {
        final InspectedChapter chapter = _chapter(
          path: 'text/chapter-10.xhtml',
          title: 'Notes',
          originalHtml:
              '<html><body><section ${semantic.value}>Notes.</section></body></html>',
        );

        expect(
          FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
          isTrue,
        );
      });
    }

    test('keeps an oversized individual footnote in its own batch', () {
      final List<FootnoteTranslationBatch> batches = planner.plan(
        chapters: <InspectedChapter>[
          _chapter(path: 'notes/ch01-fn.xhtml', title: 'Notes'),
          _chapter(path: 'notes/ch02-fn.xhtml', title: 'Notes'),
        ],
        pendingBlocksByChapter: <int, List<ExtractedBlock>>{
          0: <ExtractedBlock>[_block('p-1', textLength: 1000)],
          1: <ExtractedBlock>[_block('p-1')],
        },
        chunkSize: 300,
      );

      expect(batches, hasLength(2));
      expect(batches[0].references.single.requestId, 'f0:p-1');
      expect(batches[1].references.single.requestId, 'f1:p-1');
    });
  });
}

InspectedChapter _chapter({
  required String path,
  required String title,
  String originalHtml = '<html><body></body></html>',
}) {
  return InspectedChapter(
    path: path,
    title: title,
    body: '',
    originalHtml: originalHtml,
    blocks: const <ExtractedBlock>[],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );
}

ExtractedBlock _block(String id, {int textLength = 20}) {
  final String text = List<String>.filled(textLength, 'a').join();
  return ExtractedBlock(
    id: id,
    tagName: 'p',
    sourceHtml: '<p>$text</p>',
    sourceText: text,
  );
}
