import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/section_card.dart';

class TranslationInputs extends StatefulWidget {
  const TranslationInputs({
    super.key,
    required this.strings,
    required this.inputPath,
    required this.outputDirectory,
    required this.targetLanguage,
    required this.bilingual,
    required this.onInputChanged,
    required this.onOutputChanged,
    required this.onTargetLanguageChanged,
    required this.onBilingualChanged,
    required this.onPickInputPressed,
    required this.onPickOutputPressed,
  });

  final AppStrings strings;
  final String inputPath;
  final String outputDirectory;
  final String targetLanguage;
  final bool bilingual;
  final ValueChanged<String> onInputChanged;
  final ValueChanged<String> onOutputChanged;
  final ValueChanged<String?> onTargetLanguageChanged;
  final ValueChanged<bool> onBilingualChanged;
  final VoidCallback? onPickInputPressed;
  final VoidCallback? onPickOutputPressed;

  @override
  State<TranslationInputs> createState() => _TranslationInputsState();
}

class _TranslationInputsState extends State<TranslationInputs> {
  bool _showAdvancedPaths = false;

  @override
  Widget build(BuildContext context) {
    final bool canPickOutputDirectory = PlatformUtils.supportsDirectoryPicker;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;
    final bool hasFile = widget.inputPath.isNotEmpty;
    final String fileName = hasFile
        ? path.basename(widget.inputPath)
        : widget.strings.noEpubSelected;

    return SectionCard(
      variant: SectionCardVariant.emphasis,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            label: PlatformUtils.isWindows
                ? widget.strings.dropOrChooseEpub
                : widget.strings.chooseEpub,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: const ValueKey<String>('translation-import-zone'),
                borderRadius: BorderRadius.circular(16),
                onTap: widget.onPickInputPressed,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        hasFile
                            ? scheme.tertiaryContainer.withValues(
                                alpha: isDark ? 0.28 : 0.6,
                              )
                            : scheme.primaryContainer.withValues(
                                alpha: isDark ? 0.34 : 0.75,
                              ),
                        scheme.surfaceContainerHighest.withValues(
                          alpha: isDark ? 0.14 : 0.58,
                        ),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: CustomPaint(
                    painter: _DashedRRectPainter(
                      color: hasFile
                          ? scheme.tertiary.withValues(alpha: 0.6)
                          : scheme.primary.withValues(
                              alpha: isDark ? 0.55 : 0.46,
                            ),
                      radius: 16,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: hasFile ? 18 : 26,
                      ),
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              final bool compactAction =
                                  constraints.maxWidth < 420;
                              final Widget browseAction = compactAction
                                  ? IconButton.filledTonal(
                                      tooltip: widget.strings.browse,
                                      onPressed: widget.onPickInputPressed,
                                      icon: const Icon(
                                        Icons.folder_open_rounded,
                                      ),
                                    )
                                  : FilledButton.tonalIcon(
                                      onPressed: widget.onPickInputPressed,
                                      icon: const Icon(
                                        Icons.folder_open_rounded,
                                        size: 18,
                                      ),
                                      label: Text(widget.strings.browse),
                                    );
                              return Row(
                                children: <Widget>[
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color:
                                          (hasFile
                                                  ? scheme.tertiary
                                                  : scheme.primary)
                                              .withValues(
                                                alpha: isDark ? 0.22 : 0.14,
                                              ),
                                      border: Border.all(
                                        color:
                                            (hasFile
                                                    ? scheme.tertiary
                                                    : scheme.primary)
                                                .withValues(alpha: 0.18),
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      hasFile
                                          ? Icons.menu_book_rounded
                                          : Icons.upload_file_rounded,
                                      color: hasFile
                                          ? scheme.tertiary
                                          : scheme.primary,
                                      size: 25,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          PlatformUtils.isWindows
                                              ? widget.strings.dropOrChooseEpub
                                              : widget.strings.chooseEpub,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          fileName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  browseAction,
                                ],
                              );
                            },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: scheme.surfaceContainer.withValues(alpha: isDark ? 0.55 : 1),
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Icon(Icons.folder_outlined, color: scheme.primary),
              title: Text(
                widget.strings.outputDirectory,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                widget.outputDirectory.isEmpty
                    ? widget.strings.outputDirectoryHint
                    : widget.outputDirectory,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: canPickOutputDirectory
                  ? IconButton(
                      tooltip: widget.strings.chooseOutputDirectory,
                      onPressed: widget.onPickOutputPressed,
                      icon: const Icon(Icons.edit_rounded, size: 20),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget languageField = DropdownButtonFormField<String>(
                initialValue: widget.targetLanguage,
                onChanged: widget.onTargetLanguageChanged,
                items:
                    const <String>[
                          'Chinese',
                          'English',
                          'Japanese',
                          'Korean',
                          'French',
                          'German',
                          'Spanish',
                        ]
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                decoration: InputDecoration(
                  labelText: widget.strings.targetLanguage,
                  prefixIcon: const Icon(Icons.language_rounded),
                  isDense: true,
                ),
              );
              final Widget bilingualSwitch = Material(
                color: scheme.surfaceContainer.withValues(
                  alpha: isDark ? 0.55 : 1,
                ),
                borderRadius: BorderRadius.circular(12),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: Text(widget.strings.bilingualOutput),
                  value: widget.bilingual,
                  onChanged: widget.onBilingualChanged,
                ),
              );

              if (constraints.maxWidth < 560) {
                return Column(
                  children: <Widget>[
                    languageField,
                    const SizedBox(height: 10),
                    bilingualSwitch,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: languageField),
                  const SizedBox(width: 12),
                  Expanded(child: bilingualSwitch),
                ],
              );
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  setState(() => _showAdvancedPaths = !_showAdvancedPaths),
              child: Text(
                _showAdvancedPaths
                    ? widget.strings.advancedPaths
                    : widget.strings.advancedPaths,
              ),
            ),
          ),
          if (_showAdvancedPaths) ...<Widget>[
            TextFormField(
              key: ValueKey<String>('input-${widget.inputPath}'),
              initialValue: widget.inputPath,
              onChanged: widget.onInputChanged,
              decoration: InputDecoration(
                labelText: widget.strings.inputEpub,
                hintText: widget.strings.inputEpubHint,
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey<String>('output-${widget.outputDirectory}'),
              initialValue: widget.outputDirectory,
              onChanged: widget.onOutputChanged,
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

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    final Path shape = Path()..addRRect(rrect);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;

    const double dashWidth = 5;
    const double dashSpace = 4;
    for (final ui.PathMetric metric in shape.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double next = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
