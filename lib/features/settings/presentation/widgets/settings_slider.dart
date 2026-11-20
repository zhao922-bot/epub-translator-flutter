import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';
import 'settings_copy.dart';

class SettingsSlider extends ConsumerWidget {
  const SettingsSlider({
    super.key,
    required this.select,
    required this.label,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.semanticFormatterCallback,
    this.inputKey,
  });

  final double Function(TranslationConfig) select;
  final String Function(double) label;
  final String Function(double)? semanticFormatterCallback;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Key? inputKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(settingsProvider.select(select));
    final slider = MergeSemantics(
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
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label(value)),
        if (inputKey == null)
          slider
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: slider),
              SizedBox(
                width: 112,
                child: _NumericSettingsField(
                  fieldKey: inputKey!,
                  value: value.round(),
                  min: min.round(),
                  max: max.round(),
                  name: (semanticFormatterCallback ?? label)(value),
                  strings: ref.watch(appStringsProvider),
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _NumericSettingsField extends StatefulWidget {
  const _NumericSettingsField({
    required this.fieldKey,
    required this.value,
    required this.min,
    required this.max,
    required this.name,
    required this.strings,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Key fieldKey;
  final int value;
  final int min;
  final int max;
  final String name;
  final AppStrings strings;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_NumericSettingsField> createState() => _NumericSettingsFieldState();
}

class _NumericSettingsFieldState extends State<_NumericSettingsField> {
  late final _text = TextEditingController(text: widget.value.toString());
  late final _focus = FocusNode()..addListener(_onFocusChanged);
  late int _committedValue = widget.value;
  bool _outOfRange = false;

  @override
  void didUpdateWidget(covariant _NumericSettingsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value ||
        (oldWidget.onChanged != null && widget.onChanged == null)) {
      _committedValue = widget.value;
      final text = widget.value.toString();
      if (_text.text != text) _text.text = text;
      _outOfRange = false;
    }
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final value = int.tryParse(_text.text.trim(), radix: 10);
    if (value == null || value < widget.min || value > widget.max) {
      if (!_outOfRange) setState(() => _outOfRange = true);
      return;
    }
    if (_outOfRange) setState(() => _outOfRange = false);
    final canonicalText = value.toString();
    if (_text.text != canonicalText) _text.text = canonicalText;
    if (value == _committedValue) return;
    _committedValue = value;
    onChanged(value.toDouble());
    widget.onChangeEnd?.call(value.toDouble());
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.strings.editExactValue(widget.name),
      child: TextField(
        key: widget.fieldKey,
        controller: _text,
        focusNode: _focus,
        enabled: widget.onChanged != null,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        textAlign: TextAlign.end,
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) => _focus.unfocus(),
        decoration: InputDecoration(
          isDense: true,
          errorText: _outOfRange
              ? widget.strings.numericRange(widget.min, widget.max)
              : null,
        ),
      ),
    );
  }
}
