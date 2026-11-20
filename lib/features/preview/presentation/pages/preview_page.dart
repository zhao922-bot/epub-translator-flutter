import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../application/preview_provider.dart';
import '../widgets/chapter_block_dialog.dart';
import '../widgets/chapter_checklist.dart';
import '../widgets/chapter_preview_content.dart';

class PreviewPage extends ConsumerStatefulWidget {
  const PreviewPage({super.key});

  @override
  ConsumerState<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends ConsumerState<PreviewPage> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(previewSelectionProvider, (_, selection) {
      if (selection.index == selection.safeIndex) return;
      // Route entry can notify during widget mounting. Recheck after mounting
      // so an intervening chapter update or selection wins.
      Future.microtask(() {
        if (!mounted) return;
        final current = ref.read(previewSelectionProvider);
        if (current.index != current.safeIndex) {
          ref.read(previewSelectedIndexProvider.notifier).state =
              current.safeIndex;
        }
      });
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final chapters = ref.watch(previewChaptersProvider);
    final selection = ref.watch(previewSelectionProvider);
    // The preview only needs the inspected chapters (for the excerpt) and
    // the run-active flag (to disable the checklist); watching the whole
    // dashboard state would rebuild this page on every log tick.
    final previewState = ref.watch(
      translationDashboardProvider.select(
        (s) => (
          inspectedChapters: s.inspectedChapters,
          isRunActive: s.isRunActive,
        ),
      ),
    );
    final controller = ref.read(translationDashboardProvider.notifier);
    final strings = ref.watch(appStringsProvider);
    // Recovery runs off the UI isolate and can fail (e.g. the isolate is
    // killed); surface the failure with a retry entry instead of silently
    // projecting empty excerpts / "no translation yet".
    final recovery = ref.watch(previewRecoveryProvider);
    final empty = previewState.inspectedChapters.isEmpty || chapters.isEmpty;
    final safeIndex = selection.safeIndex;
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
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (recovery.hasError)
                  _PreviewRecoveryErrorBanner(
                    message: strings.previewRecoveryFailed,
                    retryLabel: strings.retryJob,
                    onRetry: () => ref.invalidate(previewRecoveryProvider),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final selected = chapters[safeIndex];
                      final inspected =
                          safeIndex < previewState.inspectedChapters.length
                          ? previewState.inspectedChapters[safeIndex]
                          : null;
                      final textScale = MediaQuery.textScalerOf(
                        context,
                      ).scale(1);
                      final wide = constraints.maxWidth >= 800 * textScale;
                      final parallel = constraints.maxWidth >= 1040 * textScale;
                      final checklist = ChapterChecklist(
                        chapters: chapters,
                        selectedIndex: safeIndex,
                        strings: strings,
                        enabled: !previewState.isRunActive,
                        selectedBlocks: previewState.inspectedChapters
                            .where((c) => c.includeInTranslation)
                            .fold<int>(0, (sum, c) => sum + c.blocks.length),
                        onSelect: (value) =>
                            ref
                                    .read(previewSelectedIndexProvider.notifier)
                                    .state =
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
                          strings: strings,
                          parallel: parallel,
                          onBrowseBlocks:
                              selected.hasTruncatedExcerpt &&
                                  inspected != null &&
                                  inspected.path == selected.path &&
                                  inspected.blocks.isNotEmpty
                              ? (query) => showDialog<void>(
                                  context: context,
                                  builder: (_) => ChapterBlockDialog(
                                    chapter: inspected,
                                    strings: strings,
                                    initialQuery: query,
                                  ),
                                )
                              : null,
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
                      // Reserve a proportion of the available height for the
                      // separator; fixed minimum list heights starve the detail
                      // on short windows (especially with a bottom navigation bar).
                      final separatorHeight = (constraints.maxHeight * .12)
                          .clamp(0.0, 48.0);
                      final checklistHeight =
                          ((constraints.maxHeight - separatorHeight) * .46)
                              .clamp(0.0, 300.0);
                      return Column(
                        children: [
                          SizedBox(height: checklistHeight, child: checklist),
                          SizedBox(
                            height: separatorHeight,
                            child: const Center(child: Divider(height: 1)),
                          ),
                          Expanded(child: detail),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// Error banner shown when off-isolate preview recovery failed: the
/// excerpts below may be empty, and the retry button re-runs recovery.
class _PreviewRecoveryErrorBanner extends StatelessWidget {
  const _PreviewRecoveryErrorBanner({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 20,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    );
  }
}
