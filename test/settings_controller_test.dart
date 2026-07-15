import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.loadCompleter);

  final Completer<TranslationConfig> loadCompleter;
  final List<TranslationConfig> saved = <TranslationConfig>[];

  @override
  Future<TranslationConfig> load() => loadCompleter.future;

  @override
  Future<void> save(TranslationConfig config) async {
    saved.add(config);
  }
}

class _OutOfOrderSettingsStore extends SettingsStore {
  final Completer<void> firstSaveStarted = Completer<void>();
  final Completer<void> releaseFirstSave = Completer<void>();
  final List<String> completedModels = <String>[];

  int saveCount = 0;

  @override
  Future<TranslationConfig> load() async => TranslationConfig.defaults();

  @override
  Future<void> save(TranslationConfig config) async {
    saveCount += 1;
    if (saveCount == 1) {
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
    completedModels.add(config.model);
  }
}

class _FailingConnectionRepository implements TranslationRepository {
  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    throw StateError(
      'Connection test failed for api.example.com with HTTP 401: Unauthorized',
    );
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  test('waits for persisted settings before saving user changes', () async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    final _ControlledSettingsStore store = _ControlledSettingsStore(
      loadCompleter,
    );
    final SettingsController controller = SettingsController(store);

    final Future<void> update = controller.setUiLanguage(UiLanguage.chinese);
    await Future<void>.delayed(Duration.zero);

    expect(store.saved, isEmpty);

    loadCompleter.complete(
      TranslationConfig.defaults().copyWith(apiKey: 'sk-saved'),
    );
    await update;

    expect(store.saved, hasLength(1));
    expect(store.saved.single.apiKey, 'sk-saved');
    expect(store.saved.single.uiLanguage, UiLanguage.chinese);
  });

  test(
    'does not update state after dispose when load completes late',
    () async {
      final Completer<TranslationConfig> loadCompleter =
          Completer<TranslationConfig>();
      final _ControlledSettingsStore store = _ControlledSettingsStore(
        loadCompleter,
      );
      final SettingsController controller = SettingsController(store);

      controller.dispose();
      loadCompleter.complete(
        TranslationConfig.defaults().copyWith(model: 'late-model'),
      );
      await Future<void>.delayed(Duration.zero);

      // Defaults remain; no StateError from writing after dispose.
      expect(controller.mounted, isFalse);
    },
  );

  test(
    'serializes setting saves so older writes cannot overwrite newer input',
    () async {
      final _OutOfOrderSettingsStore store = _OutOfOrderSettingsStore();
      final SettingsController controller = SettingsController(store);

      final Future<void> firstUpdate = controller.setModel('first-model');
      await store.firstSaveStarted.future;

      final Future<void> secondUpdate = controller.setModel('second-model');
      await Future<void>.delayed(Duration.zero);

      expect(store.completedModels, isEmpty);

      store.releaseFirstSave.complete();
      await Future.wait(<Future<void>>[firstUpdate, secondUpdate]);

      expect(store.completedModels, <String>['first-model', 'second-model']);
    },
  );

  test('trims pasted API identity settings before saving', () async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    final _ControlledSettingsStore store = _ControlledSettingsStore(
      loadCompleter,
    );
    final SettingsController controller = SettingsController(store);

    final Future<void> update = controller.setApiBaseUrl(
      ' https://api.edgefn.net/v1\r\n ',
    );
    loadCompleter.complete(TranslationConfig.defaults());
    await update;
    await controller.setApiKey(' sk-secret\r\n ');
    await controller.setModel(' DeepSeek-V4-Flash\n ');

    expect(controller.state.apiBaseUrl, 'https://api.edgefn.net/v1');
    expect(controller.state.apiKey, 'sk-secret');
    expect(controller.state.model, 'DeepSeek-V4-Flash');
    expect(store.saved.last.apiBaseUrl, 'https://api.edgefn.net/v1');
    expect(store.saved.last.apiKey, 'sk-secret');
    expect(store.saved.last.model, 'DeepSeek-V4-Flash');
  });

  test('connection test surfaces actionable diagnostics', () async {
    final ConnectionTestController controller = ConnectionTestController(
      _FailingConnectionRepository(),
    );

    await controller.run(TranslationConfig.defaults());

    final AsyncError<String?> errorState =
        controller.state as AsyncError<String?>;
    expect(errorState.error.toString(), contains('API key'));
    expect(errorState.error.toString(), contains('401'));
  });

  test(
    'applies fast tuning preset without changing API identity settings',
    () async {
      final Completer<TranslationConfig> loadCompleter =
          Completer<TranslationConfig>();
      final _ControlledSettingsStore store = _ControlledSettingsStore(
        loadCompleter,
      );
      final SettingsController controller = SettingsController(store);

      final Future<void> update = controller.applyTuningPreset(
        TranslationTuningPreset.fast,
      );
      loadCompleter.complete(
        TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-preserved',
          model: 'preserved-model',
        ),
      );
      await update;

      expect(controller.state.apiBaseUrl, 'https://api.example.com/v1');
      expect(controller.state.apiKey, 'sk-preserved');
      expect(controller.state.model, 'preserved-model');
      expect(controller.state.chunkSize, 8000);
      expect(controller.state.maxConcurrent, 8);
      expect(controller.state.timeoutSeconds, 120);
      expect(controller.state.maxRetries, 2);
      expect(controller.state.retryDelaySeconds, 3);
      expect(store.saved.single, controller.state);
    },
  );

  test('persists theme mode changes after settings load', () async {
    final Completer<TranslationConfig> loadCompleter =
        Completer<TranslationConfig>();
    final _ControlledSettingsStore store = _ControlledSettingsStore(
      loadCompleter,
    );
    final SettingsController controller = SettingsController(store);

    final Future<void> update = controller.setThemeMode(AppThemeMode.system);
    loadCompleter.complete(TranslationConfig.defaults());
    await update;

    expect(controller.state.themeMode, AppThemeMode.system);
    expect(store.saved.single.themeMode, AppThemeMode.system);
  });
}
