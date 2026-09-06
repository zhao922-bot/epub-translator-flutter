import 'package:flutter/material.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/preview_chapter.dart';

class ChapterPreviewContent extends StatelessWidget {
  const ChapterPreviewContent({
    super.key,
    required this.chapter,
    required this.translated,
    required this.strings,
    required this.parallel,
  });
  final PreviewChapter chapter;
  final String? translated;
  final AppStrings strings;
  final bool parallel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget passage(String title, String body) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        SelectableText(
          body,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
        ),
      ],
    );
    final original = passage(strings.sourcePreview, chapter.body);
    final translation = passage(
      strings.translatedPreview,
      translated ?? strings.noTranslationYet,
    );
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
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 24),
        if (parallel)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: original),
              const SizedBox(width: 28),
              Expanded(child: translation),
            ],
          )
        else ...[
          original,
          const SizedBox(height: 28),
          translation,
        ],
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
