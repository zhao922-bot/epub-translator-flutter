import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';
import 'settings_copy.dart';

class SettingsReasoningControls extends ConsumerWidget {
  const SettingsReasoningControls({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      settingsProvider.select(
        (c) => (
          c.apiProviderSelection,
          c.apiBaseUrl,
          c.model,
          c.reasoningEffort,
          c.thinkingMode,
          c.customReasoning,
          c.tokenSavingMode,
        ),
      ),
    );
    final config = ref.read(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final strings = ref.watch(appStringsProvider);
    final capabilities = config.capabilities;
    final customApi =
        config.apiProviderSelection == ApiProviderSelection.custom;
    final customReasoning = config.customReasoning;
    final matchingCustom =
        customApi &&
        customReasoning?.matches(config.apiBaseUrl, config.model) == true;
    final current = config.reasoningEffort;
    final efforts = [
      ModelReasoningEffort.automatic,
      ModelReasoningEffort.providerDefault,
      for (final effort in ModelReasoningEffort.wireValues)
        if (capabilities.supportedEfforts.contains(effort)) effort,
      if (matchingCustom) ModelReasoningEffort.custom,
    ];
    final isExistingUnsupported = !efforts.contains(current);
    final configureCustom =
        enabled &&
            config.apiBaseUrl.trim().isNotEmpty &&
            config.model.trim().isNotEmpty
        ? () async {
            final parameters = await showDialog<CustomReasoningParameters>(
              context: context,
              builder: (_) => _CustomReasoningDialog(
                strings: strings,
                baseUrl: config.apiBaseUrl,
                model: config.model,
                existing: matchingCustom ? customReasoning : null,
              ),
            );
            if (context.mounted && parameters != null) {
              await controller.setCustomReasoning(parameters);
            }
          }
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<ModelReasoningEffort>(
          key: ValueKey('reasoning-${current.name}-${efforts.join(',')}'),
          initialValue: isExistingUnsupported ? null : current,
          hint: isExistingUnsupported
              ? Text(
                  strings.savedReasoningChoice(current),
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.modelReasoningEffort),
          items: [
            for (final effort in efforts)
              DropdownMenuItem(
                value: effort,
                child: Text(strings.reasoningEffortLabel(effort)),
              ),
          ],
          onChanged: enabled
              ? (effort) {
                  if (effort != null) controller.setReasoningEffort(effort);
                }
              : null,
        ),
        if (current == ModelReasoningEffort.automatic)
          Text(strings.automaticReasoningBody),
        if (current == ModelReasoningEffort.providerDefault)
          Text(strings.providerDefaultReasoningBody),
        if (capabilities.supportsThinkingSwitch &&
            current != ModelReasoningEffort.providerDefault &&
            current != ModelReasoningEffort.custom) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<ModelThinkingMode>(
            key: ValueKey('thinking-${config.thinkingMode.name}'),
            initialValue: config.thinkingMode,
            isExpanded: true,
            decoration: InputDecoration(labelText: strings.thinkingMode),
            items: [
              for (final mode in ModelThinkingMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(strings.thinkingModeLabel(mode)),
                ),
            ],
            onChanged: enabled
                ? (mode) {
                    if (mode != null) controller.setThinkingMode(mode);
                  }
                : null,
          ),
        ],
        if (customApi)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: configureCustom,
              child: Text(strings.configureCustomReasoning),
            ),
          ),
      ],
    );
  }
}

class _CustomReasoningDialog extends StatefulWidget {
  const _CustomReasoningDialog({
    required this.strings,
    required this.baseUrl,
    required this.model,
    this.existing,
  });

  final AppStrings strings;
  final String baseUrl;
  final String model;
  final CustomReasoningParameters? existing;

  @override
  State<_CustomReasoningDialog> createState() => _CustomReasoningDialogState();
}

class _CustomReasoningDialogState extends State<_CustomReasoningDialog> {
  late CustomReasoningField _field =
      widget.existing?.field ?? CustomReasoningField.effort;
  late String _value = widget.existing?.value ?? ModelReasoningEffort.low.name;

  void _setField(CustomReasoningField field) {
    setState(() {
      _field = field;
      _value = field.isEffort
          ? ModelReasoningEffort.low.name
          : field.isBudget
          ? ''
          : ModelThinkingMode.enabled.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final choice = CustomReasoningParameters.forEndpoint(
      baseUrl: widget.baseUrl,
      model: widget.model,
      field: _field,
      value: _value,
    );
    return AlertDialog(
      title: Text(strings.configureCustomReasoning),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(strings.customReasoningBody(widget.model)),
              const SizedBox(height: 12),
              DropdownButtonFormField<CustomReasoningField>(
                isExpanded: true,
                initialValue: _field,
                decoration: InputDecoration(
                  labelText: strings.reasoningParameter,
                ),
                items: [
                  for (final field in CustomReasoningField.values)
                    DropdownMenuItem(
                      value: field,
                      child: Text(field.wireLabel),
                    ),
                ],
                onChanged: (field) {
                  if (field != null) _setField(field);
                },
              ),
              const SizedBox(height: 12),
              if (_field.isBudget)
                TextFormField(
                  key: ValueKey(_field),
                  initialValue: _value,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: strings.reasoningBudget,
                    helperText: strings.numericRange(1, 32768),
                  ),
                  onChanged: (value) => setState(() => _value = value),
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey(_field),
                  isExpanded: true,
                  initialValue: _value,
                  decoration: InputDecoration(
                    labelText: strings.reasoningValue,
                  ),
                  items: _field.isEffort
                      ? [
                          for (final effort in ModelReasoningEffort.wireValues)
                            DropdownMenuItem(
                              value: effort.name,
                              child: Text(strings.reasoningEffortLabel(effort)),
                            ),
                        ]
                      : [
                          for (final mode in const [
                            ModelThinkingMode.enabled,
                            ModelThinkingMode.disabled,
                          ])
                            DropdownMenuItem(
                              value: mode.name,
                              child: Text(strings.thinkingModeLabel(mode)),
                            ),
                        ],
                  onChanged: (value) {
                    if (value != null) setState(() => _value = value);
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancelRun),
        ),
        FilledButton(
          onPressed: choice == null
              ? null
              : () => Navigator.of(context).pop(choice),
          child: Text(strings.applyCustomReasoning),
        ),
      ],
    );
  }
}
