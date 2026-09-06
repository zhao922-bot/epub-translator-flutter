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
  final ValueChanged<String> onInputChanged;
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
                    hasFile ? 'EPUB' : fileName,
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
              key: ValueKey('input-${widget.inputPath}'),
              initialValue: widget.inputPath,
              enabled: widget.enabled,
              onChanged: widget.enabled ? widget.onInputChanged : null,
              decoration: InputDecoration(
                labelText: widget.strings.inputEpub,
                hintText: widget.strings.inputEpubHint,
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: ValueKey('output-${widget.outputDirectory}'),
              initialValue: widget.outputDirectory,
              enabled: widget.enabled,
              onChanged: widget.enabled ? widget.onOutputChanged : null,
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
