import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final connectionTestState = ref.watch(connectionTestProvider);
    final connectionTestController = ref.read(connectionTestProvider.notifier);
    final strings = ref.watch(appStringsProvider);

    return PageScaffold(
      title: strings.settingsTitle,
      subtitle: strings.settingsSubtitle,
      child: Column(
        children: <Widget>[
          SectionCard(
            title: strings.uiLanguage,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<UiLanguage>(
                showSelectedIcon: false,
                segments: <ButtonSegment<UiLanguage>>[
                  ButtonSegment<UiLanguage>(
                    value: UiLanguage.english,
                    label: Text(strings.englishLabel),
                  ),
                  ButtonSegment<UiLanguage>(
                    value: UiLanguage.chinese,
                    label: Text(strings.chineseLabel),
                  ),
                ],
                selected: <UiLanguage>{config.uiLanguage},
                onSelectionChanged: (Set<UiLanguage> selection) {
                  controller.setUiLanguage(selection.first);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: strings.apiSection,
            trailing: FilledButton.icon(
              onPressed: connectionTestState.isLoading
                  ? null
                  : () => connectionTestController.run(
                      ref.read(settingsProvider),
                    ),
              icon: connectionTestState.isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_rounded),
              label: Text(
                connectionTestState.isLoading
                    ? strings.testingConnection
                    : strings.testConnection,
              ),
            ),
            child: Column(
              children: <Widget>[
                TextFormField(
                  initialValue: config.apiBaseUrl,
                  onChanged: controller.setApiBaseUrl,
                  decoration: InputDecoration(
                    labelText: strings.baseUrl,
                    prefixIcon: const Icon(Icons.cloud_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: config.apiKey,
                  onChanged: controller.setApiKey,
                  decoration: InputDecoration(
                    labelText: strings.apiKey,
                    prefixIcon: const Icon(Icons.key_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: config.model,
                  onChanged: controller.setModel,
                  decoration: InputDecoration(
                    labelText: strings.model,
                    prefixIcon: const Icon(Icons.memory_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                switch (connectionTestState) {
                  AsyncData<String?>(:final value)
                      when value != null && value.isNotEmpty =>
                    _ConnectionBanner(
                      title: strings.connectionOk,
                      body: value,
                      isError: false,
                    ),
                  AsyncError(:final error) => _ConnectionBanner(
                    title: strings.connectionFailed,
                    body: '$error',
                    isError: true,
                  ),
                  _ => const SizedBox.shrink(),
                },
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: strings.translationSection,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(strings.chunkSizeLabel(config.chunkSize)),
                Slider(
                  min: 1000,
                  max: 12000,
                  divisions: 11,
                  value: config.chunkSize.toDouble(),
                  onChanged: controller.setChunkSize,
                ),
                const SizedBox(height: 8),
                Text(strings.maxConcurrentLabel(config.maxConcurrent)),
                Slider(
                  min: 1,
                  max: 8,
                  divisions: 7,
                  value: config.maxConcurrent.toDouble(),
                  onChanged: controller.setMaxConcurrent,
                ),
                const SizedBox(height: 8),
                Text(strings.timeoutLabel(config.timeoutSeconds)),
                Slider(
                  min: 30,
                  max: 300,
                  divisions: 9,
                  value: config.timeoutSeconds.toDouble(),
                  onChanged: controller.setTimeoutSeconds,
                ),
                const SizedBox(height: 8),
                Text(strings.maxRetriesLabel(config.maxRetries)),
                Slider(
                  min: 1,
                  max: 6,
                  divisions: 5,
                  value: config.maxRetries.toDouble(),
                  onChanged: controller.setMaxRetries,
                ),
                const SizedBox(height: 8),
                Text(strings.retryDelayLabel(config.retryDelaySeconds)),
                Slider(
                  min: 1,
                  max: 15,
                  divisions: 14,
                  value: config.retryDelaySeconds.toDouble(),
                  onChanged: controller.setRetryDelaySeconds,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.disableThinking),
                  value: config.disableThinking,
                  onChanged: controller.setDisableThinking,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: config.outputSuffix,
                  onChanged: controller.setOutputSuffix,
                  decoration: InputDecoration(
                    labelText: strings.outputSuffix,
                    prefixIcon: const Icon(
                      Icons.drive_file_rename_outline_rounded,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.title,
    required this.body,
    required this.isError,
  });

  final String title;
  final String body;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = isError
        ? scheme.tertiaryContainer
        : scheme.secondaryContainer;
    final Color foreground = isError
        ? scheme.onTertiaryContainer
        : scheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: foreground),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: foreground, height: 1.45),
          ),
        ],
      ),
    );
  }
}
