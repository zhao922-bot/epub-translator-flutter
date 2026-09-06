import 'package:flutter/material.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';

class TuningPresetSelector extends StatelessWidget {
  const TuningPresetSelector({
    super.key,
    required this.config,
    required this.controller,
    required this.strings,
    required this.enabled,
  });

  final TranslationConfig config;
  final SettingsController controller;
  final AppStrings strings;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _PresetChip(
          label: strings.stablePreset,
          selected: TranslationTuningPreset.stable.matches(config),
          onTap: enabled
              ? () =>
                    controller.applyTuningPreset(TranslationTuningPreset.stable)
              : null,
        ),
        _PresetChip(
          label: strings.balancedPreset,
          selected: TranslationTuningPreset.balanced.matches(config),
          onTap: enabled
              ? () => controller.applyTuningPreset(
                  TranslationTuningPreset.balanced,
                )
              : null,
        ),
        _PresetChip(
          label: strings.fastPreset,
          selected: TranslationTuningPreset.fast.matches(config),
          onTap: enabled
              ? () => controller.applyTuningPreset(TranslationTuningPreset.fast)
              : null,
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap!(),
    );
  }
}

class SettingsTextField extends StatefulWidget {
  const SettingsTextField({
    super.key,
    required this.fieldKey,
    required this.value,
    required this.onChanged,
    required this.decoration,
    this.obscureText = false,
    this.canToggleObscureText = false,
    this.maxLines = 1,
    this.enabled = true,
  });

  final Key fieldKey;
  final String value;
  final ValueChanged<String> onChanged;
  final InputDecoration decoration;
  final bool obscureText;
  final bool canToggleObscureText;
  final int maxLines;
  final bool enabled;

  @override
  State<SettingsTextField> createState() => SettingsTextFieldState();
}

class SettingsTextFieldState extends State<SettingsTextField> {
  late final TextEditingController _controller;
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _obscureText = widget.obscureText;
  }

  @override
  void didUpdateWidget(covariant SettingsTextField oldWidget) {
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
      enabled: widget.enabled,
      onChanged: widget.enabled ? widget.onChanged : null,
      decoration: decoration,
    );
  }
}

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
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
