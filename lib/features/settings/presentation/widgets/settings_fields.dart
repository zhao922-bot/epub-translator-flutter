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
    this.onCommit,
    this.resetKey,
    required this.decoration,
    required this.strings,
    this.obscureText = false,
    this.canToggleObscureText = false,
    this.maxLines = 1,
    this.enabled = true,
    this.readOnly = false,
  });

  final Key fieldKey;
  final String value;
  final FutureOr<void> Function(String) onChanged;

  /// False keeps the value retryable when loading or persistence failed.
  final FutureOr<bool> Function(String)? onCommit;

  /// Explicit preset changes replace pending edits; save echoes do not.
  final Object? resetKey;
  final InputDecoration decoration;
  final AppStrings strings;
  final bool obscureText;
  final bool canToggleObscureText;
  final int maxLines;
  final bool enabled;
  final bool readOnly;

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
  Future<bool>? _pendingCommit;
  String? _pendingText;
  int _commitSequence = 0;

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
    if (_controller.text == _lastCommitted &&
        (_pendingCommit == null || _pendingText == _controller.text)) {
      return;
    }
    _commitTimer = Timer(_commitDelay, () => unawaited(commitPending()));
  }

  void _flushCommit() {
    unawaited(commitPending());
  }

  /// Commit the displayed value before an action consumes settings. Await
  /// the controller so its asynchronous initial-load gate has also completed.
  Future<bool> commitPending() async {
    _commitTimer?.cancel();
    _commitTimer = null;
    if (!mounted || !widget.enabled) {
      return false;
    }
    final String text = _controller.text;
    if (text == _pendingText) {
      return _pendingCommit!;
    }
    if (_pendingCommit == null && text == _lastCommitted) return true;
    final sequence = ++_commitSequence;
    _pendingText = text;
    final pending = _commitText(text, sequence);
    _pendingCommit = pending;
    return pending;
  }

  Future<bool> _commitText(String text, int sequence) async {
    try {
      final commit = widget.onCommit;
      final bool succeeded;
      if (commit != null) {
        succeeded = await commit(text);
      } else {
        await widget.onChanged(text);
        succeeded = true;
      }
      if (sequence == _commitSequence && succeeded) _lastCommitted = text;
      return succeeded;
    } catch (_) {
      // Controller callbacks surface their own persistence notice. A failed
      // callback must also remain retryable and must not escape a timer.
      return false;
    } finally {
      if (sequence == _commitSequence) {
        _pendingCommit = null;
        _pendingText = null;
      }
    }
  }

  @override
  void didUpdateWidget(covariant SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.obscureText != oldWidget.obscureText) {
      _obscureText = widget.obscureText;
    }
    final reset = widget.resetKey != oldWidget.resetKey;
    final dirty = _controller.text != _lastCommitted;
    if (reset ||
        (widget.value != oldWidget.value &&
            widget.value != _controller.text &&
            !dirty &&
            _pendingCommit == null)) {
      // Initial values update untouched fields. Only an explicit preset
      // change may supersede newer edits during an older async commit.
      _commitTimer?.cancel();
      _commitTimer = null;
      _commitSequence++;
      _pendingCommit = null;
      _pendingText = null;
      _lastCommitted = widget.value;
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
    if (oldWidget.enabled && !widget.enabled) {
      // Discard half-typed input during a run, but retain the last confirmed
      // save. widget.value may itself be a failed or pending memory update.
      // commitPending blocks blur/dispose writes while disabled.
      _commitTimer?.cancel();
      _commitTimer = null;
      _controller.text = widget.value;
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
      readOnly: widget.readOnly,
      onChanged: widget.enabled && !widget.readOnly
          ? (_) => _scheduleCommit()
          : null,
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
