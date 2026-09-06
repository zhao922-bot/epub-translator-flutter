import 'package:flutter/material.dart';
import '../../../../shared/localization/app_strings.dart';

class TranslationPreferences extends StatelessWidget {
  const TranslationPreferences({
    super.key,
    required this.strings,
    required this.targetLanguage,
    required this.bilingual,
    required this.enabled,
    required this.onTargetLanguageChanged,
    required this.onBilingualChanged,
  });
  final AppStrings strings;
  final String targetLanguage;
  final bool bilingual;
  final bool enabled;
  final ValueChanged<String?> onTargetLanguageChanged;
  final ValueChanged<bool> onBilingualChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final languages = <String>{
      'Chinese',
      'English',
      'Japanese',
      'Korean',
      'French',
      'German',
      'Spanish',
      targetLanguage,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.translationPreferences,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 22),
        DropdownButtonFormField<String>(
          key: ValueKey('language-$targetLanguage'),
          initialValue: targetLanguage,
          isExpanded: true,
          onChanged: enabled ? onTargetLanguageChanged : null,
          items: languages
              .map(
                (value) => DropdownMenuItem(value: value, child: Text(value)),
              )
              .toList(),
          decoration: InputDecoration(
            labelText: strings.targetLanguage,
            isDense: true,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          strings.outputFormat,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 9),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, label: Text(strings.translatedOnly)),
            ButtonSegment(value: true, label: Text(strings.bilingualOutput)),
          ],
          selected: {bilingual},
          onSelectionChanged: enabled
              ? (values) => onBilingualChanged(values.first)
              : null,
        ),
      ],
    );
  }
}
