import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('samples preface plus early, middle and late content', () {
    final List<InspectedChapter> chapters = <InspectedChapter>[
      _chapter(
        path: 'book_prf_r1.htm',
        title: 'Preface',
        category: ChapterCategory.frontMatter,
        prefix: 'preface',
        blockCount: 9,
      ),
      _chapter(
        path: 'book_c01_r1.htm',
        title: 'Chapter 1',
        category: ChapterCategory.content,
        prefix: 'early',
      ),
      _chapter(
        path: 'book_c02_r1.htm',
        title: 'Chapter 2',
        category: ChapterCategory.content,
        prefix: 'second',
      ),
      _chapter(
        path: 'book_c03_r1.htm',
        title: 'Chapter 3',
        category: ChapterCategory.content,
        prefix: 'middle',
      ),
      _chapter(
        path: 'book_c04_r1.htm',
        title: 'Chapter 4',
        category: ChapterCategory.content,
        prefix: 'fourth',
      ),
      _chapter(
        path: 'book_c05_r1.htm',
        title: 'Chapter 5',
        category: ChapterCategory.content,
        prefix: 'late',
      ),
      _chapter(
        path: 'book_ind_r1.htm',
        title: 'Index',
        category: ChapterCategory.content,
        prefix: 'index',
        blockCount: 100,
      ),
    ];

    final List<Map<String, String>> samples =
        EpubChapterTranslator.styleProfileSourceChaptersForTest(chapters);

    expect(
      samples.map((Map<String, String> item) => item['title']).toList(),
      <String>['Preface', 'Chapter 1', 'Chapter 3', 'Chapter 5'],
    );
    expect(
      samples.map((Map<String, String> item) => item['role']).toList(),
      <String>['frontMatter', 'earlyContent', 'middleContent', 'lateContent'],
    );
    expect(samples.any((item) => item['title'] == 'Index'), isFalse);
  });

  test('long chapters sample opening, middle and ending blocks', () {
    final List<Map<String, String>> samples =
        EpubChapterTranslator.styleProfileSourceChaptersForTest(
          <InspectedChapter>[
            _chapter(
              path: 'chapter.xhtml',
              title: 'Representative chapter',
              category: ChapterCategory.content,
              prefix: 'block',
              blockCount: 20,
            ),
          ],
        );

    final String text = samples.single['text']!;
    expect(text, contains('[Opening]'));
    expect(text, contains('block-0'));
    expect(text, contains('[Middle]'));
    expect(text, contains('block-8'));
    expect(text, contains('[Ending]'));
    expect(text, contains('block-19'));
  });
}

InspectedChapter _chapter({
  required String path,
  required String title,
  required ChapterCategory category,
  required String prefix,
  int blockCount = 20,
}) {
  return InspectedChapter(
    path: path,
    title: title,
    body: '',
    originalHtml: '',
    blocks: List<ExtractedBlock>.generate(
      blockCount,
      (int index) => ExtractedBlock(
        id: 'p-$index',
        tagName: 'p',
        sourceHtml: '<p>$prefix-$index representative prose</p>',
        sourceText: '$prefix-$index representative prose',
      ),
    ),
    category: category,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );
}
