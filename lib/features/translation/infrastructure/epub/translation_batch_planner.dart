import 'dart:convert';
import 'dart:math';

import '../../../../shared/logging/app_logger.dart';
import '../../domain/models/inspected_chapter.dart';

/// Plans block batches and neighboring read-only context for API calls.
class TranslationBatchPlanner {
  const TranslationBatchPlanner({
    int contextBeforeBlockCount = 2,
    int contextAfterBlockCount = 1,
    int contextTextLimit = 240,
    int tinyBlockTextThreshold = 80,
    int tinyBlockHtmlThreshold = 360,
    int tinyBlockBudget = 48,
  // Keep the public named parameters and private raw storage for const callers.
  // ignore: prefer_initializing_formals
  }) : _contextBeforeBlockCount = contextBeforeBlockCount,
       // ignore: prefer_initializing_formals
       _contextAfterBlockCount = contextAfterBlockCount,
       // ignore: prefer_initializing_formals
       _contextTextLimit = contextTextLimit,
       // ignore: prefer_initializing_formals
       _tinyBlockTextThreshold = tinyBlockTextThreshold,
       // ignore: prefer_initializing_formals
       _tinyBlockHtmlThreshold = tinyBlockHtmlThreshold,
       // ignore: prefer_initializing_formals
       _tinyBlockBudget = tinyBlockBudget;

  // chunkSize is a character budget, not a block count. Existing callers use
  // 1 (single blocks) through 100000 (large-batch throughput tests).
  static const int minChunkSize = 1;
  static const int maxChunkSize = 100000;
  static const int defaultChunkSize = 3000;
  static const int minContextCount = 0;
  static const int maxContextCount = 16;
  static const int minContextTextLimit = 3;
  static const int maxContextTextLimit = 4096;
  static const int minTinyThreshold = 0;
  static const int maxTinyThreshold = 16384;
  static const int minTinyBudget = 1;
  static const int maxTinyBudget = 16384;

  final int _contextBeforeBlockCount;
  final int _contextAfterBlockCount;
  final int _contextTextLimit;
  final int _tinyBlockTextThreshold;
  final int _tinyBlockHtmlThreshold;
  final int _tinyBlockBudget;

  // Lazy normalization preserves const callers while making every public
  // operation safe (including direct buildContext/trimContextText calls).
  static final Expando<Set<String>> _warned = Expando<Set<String>>();
  int _bounded(String name, int value, int low, int high, int fallback) {
    if (value >= low && value <= high) return value;
    final warned = _warned[this] ??= <String>{};
    if (warned.add(name)) {
      AppLogger.warn('Invalid $name=$value; using $fallback (range $low..$high).', tag: 'batch-planner');
    }
    return fallback;
  }

  int get contextBeforeBlockCount => _bounded('contextBeforeBlockCount', _contextBeforeBlockCount, minContextCount, maxContextCount, 2);
  int get contextAfterBlockCount => _bounded('contextAfterBlockCount', _contextAfterBlockCount, minContextCount, maxContextCount, 1);
  int get contextTextLimit => _bounded('contextTextLimit', _contextTextLimit, minContextTextLimit, maxContextTextLimit, 240);
  int get tinyBlockTextThreshold => _bounded('tinyBlockTextThreshold', _tinyBlockTextThreshold, minTinyThreshold, maxTinyThreshold, 80);
  int get tinyBlockHtmlThreshold => _bounded('tinyBlockHtmlThreshold', _tinyBlockHtmlThreshold, minTinyThreshold, maxTinyThreshold, 360);
  int get tinyBlockBudget => _bounded('tinyBlockBudget', _tinyBlockBudget, minTinyBudget, maxTinyBudget, 48);

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
    final int safeChunkSize = _bounded('chunkSize:$chunkSize', chunkSize, minChunkSize, maxChunkSize, defaultChunkSize);
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
          indexById: indexById,
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
  int _serializedJsonSize(Map<String, Object?>? value) =>
      serializedJsonSize(value);

  /// Public form of [_serializedJsonSize] for planners that share the
  /// request window (e.g. the footnote planner): the shared context must
  /// come out of the same per-batch budget (性能-#41).
  static int serializedJsonSize(Map<String, Object?>? value) {
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
    Map<String, int>? indexById,
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
        indexById: indexById,
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
    Map<String, int>? indexById,
  }) {
    if (batchBlocks.isEmpty || chapterBlocks.isEmpty) {
      return TranslationBatchContext(
        chapterTitle: chapterTitle,
        bookMemory: bookMemory,
      );
    }

    final Map<String, int> chapterIndex =
        indexById ??
        <String, int>{
          for (int index = 0; index < chapterBlocks.length; index += 1)
            chapterBlocks[index].id: index,
        };
    final List<int> indexes = batchBlocks
        .map((ExtractedBlock block) => chapterIndex[block.id])
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
