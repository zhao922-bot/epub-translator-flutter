import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/translation_config.dart';
import '../../application/settings_controller.dart';
import 'settings_sections.dart';
import 'settings_slider.dart';

class SettingsAppearanceSection extends ConsumerWidget {
  const SettingsAppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final (uiLanguage, themeMode) = ref.watch(
      settingsProvider.select((c) => (c.uiLanguage, c.themeMode)),
    );
    return SettingsSection(
      title: strings.appearanceSection,
      icon: Icons.palette_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            strings.uiLanguage,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SegmentedButton<UiLanguage>(
            showSelectedIcon: false,
            segments: <ButtonSegment<UiLanguage>>[
              ButtonSegment<UiLanguage>(
                value: UiLanguage.english,
                label: Text(strings.englishLabel),
              ),
              ButtonSegment<UiLanguage>(
                value: UiLanguage.chinese,
                label: Text(strings.chineseLabel),
              ),
            ],
            selected: <UiLanguage>{uiLanguage},
            onSelectionChanged: (Set<UiLanguage> selection) {
              controller.setUiLanguage(selection.first);
            },
          ),
          const SizedBox(height: 16),
          Text(
            strings.themeSection,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SegmentedButton<AppThemeMode>(
            showSelectedIcon: false,
            segments: <ButtonSegment<AppThemeMode>>[
              ButtonSegment<AppThemeMode>(
                value: AppThemeMode.system,
                label: Text(strings.systemThemeLabel),
              ),
              ButtonSegment<AppThemeMode>(
                value: AppThemeMode.light,
                label: Text(strings.lightThemeLabel),
              ),
              ButtonSegment<AppThemeMode>(
                value: AppThemeMode.dark,
                label: Text(strings.darkThemeLabel),
              ),
            ],
            selected: <AppThemeMode>{themeMode},
            onSelectionChanged: (Set<AppThemeMode> selection) {
              controller.setThemeMode(selection.first);
            },
          ),
          const SizedBox(height: 12),
          SettingsSlider(
            select: (c) => c.textScale.clamp(0.9, 1.3),
            label: (v) => '${strings.textScaleLabel}: ${v.toStringAsFixed(2)}x',
            min: 0.9,
            max: 1.3,
            divisions: 8,
            onChanged: controller.setTextScale,
            onChangeEnd: (_) => controller.flushSliderChanges(),
          ),
        ],
      ),
    );
  }
}
