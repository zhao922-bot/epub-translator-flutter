import 'dart:io';

import 'package:epub_translator_flutter/features/settings/application/settings_controller.dart';
import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// In-memory secret store, following the round8 conflict regression fixture.
class _FakeSecrets implements SettingsSecretStore {
  final values = <SettingsSecretSlot, String>{};

  Future<String?> _read(SettingsSecretSlot slot) async => values[slot];

  Future<void> _write(SettingsSecretSlot slot, String value) async {
    values[slot] = value;
  }

  Future<void> _delete(SettingsSecretSlot slot) async {
    values.remove(slot);
  }

  @override
  Future<String?> readApiKey() => _read(SettingsSecretSlot.legacy);
  @override
  Future<String?> readDeepSeekApiKey() => _read(SettingsSecretSlot.deepSeek);
  @override
  Future<String?> readCustomApiKey() => _read(SettingsSecretSlot.custom);
  @override
  Future<String?> readProxyAuthentication() => _read(SettingsSecretSlot.proxy);
  @override
  Future<void> writeApiKey(String value) =>
      _write(SettingsSecretSlot.legacy, value);
  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      _write(SettingsSecretSlot.deepSeek, value);
  @override
  Future<void> writeCustomApiKey(String value) =>
      _write(SettingsSecretSlot.custom, value);
  @override
  Future<void> writeProxyAuthentication(String value) =>
      _write(SettingsSecretSlot.proxy, value);
  @override
  Future<void> deleteApiKey() => _delete(SettingsSecretSlot.legacy);
  @override
  Future<void> deleteDeepSeekApiKey() => _delete(SettingsSecretSlot.deepSeek);
  @override
  Future<void> deleteCustomApiKey() => _delete(SettingsSecretSlot.custom);
  @override
  Future<void> deleteProxyAuthentication() => _delete(SettingsSecretSlot.proxy);
}

void main() {
  late File file;
  late _FakeSecrets secrets;
  late SettingsController controller;
  late SettingsStore store;
  late bool failReads;
  late int blocked;
  late List<Object?> saveErrors;

  SettingsStore newStore() => SettingsStore(
    settingsFileProvider: () async {
      if (failReads) throw StateError('Injected settings read failure');
      return file;
    },
    secretStore: secrets,
  );

  Future<void> changeOtherEndpoint() async {
    final other = newStore();
    await other.save(
      (await other.load()).copyWith(
        apiBaseUrl: 'https://y.example.com',
        customApiBaseUrl: 'https://y.example.com',
      ),
    );
  }

  Future<void> changeOtherTheme() async {
    final other = newStore();
    await other.save(
      (await other.load()).copyWith(themeMode: AppThemeMode.light),
    );
  }

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('c9_settings_');
    addTearDown(() => dir.delete(recursive: true));
    file = File(p.join(dir.path, 'settings.json'));
    secrets = _FakeSecrets();
    failReads = false;
    blocked = 0;
    saveErrors = <Object?>[];
    store = newStore();
    controller = SettingsController(
      store,
      onSaveError: saveErrors.add,
      onReplayBlocked: () => blocked++,
    );
    addTearDown(controller.dispose);
    await controller.ready;
  });

  test('T1: changed credential route blocks replay until confirmed', () async {
    expect(await controller.setApiBaseUrl('https://x.example.com'), isTrue);
    await changeOtherEndpoint();
    expect(await controller.setApiKey('K'), isFalse);
    expect(store.configLoadError, isA<SettingsWriteConflict>());

    await controller.reloadSettings();
    expect(blocked, 1);
    expect(controller.state.apiBaseUrl, 'https://y.example.com');
    expect(controller.state.apiKey, isNot('K'));
    expect(secrets.values[SettingsSecretSlot.custom], isNot('K'));
    expect(secrets.values[SettingsSecretSlot.legacy], isNot('K'));

    // An unrelated successful save must retain the blocked credential edit.
    expect(await controller.setOutputSuffix('_pending'), isTrue);
    await controller.confirmBlockedConflictReplays();
    expect(blocked, 1);
    expect(controller.state.apiKey, 'K');
    expect(secrets.values[SettingsSecretSlot.custom], 'K');
    expect((await newStore().load()).apiKey, 'K');
  });

  test('T2: route change does not block non-credential replay', () async {
    expect(await controller.setApiBaseUrl('https://x.example.com'), isTrue);
    await changeOtherEndpoint();
    await controller.setThemeMode(AppThemeMode.dark);
    expect(store.configLoadError, isA<SettingsWriteConflict>());

    await controller.reloadSettings();
    expect(blocked, 0);
    expect(controller.state.themeMode, AppThemeMode.dark);
    expect(controller.state.apiBaseUrl, 'https://y.example.com');
    expect((await newStore().load()).themeMode, AppThemeMode.dark);
  });

  test('T3: next edit auto-recovers and replays the previous edit', () async {
    await changeOtherTheme();
    expect(await controller.setTargetLanguage('English'), isFalse);
    expect(store.configLoadError, isA<SettingsWriteConflict>());

    expect(await controller.setOutputSuffix('_x'), isTrue);
    expect(controller.state.targetLanguage, 'English');
    expect(controller.state.outputSuffix, '_x');
    expect(controller.state.themeMode, AppThemeMode.light);
    final persisted = await newStore().load();
    expect(persisted.targetLanguage, 'English');
    expect(persisted.outputSuffix, '_x');
  });

  test('T4: failed reload preserves conflict edits for retry', () async {
    await changeOtherTheme();
    expect(await controller.setTargetLanguage('English'), isFalse);

    failReads = true;
    await controller.reloadSettings();
    expect(saveErrors.last, isA<StateError>());
    failReads = false;
    await controller.reloadSettings();
    expect(controller.state.targetLanguage, 'English');
    expect(controller.state.themeMode, AppThemeMode.light);
    expect((await newStore().load()).targetLanguage, 'English');
  });
}
