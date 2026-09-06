import 'package:flutter/material.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/chapter_selection_preset.dart';
import '../../domain/models/preview_chapter.dart';

class ChapterChecklist extends StatelessWidget {
  const ChapterChecklist({
    super.key,
    required this.chapters,
    required this.selectedIndex,
    required this.selectedBlocks,
    required this.strings,
    required this.enabled,
    required this.onSelect,
    required this.onToggle,
    required this.onReset,
    required this.onPreset,
  });
  final List<PreviewChapter> chapters;
  final int selectedIndex;
  final int selectedBlocks;
  final AppStrings strings;
  final bool enabled;
  final ValueChanged<int> onSelect;
  final void Function(String, bool) onToggle;
  final VoidCallback onReset;
  final ValueChanged<ChapterSelectionPreset> onPreset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = chapters.where((c) => c.includeInTranslation).length;
    final presets = <(ChapterSelectionPreset, String)>[
      (ChapterSelectionPreset.recommended, strings.presetRecommended),
      (ChapterSelectionPreset.contentOnly, strings.presetContentOnly),
      (ChapterSelectionPreset.allChapters, strings.presetAll),
      (ChapterSelectionPreset.none, strings.presetNone),
    ];
    // The toolbar scrolls with the list on short windows so it cannot starve rows.
    return ListView.builder(
      key: const ValueKey('chapter-checklist-scroll'),
      itemCount: chapters.length + 1,
      itemBuilder: (context, item) {
        if (item == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.chapterChecklist,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: enabled ? onReset : null,
                      child: Text(strings.resetSelection),
                    ),
                  ],
                ),
                Text(
                  strings.chapterChecklistSummary(
                    selectedCount,
                    chapters.length,
                    selectedBlocks,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in presets)
                      ActionChip(
                        label: Text(preset.$2),
                        onPressed: enabled ? () => onPreset(preset.$1) : null,
                      ),
                  ],
                ),
              ],
            ),
          );
        }
        final index = item - 1;
        final chapter = chapters[index];
        return Material(
          color: index == selectedIndex
              ? theme.colorScheme.surfaceContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => onSelect(index),
            leading: Checkbox(
              value: chapter.includeInTranslation,
              onChanged:
                  !enabled || chapter.path.isEmpty || chapter.blockCount == 0
                  ? null
                  : (value) {
                      if (value != null) onToggle(chapter.path, value);
                    },
            ),
            title: Text(
              chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              strings.chapterCategoryBlocks(
                chapter.category,
                chapter.blockCount,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing:
                chapter.recommendedForTranslation ==
                    chapter.includeInTranslation
                ? null
                : Tooltip(
                    message: strings.manualOverrideTooltip,
                    child: const Icon(Icons.tune_rounded, size: 16),
                  ),
          ),
        );
      },
    );
  }
}
