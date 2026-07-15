import 'dart:math';

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

  /// Rough input-token estimate (~4 chars / token for Latin-ish mixed text).
  final int estimatedInputTokens;

  static const int _tinyBlockTextThreshold = 80;
  static const int _tinyBlockHtmlThreshold = 360;
  static const int _tinyBlockBudget = 48;

  bool get hasSelection => selectedChapters > 0 && totalBlocks > 0;

  bool get hasRuntimeData => blocksPerMinute != null;

  String get speedLabel {
    final double? speed = blocksPerMinute;
    if (speed == null) {
      return 'Not enough data';
    }
    return '${speed.toStringAsFixed(1)} blocks/min';
  }

  String get remainingLabel {
    final Duration? remaining = estimatedRemaining;
    if (remaining == null) {
      return 'Calculating';
    }
    if (remaining.inSeconds <= 0) {
      return 'Less than 1 min';
    }
    final int minutes = remaining.inMinutes;
    final int seconds = remaining.inSeconds.remainder(60);
    if (minutes <= 0) {
      return '${max(1, seconds)} sec';
    }
    return seconds == 0 ? '$minutes min' : '$minutes min $seconds sec';
  }

  static TranslationRunEstimate fromChapters(
    List<InspectedChapter> chapters, {
    required int chunkSize,
    TranslationJob? job,
    Duration? elapsed,
  }) {
    final List<InspectedChapter> selected = chapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .toList(growable: false);
    final int totalBlocks = selected.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );
    final int completedBlocks = min(
      job?.completedBlocks ?? 0,
      job?.totalBlocks ?? totalBlocks,
    );
    final double? speed = _blocksPerMinute(completedBlocks, elapsed);
    final Duration? remaining = _remainingDuration(
      totalBlocks: job?.totalBlocks ?? totalBlocks,
      completedBlocks: completedBlocks,
      blocksPerMinute: speed,
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
    final int inputTokens = max(1, (sourceChars / 4).ceil());

    return TranslationRunEstimate(
      selectedChapters: selected.length,
      totalBlocks: totalBlocks,
      estimatedApiBatches: _estimateBatchCount(selected, chunkSize),
      completedBlocks: completedBlocks,
      blocksPerMinute: speed,
      estimatedRemaining: remaining,
      estimatedSourceChars: sourceChars,
      estimatedInputTokens: inputTokens,
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
