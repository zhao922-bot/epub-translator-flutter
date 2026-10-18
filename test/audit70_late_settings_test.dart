import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';

class _DelayedSettings extends SettingsStore {
  final loaded = Completer<TranslationConfig>();
  final saves = <TranslationConfig>[];
  @override
  Future<TranslationConfig> load() => loaded.future;
  @override
  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    saves.add(config);
  }
}

void main() {
  test(
    'an edit waiting for initial loading completes normally while alive',
    () async {
      final store = _DelayedSettings();
      final controller = SettingsController(store);
      addTearDown(controller.dispose);
      final edit = controller.setApiKey('audit-new-key');
      store.loaded.complete(TranslationConfig.defaults());
      expect(await edit, isTrue);
      expect(store.saves.single.apiKey, 'audit-new-key');
    },
  );
  test(
    'an edit waiting for initial loading cancels cleanly after dispose',
    () async {
      final store = _DelayedSettings();
      final controller = SettingsController(store);
      final edit = controller.setApiKey('audit-new-key');
      final expectation = expectLater(edit, completion(isFalse));
      controller.dispose();
      store.loaded.complete(TranslationConfig.defaults());
      await expectation;
      expect(store.saves, isEmpty);
    },
  );
}
