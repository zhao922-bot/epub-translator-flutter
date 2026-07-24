import 'package:epub_translator_flutter/features/translation/domain/models/chapter_selection_preset.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<InspectedChapter> sample = <InspectedChapter>[
    InspectedChapter(
      path: 'c1.xhtml',
      title: 'Body',
      body: 'a',
      originalHtml: '',
      blocks: <ExtractedBlock>[
        ExtractedBlock(
          id: '1',
          tagName: 'p',
          sourceHtml: '<p>a</p>',
          sourceText: 'a',
        ),
      ],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: false,
    ),
    InspectedChapter(
      path: 'cover.xhtml',
      title: 'Cover',
      body: 'b',
      originalHtml: '',
      blocks: <ExtractedBlock>[
        ExtractedBlock(
          id: '2',
          tagName: 'p',
          sourceHtml: '<p>b</p>',
          sourceText: 'b',
        ),
      ],
      category: ChapterCategory.ancillary,
      recommendedForTranslation: false,
      includeInTranslation: true,
    ),
    InspectedChapter(
      path: 'empty.xhtml',
      title: 'Image-only page',
      body: '',
      originalHtml: '<html><body><img src="cover.jpg"/></body></html>',
      blocks: <ExtractedBlock>[],
      category: ChapterCategory.content,
      recommendedForTranslation: true,
      includeInTranslation: true,
    ),
  ];

  test('recommended preset restores heuristic defaults', () {
    final List<InspectedChapter> next = ChapterSelectionPreset.recommended
        .apply(sample);
    expect(next[0].includeInTranslation, isTrue);
    expect(next[1].includeInTranslation, isFalse);
    expect(next[2].includeInTranslation, isFalse);
  });

  test('content only selects content chapters', () {
    final List<InspectedChapter> next = ChapterSelectionPreset.contentOnly
        .apply(sample);
    expect(next[0].includeInTranslation, isTrue);
    expect(next[1].includeInTranslation, isFalse);
    expect(next[2].includeInTranslation, isFalse);
  });

  test('all and none work as expected', () {
    expect(
      ChapterSelectionPreset.allChapters
          .apply(sample)
          .map((c) => c.includeInTranslation)
          .toList(),
      <bool>[true, true, false],
    );
    expect(
      ChapterSelectionPreset.none
          .apply(sample)
          .every((c) => !c.includeInTranslation),
      isTrue,
    );
  });
}
