import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../settings/application/settings_controller.dart';
import '../../application/translation_dashboard_controller.dart';
import '../../domain/models/actionable_error.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_style_profile.dart';
import '../widgets/translation_inputs.dart';
import '../widgets/translation_logs.dart';
import '../widgets/translation_overview.dart';
import '../widgets/translation_style_profile_card.dart';
import '../widgets/translation_workflow_steps.dart';

/// Window drop is handled globally by [AppShell] so imports work on any page.
class TranslationDashboardPage extends ConsumerWidget {
  const TranslationDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TranslationDashboardState state = ref.watch(
      translationDashboardProvider,
    );
    final TranslationDashboardController controller = ref.read(
      translationDashboardProvider.notifier,
    );
    final settingsController = ref.read(settingsProvider.notifier);
    final strings = ref.watch(appStringsProvider);
    final bool hasSelectedChapters = state.inspectedChapters.any(
      (chapter) => chapter.includeInTranslation && chapter.blocks.isNotEmpty,
    );
    final bool canTranslate =
        hasSelectedChapters && !state.requiresStyleProfileConfirmation;
    final bool isRunActive = state.isRunActive;
    final bool hasInput = state.inputPath.isNotEmpty;
    final bool hasInspected = state.inspectedChapters.isNotEmpty;
    final TranslationJob? job = state.job;
    final bool showOverview =
        state.actionableError != null ||
        (job != null && job.status != TranslationJobStatus.idle) ||
        (job?.hasExportableEpub ?? false);
    final bool showLogs = state.logs.isNotEmpty;
    final bool showStyleProfile =
        state.config.styleProfileEnabled && hasInspected;

    // Primary actions only when they add value beyond the drop zone.
    final List<Widget> primaryActions = <Widget>[];
    if (isRunActive) {
      primaryActions.add(
        FilledButton.tonalIcon(
          onPressed: controller.requestCancel,
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(strings.cancelRun),
        ),
      );
    } else if (canTranslate) {
      primaryActions.add(
        FilledButton.icon(
          onPressed: controller.startTranslation,
          icon: const Icon(Icons.translate_rounded),
          label: Text(strings.translateSelected),
        ),
      );
      if (hasInput) {
        primaryActions.add(
          TextButton(
            onPressed: controller.startInspection,
            child: Text(strings.reinspectEpub),
          ),
        );
      }
    } else if (hasInput) {
      primaryActions.add(
        FilledButton.icon(
          onPressed: controller.startInspection,
          icon: const Icon(Icons.playlist_add_check_circle_rounded),
          label: Text(strings.inspectEpub),
        ),
      );
    }

    return PageScaffold(
      title: strings.translationPageTitle,
      subtitle: strings.translationPageSubtitle,
      actions: primaryActions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TranslationInputs(
            strings: strings,
            inputPath: state.inputPath,
            outputDirectory: state.outputDirectory,
            targetLanguage: state.config.targetLanguage,
            bilingual: state.config.bilingual,
            enabled: !isRunActive,
            onInputChanged: controller.setInputPath,
            onOutputChanged: controller.setOutputDirectory,
            onTargetLanguageChanged: (value) {
              if (value != null) {
                settingsController.setTargetLanguage(value);
                controller.setTargetLanguage(value);
              }
            },
            onBilingualChanged: (value) {
              settingsController.setBilingual(value);
              controller.setBilingual(value);
            },
            onPickInputPressed: isRunActive ? null : controller.pickInputPath,
            onPickOutputPressed: isRunActive
                ? null
                : controller.pickOutputDirectory,
          ),
          const SizedBox(height: 12),
          TranslationWorkflowSteps(
            strings: strings,
            hasInput: hasInput,
            hasInspectedChapters: hasInspected,
            canTranslate: canTranslate,
            job: state.job,
          ),
          if (showStyleProfile) ...<Widget>[
            const SizedBox(height: 16),
            TranslationStyleProfileCard(
              strings: strings,
              profile: state.styleProfile,
              confirmed: state.styleProfileConfirmed,
              enabled: true,
              editable: !isRunActive,
              isGenerating: state.isGeneratingStyleProfile,
              canGenerate: hasInspected && !isRunActive,
              onGenerate: controller.generateStyleProfile,
              onConfirm: controller.confirmStyleProfile,
              onChanged:
                  ({
                    String? primaryGenre,
                    String? secondaryGenresCsv,
                    String? tone,
                    String? sentenceStyle,
                    String? constraintsText,
                    String? avoidText,
                    TranslationStyleConfidence? confidence,
                  }) {
                    controller.setStyleProfileField(
                      primaryGenre: primaryGenre,
                      secondaryGenresCsv: secondaryGenresCsv,
                      tone: tone,
                      sentenceStyle: sentenceStyle,
                      constraintsText: constraintsText,
                      avoidText: avoidText,
                      confidence: confidence,
                    );
                  },
            ),
          ],
          if (showOverview) ...<Widget>[
            const SizedBox(height: 16),
            TranslationOverview(
              strings: strings,
              job: state.job,
              onTranslatePressed: controller.startTranslation,
              onExportPressed: controller.exportTranslatedEpub,
              onSaveToDownloadsPressed:
                  controller.saveTranslatedEpubToDownloads,
              canTranslate: canTranslate,
              estimate: state.runEstimate,
              canCancel: isRunActive,
              onCancelPressed: controller.requestCancel,
              actionableErrorTitle: state.actionableError?.title,
              actionableErrorBody: state.actionableError?.message,
              actionableErrorActionLabel: state.actionableError?.actionLabel,
              onDismissActionableError: controller.clearActionableError,
              onActionableErrorPressed: () async {
                final ActionableError? error = state.actionableError;
                if (error == null) {
                  return;
                }
                switch (error.actionKind) {
                  case ActionableErrorKind.openSettings:
                    controller.clearActionableError();
                    context.go('/settings');
                  case ActionableErrorKind.reduceConcurrency:
                    await settingsController.reduceConcurrencyForRateLimit();
                    controller.clearActionableError();
                  case ActionableErrorKind.retryTranslation:
                    controller.clearActionableError();
                    await controller.startTranslation();
                  case ActionableErrorKind.retryInspection:
                    controller.clearActionableError();
                    await controller.startInspection();
                  case ActionableErrorKind.dismiss:
                    controller.clearActionableError();
                }
              },
            ),
          ],
          if (showLogs) ...<Widget>[
            const SizedBox(height: 14),
            TranslationLogs(
              strings: strings,
              logs: state.logs,
              initiallyExpanded: state.actionableError != null,
            ),
          ],
        ],
      ),
    );
  }
}
