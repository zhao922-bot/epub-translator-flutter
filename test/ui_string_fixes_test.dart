import 'package:epub_translator_flutter/features/preview/application/preview_provider.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/presentation/widgets/translation_preferences.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

class _Controller extends TranslationDashboardController {
  _Controller() : super(repository: _NoRequests()) {
    state = TranslationDashboardState.initial();
  }
}

class _Settings extends SettingsStore {
  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults();
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

void main() {
  group('target language dropdown labels', () {
    testWidgets('shows native language names in a Chinese UI', (tester) async {
      const strings = AppStrings(UiLanguage.chinese);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranslationPreferences(
              strings: strings,
              targetLanguage: 'Chinese',
              bilingual: false,
              enabled: true,
              onTargetLanguageChanged: (_) {},
              onBilingualChanged: (_) {},
            ),
          ),
        ),
      );

      // Open the dropdown to render the items.
      await tester.tap(find.byKey(const ValueKey<String>('language-Chinese')));
      await tester.pumpAndSettle();

      expect(find.text('中文'), findsWidgets);
      expect(find.text('日本語'), findsOneWidget);
      expect(find.text('한국어'), findsOneWidget);
      expect(find.text('Français'), findsOneWidget);
      expect(find.text('Deutsch'), findsOneWidget);
      expect(find.text('Español'), findsOneWidget);
      // No English-only labels for the built-in languages.
      expect(find.text('Japanese'), findsNothing);
      expect(find.text('Korean'), findsNothing);
    });

    testWidgets('still selects by the stored English key', (tester) async {
      const strings = AppStrings(UiLanguage.english);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranslationPreferences(
              strings: strings,
              targetLanguage: 'English',
              bilingual: false,
              enabled: true,
              onTargetLanguageChanged: (value) => selected = value,
              onBilingualChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('language-English')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日本語').last);
      await tester.pumpAndSettle();

      expect(selected, 'Japanese');
    });
  });

  group('localization keys', () {
    test('epubFormatLabel and dialog strings exist in both languages', () {
      const zh = AppStrings(UiLanguage.chinese);
      const en = AppStrings(UiLanguage.english);
      expect(zh.epubFormatLabel, 'EPUB');
      expect(en.epubFormatLabel, 'EPUB');
      expect(zh.clearHistoryConfirmTitle, isNotEmpty);
      expect(en.clearHistoryConfirmTitle, isNotEmpty);
      expect(zh.clearHistoryConfirmBody, isNotEmpty);
      expect(en.clearHistoryConfirmBody, isNotEmpty);
      expect(zh.dialogCancel, isNotEmpty);
      expect(en.dialogConfirm, isNotEmpty);
      expect(zh.httpProxyInvalidFormat, isNotEmpty);
      expect(en.httpProxyUnsupportedScheme, isNotEmpty);
      expect(zh.previewFallbackTitle, isNotEmpty);
      expect(en.previewFallbackCategory, isNotEmpty);
    });

    test('preview fallback chapter is localized', () {
      final container = ProviderContainer(
        overrides: [
          appStringsProvider.overrideWithValue(
            const AppStrings(UiLanguage.chinese),
          ),
          settingsStoreProvider.overrideWithValue(_Settings()),
          translationDashboardProvider.overrideWith((ref) => _Controller()),
        ],
      );
      addTearDown(container.dispose);

      final chapters = container.read(previewChaptersProvider);
      expect(chapters, hasLength(1));
      expect(chapters.single.title, '尚无已检查的 EPUB');
      expect(chapters.single.category, '等待中');
      expect(chapters.single.body, isNotEmpty);
    });
  });
}
