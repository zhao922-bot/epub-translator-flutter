import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/preview_chapter.dart';
import '../preview_strings.dart';

class ChapterWarningBadges extends StatelessWidget {
  const ChapterWarningBadges({
    super.key,
    required this.chapter,
    required this.strings,
  });

  final PreviewChapter chapter;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget badge(String label) => DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (chapter.degradedBlockCount > 0)
          badge(strings.degradedChapterBlocks(chapter.degradedBlockCount)),
        if (chapter.reviewWarningBlockCount > 0)
          badge(strings.reviewChapterBlocks(chapter.reviewWarningBlockCount)),
      ],
    );
  }
}
