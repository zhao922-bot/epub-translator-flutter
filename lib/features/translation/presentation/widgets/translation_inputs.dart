import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/section_card.dart';
import 'translation_preferences.dart';

class TranslationInputs extends StatefulWidget {
  const TranslationInputs({
    super.key,
    required this.strings,
    required this.inputPath,
    required this.outputDirectory,
    required this.targetLanguage,
    required this.bilingual,
    required this.enabled,
    required this.onInputChanged,
    required this.onOutputChanged,
    required this.onTargetLanguageChanged,
    required this.onBilingualChanged,
    required this.onPickInputPressed,
    required this.onPickOutputPressed,
    this.actions = const <Widget>[],
    this.chapterSummary,
    this.onPreviewPressed,
  });

  final AppStrings strings;
  final String inputPath;
  final String outputDirectory;
  final String targetLanguage;
  final bool bilingual;
  final bool enabled;

  /// Fired when the manual input path is committed (Enter or focus leaves
  /// the field), not on every keystroke: the handler has destructive side
  /// effects (it clears the current job and inspection state).
  final ValueChanged<String> onInputChanged;

  /// Same commit semantics as [onInputChanged], for the output directory.
  final ValueChanged<String> onOutputChanged;
  final ValueChanged<String?> onTargetLanguageChanged;
  final ValueChanged<bool> onBilingualChanged;
  final VoidCallback? onPickInputPressed;
  final VoidCallback? onPickOutputPressed;
  final List<Widget> actions;
  final String? chapterSummary;
  final VoidCallback? onPreviewPressed;

  @override
  State<TranslationInputs> createState() => _TranslationInputsState();
}

class _TranslationInputsState extends State<TranslationInputs> {
  bool _showAdvancedPaths = false;
  late final TextEditingController _inputPathController;
  late final TextEditingController _outputDirectoryController;
  late final FocusNode _inputPathFocusNode;
  late final FocusNode _outputDirectoryFocusNode;

  /// Last value synced (or noted) from the widget into each field. Tracks
  /// whether the controller text is genuine user typing vs. stale content:
  /// without this, an external value arriving while the field is focused
  /// would be "reverted" by the blur commit because the untouched controller
  /// still holds the older text.
  late String _syncedInputPath;
  late String _syncedOutputDirectory;

  @override
  void initState() {
    super.initState();
    _inputPathController = TextEditingController(text: widget.inputPath);
    _outputDirectoryController = TextEditingController(
      text: widget.outputDirectory,
    );
    _syncedInputPath = widget.inputPath;
    _syncedOutputDirectory = widget.outputDirectory;
    // Typing must not trigger the controller callbacks on every keystroke:
    // those carry destructive side effects (clearing the current job and
    // inspection state, disk writes, path watchers). Commit only on submit
    // or when focus leaves the field.
    _inputPathFocusNode = FocusNode()..addListener(_commitInputPathOnBlur);
    _outputDirectoryFocusNode = FocusNode()
      ..addListener(_commitOutputDirectoryOnBlur);
  }

  void _commitInputPathOnBlur() {
    _commitInputPath();
  }

  void _commitOutputDirectoryOnBlur() {
    _commitOutputDirectory();
  }

  /// Commits the pending path edits. [force] bypasses the focus check and is
  /// used from [dispose] so uncommitted keystrokes are never silently dropped
  /// when the widget goes away. Only fires when the text is genuine user
  /// typing (differs from the last synced external value): an external value
  /// that arrived while the field was focused must not be reverted by the
  /// blur commit of an untouched field.
  void _commitInputPath({bool force = false}) {
    final String typed = _inputPathController.text;
    if ((force || !_inputPathFocusNode.hasFocus) &&
        widget.enabled &&
        typed != _syncedInputPath &&
        typed != widget.inputPath) {
      widget.onInputChanged(typed);
    }
  }

  void _commitOutputDirectory({bool force = false}) {
    final String typed = _outputDirectoryController.text;
    if ((force || !_outputDirectoryFocusNode.hasFocus) &&
        widget.enabled &&
        typed != _syncedOutputDirectory &&
        typed != widget.outputDirectory) {
      widget.onOutputChanged(typed);
    }
  }

  @override
  void didUpdateWidget(covariant TranslationInputs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Never clobber keystrokes being typed: an external value arriving while
    // the user is actively typing (cold-start session restore, dropped
    // EPUB, …) must wait for blur/submit, where _commit* decides what to do
    // with the uncommitted text. Without the focus guard the typed path is
    // silently replaced, and the later blur commit becomes a no-op because
    // the controller now matches widget.inputPath.
    //
    // But a field that merely *has focus* without any typing is safe to
    // sync: the controller still shows the old external value, so replacing
    // it cannot destroy keystrokes. Skipping the sync in that case would be
    // worse — the blur commit would see the stale text differ from
    // _syncedInputPath and re-submit it, reverting the external update.
    if (widget.inputPath != oldWidget.inputPath) {
      _syncedInputPath = widget.inputPath;
      if (_inputPathController.text == oldWidget.inputPath ||
          !_inputPathFocusNode.hasFocus) {
        if (widget.inputPath != _inputPathController.text) {
          _inputPathController.value = TextEditingValue(
            text: widget.inputPath,
            selection: TextSelection.collapsed(offset: widget.inputPath.length),
          );
        }
      }
    }
    if (widget.outputDirectory != oldWidget.outputDirectory) {
      _syncedOutputDirectory = widget.outputDirectory;
      if (_outputDirectoryController.text == oldWidget.outputDirectory ||
          !_outputDirectoryFocusNode.hasFocus) {
        if (widget.outputDirectory != _outputDirectoryController.text) {
          _outputDirectoryController.value = TextEditingValue(
            text: widget.outputDirectory,
            selection: TextSelection.collapsed(
              offset: widget.outputDirectory.length,
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    // Flush uncommitted keystrokes: navigating away with a focused field
    // never triggers blur, so without this the last typed path would be
    // silently dropped.
    _commitInputPath(force: true);
    _commitOutputDirectory(force: true);
    _inputPathFocusNode
      ..removeListener(_commitInputPathOnBlur)
      ..dispose();
    _outputDirectoryFocusNode
      ..removeListener(_commitOutputDirectoryOnBlur)
      ..dispose();
    _inputPathController.dispose();
    _outputDirectoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasFile = widget.inputPath.isNotEmpty;
    final fileName = hasFile
        ? path.basename(widget.inputPath)
        : widget.strings.noEpubSelected;
    final book = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: const ValueKey<String>('translation-import-zone'),
            borderRadius: BorderRadius.circular(8),
            onTap: widget.enabled ? widget.onPickInputPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    hasFile
                        ? Icons.menu_book_outlined
                        : Icons.upload_file_outlined,
                    size: 32,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 20),
                  Tooltip(
                    message: hasFile ? widget.inputPath : '',
                    child: Text(
                      hasFile
                          ? fileName
                          : PlatformUtils.isWindows
                          ? widget.strings.dropOrChooseEpub
                          : widget.strings.chooseEpub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasFile ? widget.strings.epubFormatLabel : fileName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: widget.enabled
                        ? widget.onPickInputPressed
                        : null,
                    icon: const Icon(Icons.folder_open_outlined, size: 17),
                    label: Text(widget.strings.browse),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.chapterSummary != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(widget.chapterSummary!, style: theme.textTheme.bodySmall),
                TextButton(
                  onPressed: widget.onPreviewPressed,
                  child: Text(widget.strings.chapterChecklist),
                ),
              ],
            ),
          ),
      ],
    );
    final preferences = TranslationPreferences(
      strings: widget.strings,
      targetLanguage: widget.targetLanguage,
      bilingual: widget.bilingual,
      enabled: widget.enabled,
      onTargetLanguageChanged: widget.onTargetLanguageChanged,
      onBilingualChanged: widget.onBilingualChanged,
    );
    final output = Row(
      children: [
        Icon(Icons.folder_outlined, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.strings.outputDirectory,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Tooltip(
                message: widget.outputDirectory,
                child: Text(
                  widget.outputDirectory.isEmpty
                      ? widget.strings.outputDirectoryHint
                      : widget.outputDirectory,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (PlatformUtils.supportsDirectoryPicker)
          IconButton(
            tooltip: widget.strings.chooseOutputDirectory,
            onPressed: widget.enabled ? widget.onPickOutputPressed : null,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
      ],
    );
    return SectionCard(
      variant: SectionCardVariant.emphasis,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth <
                  808 * MediaQuery.textScalerOf(context).scale(1)) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [book, const SizedBox(height: 26), preferences],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: book),
                  const SizedBox(width: 32),
                  Expanded(flex: 2, child: preferences),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final actions = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.actions,
              );
              if (constraints.maxWidth < 720 || widget.actions.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    output,
                    if (widget.actions.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      actions,
                    ],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: output),
                  const SizedBox(width: 20),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: actions,
                    ),
                  ),
                ],
              );
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  setState(() => _showAdvancedPaths = !_showAdvancedPaths),
              child: Text(widget.strings.advancedPaths),
            ),
          ),
          if (_showAdvancedPaths) ...[
            TextFormField(
              key: const ValueKey<String>('manual-input-path'),
              controller: _inputPathController,
              focusNode: _inputPathFocusNode,
              enabled: widget.enabled,
              onFieldSubmitted: widget.enabled
                  ? (_) {
                      if (_inputPathController.text != widget.inputPath) {
                        widget.onInputChanged(_inputPathController.text);
                      }
                    }
                  : null,
              decoration: InputDecoration(
                labelText: widget.strings.inputEpub,
                hintText: widget.strings.inputEpubHint,
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey<String>('manual-output-directory'),
              controller: _outputDirectoryController,
              focusNode: _outputDirectoryFocusNode,
              enabled: widget.enabled,
              onFieldSubmitted: widget.enabled
                  ? (_) {
                      if (_outputDirectoryController.text !=
                          widget.outputDirectory) {
                        widget.onOutputChanged(_outputDirectoryController.text);
                      }
                    }
                  : null,
              decoration: InputDecoration(
                labelText: widget.strings.outputDirectory,
                hintText: widget.strings.outputDirectoryHint,
                isDense: true,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
