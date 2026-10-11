import 'dart:collection';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedBlock block(String id, [String? text]) => ExtractedBlock(
  id: id,
  tagName: 'p',
  sourceHtml: '<p>${text ?? id}</p>',
  sourceText: text ?? id,
);

class CountingBlocks extends ListBase<ExtractedBlock> {
  CountingBlocks(this.blocks);
  final List<ExtractedBlock> blocks;
  int reads = 0;
  @override
  int get length => blocks.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  ExtractedBlock operator [](int index) {
    reads++;
    return blocks[index];
  }

  @override
  void operator []=(int index, ExtractedBlock value) =>
      throw UnsupportedError('read only');
}

void main() {
  test('many batches read chapter blocks linearly and preserve context', () {
    final blocks = List.generate(1000, (i) => block('b$i'));
    final chapter = CountingBlocks(blocks);
    const planner = TranslationBatchPlanner();
    final batches = planner.plan(
      pendingBlocks: blocks,
      chapterBlocks: chapter,
      chunkSize: 1,
      chapterTitle: 'Chapter',
      bookMemory: {'summary': 'Memory'},
    );
    expect(batches, hasLength(1000));
    expect(
      chapter.reads,
      lessThan(10000),
      reason: 'one chapter index plus bounded neighboring snippets per batch',
    );
    for (int i = 0; i < blocks.length; i++) {
      final expected = planner.buildContext(
        chapterTitle: 'Chapter',
        batchBlocks: [blocks[i]],
        chapterBlocks: blocks,
        bookMemory: {'summary': 'Memory'},
      );
      expect(batches[i].context.toJson(), expected.toJson());
    }
  });

  test('sparse, unordered, duplicate and unknown IDs preserve context', () {
    final chapter = [
      block('a'),
      block('duplicate'),
      block('empty', '  '),
      block('c'),
      block('duplicate'),
      block('last'),
    ];
    final pending = [chapter[4], chapter[0], block('unknown')];
    const planner = TranslationBatchPlanner();
    final batches = planner.plan(
      pendingBlocks: pending,
      chapterBlocks: chapter,
      chunkSize: 10000,
    );
    final batch = batches.single;
    final expected = planner.buildContext(
      chapterTitle: '',
      batchBlocks: pending,
      chapterBlocks: chapter,
    );
    expect(batch.context.toJson(), expected.toJson());
    expect(batch.context.after.single.id, 'last');
    final unknown = planner.createBatch(
      [block('unknown')],
      chapterBlocks: chapter,
      chapterTitle: 'Title',
    );
    expect(unknown.context.before, isEmpty);
    expect(
      planner.plan(pendingBlocks: [], chapterBlocks: chapter, chunkSize: 1),
      isEmpty,
    );
  });
}
