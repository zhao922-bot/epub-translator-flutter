import 'dart:math';

import '../../../../shared/localization/app_strings.dart';
import 'inspected_chapter.dart';
import 'translation_job.dart';

class TranslationRunEstimate {
  const TranslationRunEstimate({
    required this.selectedChapters,
    required this.totalBlocks,
    required this.estimatedApiBatches,
    this.completedBlocks = 0,
    this.blocksPerMinute,
    this.estimatedRemaining,
    this.estimatedSourceChars = 0,
    this.estimatedInputTokens = 0,
  });

  final int selectedChapters;
  final int totalBlocks;
  final int estimatedApiBatches;
  final int completedBlocks;
  final double? blocksPerMinute;
  final Duration? estimatedRemaining;

  /// Rough source character volume for cost/load hints.
  final int estimatedSourceChars;

  /// Rough input-token estimate: ~4 chars/token for Latin-ish text, ~1.75
  /// chars/token for CJK (Chinese/Japanese/Korean) text. Still a rough
  /// estimate, but no longer systematically ~2x low for Chinese books.
  final int estimatedInputTokens;

  static const int _tinyBlockTextThreshold = 80;
  static const int _tinyBlockHtmlThreshold = 360;
  static const int _tinyBlockBudget = 48;

  /// CJK Unified Ideographs (+ extensions), Hangul syllables, Hiragana,
  /// Katakana, Bopomofo, CJK symbols/punctuation and fullwidth forms.
  static final RegExp _cjkChar = RegExp(
    r'[\u2e00-\u2fff\u3000-\u30ff\u3100-\u312f\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef]',
  );

  /// Rough token estimate for [text]: CJK characters count ~1.75
  /// chars/token, everything else ~4 chars/token.
  static int estimateInputTokens(String text) {
    if (text.isEmpty) {
      return 1;
    }
    final int cjkChars = _cjkChar.allMatches(text).length;
    final int otherChars = text.length - cjkChars;
    return max(1, (cjkChars / 1.75 + otherChars / 4).ceil());
  }

  bool get hasSelection => selectedChapters > 0 && totalBlocks > 0;

  bool get hasRuntimeData => blocksPerMinute != null;

  String get speedLabel {
    final double? speed = blocksPerMinute;
    if (speed == null) {
      return 'Not enough data';
    }
    return '${speed.toStringAsFixed(1)} blocks/min';
  }

  String remainingLabel(AppStrings strings) {
    final Duration? remaining = estimatedRemaining;
    if (remaining == null) {
      return strings.etaCalculating;
    }
    if (remaining.inSeconds <= 0) {
      return strings.etaLessThanOneMinute;
    }
    final int minutes = remaining.inMinutes;
    final int seconds = remaining.inSeconds.remainder(60);
    if (minutes <= 0) {
      return strings.etaSeconds(max(1, seconds));
    }
    return seconds == 0
        ? strings.etaMinutes(minutes)
        : strings.etaMinutesSeconds(minutes, seconds);
  }

  static TranslationRunEstimate fromChapters(
    List<InspectedChapter> chapters, {
    required int chunkSize,
    TranslationJob? job,
    Duration? elapsed,
  }) {
    final TranslationRunEstimate base = staticPart(
      chapters,
      chunkSize: chunkSize,
    );
    return base.withProgress(
      completedBlocks: job?.completedBlocks ?? 0,
      totalBlocks: job?.totalBlocks ?? base.totalBlocks,
      elapsed: elapsed,
    );
  }

  /// The expensive, run-invariant part of the estimate: everything derived
  /// from the source text (per-block CJK token estimates, batch packing,
  /// source volume). The source text never changes during a run, so the
  /// controller computes this once per run/selection and refreshes only the
  /// progress fields via [withProgress] on every progress callback —
  /// otherwise each callback re-runs the CJK regex over the whole book on
  /// the UI isolate (tens to hundreds of ms per batch on big books).
  static TranslationRunEstimate staticPart(
    List<InspectedChapter> chapters, {
    required int chunkSize,
  }) {
    final List<InspectedChapter> selected = chapters
        .where(
          (InspectedChapter chapter) =>
              chapter.includeInTranslation && chapter.blocks.isNotEmpty,
        )
        .toList(growable: false);
    final int totalBlocks = selected.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );
    final int sourceChars = selected.fold<int>(
      0,
      (int sum, InspectedChapter chapter) =>
          sum +
          chapter.blocks.fold<int>(
            0,
            (int blockSum, ExtractedBlock block) =>
                blockSum + block.sourceText.length,
          ),
    );
    final int inputTokens = max(
      1,
      selected.fold<int>(
        0,
        (int sum, InspectedChapter chapter) =>
            sum +
            chapter.blocks.fold<int>(
              0,
              (int blockSum, ExtractedBlock block) =>
                  blockSum + estimateInputTokens(block.sourceText),
            ),
      ),
    );

    return TranslationRunEstimate(
      selectedChapters: selected.length,
      totalBlocks: totalBlocks,
      estimatedApiBatches: _estimateBatchCount(selected, chunkSize),
      estimatedSourceChars: sourceChars,
      estimatedInputTokens: inputTokens,
    );
  }

  /// Cheap per-progress-tick refresh: keeps the static fields from [staticPart]
  /// and recomputes only the speed/ETA from [completedBlocks] and [elapsed].
  /// O(1) — safe to call on every progress callback.
  TranslationRunEstimate withProgress({
    required int completedBlocks,
    required int totalBlocks,
    Duration? elapsed,
  }) {
    final int safeCompleted = min(completedBlocks, totalBlocks);
    final double? speed = _blocksPerMinute(safeCompleted, elapsed);
    return TranslationRunEstimate(
      selectedChapters: selectedChapters,
      totalBlocks: totalBlocks,
      estimatedApiBatches: estimatedApiBatches,
      completedBlocks: safeCompleted,
      blocksPerMinute: speed,
      estimatedRemaining: _remainingDuration(
        totalBlocks: totalBlocks,
        completedBlocks: safeCompleted,
        blocksPerMinute: speed,
      ),
      estimatedSourceChars: estimatedSourceChars,
      estimatedInputTokens: estimatedInputTokens,
    );
  }

  static int _estimateBatchCount(
    List<InspectedChapter> chapters,
    int chunkSize,
  ) {
    final int safeChunkSize = max(1, chunkSize);
    int count = 0;
    for (final InspectedChapter chapter in chapters) {
      int currentBudget = 0;
      bool hasOpenBatch = false;
      for (final ExtractedBlock block in chapter.blocks) {
        final int blockBudget = _blockBatchBudget(block);
        if (hasOpenBatch && currentBudget + blockBudget > safeChunkSize) {
          count += 1;
          currentBudget = 0;
          hasOpenBatch = false;
        }
        currentBudget += blockBudget;
        hasOpenBatch = true;
      }
      if (hasOpenBatch) {
        count += 1;
      }
    }
    return count;
  }

  static int _blockBatchBudget(ExtractedBlock block) {
    if (_isTinyTextBlock(block)) {
      return max(_tinyBlockBudget, block.sourceText.length + 24);
    }
    return max(block.sourceHtml.length, block.sourceText.length) + 96;
  }

  static bool _isTinyTextBlock(ExtractedBlock block) {
    return block.sourceText.length <= _tinyBlockTextThreshold &&
        block.sourceHtml.length <= _tinyBlockHtmlThreshold;
  }

  static double? _blocksPerMinute(int completedBlocks, Duration? elapsed) {
    if (completedBlocks <= 0 ||
        elapsed == null ||
        elapsed.inMilliseconds <= 0) {
      return null;
    }
    return completedBlocks /
        (elapsed.inMilliseconds / Duration.millisecondsPerMinute);
  }

  static Duration? _remainingDuration({
    required int totalBlocks,
    required int completedBlocks,
    required double? blocksPerMinute,
  }) {
    if (blocksPerMinute == null || blocksPerMinute <= 0) {
      return null;
    }
    final int remainingBlocks = max(0, totalBlocks - completedBlocks);
    final double remainingMinutes = remainingBlocks / blocksPerMinute;
    return Duration(
      milliseconds: (remainingMinutes * Duration.millisecondsPerMinute).round(),
    );
  }
}
