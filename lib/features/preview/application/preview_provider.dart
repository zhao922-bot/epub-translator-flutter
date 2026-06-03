import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../translation/application/translation_dashboard_controller.dart';
import '../domain/models/preview_chapter.dart';

final previewSelectedIndexProvider = StateProvider<int>((ref) => 0);

final previewChaptersProvider = Provider<List<PreviewChapter>>((ref) {
  final translationState = ref.watch(translationDashboardProvider);
  final chapters = translationState.inspectedChapters;
  if (chapters.isEmpty) {
    return const <PreviewChapter>[
      PreviewChapter(
        title: 'No EPUB inspected yet',
        body:
            'Inspect an EPUB from the Translation page to populate real chapters here.',
        path: '',
        category: 'Waiting',
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
