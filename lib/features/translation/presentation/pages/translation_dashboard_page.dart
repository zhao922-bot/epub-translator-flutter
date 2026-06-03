import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../settings/application/settings_controller.dart';
import '../../application/translation_dashboard_controller.dart';
import '../widgets/translation_inputs.dart';
import '../widgets/translation_logs.dart';
import '../widgets/translation_overview.dart';

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
    final bool canTranslate = state.inspectedChapters.any(
      (chapter) => chapter.includeInTranslation && chapter.blocks.isNotEmpty,
    );

    return PageScaffold(
      title: strings.translationPageTitle,
      subtitle: strings.translationPageSubtitle,
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: controller.startInspection,
          icon: const Icon(Icons.playlist_add_check_circle_rounded),
          label: Text(strings.inspectEpub),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: canTranslate ? controller.startTranslation : null,
          icon: const Icon(Icons.translate_rounded),
          label: Text(strings.translateSelected),
        ),
      ],
      child: Column(
        children: <Widget>[
          TranslationInputs(
            strings: strings,
            inputPath: state.inputPath,
            outputDirectory: state.outputDirectory,
            targetLanguage: state.config.targetLanguage,
            bilingual: state.config.bilingual,
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
            onPickInputPressed: controller.pickInputPath,
            onPickOutputPressed: controller.pickOutputDirectory,
            onStartPressed: controller.startInspection,
          ),
          const SizedBox(height: 16),
          TranslationOverview(
            strings: strings,
            job: state.job,
            onTranslatePressed: controller.startTranslation,
            onExportPressed: controller.exportTranslatedEpub,
            onSaveToDownloadsPressed: controller.saveTranslatedEpubToDownloads,
            canTranslate: canTranslate,
          ),
          const SizedBox(height: 16),
          TranslationLogs(strings: strings, logs: state.logs),
        ],
      ),
    );
  }
}
