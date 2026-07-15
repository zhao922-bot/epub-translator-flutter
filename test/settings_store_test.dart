import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSettingsSecretStore implements SettingsSecretStore {
  String? apiKey;
  bool failReads = false;

  @override
  Future<void> deleteApiKey() async {
    apiKey = null;
  }

  @override
  Future<String?> readApiKey() async {
    if (failReads) {
      throw StateError('secret store unavailable');
    }
    return apiKey;
  }

  @override
  Future<void> writeApiKey(String value) async {
    apiKey = value;
  }
}

void main() {
  test('saves API key outside settings json', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore();
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    await store.save(
      TranslationConfig.defaults().copyWith(apiKey: 'sk-secret'),
    );

    expect(secrets.apiKey, 'sk-secret');
    expect(await settingsFile.readAsString(), isNot(contains('sk-secret')));
    expect(
      jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>,
      isNot(contains('apiKey')),
    );
  });

  test('migrates legacy plaintext API key out of settings json', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    await settingsFile.writeAsString(
      jsonEncode(<String, dynamic>{
        ...TranslationConfig.defaults().copyWith(apiKey: 'sk-legacy').toJson(),
        'apiKey': 'sk-legacy',
      }),
    );

    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore();
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();

    expect(loaded.apiKey, 'sk-legacy');
    expect(secrets.apiKey, 'sk-legacy');
    expect(await settingsFile.readAsString(), isNot(contains('sk-legacy')));
  });

  test('keeps non-secret settings when secure API key read fails', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    await settingsFile.writeAsString(
      jsonEncode(
        TranslationConfig.defaults()
            .copyWith(
              apiBaseUrl: 'https://loaded.example/v1',
              model: 'loaded-model',
              outputSuffix: '_loaded',
            )
            .toJson(),
      ),
    );

    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..failReads = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();

    expect(loaded.apiBaseUrl, 'https://loaded.example/v1');
    expect(loaded.model, 'loaded-model');
    expect(loaded.outputSuffix, '_loaded');
    expect(loaded.apiKey, isEmpty);
  });
}
