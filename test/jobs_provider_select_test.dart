import 'package:epub_translator_flutter/features/jobs/application/jobs_provider.dart';
import 'package:epub_translator_flutter/features/jobs/domain/models/job_summary.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
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
  test('jobsProvider ignores unrelated dashboard state changes', () {
    final job = TranslationJob(
      id: 'job-1',
      inputPath: 'Book.epub',
      outputPath: 'out',
      status: TranslationJobStatus.completed,
      progress: 1,
    );
    final seed = TranslationDashboardState.initial().copyWith(
      jobHistory: <TranslationJob>[job],
    );
    late _Controller controller;
    final container = ProviderContainer(
      overrides: [
        appStringsProvider.overrideWithValue(
          const AppStrings(UiLanguage.english),
        ),
        settingsStoreProvider.overrideWithValue(_Settings()),
        translationDashboardProvider.overrideWith(
          (ref) => controller = _Controller(seed),
        ),
      ],
    );
    addTearDown(container.dispose);

    final List<JobSummary> before = container.read(jobsProvider);
    expect(before, hasLength(1));

    // A log tick (the hot path during a run) must not rebuild the jobs list:
    // the provider keeps serving the cached value.
    controller.state = controller.state.copyWith(
      logs: const <String>['tick 1', 'tick 2'],
    );
    expect(identical(container.read(jobsProvider), before), isTrue);

    // A real job change still rebuilds.
    controller.state = controller.state.copyWith(
      jobHistory: <TranslationJob>[job, job],
    );
    expect(identical(container.read(jobsProvider), before), isFalse);
  });
}
