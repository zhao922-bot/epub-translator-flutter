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

final _routesY = <String, TranslationConfig>{
  'Custom 路由': _routeX.copyWith(
    apiBaseUrl: 'https://service-y.example/v1',
    customApiBaseUrl: 'https://service-y.example/v1',
    apiKey: 'K_Y_old',
    customApiKey: 'K_Y_old',
  ),
  'DeepSeek 路由': _routeX.copyWith(
    apiProviderSelection: ApiProviderSelection.deepseek,
    apiBaseUrl: 'https://api.deepseek.com',
    apiKey: 'K_Y_old',
    deepseekApiKey: 'K_Y_old',
  ),
};

final _routeZ = _routeX.copyWith(
  apiBaseUrl: 'https://service-z.example/v1',
  customApiBaseUrl: 'https://service-z.example/v1',
  apiKey: 'K_Z_fresh',
  customApiKey: 'K_Z_fresh',
  deepseekApiKey: 'K_deepseek_fresh',
);

Future<SettingsController> _withBlockedEdit(
  _ControlledSettingsStore store,
  TranslationConfig routeY,
) async {
  final controller = SettingsController(store);
  addTearDown(controller.dispose);
  await controller.ready;
  store.conflictNextSave = true;
  expect(await controller.setApiKey('K_X_new'), isFalse);
  store.persisted = routeY;
  expect(await controller.reloadSettings(), isTrue);
  expect(controller.blockedReplayCount, 1);
  _expectRouteAndSecrets(controller.state, routeY);
  return controller;
}

void _expectRouteAndSecrets(
  TranslationConfig actual,
  TranslationConfig expected,
) {
  expect(actual.apiProviderSelection, expected.apiProviderSelection);
  expect(actual.apiBaseUrl, expected.apiBaseUrl);
  expect(actual.customApiBaseUrl, expected.customApiBaseUrl);
  expect(actual.apiKey, expected.apiKey);
  expect(actual.customApiKey, expected.customApiKey);
  expect(actual.deepseekApiKey, expected.deepseekApiKey);
  expect(actual.httpProxy, expected.httpProxy);
}

void main() {
  group('round12 P1-01 一致性验证', () {
    for (final route in _routesY.entries) {
      test('${route.key}：再次加载 Z 后放弃旧编辑保留 Z 的加载值', () async {
        final store = _ControlledSettingsStore(_routeX);
        final controller = await _withBlockedEdit(store, route.value);
        expect(await controller.setApiKey('K_Y_new'), isTrue);
        expect(store.persisted.apiKey, 'K_Y_new');
        expect(controller.blockedReplayCount, 1);

        store.persisted = _routeZ;
        expect(await controller.reloadSettings(), isTrue);
        expect(controller.blockedReplayCount, 1);
        _expectRouteAndSecrets(controller.state, _routeZ);
        final attemptsBeforeDiscard = store.attempts.length;

        controller.discardBlockedConflictReplays();
        expect(controller.blockedReplayCount, 0);
        expect(store.attempts, hasLength(attemptsBeforeDiscard));
        _expectRouteAndSecrets(controller.state, _routeZ);
        _expectRouteAndSecrets(store.persisted, _routeZ);

        expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
        expect(store.persisted.outputSuffix, '_ordinary_save');
        _expectRouteAndSecrets(controller.state, _routeZ);
        _expectRouteAndSecrets(store.persisted, _routeZ);
      });

      test('${route.key} 边界样本：保存返回前放弃旧编辑保留在途密钥', () async {
        final store = _ControlledSettingsStore(_routeX);
        final controller = await _withBlockedEdit(store, route.value);
        final gate = store.saveGate = Completer<void>();
        final started = store.saveStarted = Completer<void>();
        final save = controller.setApiKey('K_Y_new');
        await started.future;
        final pending = controller.state;
        try {
          expect(store.persisted.apiKey, 'K_Y_old');
          expect(store.attempts.last.apiKey, 'K_Y_new');
          expect(pending.apiKey, 'K_Y_new');

          controller.discardBlockedConflictReplays();
          expect(controller.blockedReplayCount, 0);
          _expectRouteAndSecrets(controller.state, pending);
        } finally {
          gate.complete();
          await save;
        }

        expect(await save, isTrue);
        _expectRouteAndSecrets(controller.state, pending);
        _expectRouteAndSecrets(store.persisted, pending);
        expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
        _expectRouteAndSecrets(controller.state, pending);
        _expectRouteAndSecrets(store.persisted, pending);
      });
    }

    test('边界样本：相同路由重新加载新密钥也重建提交基线', () async {
      final store = _ControlledSettingsStore(_routeX);
      final routeY = _routesY.values.first;
      final controller = await _withBlockedEdit(store, routeY);
      expect(await controller.setApiKey('K_Y_new'), isTrue);
      final refreshed = routeY.copyWith(
        apiKey: 'K_Y_fresh',
        customApiKey: 'K_Y_fresh',
      );
      store.persisted = refreshed;
      expect(await controller.reloadSettings(), isTrue);
      _expectRouteAndSecrets(controller.state, refreshed);

      controller.discardBlockedConflictReplays();
      expect(controller.blockedReplayCount, 0);
      _expectRouteAndSecrets(controller.state, refreshed);
      expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
      _expectRouteAndSecrets(store.persisted, refreshed);
    });

    test('边界样本：连续在途密钥编辑保留最新值', () async {
      final store = _ControlledSettingsStore(_routeX);
      final controller = await _withBlockedEdit(store, _routesY.values.first);
      final gate = store.saveGate = Completer<void>();
      final started = store.saveStarted = Completer<void>();
      final first = controller.setApiKey('K_Y_first');
      await started.future;
      final second = controller.setApiKey('K_Y_second');
      final pending = controller.state;
      try {
        expect(store.attempts.last.apiKey, 'K_Y_first');
        expect(pending.apiKey, 'K_Y_second');
        controller.discardBlockedConflictReplays();
        expect(controller.blockedReplayCount, 0);
        _expectRouteAndSecrets(controller.state, pending);
      } finally {
        gate.complete();
        await Future.wait([first, second]);
      }

      expect(await first, isTrue);
      expect(await second, isTrue);
      _expectRouteAndSecrets(controller.state, pending);
      _expectRouteAndSecrets(store.persisted, pending);
      expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
      _expectRouteAndSecrets(store.persisted, pending);
    });

    test('边界样本：已结束的失败保存不作为在途提交保留', () async {
      final store = _ControlledSettingsStore(_routeX);
      final routeY = _routesY.values.first;
      final controller = await _withBlockedEdit(store, routeY);
      store.saveError = StateError('disk unavailable');
      expect(await controller.setApiKey('K_Y_pending'), isFalse);
      expect(controller.state.apiKey, 'K_Y_pending');

      controller.discardBlockedConflictReplays();
      expect(controller.blockedReplayCount, 0);
      _expectRouteAndSecrets(controller.state, routeY);
      store.saveError = null;
      expect(await controller.setOutputSuffix('_ordinary_save'), isTrue);
      _expectRouteAndSecrets(store.persisted, routeY);
    });
  });
}
