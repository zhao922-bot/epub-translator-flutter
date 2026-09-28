import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../widgets/settings_fields.dart';
import '../widgets/settings_sections.dart';
import '../../../translation/domain/models/api_provider_preset.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../../translation/infrastructure/epub/translation_api_client.dart';
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
    final bool secretKeyRotated =
        ref.watch(secretKeyRotatedNoticeProvider) != null;

    // Surface persistence failures (e.g. the secret store timing out): the
    // fields already show the new values, so warn instead of failing silently.
    // Repeated failures with the same message are merged into one notice —
    // without this a broken secret backend would fire a SnackBar per commit.
    ref.listen(settingsSaveErrorProvider, (previous, next) {
      if (next != null &&
          next.message != null &&
          next.message != previous?.message) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              next.settingsFileLocked
                  ? strings.settingsFileLocked(next.message ?? '')
                  : strings.settingsSaveFailed,
            ),
          ),
        );
      }
    });

    return PageScaffold(
      title: strings.settingsTitle,
      subtitle: strings.settingsSubtitle,
      child: Column(
        children: <Widget>[
          // —— 安全提示 ——
          // Android KeyStore 密钥被轮换（锁屏/生物识别变更）：已保存的密钥
          // 已不可恢复，提醒用户重新输入。
          if (secretKeyRotated)
            _SettingsWarningBanner(text: strings.secretKeyRotatedWarning),
          // Windows 提权运行：DPAPI 密钥与普通用户不互通，提醒用户。
          if (PlatformUtils.isWindows)
            FutureBuilder<bool>(
              future: NativePlatformBridge.isWindowsElevated(),
              builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
                if (snapshot.data != true) {
                  return const SizedBox.shrink();
                }
                return _SettingsWarningBanner(
                  text: strings.windowsElevatedSecretWarning,
                );
              },
            ),
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
                  strings: strings,
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
                  strings: strings,
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
                  strings: strings,
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
                SettingsTextField(
                  strings: strings,
                  fieldKey: const ValueKey<String>('settings-http-proxy'),
                  value: config.httpProxy,
                  onChanged: controller.setHttpProxy,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.httpProxy,
                    hintText: strings.httpProxyHint,
                    prefixIcon: const Icon(Icons.vpn_lock_outlined),
                    isDense: true,
                    // Invalid values are treated as "no proxy" by the HTTP
                    // client; surface that here instead of letting the user
                    // discover it through a mysterious connection failure.
                    errorText:
                        switch (TranslationApiClient.validateProxySetting(
                          config.httpProxy,
                        )) {
                          null => null,
                          ProxySettingError.unsupportedScheme =>
                            strings.httpProxyUnsupportedScheme,
                          ProxySettingError.invalidFormat =>
                            strings.httpProxyInvalidFormat,
                        },
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
                      strings: strings,
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
                      strings: strings,
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

/// Warning banner shown at the top of the settings page for secret-store
/// conditions the user must act on (Android KeyStore rotation, Windows
/// elevation). Plain Card + icon so it fits both light and dark themes.
class _SettingsWarningBanner extends StatelessWidget {
  const _SettingsWarningBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
