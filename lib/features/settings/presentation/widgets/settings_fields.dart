import 'dart:async';

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
    required this.strings,
    this.obscureText = false,
    this.canToggleObscureText = false,
    this.maxLines = 1,
    this.enabled = true,
  });

  final Key fieldKey;
  final String value;
  final ValueChanged<String> onChanged;
  final InputDecoration decoration;
  final AppStrings strings;
  final bool obscureText;
  final bool canToggleObscureText;
  final int maxLines;
  final bool enabled;

  @override
  State<SettingsTextField> createState() => SettingsTextFieldState();
}

class SettingsTextFieldState extends State<SettingsTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late bool _obscureText;

  /// Every keystroke used to call `onChanged` directly, and each call
  /// persisted the whole settings (all secret slots + settings.json — on
  /// Windows every secret slot spawns a PowerShell process). Typing a 40
  /// character API key therefore spawned ~80 PowerShell processes and made
  /// typing stutter. Commits are now debounced; the in-memory text stays
  /// fully responsive while the expensive persist runs once the user pauses.
  static const Duration _commitDelay = Duration(milliseconds: 800);
  Timer? _commitTimer;
  String _lastCommitted = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _lastCommitted = widget.value;
    _obscureText = widget.obscureText;
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    // Commit on blur so tabbing away never loses the last typed characters.
    if (!_focusNode.hasFocus) {
      _flushCommit();
    }
  }

  void _scheduleCommit() {
    _commitTimer?.cancel();
    if (_controller.text == _lastCommitted) {
      return;
    }
    _commitTimer = Timer(_commitDelay, _flushCommit);
  }

  void _flushCommit() {
    _commitTimer?.cancel();
    _commitTimer = null;
    if (!mounted) {
      return;
    }
    final String text = _controller.text;
    if (text == _lastCommitted) {
      return;
    }
    _lastCommitted = text;
    widget.onChanged(text);
  }

  @override
  void didUpdateWidget(covariant SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.obscureText != oldWidget.obscureText) {
      _obscureText = widget.obscureText;
    }
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      // An external value (e.g. a preset) supersedes any pending keystrokes.
      _commitTimer?.cancel();
      _commitTimer = null;
      _lastCommitted = widget.value;
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
    if (oldWidget.enabled && !widget.enabled) {
      // The run started and disabled the field: discard the half-typed,
      // unconfirmed input instead of persisting it mid-run. Marking it as
      // committed suppresses the timer, the blur commit that disabling
      // triggers, and a later dispose flush.
      _commitTimer?.cancel();
      _commitTimer = null;
      _lastCommitted = _controller.text;
    }
  }

  @override
  void dispose() {
    // Flush any pending debounced commit before tearing down: leaving the
    // page within the debounce window must not silently drop the last typed
    // characters. _flushCommit is safe here — mounted is still true during
    // dispose, and it only forwards to widget.onChanged (memory + persist),
    // the same path blur uses.
    _flushCommit();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final InputDecoration decoration = widget.canToggleObscureText
        ? widget.decoration.copyWith(
            suffixIcon: IconButton(
              key: const ValueKey<String>('toggleApiKeyVisibility'),
              tooltip: _obscureText
                  ? widget.strings.showApiKey
                  : widget.strings.hideApiKey,
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
      focusNode: _focusNode,
      obscureText: widget.maxLines > 1 ? false : _obscureText,
      maxLines: widget.maxLines,
      minLines: widget.maxLines > 1 ? 3 : 1,
      enabled: widget.enabled,
      onChanged: widget.enabled ? (_) => _scheduleCommit() : null,
      onFieldSubmitted: widget.enabled ? (_) => _flushCommit() : null,
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
