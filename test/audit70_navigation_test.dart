import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/app/app.dart';
import 'package:epub_translator_flutter/app/routes.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';

class _Settings extends SettingsStore {
  @override
  Future<TranslationConfig> load() async =>
      TranslationConfig.defaults().copyWith(uiLanguage: UiLanguage.english);
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

void main() {
  testWidgets(
    'navigating to Jobs flushes a focused manual path without provider lifecycle errors',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      appRouter.go('/');
      late TranslationDashboardController controller;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(_Settings()),
            translationDashboardProvider.overrideWith((ref) {
              controller = TranslationDashboardController(
                repository: _NoRequests(),
              );
              controller.setInputPath('Book.epub');
              return controller;
            }),
          ],
          child: const EpubTranslatorApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Manual paths'));
      await tester.tap(find.text('Manual paths'));
      await tester.pump();
      final field = find.byKey(const ValueKey<String>('manual-input-path'));
      await tester.ensureVisible(field);
      await tester.enterText(field, 'NewBook.epub');
      await tester.pump();
      expect(controller.state.inputPath, 'Book.epub');
      await tester.tap(find.byTooltip('Jobs'));
      await tester.pumpAndSettle();
      final error = tester.takeException();
      debugPrint(
        'AUDIT navigation error: $error; input=${controller.state.inputPath}',
      );
      expect(error, isNull);
      expect(controller.state.inputPath, 'NewBook.epub');
      await tester.pumpWidget(const SizedBox.shrink());
      appRouter.go('/');
    },
  );
}
