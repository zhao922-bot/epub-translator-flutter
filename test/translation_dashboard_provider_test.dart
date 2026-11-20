import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_job_history_store.dart';
import 'helpers/memory_session_path_store.dart';

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.loadCompleter);

  final Completer<TranslationConfig> loadCompleter;

  @override
  Future<TranslationConfig> load() => loadCompleter.future;

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {}
}

void main() {
  test('dashboard provider follows async settings load', () async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(
          _ControlledSettingsStore(loadCompleter),
        ),
        sessionPathStoreProvider.overrideWithValue(MemorySessionPathStore()),
        jobHistoryStoreProvider.overrideWithValue(MemoryJobHistoryStore()),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(translationDashboardProvider).config.targetLanguage,
      'Chinese',
    );

    loadCompleter.complete(
      TranslationConfig.defaults().copyWith(
        targetLanguage: 'Japanese',
        retryIncompleteReviews: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(translationDashboardProvider).config.targetLanguage,
      'Japanese',
    );
    expect(
      container
          .read(translationDashboardProvider)
          .config
          .retryIncompleteReviews,
      isTrue,
    );
    await container
        .read(settingsProvider.notifier)
        .setRetryIncompleteReviews(false);
    expect(
      container
          .read(translationDashboardProvider)
          .config
          .retryIncompleteReviews,
      isFalse,
    );
  });
}
