import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/api_provider_preset.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledSettingsStore extends SettingsStore {
  _ControlledSettingsStore(this.persisted);

  TranslationConfig persisted;
  Object? loadError;
  bool conflictNextSave = false;
  Set<SettingsSecretSlot> persistedSlots = {};

  @override
  Object? get configLoadError => loadError;

  @override
  Set<SettingsSecretSlot> get lastPersistedSecretSlots => persistedSlots;

  @override
  Future<TranslationConfig> load() async {
    loadError = null;
    return persisted;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    if (conflictNextSave) {
      conflictNextSave = false;
      final error = SettingsWriteConflict();
      loadError = error;
      throw error;
    }
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

void main() {
  test(
    'round16 P1-03: discard preserves the committed Custom key after switching to DeepSeek',
    () async {
      final routeX = TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://service-x.example/v1',
        customApiBaseUrl: 'https://service-x.example/v1',
        apiKey: 'K_X_old',
        customApiKey: 'K_X_old',
        deepseekApiKey: 'K_deepseek',
      );
      final store = _ControlledSettingsStore(routeX);
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      await controller.ready;

      store.conflictNextSave = true;
      expect(await controller.setApiKey('K_X_new'), isFalse);
      expect(store.persisted.customApiKey, 'K_X_old');

      final routeY = routeX.copyWith(
        apiBaseUrl: 'https://service-y.example/v1',
        customApiBaseUrl: 'https://service-y.example/v1',
        apiKey: 'K_Y_old',
        customApiKey: 'K_Y_old',
      );
      store.persisted = routeY;
      expect(await controller.reloadSettings(), isTrue);
      expect(controller.blockedReplayCount, 1);
      expect(controller.state.customApiKey, 'K_Y_old');

      expect(await controller.setApiKey('K_Y_new'), isTrue);
      expect(store.persisted.customApiKey, 'K_Y_new');
      expect(controller.blockedReplayCount, 1);

      await controller.applyApiProviderPreset(ApiProviderPreset.deepseek);
      expect(
        controller.state.apiProviderSelection,
        ApiProviderSelection.deepseek,
      );
      expect(controller.state.apiKey, 'K_deepseek');
      expect(controller.state.customApiBaseUrl, routeY.customApiBaseUrl);
      expect(controller.state.customApiKey, 'K_Y_new');
      // The Custom snapshot still belongs to Y: the preset only saves legacy.
      expect(store.lastPersistedSecretSlots, {SettingsSecretSlot.legacy});

      controller.discardBlockedConflictReplays();
      expect(controller.state.customApiKey, 'K_Y_new');
      expect(controller.state.apiKey, 'K_deepseek');
      expect(controller.state.apiKey, controller.state.deepseekApiKey);
      expect(controller.blockedReplayCount, 0);

      expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
      expect(store.persisted.outputSuffix, '_ordinary_save');
      expect(store.persisted.customApiKey, 'K_Y_new');
      expect(store.persisted.apiKey, 'K_deepseek');
    },
  );
}
