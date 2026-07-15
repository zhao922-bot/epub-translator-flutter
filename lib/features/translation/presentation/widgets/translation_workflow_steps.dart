import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/translation_job.dart';

/// Minimal step strip: connected dots + one short status label.
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
    final bool translating =
        job?.status == TranslationJobStatus.running ||
        job?.status == TranslationJobStatus.queued;
    final bool inspecting =
        translating == false &&
        job?.status == TranslationJobStatus.running &&
        job?.phase == TranslationJobPhase.inspection;

    final int step;
    final String label;
    if (translationComplete) {
      step = 4;
      label = strings.stepExportDone;
    } else if (translating && job?.phase == TranslationJobPhase.translation) {
      step = 3;
      label = strings.stepTranslating;
    } else if (hasInspectedChapters && canTranslate) {
      step = 3;
      label = strings.stepReadyToTranslate;
    } else if (hasInspectedChapters) {
      step = 2;
      label = strings.stepReviewChapters;
    } else if (inspecting ||
        (hasInput && job?.status == TranslationJobStatus.running)) {
      step = 2;
      label = strings.stepInspecting;
    } else if (hasInput) {
      step = 1;
      label = strings.stepReadyToInspect;
    } else {
      step = 1;
      label = strings.stepChooseEpub;
    }

    return Semantics(
      label: label,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: <Color>[
                scheme.surfaceContainer.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.55 : 0.92,
                ),
                scheme.primaryContainer.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.12 : 0.36,
                ),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.account_tree_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  flex: 3,
                  child: Row(
                    children: <Widget>[
                      for (int i = 1; i <= 4; i++) ...<Widget>[
                        _Dot(active: i <= step, current: i == step),
                        if (i < 4)
                          Expanded(
                            child: Container(
                              height: 3,
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: i < step
                                    ? scheme.primary
                                    : scheme.outlineVariant.withValues(
                                        alpha: 0.75,
                                      ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  flex: 2,
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active, required this.current});

  final bool active;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double size = current ? 14 : 11;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? scheme.primary : Colors.transparent,
        border: Border.all(
          color: active ? scheme.primary : scheme.outlineVariant,
          width: current ? 3 : 1.5,
        ),
      ),
    );
  }
}
