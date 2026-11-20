import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/chapter_selection_preset.dart';
import '../../domain/models/preview_chapter.dart';
import '../preview_strings.dart';
import 'chapter_warning_badges.dart';
import 'preview_search_field.dart';

class ChapterChecklist extends StatefulWidget {
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
  State<ChapterChecklist> createState() => _ChapterChecklistState();
}

class _ChapterChecklistState extends State<ChapterChecklist> {
  final _search = TextEditingController();
  String _query = '';
  bool _warningsOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _isVisible(PreviewChapter chapter) {
    if (_warningsOnly && !chapter.hasWarnings) return false;
    return _query.isEmpty ||
        chapter.title.toLowerCase().contains(_query) ||
        chapter.path.toLowerCase().contains(_query) ||
        widget.strings
            .chapterCategoryBlocks(chapter.category, chapter.blockCount)
            .toLowerCase()
            .contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = widget.strings;
    final chapters = widget.chapters;
    final selectedCount = chapters.where((c) => c.includeInTranslation).length;
    final hasWarnings = chapters.any((c) => c.hasWarnings);
    final visibleIndices = [
      for (var i = 0; i < chapters.length; i++)
        if (_isVisible(chapters[i])) i,
    ];
    final presets = <(ChapterSelectionPreset, String)>[
      (ChapterSelectionPreset.recommended, strings.presetRecommended),
      (ChapterSelectionPreset.contentOnly, strings.presetContentOnly),
      (ChapterSelectionPreset.allChapters, strings.presetAll),
      (ChapterSelectionPreset.none, strings.presetNone),
    ];
    // The toolbar scrolls with the list so it fits short windows.
    return ListView.builder(
      key: const ValueKey('chapter-checklist-scroll'),
      itemCount: visibleIndices.isEmpty ? 2 : visibleIndices.length + 1,
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
                      onPressed: widget.enabled ? widget.onReset : null,
                      child: Text(strings.resetSelection),
                    ),
                  ],
                ),
                Text(
                  strings.chapterChecklistSummary(
                    selectedCount,
                    chapters.length,
                    widget.selectedBlocks,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                PreviewSearchField(
                  controller: _search,
                  label: strings.searchChapters,
                  clearLabel: strings.clearPreviewSearch,
                  onChanged: (text) => setState(() {
                    _query = text.trim().toLowerCase();
                  }),
                ),
                if (hasWarnings || _warningsOnly)
                  FilterChip(
                    label: Text(strings.warningsOnly),
                    selected: _warningsOnly,
                    onSelected: (value) =>
                        setState(() => _warningsOnly = value),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in presets)
                      ActionChip(
                        label: Text(preset.$2),
                        onPressed: widget.enabled
                            ? () => widget.onPreset(preset.$1)
                            : null,
                      ),
                  ],
                ),
              ],
            ),
          );
        }
        if (visibleIndices.isEmpty) {
          return Semantics(
            liveRegion: true,
            child: Text(strings.noMatchingChapters),
          );
        }
        final index = visibleIndices[item - 1];
        final chapter = chapters[index];
        return Material(
          key: ValueKey(chapter.path),
          color: index == widget.selectedIndex
              ? theme.colorScheme.surfaceContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: ListTile(
            selected: index == widget.selectedIndex,
            selectedColor: theme.colorScheme.onSurface,
            contentPadding: EdgeInsets.zero,
            onTap: () => widget.onSelect(index),
            leading: Semantics(
              label: chapter.title,
              child: Checkbox(
                value: chapter.includeInTranslation,
                onChanged:
                    !widget.enabled ||
                        chapter.path.isEmpty ||
                        chapter.blockCount == 0
                    ? null
                    : (value) {
                        if (value != null) widget.onToggle(chapter.path, value);
                      },
              ),
            ),
            title: Text(
              chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.chapterCategoryBlocks(
                    chapter.category,
                    chapter.blockCount,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                if (chapter.hasWarnings) ...[
                  const SizedBox(height: 6),
                  ChapterWarningBadges(chapter: chapter, strings: strings),
                ],
              ],
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
