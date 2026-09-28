import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/android_service_bridge.dart';
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
///
/// The page itself only watches the strings and the permission-notice id.
/// Each section below selects just the state slice it renders, so the
/// high-frequency log ticks (one per translated batch) rebuild only the log
/// area instead of the whole page.
class TranslationDashboardPage extends ConsumerWidget {
  const TranslationDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    // Storage permission permanently denied (Android 6-9): guide the user to
    // the app settings page. permissionNoticeId is bumped by the controller
    // once per denial so the SnackBar is not re-shown on rebuilds.
    ref.listen(
      translationDashboardProvider.select((s) => s.permissionNoticeId),
      (previous, next) {
        if (next > (previous ?? 0)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(strings.storagePermissionPermanentlyDenied),
              action: SnackBarAction(
                label: strings.openAppSettingsAction,
                onPressed: () => AndroidServiceBridge.openAppSettings(),
              ),
            ),
          );
        }
      },
    );

    return PageScaffold(
      title: strings.translationPageTitle,
      subtitle: strings.translationPageSubtitle,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DashboardOverview(),
          _DashboardInputs(),
          _DashboardWorkflow(),
          _DashboardStyleProfile(),
          _DashboardLogs(),
        ],
      ),
    );
  }
}

class _DashboardOverview extends ConsumerWidget {
  const _DashboardOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    final settingsController = ref.read(settingsProvider.notifier);
    final overview = ref.watch(
      translationDashboardProvider.select(
        (s) => (
          job: s.job,
          estimate: s.runEstimate,
          isSaving: s.isSaving,
          isSharing: s.isSharing,
          actionableError: s.actionableError,
          isRunActive: s.isRunActive,
          inspectedChapters: s.inspectedChapters,
          requiresStyleProfileConfirmation: s.requiresStyleProfileConfirmation,
        ),
      ),
    );
    final TranslationJob? job = overview.job;
    final bool showOverview =
        overview.actionableError != null ||
        (job != null && job.status != TranslationJobStatus.idle) ||
        (job?.hasExportableEpub ?? false);
    if (!showOverview) {
      return const SizedBox.shrink();
    }
    final selectedChapters = overview.inspectedChapters.where(
      (chapter) => chapter.includeInTranslation,
    );
    final int selectedBlocks = selectedChapters.fold<int>(
      0,
      (int sum, chapter) => sum + chapter.blocks.length,
    );
    final bool canTranslate =
        selectedChapters.isNotEmpty &&
        (selectedBlocks == 0 || !overview.requiresStyleProfileConfirmation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TranslationOverview(
          strings: strings,
          job: job,
          onExportPressed: controller.exportTranslatedEpub,
          onSaveToDownloadsPressed: controller.saveTranslatedEpubToDownloads,
          canTranslate: canTranslate,
          estimate: overview.estimate,
          canCancel: overview.isRunActive,
          onCancelPressed: controller.requestCancel,
          isSaving: overview.isSaving,
          isSharing: overview.isSharing,
          actionableErrorTitle: overview.actionableError?.title,
          actionableErrorBody: overview.actionableError?.message,
          actionableErrorActionLabel: overview.actionableError?.actionLabel,
          onDismissActionableError: controller.clearActionableError,
          onActionableErrorPressed: () async {
            final ActionableError? error = overview.actionableError;
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
        const SizedBox(height: 20),
      ],
    );
  }
}

class _DashboardInputs extends ConsumerWidget {
  const _DashboardInputs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    final settingsController = ref.read(settingsProvider.notifier);
    final inputs = ref.watch(
      translationDashboardProvider.select(
        (s) => (
          inputPath: s.inputPath,
          outputDirectory: s.outputDirectory,
          targetLanguage: s.config.targetLanguage,
          bilingual: s.config.bilingual,
          isRunActive: s.isRunActive,
          inspectedChapters: s.inspectedChapters,
          requiresStyleProfileConfirmation: s.requiresStyleProfileConfirmation,
        ),
      ),
    );
    final selectedChapters = inputs.inspectedChapters.where(
      (chapter) => chapter.includeInTranslation,
    );
    final int selectedBlocks = selectedChapters.fold<int>(
      0,
      (int sum, chapter) => sum + chapter.blocks.length,
    );
    final bool canTranslate =
        selectedChapters.isNotEmpty &&
        (selectedBlocks == 0 || !inputs.requiresStyleProfileConfirmation);
    final bool isRunActive = inputs.isRunActive;
    final bool hasInput = inputs.inputPath.isNotEmpty;

    // Primary actions only when they add value beyond the drop zone.
    final List<Widget> primaryActions = <Widget>[];
    // Path edits commit on blur/submit, and tapping a button does not move
    // focus — unfocus first so a run started right after typing reads the
    // freshly typed paths instead of silently using stale ones.
    void unfocusBeforeRun() => FocusScope.of(context).unfocus();
    if (!isRunActive && canTranslate) {
      primaryActions.add(
        FilledButton.icon(
          onPressed: () {
            unfocusBeforeRun();
            controller.startTranslation();
          },
          icon: const Icon(Icons.translate_rounded),
          label: Text(strings.translateSelected),
        ),
      );
      if (hasInput) {
        primaryActions.add(
          TextButton(
            onPressed: () {
              unfocusBeforeRun();
              controller.startInspection();
            },
            child: Text(strings.reinspectEpub),
          ),
        );
      }
    } else if (!isRunActive && hasInput) {
      primaryActions.add(
        FilledButton.icon(
          onPressed: () {
            unfocusBeforeRun();
            controller.startInspection();
          },
          icon: const Icon(Icons.playlist_add_check_circle_rounded),
          label: Text(strings.inspectEpub),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TranslationInputs(
          key: const ValueKey<String>('translation-inputs'),
          actions: primaryActions,
          chapterSummary: inputs.inspectedChapters.isNotEmpty
              ? strings.chapterChecklistSummary(
                  selectedChapters.length,
                  inputs.inspectedChapters.length,
                  selectedBlocks,
                )
              : null,
          onPreviewPressed: () => context.go('/preview'),
          strings: strings,
          inputPath: inputs.inputPath,
          outputDirectory: inputs.outputDirectory,
          targetLanguage: inputs.targetLanguage,
          bilingual: inputs.bilingual,
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
      ],
    );
  }
}

class _DashboardWorkflow extends ConsumerWidget {
  const _DashboardWorkflow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final workflow = ref.watch(
      translationDashboardProvider.select(
        (s) => (
          inputPath: s.inputPath,
          inspectedChapters: s.inspectedChapters,
          job: s.job,
          requiresStyleProfileConfirmation: s.requiresStyleProfileConfirmation,
        ),
      ),
    );
    final selectedChapters = workflow.inspectedChapters.where(
      (chapter) => chapter.includeInTranslation,
    );
    final int selectedBlocks = selectedChapters.fold<int>(
      0,
      (int sum, chapter) => sum + chapter.blocks.length,
    );
    return TranslationWorkflowSteps(
      strings: strings,
      hasInput: workflow.inputPath.isNotEmpty,
      hasInspectedChapters: workflow.inspectedChapters.isNotEmpty,
      canTranslate:
          selectedChapters.isNotEmpty &&
          (selectedBlocks == 0 || !workflow.requiresStyleProfileConfirmation),
      job: workflow.job,
    );
  }
}

class _DashboardStyleProfile extends ConsumerWidget {
  const _DashboardStyleProfile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    final profile = ref.watch(
      translationDashboardProvider.select(
        (s) => (
          styleProfileEnabled: s.config.styleProfileEnabled,
          inspectedChapters: s.inspectedChapters,
          requiresStyleProfileConfirmation: s.requiresStyleProfileConfirmation,
          styleProfile: s.styleProfile,
          styleProfileConfirmed: s.styleProfileConfirmed,
          isGeneratingStyleProfile: s.isGeneratingStyleProfile,
          isRunActive: s.isRunActive,
        ),
      ),
    );
    final bool hasInspected = profile.inspectedChapters.isNotEmpty;
    if (!profile.styleProfileEnabled || !hasInspected) {
      return const SizedBox.shrink();
    }
    final int selectedBlocks = profile.inspectedChapters
        .where((chapter) => chapter.includeInTranslation)
        .fold<int>(0, (int sum, chapter) => sum + chapter.blocks.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        if (profile.requiresStyleProfileConfirmation && selectedBlocks > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              strings.reviewStyleFirst,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        TranslationStyleProfileCard(
          strings: strings,
          profile: profile.styleProfile,
          confirmed: profile.styleProfileConfirmed,
          enabled: true,
          editable: !profile.isRunActive,
          isGenerating: profile.isGeneratingStyleProfile,
          canGenerate: hasInspected && !profile.isRunActive,
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
    );
  }
}

class _DashboardLogs extends ConsumerWidget {
  const _DashboardLogs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final List<String> logs = ref.watch(
      translationDashboardProvider.select((s) => s.logs),
    );
    if (logs.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 14),
        TranslationLogs(strings: strings, logs: logs, initiallyExpanded: false),
      ],
    );
  }
}
