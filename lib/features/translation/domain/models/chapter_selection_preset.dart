import 'inspected_chapter.dart';

/// One-click chapter checklist strategies.
enum ChapterSelectionPreset { recommended, contentOnly, allChapters, none }

extension ChapterSelectionPresetOps on ChapterSelectionPreset {
  String get id => name;

  List<InspectedChapter> apply(List<InspectedChapter> chapters) {
    return chapters
        .map((InspectedChapter chapter) {
          final bool include = switch (this) {
            ChapterSelectionPreset.recommended =>
              chapter.recommendedForTranslation,
            ChapterSelectionPreset.contentOnly =>
              chapter.category == ChapterCategory.content,
            ChapterSelectionPreset.allChapters => chapter.blocks.isNotEmpty,
            ChapterSelectionPreset.none => false,
          };
          return chapter.copyWith(includeInTranslation: include);
        })
        .toList(growable: false);
  }
}
