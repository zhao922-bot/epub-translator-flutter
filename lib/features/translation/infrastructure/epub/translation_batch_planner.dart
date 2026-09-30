import 'dart:convert';
import 'dart:math';

import '../../domain/models/inspected_chapter.dart';

/// Plans block batches and neighboring read-only context for API calls.
class TranslationBatchPlanner {
  const TranslationBatchPlanner({
    this.contextBeforeBlockCount = 2,
    this.contextAfterBlockCount = 1,
    this.contextTextLimit = 240,
    this.tinyBlockTextThreshold = 80,
    this.tinyBlockHtmlThreshold = 360,
    this.tinyBlockBudget = 48,
  });

  final int contextBeforeBlockCount;
  final int contextAfterBlockCount;
  final int contextTextLimit;
  final int tinyBlockTextThreshold;
  final int tinyBlockHtmlThreshold;
  final int tinyBlockBudget;

  List<TranslationBlockBatch> plan({
    required List<ExtractedBlock> pendingBlocks,
    required int chunkSize,
    List<ExtractedBlock> chapterBlocks = const <ExtractedBlock>[],
    String chapterTitle = '',
    Map<String, Object?>? bookMemory,
  }) {
    final List<TranslationBlockBatch> batches = <TranslationBlockBatch>[];
    List<ExtractedBlock> current = <ExtractedBlock>[];
    int currentBudget = 0;
    final int safeChunkSize = max(1, chunkSize);
    // The read-only context appended to every batch (chapter title,
    // bookMemory summary, before/after snippets) shares the request window
    // with the blocks, so it must come out of the same budget. The title
    // and bookMemory parts are identical for every batch; the snippet part
    // depends on the batch's position within the chapter and is tracked
    // incrementally below (mirroring buildContext's index ranges).
    // The fixed JSON envelope (~100 chars of keys plus the read-only
    // instruction line) is intentionally not counted separately:
    // blockBudgetFor already pads every block by 96 chars, which absorbs
    // it.
    final int fixedContextOverhead =
        chapterTitle.length + _serializedJsonSize(bookMemory);
    final Map<String, int> indexById = <String, int>{
      for (int index = 0; index < chapterBlocks.length; index += 1)
        chapterBlocks[index].id: index,
    };
    int? currentMinIndex;
    int? currentMaxIndex;

    void emitBatch() {
      batches.add(
        createBatch(
          current,
          chapterBlocks: chapterBlocks,
          chapterTitle: chapterTitle,
          bookMemory: bookMemory,
        ),
      );
      current = <ExtractedBlock>[];
      currentBudget = 0;
      currentMinIndex = null;
      currentMaxIndex = null;
    }

    for (final ExtractedBlock block in pendingBlocks) {
      final int blockBudget = blockBudgetFor(block);
      final int? blockIndex = indexById[block.id];
      // Snippet ranges for the batch if `block` joins it (mirrors
      // buildContext: min/max over the batch blocks' chapter indexes).
      final int? candidateMin = blockIndex == null
          ? currentMinIndex
          : (currentMinIndex == null
                ? blockIndex
                : min(currentMinIndex!, blockIndex));
      final int? candidateMax = blockIndex == null
          ? currentMaxIndex
          : (currentMaxIndex == null
                ? blockIndex
                : max(currentMaxIndex!, blockIndex));
      final int candidateSnippetOverhead =
          candidateMin == null || candidateMax == null
          ? 0
          : _snippetOverheadFor(chapterBlocks, candidateMin, candidateMax);
      final bool exceedsCurrent =
          current.isNotEmpty &&
          currentBudget +
                  blockBudget +
                  fixedContextOverhead +
                  candidateSnippetOverhead >
              safeChunkSize;
      if (exceedsCurrent) {
        emitBatch();
        currentMinIndex = blockIndex;
        currentMaxIndex = blockIndex;
      } else {
        currentMinIndex = candidateMin;
        currentMaxIndex = candidateMax;
      }
      current.add(block);
      currentBudget += blockBudget;
    }

    if (current.isNotEmpty) {
      emitBatch();
    }
    return batches;
  }

  /// Char estimate of the before/after read-only snippets for a batch
  /// spanning chapter indexes [firstIndex, lastIndex] (inclusive).
  /// Mirrors [buildContext]'s ranges: at most [contextBeforeBlockCount]
  /// snippets before and [contextAfterBlockCount] after the batch.
  int _snippetOverheadFor(
    List<ExtractedBlock> chapterBlocks,
    int firstIndex,
    int lastIndex,
  ) {
    final int beforeStart = max(0, firstIndex - contextBeforeBlockCount);
    final int afterEnd = min(
      chapterBlocks.length,
      lastIndex + 1 + contextAfterBlockCount,
    );
    int total = 0;
    for (int i = beforeStart; i < firstIndex; i++) {
      total += _snippetChars(chapterBlocks[i]);
    }
    for (int i = lastIndex + 1; i < afterEnd; i++) {
      total += _snippetChars(chapterBlocks[i]);
    }
    return total;
  }

  /// Char estimate of one read-only snippet: trimmed text plus its id and
  /// a small allowance for JSON framing. Snippets with empty text are
  /// dropped by [contextSnippets], so they cost nothing here either.
  int _snippetChars(ExtractedBlock block) {
    final String text = trimContextText(block.sourceText);
    if (text.isEmpty) {
      return 0;
    }
    return text.length + block.id.length + 24;
  }

  /// Serialized size of the bookMemory summary, as it will appear in the
  /// request payload's context object.
  int _serializedJsonSize(Map<String, Object?>? value) {
    if (value == null || value.isEmpty) {
      return 0;
    }
    return jsonEncode(value).length;
  }

  /// Test-friendly plan maps used by repository safety tests.
  List<Map<String, Object?>> planForTest({
    required String chapterTitle,
    required int chunkSize,
    required List<ExtractedBlock> pendingBlocks,
    required List<ExtractedBlock> chapterBlocks,
  }) {
    return plan(
          pendingBlocks: pendingBlocks,
          chunkSize: chunkSize,
          chapterBlocks: chapterBlocks,
          chapterTitle: chapterTitle,
        )
        .map((TranslationBlockBatch batch) => batch.toPlanForTest())
        .toList(growable: false);
  }

  TranslationBlockBatch createBatch(
    List<ExtractedBlock> blocks, {
    required List<ExtractedBlock> chapterBlocks,
    required String chapterTitle,
    Map<String, Object?>? bookMemory,
  }) {
    final List<ExtractedBlock> immutableBlocks =
        List<ExtractedBlock>.unmodifiable(blocks);
    return TranslationBlockBatch(
      immutableBlocks,
      context: buildContext(
        chapterTitle: chapterTitle,
        batchBlocks: immutableBlocks,
        chapterBlocks: chapterBlocks,
        bookMemory: bookMemory,
      ),
    );
  }

  int blockBudgetFor(ExtractedBlock block) {
    if (isTinyTextBlock(block)) {
      return max(tinyBlockBudget, block.sourceText.length + 24);
    }
    return max(block.sourceHtml.length, block.sourceText.length) + 96;
  }

  bool isTinyTextBlock(ExtractedBlock block) {
    return block.sourceText.length <= tinyBlockTextThreshold &&
        block.sourceHtml.length <= tinyBlockHtmlThreshold;
  }

  TranslationBatchContext buildContext({
    required String chapterTitle,
    required List<ExtractedBlock> batchBlocks,
    required List<ExtractedBlock> chapterBlocks,
    Map<String, Object?>? bookMemory,
  }) {
    if (batchBlocks.isEmpty || chapterBlocks.isEmpty) {
      return TranslationBatchContext(
        chapterTitle: chapterTitle,
        bookMemory: bookMemory,
      );
    }

    final Map<String, int> indexById = <String, int>{
      for (int index = 0; index < chapterBlocks.length; index += 1)
        chapterBlocks[index].id: index,
    };
    final List<int> indexes = batchBlocks
        .map((ExtractedBlock block) => indexById[block.id])
        .whereType<int>()
        .toList(growable: false);
    if (indexes.isEmpty) {
      return TranslationBatchContext(
        chapterTitle: chapterTitle,
        bookMemory: bookMemory,
      );
    }

    final int firstIndex = indexes.reduce(min);
    final int lastIndex = indexes.reduce(max);
    final int beforeStart = max(0, firstIndex - contextBeforeBlockCount);
    final int afterEnd = min(
      chapterBlocks.length,
      lastIndex + 1 + contextAfterBlockCount,
    );

    return TranslationBatchContext(
      chapterTitle: chapterTitle,
      before: contextSnippets(chapterBlocks.sublist(beforeStart, firstIndex)),
      after: contextSnippets(chapterBlocks.sublist(lastIndex + 1, afterEnd)),
      bookMemory: bookMemory,
    );
  }

  List<TranslationContextSnippet> contextSnippets(List<ExtractedBlock> blocks) {
    return blocks
        .map(
          (ExtractedBlock block) => TranslationContextSnippet(
            id: block.id,
            text: trimContextText(block.sourceText),
          ),
        )
        .where((TranslationContextSnippet snippet) => snippet.text.isNotEmpty)
        .toList(growable: false);
  }

  String trimContextText(String value) {
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= contextTextLimit) {
      return collapsed;
    }
    return '${collapsed.substring(0, contextTextLimit - 3)}...';
  }
}

class TranslationBlockBatch {
  const TranslationBlockBatch(
    this.blocks, {
    this.context = const TranslationBatchContext(),
  });

  final List<ExtractedBlock> blocks;
  final TranslationBatchContext context;

  Map<String, Object?> toPlanForTest() {
    return <String, Object?>{
      'ids': blocks
          .map((ExtractedBlock block) => block.id)
          .toList(growable: false),
      'before': context.before
          .map((TranslationContextSnippet snippet) => snippet.toJson())
          .toList(growable: false),
      'after': context.after
          .map((TranslationContextSnippet snippet) => snippet.toJson())
          .toList(growable: false),
    };
  }
}

class TranslationBatchContext {
  const TranslationBatchContext({
    this.chapterTitle = '',
    this.before = const <TranslationContextSnippet>[],
    this.after = const <TranslationContextSnippet>[],
    this.bookMemory,
  });

  final String chapterTitle;
  final List<TranslationContextSnippet> before;
  final List<TranslationContextSnippet> after;
  final Map<String, Object?>? bookMemory;

  bool get isEmpty =>
      chapterTitle.trim().isEmpty &&
      before.isEmpty &&
      after.isEmpty &&
      (bookMemory == null || bookMemory!.isEmpty);

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (chapterTitle.trim().isNotEmpty) 'chapterTitle': chapterTitle.trim(),
      'before': before
          .map((TranslationContextSnippet snippet) => snippet.toJson())
          .toList(growable: false),
      'after': after
          .map((TranslationContextSnippet snippet) => snippet.toJson())
          .toList(growable: false),
      if (bookMemory != null && bookMemory!.isNotEmpty)
        'bookMemory': bookMemory,
      'instruction': 'Read-only context for continuity; translate only blocks.',
    };
  }
}

class TranslationContextSnippet {
  const TranslationContextSnippet({required this.id, required this.text});

  final String id;
  final String text;

  Map<String, String> toJson() {
    return <String, String>{'id': id, 'text': text};
  }
}
