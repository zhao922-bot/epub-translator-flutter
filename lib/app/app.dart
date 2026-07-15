import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/application/settings_controller.dart';
import '../features/translation/domain/models/translation_config.dart';
import '../shared/localization/app_strings.dart';
import 'routes.dart';
import 'theme/app_theme.dart';

class EpubTranslatorApp extends ConsumerWidget {
  const EpubTranslatorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final UiLanguage uiLanguage = ref.watch(
      settingsProvider.select((TranslationConfig config) => config.uiLanguage),
    );
    final AppThemeMode appThemeMode = ref.watch(
      settingsProvider.select((TranslationConfig config) => config.themeMode),
    );
    final double textScale = ref.watch(
      settingsProvider.select((TranslationConfig config) => config.textScale),
    );
    return MaterialApp.router(
      title: strings.appTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      theme: AppTheme.light(uiLanguage),
      darkTheme: AppTheme.dark(uiLanguage),
      themeMode: switch (appThemeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(textScale.clamp(0.9, 1.3)),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
