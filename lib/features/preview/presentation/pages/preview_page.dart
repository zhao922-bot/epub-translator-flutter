import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../application/preview_provider.dart';
import '../../domain/models/preview_chapter.dart';

class PreviewPage extends ConsumerWidget {
  const PreviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = ref.watch(previewChaptersProvider);
    final selectedIndex = ref.watch(previewSelectedIndexProvider);
    final selectedChapter =
        chapters[selectedIndex.clamp(0, chapters.length - 1)];
    final selectedController = ref.read(previewSelectedIndexProvider.notifier);
    final dashboardState = ref.watch(translationDashboardProvider);
    final dashboardController = ref.read(translationDashboardProvider.notifier);
    final strings = ref.watch(appStringsProvider);
    final selectedCount = chapters
        .where((PreviewChapter chapter) => chapter.includeInTranslation)
        .length;
    final selectedBlockCount = dashboardState.inspectedChapters
        .where((chapter) => chapter.includeInTranslation)
        .fold<int>(0, (int sum, chapter) => sum + chapter.blocks.length);

    return PageScaffold(
      title: strings.previewTitle,
      subtitle: strings.previewSubtitle,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool stackedLayout = constraints.maxWidth < 980;
          final Widget checklist = SizedBox(
            width: stackedLayout ? double.infinity : 360,
            child: SectionCard(
              title: strings.chapterChecklist,
              trailing: TextButton.icon(
                onPressed: dashboardState.inspectedChapters.isEmpty
                    ? null
                    : dashboardController.resetChapterSelection,
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(strings.resetSelection),
              ),
              child: Column(
                children: <Widget>[
                  if (chapters.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          strings.chapterChecklistSummary(
                            selectedCount,
                            chapters.length,
                            selectedBlockCount,
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ...List<Widget>.generate(chapters.length, (int index) {
                    final PreviewChapter chapter = chapters[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      selected: index == selectedIndex,
                      onTap: () => selectedController.state = index,
                      leading: Checkbox(
                        value: chapter.includeInTranslation,
                        onChanged: chapter.path.isEmpty
                            ? null
                            : (bool? value) {
                                if (value == null) {
                                  return;
                                }
                                dashboardController.toggleChapterInclusion(
                                  chapter.path,
                                  value,
                                );
                              },
                      ),
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        strings.chapterCategoryBlocks(
                          chapter.category,
                          chapter.blockCount,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing:
                          chapter.recommendedForTranslation ==
                              chapter.includeInTranslation
                          ? null
                          : Tooltip(
                              message: strings.manualOverrideTooltip,
                              child: const Icon(Icons.tune_rounded, size: 18),
                            ),
                    );
                  }),
                ],
              ),
            ),
          );

          final Widget detail = Column(
            children: <Widget>[
              SectionCard(
                title: selectedChapter.title,
                trailing: _PreviewBadge(
                  chapter: selectedChapter,
                  strings: strings,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      selectedChapter.path.isEmpty
                          ? (strings.isChinese
                                ? '尚无章节路径'
                                : 'No chapter path yet')
                          : selectedChapter.path,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        _MetricChip(
                          label: strings.blocksLabel,
                          value:
                              '${selectedChapter.translatedBlockCount}/${selectedChapter.blockCount}',
                        ),
                        _MetricChip(
                          label: strings.defaultLabel,
                          value: selectedChapter.recommendedForTranslation
                              ? strings.translateBadge
                              : strings.skipBadge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ExcludeSemantics(
                      child: SelectableText(
                        selectedChapter.body,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(height: 1.6),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: strings.currentFilteringRule,
                child: Text(
                  strings.currentFilteringRuleBody,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          );

          if (stackedLayout) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[checklist, const SizedBox(height: 16), detail],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              checklist,
              const SizedBox(width: 16),
              Expanded(child: detail),
            ],
          );
        },
      ),
    );
  }
}

class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge({required this.chapter, required this.strings});

  final PreviewChapter chapter;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = chapter.includeInTranslation
        ? scheme.secondaryContainer
        : scheme.tertiaryContainer;
    final Color foreground = chapter.includeInTranslation
        ? scheme.onSecondaryContainer
        : scheme.onTertiaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        chapter.includeInTranslation
            ? strings.translateBadge
            : strings.skipBadge,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: foreground),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 148,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}
