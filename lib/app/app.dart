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
    return MaterialApp.router(
      title: strings.appTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      theme: AppTheme.light(uiLanguage),
      darkTheme: AppTheme.dark(uiLanguage),
      themeMode: ThemeMode.dark,
    );
  }
}
