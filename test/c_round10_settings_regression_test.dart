import 'dart:async';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReplayStore extends SettingsStore {
  TranslationConfig persisted = TranslationConfig.defaults();
  TranslationConfig? nextLoad;
  Object? saveError;
  Object? loadError;
  final attempts = <String>[];
  final events = <String>[];
  Completer<void>? saveStarted;
  Completer<void>? releaseSave;

  @override
  Object? get configLoadError => loadError;

  @override
  Future<TranslationConfig> load() async {
    events.add('load');
    loadError = null;
    final loaded = nextLoad ?? persisted;
    nextLoad = null;
    return loaded;
  }

  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    attempts.add(config.outputSuffix);
    events.add('save-start:${config.outputSuffix}');
    final gate = releaseSave;
    if (gate != null) {
      releaseSave = null;
      saveStarted!.complete();
      await gate.future;
    }
    final error = saveError;
    if (error != null) {
      if (error is SettingsWriteConflict) loadError = error;
      throw error;
    }
    persisted = config;
    events.add('save-end:${config.outputSuffix}');
  }
}

/// A fresh snapshot whose transformation throws before reaching save().
class _ThrowingConfig implements TranslationConfig {
  final defaults = TranslationConfig.defaults();
  final error = StateError('Injected transformation failure');

  @override
  ApiProviderSelection get apiProviderSelection =>
      defaults.apiProviderSelection;
  @override
  String get apiBaseUrl => defaults.apiBaseUrl;
  @override
  String get customApiBaseUrl => defaults.customApiBaseUrl;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw error;
}

void main() {
  late _ReplayStore store;
  late SettingsController controller;
  late List<Object?> notices;

  setUp(() async {
    store = _ReplayStore();
    notices = <Object?>[];
    controller = SettingsController(store, onSaveError: notices.add);
    addTearDown(controller.dispose);
    await controller.ready;
  });

  Future<void> queueTwoConflicts() async {
    store.saveError = SettingsWriteConflict();
    // Queue both snapshots before the first save reports its conflict, as
    // happens when the user makes another edit during an in-flight save.
    final first = controller.setOutputSuffix('_first');
    final second = controller.setOutputSuffix('_second');
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(store.attempts, ['_first', '_second']);
    store.saveError = null;
    store.attempts.clear();
    notices.clear();
  }

  test('P2-#5: non-conflict replay failures retain edits in order', () async {
    await queueTwoConflicts();
    final failure = StateError('Injected disk write failure');
    store.saveError = failure;

    await controller.reloadSettings();
    expect(store.attempts, ['_first', '_second']);
    expect(notices, [same(failure), same(failure)]);
    expect(store.persisted.outputSuffix, '_translated');

    store.saveError = null;
    store.attempts.clear();
    await controller.reloadSettings();
    expect(store.attempts, ['_first', '_second']);
    expect(controller.state.outputSuffix, '_second');
    expect(store.persisted.outputSuffix, '_second');
    expect(notices.last, isNull);

    store.attempts.clear();
    await controller.reloadSettings();
    expect(store.attempts, isEmpty, reason: 'Successful edits leave the queue');
  });

  test('P2-#5: thrown update retains current and remaining edits', () async {
    await queueTwoConflicts();
    final broken = _ThrowingConfig();
    store.nextLoad = broken;

    await controller.reloadSettings();
    expect(notices, [same(broken.error)]);
    expect(store.attempts, isEmpty, reason: 'The error precedes _saveUpdate');

    await controller.reloadSettings();
    expect(store.attempts, ['_first', '_second']);
    expect(controller.state.outputSuffix, '_second');
    expect(store.persisted.outputSuffix, '_second');

    store.attempts.clear();
    await controller.reloadSettings();
    expect(store.attempts, isEmpty);
  });

  test(
    'P2-#5: repeated replay conflicts do not duplicate or reorder edits',
    () async {
      await queueTwoConflicts();
      store.saveError = SettingsWriteConflict();

      await controller.reloadSettings();
      expect(store.attempts, ['_first', '_second']);
      expect(notices.whereType<SettingsWriteConflict>(), hasLength(2));

      store.saveError = null;
      store.attempts.clear();
      await controller.reloadSettings();
      expect(store.attempts, ['_first', '_second']);
      expect(store.persisted.outputSuffix, '_second');
    },
  );

  test('P2-#6: reload waits for the entire current save chain', () async {
    store.saveStarted = Completer<void>();
    final release = store.releaseSave = Completer<void>();
    final first = controller.setOutputSuffix('_A');
    await store.saveStarted!.future;
    final second = controller.setOutputSuffix('_B');
    final reloading = controller.reloadSettings();
    await Future<void>.delayed(Duration.zero);

    expect(store.events, ['load', 'save-start:_A']);
    expect(controller.state.outputSuffix, '_B');

    release.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    await reloading;
    expect(store.events, [
      'load',
      'save-start:_A',
      'save-end:_A',
      'save-start:_B',
      'save-end:_B',
      'load',
    ]);
    expect(controller.state.outputSuffix, '_B');
    expect(store.persisted.outputSuffix, '_B');
  });
}
