import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/platform/windows_elevation_check.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../widgets/settings_fields.dart';
import '../widgets/settings_sections.dart';
import '../../../translation/domain/models/api_provider_preset.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../../translation/infrastructure/epub/translation_api_client.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../../application/settings_controller.dart';
import '../../infrastructure/settings_store.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with WidgetsBindingObserver {
  final _connectionFields = List.generate(
    4,
    (_) => GlobalKey<SettingsTextFieldState>(),
  );
  bool _committingConnectionFields = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final saveError = ref.read(settingsSaveErrorProvider);
      final conflict = ref.read(settingsWriteConflictProvider);
      if (saveError != null || conflict != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saveError?.message ??
                  'Settings failed to load or save earlier; review before editing.',
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A slider value may be sitting in the 400ms debounce window when the
    // app is backgrounded or killed. Flush it now instead of waiting for
    // the timer: dispose()'s unawaited flush is not guaranteed to reach
    // disk before the process dies. (True synchronous IO is impossible in
    // Dart; starting the save at the lifecycle transition is the earliest
    // possible point.)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(settingsProvider.notifier).flushSliderChanges());
      unawaited(_commitConnectionFields());
    }
  }

  Future<bool> _commitConnectionFields() async {
    // Capture every field before settings notifications rebuild the page.
    // Commit the key first so it still belongs to the displayed provider.
    final results = await Future.wait([
      for (final index in [1, 0, 2, 3])
        if (_connectionFields[index].currentState case final field?)
          field.commitPending(),
    ]);
    return results.every((succeeded) => succeeded);
  }

  Future<void> _selectProvider(ApiProviderPreset preset) async {
    if (_committingConnectionFields) return;
    setState(() => _committingConnectionFields = true);
    try {
      if (!await _commitConnectionFields()) return;
      if (!mounted || ref.read(translationDashboardProvider).isRunActive) {
        return;
      }
      await ref.read(settingsProvider.notifier).applyApiProviderPreset(preset);
    } finally {
      if (mounted) setState(() => _committingConnectionFields = false);
    }
  }

  Future<void> _testConnection() async {
    if (_committingConnectionFields ||
        !ref.read(settingsProvider.notifier).canTestConnection) {
      return;
    }
    setState(() => _committingConnectionFields = true);
    try {
      if (!await _commitConnectionFields()) return;
    } finally {
      if (mounted) setState(() => _committingConnectionFields = false);
    }
    if (!mounted || ref.read(translationDashboardProvider).isRunActive) return;
    await ref
        .read(connectionTestProvider.notifier)
        .run(ref.read(settingsProvider));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(settingsProvider.notifier);
    // The page owns non-slider fields; each slider subscribes independently.
    ref.watch(settingsProvider.select((c) => (
      c.apiBaseUrl, c.apiKey, c.model, c.apiProviderSelection,
      c.deepseekApiKey, c.customApiBaseUrl, c.customApiKey, c.customModel,
      c.uiLanguage, c.themeMode, c.targetLanguage, c.bilingual,
      c.outputSuffix, c.residualQualityCheck, c.styleProfileEnabled,
      c.lockedGlossary, c.httpProxy,
      controller.providerSelectionRevision, controller.credentialDiscardRevision,
      controller.secretReadFailed(SettingsSecretSlot.deepSeek),
      controller.secretReadFailed(SettingsSecretSlot.custom),
      controller.secretReadFailed(SettingsSecretSlot.proxy),
    )));
    final config = ref.read(settingsProvider);
    final bool isRunActive = ref.watch(
      translationDashboardProvider.select(
        (TranslationDashboardState state) => state.isRunActive,
      ),
    );
    final replayInProgress = ref.watch(settingsReplayInProgressProvider);
    final settingsLoaded =
        ref.watch(settingsLoadedProvider).hasValue &&
        controller.canTestConnection;
    final connectionTestState = ref.watch(connectionTestProvider);
    ref.watch(appStringsProvider.select((s) => s.isChinese));
    final strings = ref.read(appStringsProvider);
    final bool secretKeyRotated =
        ref.watch(secretKeyRotatedNoticeProvider) != null;
    final bool writeConflict =
        ref.watch(settingsWriteConflictProvider) != null;
    // P2-#37: credential replays blocked by a route change must be visible.
    // The queued edits are retained until the user confirms the new target
    // or discards them.
    final bool replayBlocked =
        ref.watch(settingsReplayBlockedProvider) != null;

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
          // 跨实例写冲突：快照已过期，后续保存会继续冲突。提供"重新加载"
          // 恢复路径：重读磁盘文件后再保存即可通过。
          if (writeConflict)
            _SettingsWarningBanner(
              text: strings.isChinese
                  ? '另一实例修改了设置，当前页面的值可能已过期，保存会失败。请重新加载后再试。'
                  : 'Another instance changed the settings; this page may show stale values and saves will fail. Reload and try again.',
              actionLabel: strings.isChinese ? '重新加载' : 'Reload',
              onAction: () async {
                final eventId = ref.read(settingsWriteConflictProvider)?.id;
                final bool ok = await ref
                    .read(settingsProvider.notifier)
                    .reloadSettings();
                // P2-#38: keep the conflict notice when reload failed so
                // the user doesn't lose the recovery entry. P2-#39: the
                // page may be disposed while the reload is in flight.
                if (ok && mounted &&
                    ref.read(settingsWriteConflictProvider)?.id == eventId) {
                  ref.read(settingsWriteConflictProvider.notifier).state =
                      null;
                }
              },
            ),
          // 凭据回放被路由保护阻止：队列保留，等待用户确认为当前服务地址
          // 或放弃。无提示用户会不知晓凭据修改未生效。
          if (replayBlocked)
            _SettingsWarningBanner(
              text: strings.isChinese
                  ? '有 ${controller.blockedReplayCount} 个凭据修改因服务地址变更被暂缓，等待确认。确认为当前地址后将继续保存，放弃则丢弃这些修改。'
                  : '${controller.blockedReplayCount} credential change(s) are held back because the service address changed. Confirm to save them against the current address, or discard them.',
              actionLabel: strings.isChinese ? '确认应用' : 'Apply',
              onAction: replayInProgress ? null : () async {
                if (controller.isReplayingConflictedEdits) return;
                final eventId = ref.read(settingsReplayBlockedProvider)?.id;
                await controller.confirmBlockedConflictReplays();
                if (mounted &&
                    ref.read(settingsReplayBlockedProvider)?.id == eventId) {
                  ref.read(settingsReplayBlockedProvider.notifier).state =
                      null;
                }
              },
              secondaryActionLabel: strings.isChinese ? '放弃' : 'Discard',
              secondaryActionDisabled: replayInProgress,
              onSecondaryAction: () async {
                controller.discardBlockedConflictReplays();
                if (mounted) {
                  ref.read(settingsReplayBlockedProvider.notifier).state =
                      null;
                }
              },
            ),
          // Windows 提权运行：DPAPI 密钥与普通用户不互通，提醒用户。
          if (PlatformUtils.isWindows) const _WindowsElevatedWarning(),
          // —— API ——
          SettingsSection(
            title: strings.apiSection,
            icon: Icons.cloud_outlined,
            trailing: FilledButton.tonalIcon(
              onPressed:
                  connectionTestState.isLoading ||
                      !settingsLoaded ||
                      isRunActive ||
                      _committingConnectionFields
                  ? null
                  : _testConnection,
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
                      onSelected: isRunActive || _committingConnectionFields
                          ? null
                          : (_) => _selectProvider(preset),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                SettingsTextField(
                  key: _connectionFields[0],
                  strings: strings,
                  fieldKey: const ValueKey<String>('settings-api-base-url'),
                  readOnly: _committingConnectionFields,
                  value: config.apiBaseUrl,
                  onChanged: controller.setApiBaseUrl,
                  onCommit: controller.setApiBaseUrl,
                  resetKey: controller.providerSelectionRevision,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.baseUrl,
                    prefixIcon: const Icon(Icons.cloud_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                SettingsTextField(
                  key: _connectionFields[1],
                  strings: strings,
                  fieldKey: const ValueKey<String>('settings-api-key'),
                  readOnly: _committingConnectionFields,
                  value: config.apiKey,
                  onChanged: controller.setApiKey,
                  onCommit: controller.setApiKey,
                  resetKey: (
                    controller.providerSelectionRevision,
                    controller.credentialDiscardRevision,
                  ),
                  obscureText: true,
                  canToggleObscureText: true,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.apiKey,
                    helperText:
                        controller.secretReadFailed(
                          config.apiProviderSelection ==
                                  ApiProviderSelection.deepseek
                              ? SettingsSecretSlot.deepSeek
                              : SettingsSecretSlot.custom,
                        )
                        ? strings.credentialReadFailed
                        : null,
                    prefixIcon: const Icon(Icons.key_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                SettingsTextField(
                  key: _connectionFields[2],
                  strings: strings,
                  fieldKey: const ValueKey<String>('settings-model'),
                  readOnly: _committingConnectionFields,
                  value: config.model,
                  onChanged: controller.setModel,
                  onCommit: controller.setModel,
                  resetKey: controller.providerSelectionRevision,
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.model,
                    prefixIcon: const Icon(Icons.memory_rounded),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                SettingsTextField(
                  key: _connectionFields[3],
                  strings: strings,
                  fieldKey: const ValueKey<String>('settings-http-proxy'),
                  readOnly: _committingConnectionFields,
                  value: config.httpProxy,
                  onChanged: controller.setHttpProxy,
                  onCommit: controller.setHttpProxy,
                  showSecretTooltip: strings.showProxyCredentials,
                  hideSecretTooltip: strings.hideProxyCredentials,
                  obscureText: true,
                  canToggleObscureText: true,
                  visibilityToggleKey: const ValueKey<String>(
                    'toggleProxyVisibility',
                  ),
                  enabled: !isRunActive,
                  decoration: InputDecoration(
                    labelText: strings.httpProxy,
                    helperText:
                        controller.secretReadFailed(SettingsSecretSlot.proxy)
                        ? strings.credentialReadFailed
                        : null,
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
                Consumer(builder: (context, ref, child) {
                  ref.watch(settingsProvider.select((c) => (
                    c.chunkSize, c.maxConcurrent, c.timeoutSeconds,
                    c.maxRetries, c.retryDelaySeconds,
                  )));
                  return TuningPresetSelector(
                  config: ref.read(settingsProvider),
                  controller: controller,
                  strings: strings,
                  enabled: !isRunActive,
                );
                }),
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
                    _SettingsSlider(
                      select: (c) => c.chunkSize.toDouble(),
                      label: (v) => strings.chunkSizeLabel(v.round()),
                      semanticFormatterCallback: (v) => strings.isChinese
                          ? '分块大小 ${v.round()} 字符'
                          : 'Chunk size ${v.round()} characters',
                      min: 1000,
                      max: 12000,
                      divisions: 11,
                      onChanged: isRunActive ? null : controller.setChunkSize,
                      onChangeEnd: isRunActive
                          ? null
                          : (_) => controller.flushSliderChanges(),
                    ),
                    _SettingsSlider(
                      select: (c) => c.maxConcurrent.toDouble(),
                      label: (v) => strings.maxConcurrentLabel(v.round()),
                      semanticFormatterCallback: (v) => strings.isChinese
                          ? '并发数 ${v.round()}'
                          : 'Concurrency ${v.round()}',
                      min: 1,
                      max: 8,
                      divisions: 7,
                      onChangeEnd: isRunActive
                          ? null
                          : (_) => controller.flushSliderChanges(),
                      onChanged: isRunActive
                          ? null
                          : controller.setMaxConcurrent,
                    ),
                    _SettingsSlider(
                      select: (c) => c.timeoutSeconds.toDouble(),
                      label: (v) => strings.timeoutLabel(v.round()),
                      semanticFormatterCallback: (v) => strings.isChinese
                          ? '超时 ${v.round()} 秒'
                          : 'Timeout ${v.round()} seconds',
                      min: 30,
                      max: 300,
                      divisions: 9,
                      onChangeEnd: isRunActive
                          ? null
                          : (_) => controller.flushSliderChanges(),
                      onChanged: isRunActive
                          ? null
                          : controller.setTimeoutSeconds,
                    ),
                    _SettingsSlider(
                      select: (c) => c.maxRetries.toDouble(),
                      label: (v) => strings.maxRetriesLabel(v.round()),
                      semanticFormatterCallback: (v) => strings.isChinese
                          ? '最多重试 ${v.round()} 次'
                          : 'Maximum retries ${v.round()}',
                      min: 1,
                      max: 6,
                      divisions: 5,
                      onChangeEnd: isRunActive
                          ? null
                          : (_) => controller.flushSliderChanges(),
                      onChanged: isRunActive ? null : controller.setMaxRetries,
                    ),
                    _SettingsSlider(
                      select: (c) => c.retryDelaySeconds.toDouble(),
                      label: (v) => strings.retryDelayLabel(v.round()),
                      semanticFormatterCallback: (v) => strings.isChinese
                          ? '重试间隔 ${v.round()} 秒'
                          : 'Retry delay ${v.round()} seconds',
                      min: 1,
                      max: 15,
                      divisions: 14,
                      onChangeEnd: isRunActive
                          ? null
                          : (_) => controller.flushSliderChanges(),
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
                      onCommit: controller.setOutputSuffix,
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
                      onCommit: controller.setLockedGlossary,
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
                _SettingsSlider(
                  select: (c) => c.textScale.clamp(0.9, 1.3),
                  label: (v) => '${strings.textScaleLabel}: ${v.toStringAsFixed(2)}x',
                  min: 0.9,
                  max: 1.3,
                  divisions: 8,
                  onChanged: controller.setTextScale,
                  onChangeEnd: (_) => controller.flushSliderChanges(),
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

class _SettingsSlider extends ConsumerWidget {
  const _SettingsSlider({
    required this.select, required this.label, required this.min,
    required this.max, required this.divisions, required this.onChanged,
    required this.onChangeEnd,
    this.semanticFormatterCallback,
  });

  final double Function(TranslationConfig) select;
  final String Function(double) label;
  final String Function(double)? semanticFormatterCallback;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(settingsProvider.select(select));
    return Column(children: [
      Align(alignment: Alignment.centerLeft, child: Text(label(value))),
      MergeSemantics(
        child: Semantics(
          child: Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value,
            semanticFormatterCallback: semanticFormatterCallback ?? label,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ),
    ]);
  }
}

/// Shows the Windows-elevation secret warning once the (cached, process-wide)
/// elevation check reports the process is elevated.
///
/// The widget owns a cancellable probe. Disposing it releases the timeout and
/// the child process, while a timeout settles the result and ignores late data.
class _WindowsElevatedWarning extends ConsumerStatefulWidget {
  const _WindowsElevatedWarning();

  @override
  ConsumerState<_WindowsElevatedWarning> createState() =>
      _WindowsElevatedWarningState();
}

class _WindowsElevatedWarningState
    extends ConsumerState<_WindowsElevatedWarning> {
  bool _elevated = false;
  late final WindowsElevationCheck _check;

  @override
  void initState() {
    super.initState();
    _check = NativePlatformBridge.startWindowsElevationCheck();
    unawaited(
      _check.result.then((bool elevated) {
        if (mounted) {
          setState(() {
            _elevated = elevated;
          });
        }
      }),
    );
  }

  @override
  void dispose() {
    _check.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_elevated) {
      return const SizedBox.shrink();
    }
    final AppStrings strings = ref.watch(appStringsProvider);
    return _SettingsWarningBanner(text: strings.windowsElevatedSecretWarning);
  }
}

/// Warning banner shown at the top of the settings page for secret-store
/// conditions the user must act on (Android KeyStore rotation, Windows
/// elevation, cross-instance write conflicts). Plain Card + icon so it fits
/// both light and dark themes. An optional action button (e.g. "Reload")
/// gives the user a recovery path without leaving the page.
class _SettingsWarningBanner extends StatelessWidget {
  const _SettingsWarningBanner({
    required this.text,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.secondaryActionDisabled = false,
  });

  final String text;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final String? secondaryActionLabel;
  final Future<void> Function()? onSecondaryAction;
  final bool secondaryActionDisabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? actionLabel = this.actionLabel;
    final Future<void> Function()? onAction = this.onAction;
    final String? secondaryActionLabel = this.secondaryActionLabel;
    final Future<void> Function()? onSecondaryAction = this.onSecondaryAction;
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
              if (secondaryActionLabel != null && onSecondaryAction != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: secondaryActionDisabled ? null : () {
                    // P2-#39: an unawaited banner action must not drop
                    // errors silently.
                    unawaited(
                      onSecondaryAction().then(
                        (_) {},
                        onError: (Object error) {
                          AppLogger.error(
                            'Settings banner action failed: '
                            '${error.runtimeType}',
                            tag: 'settings',
                          );
                        },
                      ),
                    );
                  },
                  child: Text(secondaryActionLabel),
                ),
              ],
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onAction == null ? null : () {
                    // P2-#39: an unawaited banner action must not drop
                    // errors silently.
                    unawaited(
                      onAction().then(
                        (_) {},
                        onError: (Object error) {
                          AppLogger.error(
                            'Settings banner action failed: '
                            '${error.runtimeType}',
                            tag: 'settings',
                          );
                        },
                      ),
                    );
                  },
                  child: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
