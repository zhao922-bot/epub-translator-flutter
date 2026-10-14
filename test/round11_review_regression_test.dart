import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.persisted);

  TranslationConfig persisted;
  Object? loadError;
  Object? saveError;
  bool conflictNextSave = false;
  int loadCount = 0;
  final attempts = <TranslationConfig>[];
  Set<SettingsSecretSlot> persistedSlots = {};
  Completer<void>? saveGate;
  Completer<void>? saveStarted;

  @override
  Object? get configLoadError => loadError;

  @override
  Set<SettingsSecretSlot> get lastPersistedSecretSlots => persistedSlots;

  @override
  Future<TranslationConfig> load() async {
    loadCount++;
    loadError = null;
    return persisted;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config);
    final error = saveError;
    final conflict = conflictNextSave;
    conflictNextSave = false;
    final gate = saveGate;
    saveGate = null;
    saveStarted?.complete();
    saveStarted = null;
    if (gate != null) await gate.future;
    if (conflict) {
      final conflictError = SettingsWriteConflict();
      loadError = conflictError;
      throw conflictError;
    }
    if (error != null) throw error;
    persistedSlots = {
      ...?explicitSecretMutations,
      if (config.apiKey != persisted.apiKey) SettingsSecretSlot.legacy,
      if (config.deepseekApiKey != persisted.deepseekApiKey)
        SettingsSecretSlot.deepSeek,
      if (config.customApiKey != persisted.customApiKey)
        SettingsSecretSlot.custom,
      if (config.httpProxy != persisted.httpProxy) SettingsSecretSlot.proxy,
    };
    persisted = config;
  }
}

final _routeX = TranslationConfig.defaults().copyWith(
  apiProviderSelection: ApiProviderSelection.custom,
  apiBaseUrl: 'https://service-x.example/v1',
  customApiBaseUrl: 'https://service-x.example/v1',
  apiKey: 'K_X_old',
  customApiKey: 'K_X_old',
  deepseekApiKey: 'K_deepseek_old',
);

final _recoveredRoutes = <String, TranslationConfig>{
  'custom endpoint changes': _routeX.copyWith(
    apiBaseUrl: 'https://service-y.example/v1',
    customApiBaseUrl: 'https://service-y.example/v1',
    apiKey: 'K_Y_old',
    customApiKey: 'K_Y_old',
  ),
  'provider changes to DeepSeek': _routeX.copyWith(
    apiProviderSelection: ApiProviderSelection.deepseek,
    apiBaseUrl: 'https://api.deepseek.com',
    apiKey: 'K_Y_old',
    deepseekApiKey: 'K_Y_old',
  ),
};

void main() {
  group('round11 P1-01', () {
    for (final route in _recoveredRoutes.entries) {
      for (final confirm in [true, false]) {
        test(
          '${route.key}: blocks until ${confirm ? 'confirm' : 'discard'}',
          () async {
            final store = _ControlledSettingsStore(_routeX);
            var blockedNotices = 0;
            final controller = SettingsController(
              store,
              onReplayBlocked: () => blockedNotices++,
            );
            addTearDown(controller.dispose);
            await controller.ready;
            store
              ..persisted = route.value
              ..loadError = SettingsWriteConflict();
            expect(controller.state.apiBaseUrl, _routeX.apiBaseUrl);

            expect(await controller.setApiKey('K_X_new'), isFalse);
            expect(store.loadCount, 2);
            expect(controller.state.apiBaseUrl, route.value.apiBaseUrl);
            expect(controller.state.apiKey, 'K_Y_old');
            expect(controller.blockedReplayCount, 1);
            expect(blockedNotices, 1);
            expect(store.attempts, isEmpty);
            expect(store.persisted.apiKey, 'K_Y_old');

            expect(await controller.reloadSettings(), isTrue);
            expect(controller.blockedReplayCount, 1);
            expect(store.attempts, isEmpty);
            expect(store.persisted.apiKey, 'K_Y_old');

            if (confirm) {
              await controller.confirmBlockedConflictReplays();
              expect(controller.state.apiKey, 'K_X_new');
              expect(store.persisted.apiKey, 'K_X_new');
              if (route.value.apiProviderSelection ==
                  ApiProviderSelection.custom) {
                expect(store.persisted.customApiKey, 'K_X_new');
              } else {
                expect(store.persisted.deepseekApiKey, 'K_X_new');
                expect(store.persisted.customApiKey, _routeX.customApiKey);
              }
            } else {
              controller.discardBlockedConflictReplays();
              expect(controller.state.apiKey, 'K_Y_old');
              expect(
                await controller.setOutputSuffix('_after_discard'),
                isTrue,
              );
              expect(store.persisted.apiKey, 'K_Y_old');
            }
            expect(controller.blockedReplayCount, 0);
          },
        );
      }
    }
  });

  group('round11 P1-02', () {
    for (final route in _recoveredRoutes.entries) {
      test(
        'discard preserves newer committed secrets when ${route.key}',
        () async {
          final store = _ControlledSettingsStore(_routeX);
          final controller = SettingsController(store);
          addTearDown(controller.dispose);
          await controller.ready;
          store.conflictNextSave = true;
          expect(await controller.setApiKey('K_X_pending'), isFalse);
          store.persisted = route.value;
          expect(await controller.reloadSettings(), isTrue);
          expect(controller.blockedReplayCount, 1);
          expect(controller.state.apiKey, 'K_Y_old');

          expect(await controller.setApiKey('K_Y_new'), isTrue);
          expect(controller.state.apiKey, 'K_Y_new');
          expect(store.persisted.apiKey, 'K_Y_new');
          expect(controller.blockedReplayCount, 1);
          final committed = store.persisted;

          controller.discardBlockedConflictReplays();
          expect(controller.blockedReplayCount, 0);
          expect(controller.state.apiKey, committed.apiKey);
          expect(controller.state.customApiKey, committed.customApiKey);
          expect(controller.state.deepseekApiKey, committed.deepseekApiKey);
          expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
          expect(store.persisted.apiKey, 'K_Y_new');
          expect(store.persisted.customApiKey, committed.customApiKey);
          expect(store.persisted.deepseekApiKey, committed.deepseekApiKey);
        },
      );
    }

    test(
      'a commit before the discarded edit still restores the loaded values',
      () async {
        final store = _ControlledSettingsStore(_routeX);
        final controller = SettingsController(store);
        addTearDown(controller.dispose);
        await controller.ready;
        expect(await controller.setApiKey('K_X_committed'), isTrue);
        store.conflictNextSave = true;
        expect(await controller.setApiKey('K_X_pending'), isFalse);
        store.persisted = _recoveredRoutes.values.first;
        expect(await controller.reloadSettings(), isTrue);
        expect(controller.blockedReplayCount, 1);

        controller.discardBlockedConflictReplays();
        expect(controller.state.apiKey, 'K_Y_old');
        expect(controller.state.customApiKey, 'K_Y_old');
        expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
        expect(store.persisted.apiKey, 'K_Y_old');
        expect(store.persisted.customApiKey, 'K_Y_old');
      },
    );
  });

  group('round11 P2-01', () {
    test(
      'shared flush saves edits that arrive while the first save is pending',
      () async {
        final store = _ControlledSettingsStore(_routeX);
        final controller = SettingsController(store);
        addTearDown(controller.dispose);
        await controller.ready;
        final firstEdit = controller.setChunkSize(4000);
        final gate = store.saveGate = Completer<void>();
        final started = store.saveStarted = Completer<void>();
        final flush = controller.flushSliderChanges();
        await started.future;
        final secondEdit = controller.setChunkSize(5000);
        final joinedFlush = controller.flushSliderChanges();
        expect(controller.state.chunkSize, 5000);
        expect(store.attempts.single.chunkSize, 4000);
        gate.complete();

        expect(await flush, isTrue);
        expect(await joinedFlush, isTrue);
        expect(store.attempts.map((config) => config.chunkSize), [4000, 5000]);
        expect(store.persisted.chunkSize, 5000);
        await expectLater(firstEdit, completion(isTrue));
        await expectLater(secondEdit, completion(isTrue));
        expect(await controller.flushSliderChanges(), isTrue);
        expect(store.attempts, hasLength(2));
      },
    );

    for (final failingStep in [1, 2]) {
      test(
        'failure in step $failingStep keeps the shared flush false and aborts reload',
        () async {
          final store = _ControlledSettingsStore(_routeX);
          final controller = SettingsController(store);
          addTearDown(controller.dispose);
          await controller.ready;
          final firstEdit = controller.setChunkSize(4000);
          if (failingStep == 1) {
            store.saveError = StateError('disk unavailable');
          }
          final gate = store.saveGate = Completer<void>();
          final started = store.saveStarted = Completer<void>();
          final flush = controller.flushSliderChanges();
          await started.future;
          store.saveError = failingStep == 2
              ? StateError('disk unavailable')
              : null;
          final secondEdit = controller.setChunkSize(5000);
          final reload = controller.reloadSettings();
          gate.complete();

          expect(await flush, isFalse);
          expect(await reload, isFalse);
          expect(store.loadCount, 1);
          expect(store.attempts.map((config) => config.chunkSize), [
            4000,
            5000,
          ]);
          await expectLater(firstEdit, completion(failingStep != 1));
          await expectLater(secondEdit, completion(failingStep != 2));
          expect(store.persisted.chunkSize, failingStep == 1 ? 5000 : 4000);
        },
      );
    }
  });
}
