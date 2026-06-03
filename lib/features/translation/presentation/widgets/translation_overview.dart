import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../domain/models/translation_job.dart';

class TranslationOverview extends StatelessWidget {
  const TranslationOverview({
    super.key,
    required this.strings,
    required this.job,
    required this.onTranslatePressed,
    required this.onExportPressed,
    required this.onSaveToDownloadsPressed,
    required this.canTranslate,
  });

  final AppStrings strings;
  final TranslationJob? job;
  final VoidCallback onTranslatePressed;
  final VoidCallback onExportPressed;
  final VoidCallback onSaveToDownloadsPressed;
  final bool canTranslate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TranslationJobStatus status =
        job?.status ?? TranslationJobStatus.idle;
    final bool canExport =
        status == TranslationJobStatus.completed &&
        (job?.outputPath.isNotEmpty ?? false);

    return SectionCard(
      title: strings.runOverview,
      trailing: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          if (canExport && PlatformUtils.isAndroid)
            OutlinedButton.icon(
              onPressed: onSaveToDownloadsPressed,
              icon: const Icon(Icons.download_done_rounded),
              label: Text(strings.saveToDownloads),
            ),
          if (canExport)
            OutlinedButton.icon(
              onPressed: onExportPressed,
              icon: Icon(
                PlatformUtils.isAndroid
                    ? Icons.ios_share_rounded
                    : Icons.open_in_new_rounded,
              ),
              label: Text(
                PlatformUtils.isAndroid ? strings.shareEpub : strings.openEpub,
              ),
            ),
          FilledButton.icon(
            onPressed: canTranslate ? onTranslatePressed : null,
            icon: const Icon(Icons.auto_awesome_motion_rounded),
            label: Text(strings.translateSelected),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LinearProgressIndicator(value: job?.progress ?? 0),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _MetricChip(label: strings.statusLabel, value: status.name),
              _MetricChip(
                label: strings.chapterLabel,
                value: job?.currentChapter ?? strings.notStarted,
              ),
              _MetricChip(
                label: strings.filesLabel,
                value: '${job?.completedFiles ?? 0}/${job?.totalFiles ?? 0}',
              ),
              _MetricChip(
                label: strings.blocksLabel,
                value: '${job?.completedBlocks ?? 0}/${job?.totalBlocks ?? 0}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            strings.overviewBody(
              currentBlock: job?.currentBlock?.isNotEmpty == true
                  ? job?.currentBlock
                  : null,
            ),
            style: theme.textTheme.bodyMedium,
          ),
        ],
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
      width: 180,
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
