import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/widgets/section_card.dart';

class TranslationInputs extends StatelessWidget {
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
    required this.onStartPressed,
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
  final VoidCallback onPickInputPressed;
  final VoidCallback onPickOutputPressed;
  final VoidCallback onStartPressed;

  @override
  Widget build(BuildContext context) {
    final bool canPickOutputDirectory = PlatformUtils.supportsDirectoryPicker;

    return SectionCard(
      title: strings.bookSetup,
      trailing: FilledButton.icon(
        onPressed: onStartPressed,
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(strings.inspectEpub),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextFormField(
                  key: ValueKey<String>('input-$inputPath'),
                  initialValue: inputPath,
                  onChanged: onInputChanged,
                  decoration: InputDecoration(
                    labelText: strings.inputEpub,
                    hintText: strings.inputEpubHint,
                    prefixIcon: const Icon(Icons.menu_book_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: onPickInputPressed,
                tooltip: strings.chooseEpub,
                icon: const Icon(Icons.folder_open_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextFormField(
                  key: ValueKey<String>('output-$outputDirectory'),
                  initialValue: outputDirectory,
                  onChanged: onOutputChanged,
                  decoration: InputDecoration(
                    labelText: strings.outputDirectory,
                    hintText: strings.outputDirectoryHint,
                    prefixIcon: const Icon(Icons.folder_open_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: canPickOutputDirectory ? onPickOutputPressed : null,
                tooltip: canPickOutputDirectory
                    ? strings.chooseOutputDirectory
                    : 'Android uses the app output folder',
                icon: const Icon(Icons.drive_folder_upload_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: targetLanguage,
                  onChanged: onTargetLanguageChanged,
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
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.language_rounded),
                  ).copyWith(labelText: strings.targetLanguage),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.bilingualOutput),
                  value: bilingual,
                  onChanged: onBilingualChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
