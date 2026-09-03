import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSettingsSecretStore implements SettingsSecretStore {
  String? apiKey;
  String? deepSeekApiKey;
  String? customApiKey;
  bool failReads = false;
  bool failWrites = false;
  int secretMutationCount = 0;

  @override
  Future<void> deleteApiKey() async {
    secretMutationCount += 1;
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
    if (failWrites) {
      throw StateError('secret store unavailable');
    }
    secretMutationCount += 1;
    apiKey = value;
  }

  @override
  Future<void> deleteDeepSeekApiKey() async {
    secretMutationCount += 1;
    deepSeekApiKey = null;
  }

  @override
  Future<String?> readDeepSeekApiKey() async {
    if (failReads) {
      throw StateError('secret store unavailable');
    }
    return deepSeekApiKey;
  }

  @override
  Future<void> writeDeepSeekApiKey(String value) async {
    if (failWrites) {
      throw StateError('secret store unavailable');
    }
    secretMutationCount += 1;
    deepSeekApiKey = value;
  }

  @override
  Future<void> deleteCustomApiKey() async {
    secretMutationCount += 1;
    customApiKey = null;
  }

  @override
  Future<String?> readCustomApiKey() async {
    if (failReads) {
      throw StateError('secret store unavailable');
    }
    return customApiKey;
  }

  @override
  Future<void> writeCustomApiKey(String value) async {
    if (failWrites) {
      throw StateError('secret store unavailable');
    }
    secretMutationCount += 1;
    customApiKey = value;
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

  test(
    'persists DeepSeek and Custom credentials as separate secrets',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_provider_profiles_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore();
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );
      final TranslationConfig custom = TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://custom.example/v1',
        apiKey: 'sk-custom',
        model: 'custom-model',
        deepseekApiKey: 'sk-deepseek',
        customApiBaseUrl: 'https://custom.example/v1',
        customApiKey: 'sk-custom',
        customModel: 'custom-model',
      );

      await store.save(custom);
      final TranslationConfig restored = await store.load();

      expect(restored.apiProviderSelection, ApiProviderSelection.custom);
      expect(restored.apiBaseUrl, 'https://custom.example/v1');
      expect(restored.apiKey, 'sk-custom');
      expect(restored.model, 'custom-model');
      expect(restored.deepseekApiKey, 'sk-deepseek');
      expect(secrets.deepSeekApiKey, 'sk-deepseek');
      expect(secrets.customApiKey, 'sk-custom');
      final String json = await settingsFile.readAsString();
      expect(json, isNot(contains('sk-custom')));
      expect(json, isNot(contains('sk-deepseek')));
    },
  );

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

  test('assigns a legacy secure key to an old DeepSeek profile', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_legacy_deepseek_profile_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    await settingsFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'apiBaseUrl': 'https://api.deepseek.com',
        'model': 'deepseek-chat',
      }),
    );
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..apiKey = 'sk-legacy-secure';
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();

    expect(loaded.apiProviderSelection, ApiProviderSelection.deepseek);
    expect(loaded.apiKey, 'sk-legacy-secure');
    expect(loaded.deepseekApiKey, 'sk-legacy-secure');
    expect(loaded.customApiKey, isEmpty);
  });

  test(
    'keeps legacy plaintext key when secure migration write fails',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_failed_key_migration_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      await settingsFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...TranslationConfig.defaults()
              .copyWith(apiKey: 'sk-legacy')
              .toJson(),
          'apiKey': 'sk-legacy',
        }),
      );
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
        ..failWrites = true;
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      final TranslationConfig loaded = await store.load();

      expect(loaded.apiKey, 'sk-legacy');
      expect(secrets.apiKey, isNull);
      expect(await settingsFile.readAsString(), contains('sk-legacy'));
    },
  );

  test(
    'legacy migration preserves an unreadable inactive provider key',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_scoped_key_migration_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      await settingsFile.writeAsString(
        jsonEncode(<String, dynamic>{
          ...TranslationConfig.defaults()
              .copyWith(
                apiProviderSelection: ApiProviderSelection.custom,
                apiKey: 'sk-legacy-custom',
              )
              .toJson(),
          'apiKey': 'sk-legacy-custom',
        }),
      );
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
        ..deepSeekApiKey = 'sk-unreadable-deepseek'
        ..failReads = true;
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      final TranslationConfig loaded = await store.load();

      expect(loaded.apiKey, 'sk-legacy-custom');
      expect(secrets.apiKey, 'sk-legacy-custom');
      expect(secrets.deepSeekApiKey, 'sk-unreadable-deepseek');
      expect(secrets.customApiKey, 'sk-legacy-custom');
      expect(secrets.secretMutationCount, 2);
      expect(
        await settingsFile.readAsString(),
        isNot(contains('sk-legacy-custom')),
      );
    },
  );

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

  test('unrelated save preserves secrets whose reads failed', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_unreadable_secrets_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..apiKey = 'sk-legacy'
      ..deepSeekApiKey = 'sk-deepseek'
      ..customApiKey = 'sk-custom'
      ..failReads = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();
    await store.save(
      loaded.copyWith(themeMode: AppThemeMode.dark),
      explicitSecretMutations: const <SettingsSecretSlot>{},
    );

    expect(secrets.secretMutationCount, 0);
    expect(secrets.apiKey, 'sk-legacy');
    expect(secrets.deepSeekApiKey, 'sk-deepseek');
    expect(secrets.customApiKey, 'sk-custom');
  });

  test(
    'explicit key edit can replace only selected unreadable secrets',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_replace_unreadable_secrets_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
        ..apiKey = 'sk-old-legacy'
        ..deepSeekApiKey = 'sk-old-deepseek'
        ..customApiKey = 'sk-old-custom'
        ..failReads = true;
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      final TranslationConfig loaded = await store.load();
      await store.save(
        loaded.copyWith(apiKey: 'sk-new', customApiKey: 'sk-new'),
        explicitSecretMutations: const <SettingsSecretSlot>{
          SettingsSecretSlot.legacy,
          SettingsSecretSlot.custom,
        },
      );

      expect(secrets.secretMutationCount, 2);
      expect(secrets.apiKey, 'sk-new');
      expect(secrets.deepSeekApiKey, 'sk-old-deepseek');
      expect(secrets.customApiKey, 'sk-new');
    },
  );

  test('explicit key clear can delete selected unreadable secrets', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_clear_unreadable_secrets_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..apiKey = 'sk-old-legacy'
      ..deepSeekApiKey = 'sk-old-deepseek'
      ..customApiKey = 'sk-old-custom'
      ..failReads = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();
    await store.save(
      loaded,
      explicitSecretMutations: const <SettingsSecretSlot>{
        SettingsSecretSlot.legacy,
        SettingsSecretSlot.custom,
      },
    );

    expect(secrets.secretMutationCount, 2);
    expect(secrets.apiKey, isNull);
    expect(secrets.deepSeekApiKey, 'sk-old-deepseek');
    expect(secrets.customApiKey, isNull);
  });
}
