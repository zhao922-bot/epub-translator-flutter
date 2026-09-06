import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/translation_job.dart';

/// Minimal step strip: connected dots + one short status label.
///
/// Active run [phase] is checked before "has chapters" so re-inspect and
/// translation never show the wrong idle status.
class TranslationWorkflowSteps extends StatelessWidget {
  const TranslationWorkflowSteps({
    super.key,
    required this.strings,
    required this.hasInput,
    required this.hasInspectedChapters,
    required this.canTranslate,
    required this.job,
  });

  final AppStrings strings;
  final bool hasInput;
  final bool hasInspectedChapters;
  final bool canTranslate;
  final TranslationJob? job;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool translationComplete = job?.hasExportableEpub ?? false;
    final TranslationJobStatus? status = job?.status;
    final TranslationJobPhase phase =
        job?.phase ?? TranslationJobPhase.inspection;
    final bool runActive =
        status == TranslationJobStatus.running ||
        status == TranslationJobStatus.queued;

    final int step;
    final String label;
    if (translationComplete) {
      step = 4;
      label = strings.stepExportDone;
    } else if (runActive && phase == TranslationJobPhase.inspection) {
      step = 2;
      label = strings.stepInspecting;
    } else if (runActive && phase == TranslationJobPhase.cacheRestoration) {
      step = 3;
      label = strings.stepRestoringCache;
    } else if (runActive && phase == TranslationJobPhase.translation) {
      step = 3;
      label = strings.stepTranslating;
    } else if (hasInspectedChapters && canTranslate) {
      step = 3;
      label = strings.stepReadyToTranslate;
    } else if (hasInspectedChapters) {
      step = 2;
      label = strings.stepReviewChapters;
    } else if (hasInput) {
      step = 1;
      label = strings.stepReadyToInspect;
    } else {
      step = 1;
      label = strings.stepChooseEpub;
    }

    return Semantics(
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int index = 1; index <= 4; index++)
                  Container(
                    width: 22,
                    height: 3,
                    margin: const EdgeInsets.only(right: 5),
                    color: index <= step
                        ? scheme.primary
                        : scheme.outlineVariant,
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
