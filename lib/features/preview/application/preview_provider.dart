import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/localization/app_strings.dart';
import '../../translation/application/translation_dashboard_controller.dart';
import '../domain/models/preview_chapter.dart';

final previewSelectedIndexProvider = StateProvider<int>((ref) => 0);

final previewChaptersProvider = Provider<List<PreviewChapter>>((ref) {
  // Only the inspected chapters matter here; a plain watch of the whole
  // dashboard state would rebuild the preview on every log tick.
  final chapters = ref.watch(
    translationDashboardProvider.select((s) => s.inspectedChapters),
  );
  if (chapters.isEmpty) {
    // Currently unreachable (the preview page renders strings.noPreviewYet
    // for the empty state), but keep it localized in case the fallback is
    // ever surfaced.
    final AppStrings strings = ref.watch(appStringsProvider);
    return <PreviewChapter>[
      PreviewChapter(
        title: strings.previewFallbackTitle,
        body: strings.noPreviewYet,
        path: '',
        category: strings.previewFallbackCategory,
        recommendedForTranslation: false,
        includeInTranslation: false,
        blockCount: 0,
        translatedBlockCount: 0,
      ),
    ];
  }

  return chapters
      .map(
        (chapter) => PreviewChapter(
          title: chapter.title,
          body: chapter.body,
          path: chapter.path,
          category: chapter.categoryLabel,
          recommendedForTranslation: chapter.recommendedForTranslation,
          includeInTranslation: chapter.includeInTranslation,
          blockCount: chapter.blocks.length,
          translatedBlockCount: chapter.translatedBlockCount,
        ),
      )
      .toList();
});
