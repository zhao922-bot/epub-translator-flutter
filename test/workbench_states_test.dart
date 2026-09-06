import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/presentation/pages/translation_dashboard_page.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

class _Controller extends TranslationDashboardController {
  _Controller(TranslationDashboardState seed)
    : super(repository: _NoRequests()) {
    state = seed;
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
  testWidgets(
    'partial output warning and open action are visible before inputs',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const strings = AppStrings(UiLanguage.chinese);
      final seed = TranslationDashboardState.initial().copyWith(
        inputPath: 'book.epub',
        outputDirectory: 'output',
        job: const TranslationJob(
          id: 'warning',
          inputPath: 'book.epub',
          outputPath: 'output/book_translated.epub',
          status: TranslationJobStatus.completedWithWarnings,
          phase: TranslationJobPhase.translation,
          progress: 1,
          totalBlocks: 18,
          completedBlocks: 18,
          degradedBlockCount: 3,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStringsProvider.overrideWithValue(strings),
            settingsStoreProvider.overrideWithValue(_Settings()),
            translationDashboardProvider.overrideWith(
              (ref) => _Controller(seed),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(UiLanguage.chinese),
            home: const Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: TranslationDashboardPage(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('完成但有警告').hitTestable(), findsOneWidget);
      expect(find.text(strings.openEpub).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
