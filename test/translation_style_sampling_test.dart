import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eligibility stops at the first oversized block', () {
    final blocks = List<_CountingBlock>.generate(
      100,
      (_) => _CountingBlock('prose ' * 100000),
    );
    expect(
      EpubChapterTranslator.hasRepresentativeStyleTextForTest(blocks),
      isTrue,
    );
    expect(blocks.first.reads, lessThanOrEqualTo(2));
    expect(blocks.skip(1).every((block) => block.reads == 0), isTrue);
  });

  test('bounded sampling matches the previous sampler exactly', () {
    for (final values in <List<String>>[
      ['\u0085 prose \u0085', '\uFEFF text \uFEFF', '\u00a0more\u00a0'],
      [for (int i = 0; i < 20; i++) i == 5 ? 'x' * 100000 : 'a'],
      [for (int i = 0; i < 13; i++) i == 0 ? 'x' * 800 : 'b'],
    ]) {
      final chapter = _chapter(
        path: 'edge.xhtml',
        title: 'Edge',
        category: ChapterCategory.content,
        prefix: '',
      ).copyWith(blocks: values.map(_CountingBlock.new).toList());
      expect(
        EpubChapterTranslator.styleProfileSourceChaptersForTest([
          chapter,
        ]).single['text'],
        _legacySample(chapter.blocks),
      );
      expect(
        EpubChapterTranslator.hasRepresentativeStyleTextForTest(chapter.blocks),
        _legacySample(chapter.blocks).length >= 240,
      );
    }
    for (final count in [1, 12, 13, 20]) {
      for (final size in [10, 239, 240, 800, 2400, 100000]) {
        final chapter =
            _chapter(
              path: 'chapter.xhtml',
              title: 'Chapter',
              category: ChapterCategory.content,
              prefix: 'text',
            ).copyWith(
              blocks: List.generate(
                count,
                (i) => ExtractedBlock(
                  id: '$i',
                  tagName: 'p',
                  sourceHtml: '',
                  sourceText: i % 5 == 3
                      ? ' \n\t '
                      : ' \t$i ${'word\n\t ' * size} end  ',
                ),
              ),
            );
        final samples = EpubChapterTranslator.styleProfileSourceChaptersForTest(
          [chapter],
        );
        expect(
          samples.single['text'],
          _legacySample(chapter.blocks),
          reason: 'count=$count size=$size',
        );
        expect(
          EpubChapterTranslator.hasRepresentativeStyleTextForTest(
            chapter.blocks,
          ),
          _legacySample(chapter.blocks).length >= 240,
        );
      }
    }
    for (final length in [239, 240, 799, 800, 801, 2399, 2400, 2401]) {
      final chapter = _chapter(
        path: 'boundary.xhtml',
        title: 'Boundary',
        category: ChapterCategory.content,
        prefix: '',
      ).copyWith(blocks: [_CountingBlock('x' * length)]);
      expect(
        EpubChapterTranslator.styleProfileSourceChaptersForTest([
          chapter,
        ]).single['text'],
        _legacySample(chapter.blocks),
      );
      expect(
        EpubChapterTranslator.hasRepresentativeStyleTextForTest(chapter.blocks),
        length >= 240,
      );
    }
  });
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

  test('excludes EPUB navigation, footnotes, and promotional matter', () {
    final List<InspectedChapter> chapters = <InspectedChapter>[
      _chapter(
        path: 'Introduction.xhtml',
        title: 'Introduction',
        category: ChapterCategory.frontMatter,
        prefix: 'introduction',
        blockCount: 30,
      ),
      _chapter(
        path: 'nav.xhtml',
        title: 'Communion',
        category: ChapterCategory.content,
        prefix: 'navigation',
        blockCount: 100,
      ),
      for (int number = 1; number <= 12; number += 1)
        _chapter(
          path: 'Chapter_$number.xhtml',
          title: 'Chapter $number',
          category: ChapterCategory.content,
          prefix: 'chapter-$number',
          blockCount: 30,
        ),
      _chapter(
        path: 'About_the_Publisher.xhtml',
        title: 'About the Publisher',
        category: ChapterCategory.content,
        prefix: 'publisher',
        blockCount: 30,
      ),
      _chapter(
        path: '9780063575059_Chapter_22_2-fn.xhtml',
        title: 'Footnote',
        category: ChapterCategory.content,
        prefix: 'footnote',
        blockCount: 1,
      ),
    ];

    final List<Map<String, String>> samples =
        EpubChapterTranslator.styleProfileSourceChaptersForTest(chapters);

    expect(
      samples.map((Map<String, String> item) => item['title']).toList(),
      <String>['Introduction', 'Chapter 1', 'Chapter 7', 'Chapter 12'],
    );
  });

  test(
    'tiny trailing documents do not replace a representative late chapter',
    () {
      final List<InspectedChapter> chapters = <InspectedChapter>[
        for (int number = 1; number <= 5; number += 1)
          _chapter(
            path: 'chapter-$number.xhtml',
            title: 'Chapter $number',
            category: ChapterCategory.content,
            prefix: 'chapter-$number',
            blockCount: 30,
          ),
        _chapter(
          path: 'fragment.xhtml',
          title: 'Untitled',
          category: ChapterCategory.content,
          prefix: 'fragment',
          blockCount: 1,
        ),
      ];

      final List<Map<String, String>> samples =
          EpubChapterTranslator.styleProfileSourceChaptersForTest(chapters);

      expect(
        samples.map((Map<String, String> item) => item['title']).toList(),
        <String>['Chapter 1', 'Chapter 3', 'Chapter 5'],
      );
    },
  );
}

class _CountingBlock implements ExtractedBlock {
  _CountingBlock(this.text);
  final String text;
  int reads = 0;
  @override
  String get sourceText {
    reads++;
    return text;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _legacySample(List<ExtractedBlock> blocks) {
  final texts = blocks
      .map((b) => b.sourceText.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  String trim(List<String> values, int limit) {
    final text = values.join('\n').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= limit ? text : '${text.substring(0, limit - 3)}...';
  }

  if (texts.length <= 12) return trim(texts, 2400);
  return '[Opening]\n${trim(texts.take(4).toList(), 800)}\n[Middle]\n${trim(texts.skip((texts.length - 4) ~/ 2).take(4).toList(), 800)}\n[Ending]\n${trim(texts.skip(texts.length - 4).toList(), 800)}';
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
