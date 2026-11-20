import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/preview_chapter.dart';
import '../preview_strings.dart';
import 'chapter_warning_badges.dart';
import 'preview_passages.dart';
import 'preview_search_field.dart';

class ChapterPreviewContent extends StatefulWidget {
  const ChapterPreviewContent({
    super.key,
    required this.chapter,
    required this.strings,
    required this.parallel,
    this.onBrowseBlocks,
  });

  final PreviewChapter chapter;
  final AppStrings strings;
  final bool parallel;
  final ValueChanged<String>? onBrowseBlocks;

  @override
  State<ChapterPreviewContent> createState() => _ChapterPreviewContentState();
}

class _ChapterPreviewContentState extends State<ChapterPreviewContent> {
  final _search = TextEditingController();
  RegExp? _pattern;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapter = widget.chapter;
    final strings = widget.strings;
    final browseBlocks = widget.onBrowseBlocks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(chapter.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          chapter.path,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            Text(
              '${strings.blocksLabel}: ${chapter.translatedBlockCount}/${chapter.blockCount}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${strings.defaultLabel}: ${chapter.recommendedForTranslation ? strings.translateBadge : strings.skipBadge}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (chapter.hasWarnings) ...[
          const SizedBox(height: 10),
          ChapterWarningBadges(chapter: chapter, strings: strings),
        ],
        const SizedBox(height: 20),
        PreviewSearchField(
          controller: _search,
          label: strings.searchExcerpt,
          clearLabel: strings.clearPreviewSearch,
          onChanged: (text) =>
              setState(() => _pattern = previewSearchPattern(text)),
        ),
        if (browseBlocks != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => browseBlocks(_search.text),
              icon: const Icon(Icons.view_agenda_outlined),
              label: Text(strings.browseChapterBlocks),
            ),
          ),
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 20),
        PreviewPassages(
          strings: strings,
          source: chapter.body,
          translation: chapter.translatedBody ?? '',
          parallel: widget.parallel,
          pattern: _pattern,
        ),
        const SizedBox(height: 28),
        ExpansionTile(
          title: Text(
            strings.currentFilteringRule,
            style: theme.textTheme.bodySmall,
          ),
          children: [
            Text(
              strings.currentFilteringRuleBody,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}
