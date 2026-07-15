import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.loadCompleter);

  final Completer<TranslationConfig> loadCompleter;

  @override
  Future<TranslationConfig> load() => loadCompleter.future;

  @override
  Future<void> save(TranslationConfig config) async {}
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  @override
  Future<List<TranslationJob>> load() async => const <TranslationJob>[];

  @override
  Future<void> save(List<TranslationJob> jobs) async {}
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
        jobHistoryStoreProvider.overrideWithValue(_MemoryJobHistoryStore()),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(translationDashboardProvider).config.targetLanguage,
      'Chinese',
    );

    loadCompleter.complete(
      TranslationConfig.defaults().copyWith(targetLanguage: 'Japanese'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(translationDashboardProvider).config.targetLanguage,
      'Japanese',
    );
  });
}
