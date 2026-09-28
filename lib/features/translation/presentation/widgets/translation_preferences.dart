import 'package:flutter/material.dart';
import '../../../../shared/localization/app_strings.dart';

/// Display label for a stored target-language key: each language in its own
/// native name. Unknown/custom values fall back to the raw key.
String _nativeLanguageName(String languageKey) {
  return const <String, String>{
        'Chinese': '中文',
        'English': 'English',
        'Japanese': '日本語',
        'Korean': '한국어',
        'French': 'Français',
        'German': 'Deutsch',
        'Spanish': 'Español',
      }[languageKey] ??
      languageKey;
}

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
    // The stored value stays the English key (config + cache keys depend on
    // it); only the display label uses the language's own native name so the
    // dropdown reads naturally in any UI language.
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
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(_nativeLanguageName(value)),
                ),
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
