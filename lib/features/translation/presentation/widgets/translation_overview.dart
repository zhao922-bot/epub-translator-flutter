import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_run_estimate.dart';

class TranslationOverview extends StatelessWidget {
  const TranslationOverview({
    super.key,
    required this.strings,
    required this.job,
    required this.onTranslatePressed,
    required this.onExportPressed,
    required this.onSaveToDownloadsPressed,
    required this.canTranslate,
    this.estimate,
    this.onCancelPressed,
    this.canCancel = false,
    this.actionableErrorTitle,
    this.actionableErrorBody,
    this.actionableErrorActionLabel,
    this.onActionableErrorPressed,
    this.onDismissActionableError,
  });

  final AppStrings strings;
  final TranslationJob? job;
  final VoidCallback onTranslatePressed;
  final VoidCallback onExportPressed;
  final VoidCallback onSaveToDownloadsPressed;
  final bool canTranslate;
  final TranslationRunEstimate? estimate;
  final VoidCallback? onCancelPressed;
  final bool canCancel;
  final String? actionableErrorTitle;
  final String? actionableErrorBody;
  final String? actionableErrorActionLabel;
  final VoidCallback? onActionableErrorPressed;
  final VoidCallback? onDismissActionableError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TranslationJobStatus status =
        job?.status ?? TranslationJobStatus.idle;
    final bool canExport = job?.hasExportableEpub ?? false;
    final String statusText = strings.jobStatusLabel(status);
    final double progress = (job?.progress ?? 0).clamp(0.0, 1.0);
    final int percent = (progress * 100).round();

    return SectionCard(
      title: strings.runOverview,
      icon: Icons.timeline_rounded,
      variant: SectionCardVariant.standard,
      trailing: canExport
          ? FilledButton.tonalIcon(
              onPressed: onExportPressed,
              icon: Icon(
                PlatformUtils.isAndroid
                    ? Icons.ios_share_rounded
                    : Icons.open_in_new_rounded,
                size: 18,
              ),
              label: Text(
                PlatformUtils.isAndroid ? strings.shareEpub : strings.openEpub,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (actionableErrorTitle != null &&
              actionableErrorBody != null) ...<Widget>[
            _ActionableErrorBanner(
              title: actionableErrorTitle!,
              body: actionableErrorBody!,
              actionLabel: actionableErrorActionLabel,
              onAction: onActionableErrorPressed,
              onDismiss: onDismissActionableError,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: <Widget>[
              _StatusPill(status: status, label: statusText),
              const Spacer(),
              Text(
                '$percent%',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (job?.currentChapter?.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              job!.currentChapter!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Semantics(
            label: 'Translation progress $percent%',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: progress, minHeight: 8),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              if ((job?.totalBlocks ?? 0) > 0)
                _MetaText(
                  '${strings.blocksLabel}: ${job!.completedBlocks}/${job!.totalBlocks}',
                ),
              if (estimate case final TranslationRunEstimate e
                  when e.hasRuntimeData)
                _MetaText('${strings.etaLabel}: ${e.remainingLabel}'),
              if (estimate case final TranslationRunEstimate e
                  when e.hasSelection && !canExport)
                _MetaText(
                  strings.estimateSummary(
                    e.estimatedApiBatches,
                    e.estimatedInputTokens,
                  ),
                ),
            ],
          ),
          if (job?.currentBlock?.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              strings.overviewBody(currentBlock: job!.currentBlock),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (canExport) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    path.basename(job!.outputPath),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (PlatformUtils.isAndroid)
                  TextButton(
                    onPressed: onSaveToDownloadsPressed,
                    child: Text(strings.saveToDownloads),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.label});

  final TranslationJobStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (status) {
      TranslationJobStatus.completed => (
        scheme.primary.withValues(alpha: 0.12),
        scheme.primary,
      ),
      TranslationJobStatus.failed => (
        scheme.error.withValues(alpha: 0.12),
        scheme.error,
      ),
      TranslationJobStatus.running || TranslationJobStatus.queued => (
        scheme.tertiary.withValues(alpha: 0.14),
        scheme.tertiary,
      ),
      _ => (scheme.surfaceContainer, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      label,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _ActionableErrorBanner extends StatelessWidget {
  const _ActionableErrorBanner({
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (actionLabel != null && onAction != null)
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                if (onDismiss != null)
                  TextButton(onPressed: onDismiss, child: const Text('OK')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
