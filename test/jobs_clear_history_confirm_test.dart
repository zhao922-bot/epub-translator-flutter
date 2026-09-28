import 'package:epub_translator_flutter/app/theme/app_theme.dart';
import 'package:epub_translator_flutter/features/jobs/presentation/pages/jobs_page.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
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
  _Controller(TranslationDashboardState seed)
    : super(repository: _NoRequests()) {
    state = seed;
  }

  bool cleared = false;
  bool clearResult = true;

  @override
  Future<bool> clearJobHistory() {
    cleared = true;
    return Future<bool>.value(clearResult);
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

Future<void> _pumpPage(WidgetTester tester, _Controller Function() create) {
  const strings = AppStrings(UiLanguage.chinese);
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStringsProvider.overrideWithValue(strings),
        settingsStoreProvider.overrideWithValue(_Settings()),
        translationDashboardProvider.overrideWith((ref) => create()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(UiLanguage.chinese),
        // The real app hosts pages inside AppShell's Scaffold; the page's
        // SnackBar needs a Scaffold ancestor here too.
        home: const Scaffold(body: JobsPage()),
      ),
    ),
  );
}

void main() {
  const strings = AppStrings(UiLanguage.chinese);

  testWidgets('canceling the confirm dialog keeps history', (tester) async {
    late _Controller controller;
    await _pumpPage(tester, () {
      controller = _Controller(
        TranslationDashboardState.initial().copyWith(
          jobHistory: <TranslationJob>[
            TranslationJob(
              id: 'job-1',
              inputPath: 'Book.epub',
              outputPath: 'out',
              status: TranslationJobStatus.completed,
              progress: 1,
            ),
          ],
        ),
      );
      return controller;
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text(strings.clearHistory));
    await tester.pumpAndSettle();
    expect(find.text(strings.clearHistoryConfirmTitle), findsOneWidget);

    await tester.tap(find.text(strings.dialogCancel));
    await tester.pumpAndSettle();
    expect(controller.cleared, isFalse);
    expect(find.text(strings.clearHistoryConfirmTitle), findsNothing);
  });

  testWidgets('confirming the dialog clears history', (tester) async {
    late _Controller controller;
    await _pumpPage(tester, () {
      controller = _Controller(
        TranslationDashboardState.initial().copyWith(
          jobHistory: <TranslationJob>[
            TranslationJob(
              id: 'job-1',
              inputPath: 'Book.epub',
              outputPath: 'out',
              status: TranslationJobStatus.completed,
              progress: 1,
            ),
          ],
        ),
      );
      return controller;
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text(strings.clearHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.dialogConfirm));
    await tester.pumpAndSettle();
    expect(controller.cleared, isTrue);
  });

  testWidgets('a blocked clear shows a snackbar while a run is active', (
    tester,
  ) async {
    late _Controller controller;
    await _pumpPage(tester, () {
      controller = _Controller(
        TranslationDashboardState.initial().copyWith(
          job: TranslationJob(
            id: 'job-active',
            inputPath: 'Book.epub',
            outputPath: 'out',
            status: TranslationJobStatus.running,
            progress: 0.5,
          ),
          jobHistory: <TranslationJob>[
            TranslationJob(
              id: 'job-1',
              inputPath: 'Book.epub',
              outputPath: 'out',
              status: TranslationJobStatus.completed,
              progress: 1,
            ),
          ],
        ),
      );
      controller.clearResult = false;
      return controller;
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text(strings.clearHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.dialogConfirm));
    await tester.pumpAndSettle();
    expect(controller.cleared, isTrue);
    expect(find.text(strings.clearBlockedByActiveRun), findsOneWidget);
  });

  testWidgets('a failed clear shows a snackbar when no run is active', (
    tester,
  ) async {
    late _Controller controller;
    await _pumpPage(tester, () {
      controller = _Controller(
        TranslationDashboardState.initial().copyWith(
          jobHistory: <TranslationJob>[
            TranslationJob(
              id: 'job-1',
              inputPath: 'Book.epub',
              outputPath: 'out',
              status: TranslationJobStatus.completed,
              progress: 1,
            ),
          ],
        ),
      );
      controller.clearResult = false;
      return controller;
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text(strings.clearHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.dialogConfirm));
    await tester.pumpAndSettle();
    expect(controller.cleared, isTrue);
    expect(find.text(strings.logClearHistoryFailed), findsOneWidget);
  });
}
