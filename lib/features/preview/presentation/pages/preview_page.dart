import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../application/preview_provider.dart';
import '../../domain/models/preview_chapter.dart';
import '../widgets/chapter_checklist.dart';
import '../widgets/chapter_preview_content.dart';

class PreviewPage extends ConsumerWidget {
  const PreviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = ref.watch(previewChaptersProvider);
    final index = ref.watch(previewSelectedIndexProvider);
    final state = ref.watch(translationDashboardProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    final strings = ref.watch(appStringsProvider);
    final empty = state.inspectedChapters.isEmpty || chapters.isEmpty;
    final safeIndex = empty ? 0 : index.clamp(0, chapters.length - 1);
    if (safeIndex != index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted &&
            ref.read(previewSelectedIndexProvider) == index) {
          ref.read(previewSelectedIndexProvider.notifier).state = safeIndex;
        }
      });
    }
    return PageScaffold(
      title: strings.previewTitle,
      subtitle: strings.previewSubtitle,
      scrollBody: false,
      child: empty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_stories_outlined,
                      size: 38,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      strings.noPreviewYet,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => context.go('/'),
                      icon: const Icon(Icons.upload_file_outlined, size: 18),
                      label: Text(strings.chooseEpub),
                    ),
                  ],
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final selected = chapters[safeIndex];
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                final wide = constraints.maxWidth >= 800 * textScale;
                final parallel = constraints.maxWidth >= 1040 * textScale;
                final checklist = ChapterChecklist(
                  chapters: chapters,
                  selectedIndex: safeIndex,
                  strings: strings,
                  enabled: !state.isRunActive,
                  selectedBlocks: state.inspectedChapters
                      .where((c) => c.includeInTranslation)
                      .fold<int>(0, (sum, c) => sum + c.blocks.length),
                  onSelect: (value) =>
                      ref.read(previewSelectedIndexProvider.notifier).state =
                          value,
                  onToggle: controller.toggleChapterInclusion,
                  onReset: controller.resetChapterSelection,
                  onPreset: controller.applyChapterSelectionPreset,
                );
                final detail = SingleChildScrollView(
                  key: ValueKey(selected.path),
                  padding: const EdgeInsets.only(bottom: 28),
                  child: ChapterPreviewContent(
                    chapter: selected,
                    translated: _translatedExcerpt(state, selected),
                    strings: strings,
                    parallel: parallel,
                  ),
                );
                if (wide) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 260, child: checklist),
                        const SizedBox(width: 24),
                        const VerticalDivider(width: 1),
                        const SizedBox(width: 24),
                        Expanded(child: detail),
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    SizedBox(
                      height: (constraints.maxHeight * .46).clamp(160.0, 300.0),
                      child: checklist,
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 16),
                    Expanded(child: detail),
                  ],
                );
              },
            ),
    );
  }
}

String? _translatedExcerpt(
  TranslationDashboardState state,
  PreviewChapter selected,
) {
  for (final chapter in state.inspectedChapters) {
    if (chapter.path != selected.path) continue;
    final text = chapter.blocks
        .map((b) => b.translatedHtml)
        .whereType<String>()
        .map((html) => html.replaceAll(RegExp(r'<[^>]+>'), ' '))
        .map((text) => text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((text) => text.isNotEmpty)
        .take(8)
        .join('\n\n');
    return text.isEmpty ? null : text;
  }
  return null;
}
