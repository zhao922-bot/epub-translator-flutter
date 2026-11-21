import 'dart:math';

import '../domain/models/inspected_chapter.dart';
import '../domain/models/translation_config.dart';
import '../domain/models/translation_job.dart';
import '../domain/models/translation_run_estimate.dart';

/// Memoizes the static source-derived portion of [TranslationRunEstimate] so
/// progress ticks and source releases avoid re-scanning unchanged chapters.
class DashboardEstimateMemoizer {
  List<InspectedChapter>? _staticChaptersKey;
  int _staticChunkSizeKey = -1;
  TranslationRunEstimate? _staticCache;
  // A partial release prevents a fresh replan from the surviving sources.
  bool _hasReleasedSources = false;
  // Scale from the original plan to avoid compounding ceil() rounding when
  // the chunk size changes repeatedly after source release.
  int _anchorChunkSize = -1;
  int _anchorBatches = -1;

  TranslationRunEstimate? get staticCache => _staticCache;

  void reset() {
    _staticChaptersKey = null;
    _staticChunkSizeKey = -1;
    _staticCache = null;
  }

  void markChapterSourcesReleased({
    required List<InspectedChapter> previousChapters,
    required List<InspectedChapter> updatedChapters,
    required bool chapterWasIncluded,
  }) {
    if (identical(previousChapters, _staticChaptersKey)) {
      _staticChaptersKey = updatedChapters;
      if (chapterWasIncluded) {
        _hasReleasedSources = true;
      }
    }
  }

  void adoptUpdatedChapters(List<InspectedChapter> chapters) {
    _staticChaptersKey = chapters;
  }

  TranslationRunEstimate? build({
    required List<InspectedChapter> sourceChapters,
    required List<InspectedChapter> stateChapters,
    required TranslationConfig config,
    required TranslationJob? job,
    required Duration? elapsed,
  }) {
    if (sourceChapters.isEmpty) {
      return null;
    }
    final int chunkSize = config.chunkSize;
    TranslationRunEstimate? staticPart = _staticCache;
    if (!identical(sourceChapters, _staticChaptersKey) ||
        chunkSize != _staticChunkSizeKey ||
        staticPart == null) {
      final List<InspectedChapter> selectedChapters = sourceChapters
          .where((chapter) => chapter.includeInTranslation)
          .toList();
      // Unselected sources do not determine whether the selected chapters can
      // be replanned. For an empty selection, consult the last plan's sources.
      final List<InspectedChapter> releaseCheckChapters =
          selectedChapters.isNotEmpty
          ? selectedChapters
          : (_staticChaptersKey ?? sourceChapters);
      final bool sourcesReleased =
          (identical(sourceChapters, _staticChaptersKey) &&
              _hasReleasedSources) ||
          (releaseCheckChapters.isNotEmpty &&
              !releaseCheckChapters.any(
                (chapter) =>
                    chapter.blocks.any((block) => block.sourceText.isNotEmpty),
              ));
      // A selection change after source release advances only the memo keys
      // because the underlying text is no longer available to replan.
      if (sourcesReleased && staticPart != null) {
        if (identical(sourceChapters, _staticChaptersKey)) {
          if (_anchorBatches < 0) {
            _anchorChunkSize = _staticChunkSizeKey;
            _anchorBatches = staticPart.estimatedApiBatches;
          }
          final int batches = max(
            1,
            (_anchorBatches * _anchorChunkSize / chunkSize).ceil(),
          );
          staticPart = TranslationRunEstimate(
            selectedChapters: staticPart.selectedChapters,
            totalBlocks: staticPart.totalBlocks,
            estimatedSourceChars: staticPart.estimatedSourceChars,
            estimatedInputTokens: staticPart.estimatedInputTokens,
            estimatedApiBatches: batches,
          );
        }
      } else {
        staticPart = TranslationRunEstimate.staticPart(
          sourceChapters,
          chunkSize: chunkSize,
        );
        _hasReleasedSources = false;
        _anchorChunkSize = chunkSize;
        _anchorBatches = staticPart.estimatedApiBatches;
      }
      _staticChaptersKey = sourceChapters;
      _staticChunkSizeKey = chunkSize;
      _staticCache = staticPart;
    }
    // Changing the chapter list invalidates the prior job's progress and ETA.
    final bool reuseProgress = identical(sourceChapters, stateChapters);
    return staticPart.withProgress(
      completedBlocks: reuseProgress ? job?.completedBlocks ?? 0 : 0,
      totalBlocks: reuseProgress
          ? job?.totalBlocks ?? staticPart.totalBlocks
          : staticPart.totalBlocks,
      elapsed: reuseProgress ? elapsed : null,
      apiTranslatedBlocks: reuseProgress
          ? TranslationRunEstimate.apiTranslatedBlocksForThroughput(job)
          : 0,
      budgetJob: reuseProgress ? job : null,
      maxOutputTokens: config.maxOutputTokens,
      tokenSavingMode: config.tokenSavingMode,
      styleEnabled: config.styleProfileEnabled,
      reviewEnabled: config.semanticQualityCheck,
      reviewBudget: config.maxSemanticReviewTokens,
    );
  }
}
