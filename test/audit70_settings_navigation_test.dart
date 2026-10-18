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
  final saves = <TranslationConfig>[];
  @override
  Future<TranslationConfig> load() async =>
      TranslationConfig.defaults().copyWith(uiLanguage: UiLanguage.english);
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    saves.add(config);
  }
}

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

void main() {
  testWidgets('leaving Settings flushes the pending key to storage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/settings');
    final store = _Settings();
    late SettingsController settings;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          translationDashboardProvider.overrideWith((ref) {
            return TranslationDashboardController(repository: _NoRequests());
          }),
        ],
        child: const EpubTranslatorApp(),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey<String>('settings-api-key'));
    settings = ProviderScope.containerOf(
      tester.element(field),
    ).read(settingsProvider.notifier);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'audit-navigation-key');
    await tester.pump();
    expect(store.saves, isEmpty);
    await tester.tap(find.byTooltip('Jobs'));
    await tester.pumpAndSettle();
    final error = tester.takeException();
    debugPrint(
      'AUDIT Settings navigation error: $error; in-memory key changed=${settings.state.apiKey == "audit-navigation-key"}; saves=${store.saves.length}',
    );
    expect(
      store.saves.any((s) => s.apiKey == 'audit-navigation-key'),
      isTrue,
      reason:
          'The dispose flush must actually persist the key, not merely change optimistic state',
    );
    expect(error, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    appRouter.go('/');
  });
}
