import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

const _planner = TranslationBatchPlanner();

ExtractedBlock _block(String id, String text, {String? html}) => ExtractedBlock(
  id: id,
  tagName: 'p',
  sourceHtml: html ?? '<p>$text</p>',
  sourceText: text,
);

void main() {
  test(
    'simple requests send only matched mappings without duplicating style',
    () {
      final paragraph = _block('body', 'North–Bank funds a blue harbour.');
      const style = {
        'tone': 'Direct prose',
        'translationConstraints': ['Keep quoted facts.'],
        'confidence': 'high',
      };
      const memory = {
        'styleProfile': style,
        'styleProfileConfirmed': true,
        'styleGuide': ['Direct prose.', 'Keep quoted facts', 'Keep units.'],
        'bookSummary': 'Wide context for the rest of the book.',
        'glossary': [
          {'source': 'North Bank', 'target': 'Outdated lock', 'locked': 'true'},
          {'source': 'North-Bank', 'target': 'Automatic conflict'},
          {'source': 'blue harbour', 'target': '港湾', 'lastUsed': '9'},
          {'source': 'Red Hill', 'target': 'Unused target'},
        ],
        'recentChapters': [
          {
            'title': 'Earlier chapter',
            'summary': 'Earlier events.',
            'glossary': [
              {'source': 'BLUE HARBOUR', 'target': 'Outdated duplicate'},
              {'source': 'Harper', 'target': '哈珀'},
            ],
          },
        ],
      };
      final chapter = [
        _block('outside', 'Red Hill is far from this batch.'),
        _block('other', 'Autumn rain began.'),
        _block('prior', 'Harper took a seat.'),
        paragraph,
      ];
      final batch = _planner.createBatch(
        [paragraph],
        chapterBlocks: chapter,
        chapterTitle: 'Chapter 4',
        bookMemory: memory,
        tokenSavingMode: true,
        lockedGlossary: 'North Bank => 北岸\nRiver => 河\nNORTH-BANK → 北行',
      );
      final context = batch.context;
      expect(context.usesSelectiveContext, isTrue);
      expect(context.needsContinuity, isFalse);
      expect(context.bookMemory!['styleProfile'], style);
      expect(context.bookMemory!['styleProfileConfirmed'], isTrue);
      expect(context.toJson(), {
        'chapterTitle': 'Chapter 4',
        'lockedGlossary': [
          {'source': 'NORTH-BANK', 'target': '北行'},
        ],
        'bookMemory': {
          'styleGuide': ['Keep units.'],
          'glossary': [
            {'source': 'blue harbour', 'target': '港湾'},
            {'source': 'Harper', 'target': '哈珀'},
          ],
        },
      });
      final legacy = _planner.createBatch(
        [paragraph],
        chapterBlocks: chapter,
        chapterTitle: 'Chapter 4',
        bookMemory: memory,
      );
      expect(legacy.context.usesSelectiveContext, isFalse);
      expect(legacy.context.before.map((snippet) => snippet.id), [
        'other',
        'prior',
      ]);
      expect(legacy.context.bookMemory, memory);
      expect(
        utf8.encode(jsonEncode(context.toJson())).length,
        lessThan(utf8.encode(jsonEncode(legacy.context.toJson())).length ~/ 2),
      );
    },
  );

  test(
    'term boundaries, punctuation, aliases, and inflections preserve locks',
    () {
      final paragraph = _block(
        'p',
        "ÉLODIE、北京大学の李白、НОВЫЙ МОСТ; O’Neill’s drakes reached several cities. "
            'Culture showed a cafe\u0301 and cities held a city council session. '
            'Running children crossed the artful blacksmith’s workshop.',
      );
      final context = _planner.buildContext(
        chapterTitle: '',
        batchBlocks: [paragraph],
        chapterBlocks: [],
        tokenSavingMode: true,
        lockedGlossary: '''
Élodie => 埃洛迪
北京大学 => Peking University
李白 => Li Bai
новый мост => New Bridge
O'Neill => 奥尼尔
dragon / drake => 龙
city = 城市
café：咖啡馆
run => 跑
child => 孩子
art => 艺术
smith => 史密斯
Li => 李
''',
        bookMemory: const {
          'glossary': [
            {'source': 'cities', 'target': 'Conflicting plural'},
            {'source': 'city council', 'target': '市议会'},
            {'source': 'cafe', 'target': 'Accent-free partial match'},
            {'source': 'bridge', 'target': 'English only'},
          ],
        },
      );
      expect(context.lockedGlossary.map((term) => term['source']), [
        'Élodie',
        '北京大学',
        '李白',
        'новый мост',
        "O'Neill",
        'drake',
        'city',
        'cafe\u0301',
        'run',
        'child',
      ]);
      expect((context.toJson()['bookMemory'] as Map)['glossary'], [
        {'source': 'city council', 'target': '市议会'},
      ]);
    },
  );

  test('configured sources override legacy checkpoint separator guesses', () {
    final paragraph = _block('p', 'Gate: north stood open. 北京Ace回來了。ВBlade.');
    final context = _planner.selectRequestContext(
      context: const TranslationBatchContext(
        bookMemory: {
          'glossary': [
            {'source': 'Gate', 'target': 'north => 北门', 'locked': 'true'},
          ],
        },
      ),
      batchBlocks: [paragraph],
      lockedGlossary: 'Gate: north => 北门\nAce => 艾斯\nBlade => 刀锋',
    );
    expect(context.lockedGlossary, [
      {'source': 'Gate: north', 'target': '北门'},
      {'source': 'Ace', 'target': '艾斯'},
    ]);
  });

  test(
    'only adjacent gap text survives in sparse repair and remains read-only',
    () {
      final first = _block('failed-1', 'She opened the window.');
      final second = _block('failed-2', '‘Look at this,’ he whispered.');
      final chapter = [
        _block('unrelated', 'The Obsidian Palace stands far away.'),
        _block('boundary', 'The storm cleared.'),
        _block(
          'first-speaker',
          '${'Unrelated detail. ' * 24} Mara was there. 🧭',
        ),
        first,
        _block('gap', 'Otto stayed by the window.'),
        _block('second-speaker', 'Marcel pointed across the street.'),
        second,
        _block('next', 'The crowd left. 🧭${'Afterwards. ' * 24}'),
      ];
      const locks =
          'Mara => 玛拉\nOtto => 奥托\nMarcel => 马塞尔\nObsidian Palace => 黑曜宫';
      final previous = _planner.createBatch(
        chapter,
        chapterBlocks: chapter,
        chapterTitle: 'A Storm',
        tokenSavingMode: true,
        lockedGlossary: locks,
        bookMemory: const {
          'bookSummary': 'An earlier event.',
          'recentChapters': [
            {'summary': 'Earlier mystery.', 'path': 'text/early.xhtml'},
          ],
        },
      );
      expect(previous.context.lockedGlossary, hasLength(4));
      final repair = _planner.selectRequestContext(
        context: previous.context,
        batchBlocks: [first, second],
        chapterBlocks: previous.sourceOrder,
        indexById: previous.sourceIndexById,
        compact: true,
      );
      expect(repair.needsContinuity, isTrue);
      expect(repair.before.map((snippet) => snippet.id), [
        'boundary',
        'first-speaker',
        'gap',
        'second-speaker',
      ]);
      expect(repair.after.single.id, 'next');
      expect(repair.before[1].text, endsWith('Mara was there. 🧭'));
      expect(repair.after.single.text, startsWith('The crowd left. 🧭'));
      expect(repair.before[1].text.length, lessThanOrEqualTo(96));
      expect(repair.bookMemory, isNull);
      expect(repair.lockedGlossary.map((term) => term['source']), [
        'Mara',
        'Otto',
        'Marcel',
      ]);
      expect(jsonEncode(repair.toJson()), isNot(contains('Obsidian Palace')));
    },
  );

  test(
    'attached note retains explicit context, decoding visible HTML only',
    () {
      const source = TranslationBatchContext(
        before: [
          TranslationContextSnippet(
            id: 'main.xhtml:paragraph-16',
            text: 'The footnote refers to the Ashford lease.',
          ),
        ],
      );
      final note = _block(
        'note-1',
        '',
        html: '<p title="Hidden jargon"><em>Act&nbsp;II</em> applies.</p>',
      );
      final context = _planner.selectRequestContext(
        context: source,
        batchBlocks: [note],
        lockedGlossary: '''
Ashford lease => 阿什福德租约
Act II => 第二法案
Hidden jargon => 不应发送
Keep dates intact.
Keep dates intact.
''',
      );
      expect(context.needsContinuity, isTrue);
      expect(context.before.single.toJson(), source.before.single.toJson());
      expect(context.lockedGlossary.map((term) => term['source']), [
        'Ashford lease',
        'Act II',
      ]);
      expect(context.lockedGlossaryNotes, ['Keep dates intact.']);
    },
  );

  test('nested markup retains continuity without re-sending glossary rows', () {
    final first = _block('before', 'The hearing resumed.');
    final second = _block(
      'markup',
      'Silence followed.',
      html: '<p><em>Silence</em> followed.</p>',
    );
    final context = _planner.buildContext(
      chapterTitle: '',
      batchBlocks: [second],
      chapterBlocks: [first, second],
      tokenSavingMode: true,
      bookMemory: const {
        'bookSummary': 'A witness disappeared.',
        'glossary': [
          {'source': 'hearing', 'target': '听证会'},
        ],
        'recentChapters': [
          {
            'title': 'Witnesses',
            'path': 'text/previous.xhtml',
            'continuityNotes': ['The judge spoke first.'],
            'glossary': [
              {'source': 'hearing', 'target': '审理'},
            ],
          },
        ],
      },
    );
    expect(context.needsContinuity, isTrue);
    expect(context.before.single.id, 'before');
    expect(context.toJson()['bookMemory'], {
      'glossary': [
        {'source': 'hearing', 'target': '听证会'},
      ],
      'bookSummary': 'A witness disappeared.',
      'recentChapters': [
        {
          'title': 'Witnesses',
          'continuityNotes': ['The judge spoke first.'],
        },
      ],
    });
  });
}
