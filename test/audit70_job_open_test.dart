import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/jobs/presentation/pages/jobs_page.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';

class _NoRequests implements TranslationRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

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

class _ObservedController extends TranslationDashboardController {
  _ObservedController(String missing) : super(repository: _NoRequests()) {
    state = TranslationDashboardState.initial().copyWith(
      config: TranslationConfig.defaults().copyWith(
        uiLanguage: UiLanguage.english,
      ),
      jobHistory: [
        TranslationJob(
          id: 'audit-missing-output',
          inputPath: 'Book.epub',
          outputPath: missing,
          status: TranslationJobStatus.completed,
          phase: TranslationJobPhase.translation,
          progress: 1,
        ),
      ],
    );
  }
  final done = Completer<void>();
  @override
  Future<String?> openJobOutput(String id) async {
    try {
      return await super.openJobOutput(id);
    } finally {
      done.complete();
    }
  }
}

void main() {
  testWidgets('Jobs page explains why an output can no longer be opened', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('audit-missing-output-');
    addTearDown(() => temp.deleteSync(recursive: true));
    late _ObservedController controller;
    const strings = AppStrings(UiLanguage.english);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(strings),
          settingsStoreProvider.overrideWithValue(_Settings()),
          translationDashboardProvider.overrideWith(
            (ref) =>
                controller = _ObservedController('${temp.path}/deleted.epub'),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: JobsPage())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(strings.openOutput));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(controller.done.isCompleted, isTrue);
    final message = controller.state.logs.last;
    debugPrint('AUDIT actual controller message: $message');
    expect(message, contains('deleted.epub'));
    expect(
      find.text(message),
      findsOneWidget,
      reason:
          'The user must be able to see the missing-output explanation on the Jobs page where Open was pressed',
    );
  });
}
