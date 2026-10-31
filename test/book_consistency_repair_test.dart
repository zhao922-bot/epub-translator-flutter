import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/book_consistency_repair.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/book_source_index.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_consistency_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InspectedChapter chapter({
    required List<ExtractedBlock> blocks,
    String path = 'OEBPS/chapter.xhtml',
  }) => InspectedChapter(
    path: path,
    title: 'The Yellow Wallpaper',
    body: '',
    originalHtml: '',
    blocks: blocks,
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );

  ExtractedBlock block({
    required String id,
    required String source,
    required String translated,
    String tag = 'p',
  }) => ExtractedBlock(
    id: id,
    tagName: tag,
    sourceHtml: '<$tag>$source</$tag>',
    sourceText: source,
    translatedHtml: '<$tag>$translated</$tag>',
  );

  final config = TranslationConfig.defaults().copyWith(
    targetLanguage: 'Chinese',
  );

  test('equivalent source titles reuse the translated body heading', () {
    final chapters = [
      chapter(
        blocks: [
          block(
            id: 'b1',
            tag: 'h1',
            source: 'The Yellow Wallpaper',
            translated: '《黄色墙纸》',
          ),
        ],
      ),
    ];
    expect(
      BookTitleConsistency.translatedBodyTitle(
        metadataTitle: 'The Yellow Wallpaper',
        chapters: chapters,
      ),
      '黄色墙纸',
    );
    expect(
      BookTitleConsistency.sourceTitlesEquivalent(
        'The Yellow Wallpaper',
        'Yellow Wallpaper!',
      ),
      isTrue,
    );
  });

  test('a distinct body heading does not override metadata title', () {
    final chapters = [
      chapter(
        blocks: [
          block(
            id: 'b1',
            tag: 'h1',
            source: 'A Note from the Publisher',
            translated: '出版者说明',
          ),
        ],
      ),
    ];
    expect(
      BookTitleConsistency.translatedBodyTitle(
        metadataTitle: 'Collected Stories',
        chapters: chapters,
      ),
      isNull,
    );
  });

  test('unqualified cousins use one neutral canonical form across blocks', () {
    final chapters = [
      chapter(
        blocks: [
          block(
            id: 'b1',
            source: 'We asked Cousin Henry and Julia to visit.',
            translated: '我们请<strong>堂兄亨利</strong>和朱莉娅来。',
          ),
          block(
            id: 'b2',
            source: 'I wanted to visit Cousin Henry and Cousin Julia.',
            translated: '我想去拜访亨利表哥和朱莉娅表姐。',
          ),
        ],
      ),
    ];
    final result = BookRelationshipConsistency.repairUnqualifiedCousins(
      chapters: chapters,
      config: config,
      glossary: const [
        {'source': 'Henry', 'target': '亨利'},
        {'source': 'Julia', 'target': '朱莉娅'},
      ],
    );
    final text = result.chapters.single.blocks
        .map(
          (block) => TranslationConsistencyChecker.text(block.translatedHtml!),
        )
        .join('\n');
    expect(text, contains('表亲亨利和表亲朱莉娅'));
    expect(text, contains('表亲亨利和表亲朱莉娅'));
    expect(text, isNot(matches(RegExp('堂兄|表哥|表姐'))));
    expect(result.corrections, hasLength(2));
    expect(
      result.chapters.single.blocks.first.translatedHtml,
      contains('<strong>表亲亨利</strong>'),
    );
  });

  test('indexed cousin evidence survives released block sources', () {
    final sourceChapter = chapter(
      blocks: [
        block(
          id: 'b1',
          source: 'We asked Cousin Henry and Julia to visit.',
          translated: '我们请堂兄亨利和朱莉娅来。',
        ),
        block(
          id: 'b2',
          source: 'I wanted to visit Cousin Henry and Cousin Julia.',
          translated: '我想去拜访亨利表哥和朱莉娅表姐。',
        ),
      ],
    );
    final sourceHints = BookSourceIndex.build([sourceChapter]);
    expect(sourceHints['cousinMentions'], hasLength(2));
    final releasedChapter = sourceChapter.copyWith(
      blocks: [
        for (final value in sourceChapter.blocks)
          value.copyWith(sourceHtml: '', sourceText: ''),
      ],
    );
    final result = BookRelationshipConsistency.repairUnqualifiedCousins(
      chapters: [releasedChapter],
      config: config,
      glossary: const [],
      sourceHints: sourceHints,
    );
    final text = TranslationConsistencyChecker.text(
      result.chapters.single.blocks.first.translatedHtml!,
    );
    expect(text, contains('表亲亨利'));
  });

  test('ambiguous target-name evidence leaves kinship text untouched', () {
    final sourceHints = {
      'cousinMentions': [
        {
          'chapter': 'OEBPS/chapter.xhtml',
          'id': 'b1',
          'names': ['Henry', 'Julia'],
          'explicitAge': false,
        },
        {
          'chapter': 'OEBPS/chapter.xhtml',
          'id': 'b2',
          'names': ['Henry', 'Julia'],
          'explicitAge': false,
        },
      ],
    };
    final chapters = [
      chapter(
        blocks: [
          block(id: 'b1', source: '', translated: '我们请堂兄亨利来。'),
          block(id: 'b2', source: '', translated: '堂兄亨利又来了。'),
        ],
      ),
    ];
    final result = BookRelationshipConsistency.repairUnqualifiedCousins(
      chapters: chapters,
      config: config,
      glossary: const [],
      sourceHints: sourceHints,
    );
    expect(result.corrections, isEmpty);
    expect(result.chapters.single, same(chapters.single));
  });

  test('explicit age evidence is preserved', () {
    final chapters = [
      chapter(
        blocks: [
          block(
            id: 'b1',
            source: 'Our older cousin Henry arrived.',
            translated: '我们的表哥亨利到了。',
          ),
        ],
      ),
    ];
    final result = BookRelationshipConsistency.repairUnqualifiedCousins(
      chapters: chapters,
      config: config,
      glossary: const [
        {'source': 'Henry', 'target': '亨利'},
      ],
    );
    expect(result.corrections, isEmpty);
    expect(
      TranslationConsistencyChecker.text(
        result.chapters.single.blocks.single.translatedHtml!,
      ),
      '我们的表哥亨利到了。',
    );
  });

  test('non-Chinese targets are left unchanged', () {
    final chapters = [
      chapter(
        blocks: [
          block(
            id: 'b1',
            source: 'Cousin Henry arrived.',
            translated: 'Cousin Henry arrived.',
          ),
        ],
      ),
    ];
    final result = BookRelationshipConsistency.repairUnqualifiedCousins(
      chapters: chapters,
      config: config.copyWith(targetLanguage: 'French'),
      glossary: const [
        {'source': 'Henry', 'target': 'Henri'},
      ],
    );
    expect(result.corrections, isEmpty);
    expect(result.chapters.single, same(chapters.single));
  });
}
