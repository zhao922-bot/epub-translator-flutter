import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../widgets/settings_fields.dart';
import '../widgets/settings_sections.dart';
import '../../../translation/domain/models/api_provider_preset.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../application/settings_controller.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(settingsProvider);
    final bool isRunActive = ref.watch(
      translationDashboardProvider.select(
        (TranslationDashboardState state) => state.isRunActive,
      ),
    );
    final controller = ref.read(settingsProvider.notifier);
    final connectionTestState = ref.watch(connectionTestProvider);
    final connectionTestController = ref.read(connectionTestProvider.notifier);
    final strings = ref.watch(appStringsProvider);

    return PageScaffold(
      title: strings.settingsTitle,
      subtitle: strings.settingsSubtitle,
      child: Column(
        children: <Widget>[
          // —— API ——
          SettingsSection(
            title: strings.apiSection,
            icon: Icons.cloud_outlined,
            trailing: FilledButton.tonalIcon(
              onPressed: connectionTestState.isLoading || isRunActive
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
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(
                connectionTestState.isLoading
                    ? strings.testingConnection
                    : strings.testConnection,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ApiProviderPreset.values.map((preset) {
                    return ChoiceChip(
                      key: ValueKey<String>('api-provider-${preset.name}'),
                      label: Text(preset.label),
                      selected: preset.matches(config),
                      onSelected: isRunActive
                          ? null
                          : (_) => controller.applyApiProviderPreset(preset),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-api-base-url'),
                  value: config.apiBaseUrl,
                  onChanged: controller.setApiBaseUrl,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.baseUrl,
                    prefixIcon: const Icon(Icons.cloud_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-api-key'),
                  value: config.apiKey,
                  onChanged: controller.setApiKey,
                  obscureText: true,
                  canToggleObscureText: true,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.apiKey,
                    prefixIcon: const Icon(Icons.key_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-model'),
                  value: config.model,
                  onChanged: controller.setModel,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.model,
                    prefixIcon: const Icon(Icons.memory_rounded),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                switch (connectionTestState) {
                  AsyncData<String?>(:final value)
                      when value != null && value.isNotEmpty =>
                    ConnectionBanner(
                      title: strings.connectionOk,
                      body: value,
                      isError: false,
                    ),
                  AsyncError(:final error) => ConnectionBanner(
                    title: strings.connectionFailed,
                    body: '$error',
                    isError: true,
                  ),
                  _ => const SizedBox.shrink(),
                },
              ],
            ),
          ),
          const SizedBox(height: 14),
          // —— Translation ——
          SettingsSection(
            title: strings.translationSection,
            icon: Icons.tune_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TuningPresetSelector(
                  config: config,
                  controller: controller,
                  strings: strings,
                  enabled: !isRunActive,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(strings.residualQualityCheck),
                  subtitle: Text(strings.residualQualityCheckBody),
                  value: config.residualQualityCheck,
                  onChanged: isRunActive
                      ? null
                      : controller.setResidualQualityCheck,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(strings.styleProfileEnabled),
                  subtitle: Text(strings.styleProfileEnabledBody),
                  value: config.styleProfileEnabled,
                  onChanged: isRunActive
                      ? null
                      : controller.setStyleProfileEnabled,
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(strings.advancedTuning),
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(strings.chunkSizeLabel(config.chunkSize)),
                    ),
                    Slider(
                      min: 1000,
                      max: 12000,
                      divisions: 11,
                      value: config.chunkSize.toDouble(),
                      onChanged: isRunActive ? null : controller.setChunkSize,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        strings.maxConcurrentLabel(config.maxConcurrent),
                      ),
                    ),
                    Slider(
                      min: 1,
                      max: 8,
                      divisions: 7,
                      value: config.maxConcurrent.toDouble(),
                      onChanged: isRunActive
                          ? null
                          : controller.setMaxConcurrent,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(strings.timeoutLabel(config.timeoutSeconds)),
                    ),
                    Slider(
                      min: 30,
                      max: 300,
                      divisions: 9,
                      value: config.timeoutSeconds.toDouble(),
                      onChanged: isRunActive
                          ? null
                          : controller.setTimeoutSeconds,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(strings.maxRetriesLabel(config.maxRetries)),
                    ),
                    Slider(
                      min: 1,
                      max: 6,
                      divisions: 5,
                      value: config.maxRetries.toDouble(),
                      onChanged: isRunActive ? null : controller.setMaxRetries,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        strings.retryDelayLabel(config.retryDelaySeconds),
                      ),
                    ),
                    Slider(
                      min: 1,
                      max: 15,
                      divisions: 14,
                      value: config.retryDelaySeconds.toDouble(),
                      onChanged: isRunActive
                          ? null
                          : controller.setRetryDelaySeconds,
                    ),
                    SettingsTextField(
                      fieldKey: const ValueKey<String>(
                        'settings-output-suffix',
                      ),
                      value: config.outputSuffix,
                      onChanged: controller.setOutputSuffix,
                      enabled: !isRunActive,
                      decoration: InputDecoration(
                        labelText: strings.outputSuffix,
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SettingsTextField(
                      fieldKey: const ValueKey<String>(
                        'settings-locked-glossary',
                      ),
                      value: config.lockedGlossary,
                      onChanged: controller.setLockedGlossary,
                      enabled: !isRunActive,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: strings.lockedGlossary,
                        hintText: strings.lockedGlossaryHint,
                        alignLabelWithHint: true,
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  strings.supportedPlatformsNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          // —— Appearance ——
          SettingsSection(
            title: strings.appearanceSection,
            icon: Icons.palette_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  strings.uiLanguage,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                SegmentedButton<UiLanguage>(
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
                const SizedBox(height: 16),
                Text(
                  strings.themeSection,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                SegmentedButton<AppThemeMode>(
                  showSelectedIcon: false,
                  segments: <ButtonSegment<AppThemeMode>>[
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.system,
                      label: Text(strings.systemThemeLabel),
                    ),
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.light,
                      label: Text(strings.lightThemeLabel),
                    ),
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.dark,
                      label: Text(strings.darkThemeLabel),
                    ),
                  ],
                  selected: <AppThemeMode>{config.themeMode},
                  onSelectionChanged: (Set<AppThemeMode> selection) {
                    controller.setThemeMode(selection.first);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  '${strings.textScaleLabel}: ${config.textScale.toStringAsFixed(2)}x',
                ),
                Slider(
                  min: 0.9,
                  max: 1.3,
                  divisions: 8,
                  value: config.textScale.clamp(0.9, 1.3),
                  onChanged: controller.setTextScale,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
