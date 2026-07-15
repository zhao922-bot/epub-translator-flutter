import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../translation/domain/models/api_provider_preset.dart';
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
          // —— Appearance ——
          SectionCard(
            title: strings.appearanceSection,
            icon: Icons.palette_outlined,
            variant: SectionCardVariant.standard,
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
          // —— API ——
          SectionCard(
            title: strings.apiSection,
            icon: Icons.cloud_outlined,
            variant: SectionCardVariant.emphasis,
            trailing: FilledButton.tonalIcon(
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
                    final bool selected = preset.matches(config);
                    return ChoiceChip(
                      label: Text(preset.label),
                      selected: selected,
                      onSelected: (_) =>
                          controller.applyApiProviderPreset(preset),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                _SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-api-base-url'),
                  value: config.apiBaseUrl,
                  onChanged: controller.setApiBaseUrl,
                  decoration: InputDecoration(
                    labelText: strings.baseUrl,
                    prefixIcon: const Icon(Icons.cloud_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                _SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-api-key'),
                  value: config.apiKey,
                  onChanged: controller.setApiKey,
                  obscureText: true,
                  canToggleObscureText: true,
                  decoration: InputDecoration(
                    labelText: strings.apiKey,
                    prefixIcon: const Icon(Icons.key_outlined),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                _SettingsTextField(
                  fieldKey: const ValueKey<String>('settings-model'),
                  value: config.model,
                  onChanged: controller.setModel,
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
          const SizedBox(height: 14),
          // —— Translation ——
          SectionCard(
            title: strings.translationSection,
            icon: Icons.tune_rounded,
            variant: SectionCardVariant.standard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _TuningPresetSelector(
                  config: config,
                  controller: controller,
                  strings: strings,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(strings.residualQualityCheck),
                  subtitle: Text(strings.residualQualityCheckBody),
                  value: config.residualQualityCheck,
                  onChanged: controller.setResidualQualityCheck,
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
                      onChanged: controller.setChunkSize,
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
                      onChanged: controller.setMaxConcurrent,
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
                      onChanged: controller.setTimeoutSeconds,
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
                      onChanged: controller.setMaxRetries,
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
                      onChanged: controller.setRetryDelaySeconds,
                    ),
                    _SettingsTextField(
                      fieldKey: const ValueKey<String>(
                        'settings-output-suffix',
                      ),
                      value: config.outputSuffix,
                      onChanged: controller.setOutputSuffix,
                      decoration: InputDecoration(
                        labelText: strings.outputSuffix,
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _SettingsTextField(
                      fieldKey: const ValueKey<String>(
                        'settings-locked-glossary',
                      ),
                      value: config.lockedGlossary,
                      onChanged: controller.setLockedGlossary,
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
        ],
      ),
    );
  }
}

class _TuningPresetSelector extends StatelessWidget {
  const _TuningPresetSelector({
    required this.config,
    required this.controller,
    required this.strings,
  });

  final TranslationConfig config;
  final SettingsController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _PresetChip(
          label: strings.stablePreset,
          selected: TranslationTuningPreset.stable.matches(config),
          onTap: () =>
              controller.applyTuningPreset(TranslationTuningPreset.stable),
        ),
        _PresetChip(
          label: strings.balancedPreset,
          selected: TranslationTuningPreset.balanced.matches(config),
          onTap: () =>
              controller.applyTuningPreset(TranslationTuningPreset.balanced),
        ),
        _PresetChip(
          label: strings.fastPreset,
          selected: TranslationTuningPreset.fast.matches(config),
          onTap: () =>
              controller.applyTuningPreset(TranslationTuningPreset.fast),
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _SettingsTextField extends StatefulWidget {
  const _SettingsTextField({
    required this.fieldKey,
    required this.value,
    required this.onChanged,
    required this.decoration,
    this.obscureText = false,
    this.canToggleObscureText = false,
    this.maxLines = 1,
  });

  final Key fieldKey;
  final String value;
  final ValueChanged<String> onChanged;
  final InputDecoration decoration;
  final bool obscureText;
  final bool canToggleObscureText;
  final int maxLines;

  @override
  State<_SettingsTextField> createState() => _SettingsTextFieldState();
}

class _SettingsTextFieldState extends State<_SettingsTextField> {
  late final TextEditingController _controller;
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _obscureText = widget.obscureText;
  }

  @override
  void didUpdateWidget(covariant _SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.obscureText != oldWidget.obscureText) {
      _obscureText = widget.obscureText;
    }
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final InputDecoration decoration = widget.canToggleObscureText
        ? widget.decoration.copyWith(
            suffixIcon: IconButton(
              tooltip: _obscureText ? 'Show API key' : 'Hide API key',
              onPressed: () {
                setState(() {
                  _obscureText = !_obscureText;
                });
              },
              icon: Icon(
                _obscureText
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
              ),
            ),
          )
        : widget.decoration;

    return TextFormField(
      key: widget.fieldKey,
      controller: _controller,
      obscureText: widget.maxLines > 1 ? false : _obscureText,
      maxLines: widget.maxLines,
      minLines: widget.maxLines > 1 ? 3 : 1,
      onChanged: widget.onChanged,
      decoration: decoration,
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
        ? scheme.errorContainer
        : scheme.primaryContainer;
    final Color foreground = isError
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: foreground),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
