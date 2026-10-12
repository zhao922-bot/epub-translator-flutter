import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_translator_flutter/features/settings/infrastructure/settings_store.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

class _FakeSettingsSecretStore implements SettingsSecretStore {
  String? proxyAuthentication;
  @override
  Future<String?> readProxyAuthentication() async {
    if (failReads) throw StateError('secret store unavailable');
    return proxyAuthentication;
  }

  @override
  Future<void> writeProxyAuthentication(String value) async {
    if (failWrites) throw StateError('secret store unavailable');
    proxyAuthentication = value;
  }

  @override
  Future<void> deleteProxyAuthentication() async {
    if (failDeletes) throw StateError('secret store unavailable');
    proxyAuthentication = null;
  }

  String? apiKey;
  String? deepSeekApiKey;
  String? customApiKey;
  bool failReads = false;

  /// When true, reads throw [SecretKeyRotatedException], simulating an
  /// Android KeyStore key invalidated by a lock-screen/biometric change.
  bool rotateKeyOnReads = false;
  bool failWrites = false;
  bool failDeepSeekWrites = false;
  bool failDeletes = false;
  int secretMutationCount = 0;

  @override
  Future<void> deleteApiKey() async {
    secretMutationCount += 1;
    if (failDeletes) {
      throw StateError('secret store unavailable');
    }
    apiKey = null;
  }

  @override
  Future<String?> readApiKey() async {
    if (rotateKeyOnReads) {
      throw const SecretKeyRotatedException();
    }
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
    if (failWrites || failDeepSeekWrites) {
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

class _PausedCustomSecretStore extends _FakeSettingsSecretStore {
  Completer<void>? release;
  final started = Completer<void>();
  @override
  Future<void> writeCustomApiKey(String value) async {
    final gate = release;
    if (gate != null) {
      started.complete();
      await gate.future;
    }
    await super.writeCustomApiKey(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('P1-8 a load cannot straddle secure key and endpoint writes', () async {
    final temp = await Directory.systemTemp.createTemp('settings_read_write_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final secrets = _PausedCustomSecretStore();
    final a = SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: secrets,
    );
    final b = SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: secrets,
    );
    await a.save(
      TranslationConfig.defaults().copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: 'https://old.example',
        customApiBaseUrl: 'https://old.example',
        apiKey: 'old',
        customApiKey: 'old',
      ),
    );
    final old = await a.load();
    secrets.release = Completer<void>();
    final saving = a.save(
      old.copyWith(
        apiBaseUrl: 'https://new.example',
        customApiBaseUrl: 'https://new.example',
        apiKey: 'new',
        customApiKey: 'new',
      ),
    );
    await secrets.started.future;
    var loaded = false;
    final loading = b.load().then((config) {
      loaded = true;
      return config;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(loaded, isFalse);
    secrets.release!.complete();
    await saving;
    final config = await loading;
    expect(config.apiBaseUrl, 'https://new.example');
    expect(config.customApiKey, 'new');
  });
  test(
    'P1-7 failed legacy delete cannot cross provider boundaries on restart',
    () async {
      final temp = await Directory.systemTemp.createTemp('provider_ownership_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      SettingsStore makeStore() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final store = makeStore();
      await store.save(
        TranslationConfig.defaults().copyWith(
          apiKey: 'official-secret',
          deepseekApiKey: 'official-secret',
        ),
      );
      final loaded = await store.load();
      secrets.failDeletes = true;
      await expectLater(
        store.save(
          loaded.copyWith(
            apiProviderSelection: ApiProviderSelection.custom,
            apiBaseUrl: 'https://third-party.example',
            customApiBaseUrl: 'https://third-party.example',
            apiKey: '',
            customApiKey: '',
          ),
        ),
        throwsStateError,
      );
      expect(secrets.apiKey, 'official-secret');
      final restarted = await makeStore().load();
      expect(restarted.apiProviderSelection, ApiProviderSelection.custom);
      expect(restarted.apiKey, isEmpty);
      expect(restarted.customApiKey, isEmpty);
      expect(restarted.deepseekApiKey, 'official-secret');
      expect(secrets.customApiKey, isNull);
    },
  );

  test(
    'P1-7 explicit provider clear is not resurrected by legacy residue',
    () async {
      final temp = await Directory.systemTemp.createTemp('provider_clear_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.save(
        TranslationConfig.defaults().copyWith(
          apiKey: 'old-secret',
          deepseekApiKey: 'old-secret',
        ),
      );
      final loaded = await store.load();
      secrets.failDeletes = true;
      await expectLater(
        store.save(loaded.copyWith(apiKey: '', deepseekApiKey: '')),
        throwsStateError,
      );
      final restarted = await SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      ).load();
      expect(restarted.apiKey, isEmpty);
      expect(restarted.deepseekApiKey, isEmpty);
      expect(secrets.apiKey, 'old-secret');
    },
  );

  test(
    'P1-8 stale theme save cannot combine an old endpoint with a new key',
    () async {
      final temp = await Directory.systemTemp.createTemp('settings_instances_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      SettingsStore makeStore() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final a = makeStore();
      await a.save(
        TranslationConfig.defaults().copyWith(
          apiProviderSelection: ApiProviderSelection.custom,
          apiBaseUrl: 'https://old.example',
          customApiBaseUrl: 'https://old.example',
          apiKey: 'old-key',
          customApiKey: 'old-key',
        ),
      );
      final b = makeStore();
      final aConfig = await a.load();
      final bConfig = await b.load();
      await a.save(
        aConfig.copyWith(
          apiBaseUrl: 'https://new.example',
          customApiBaseUrl: 'https://new.example',
          apiKey: 'new-key',
          customApiKey: 'new-key',
        ),
      );
      final mutationCount = secrets.secretMutationCount;
      await expectLater(
        b.save(bConfig.copyWith(themeMode: AppThemeMode.light)),
        throwsA(isA<SettingsWriteConflict>()),
      );
      expect(secrets.secretMutationCount, mutationCount);
      final restarted = await makeStore().load();
      expect(restarted.apiBaseUrl, 'https://new.example');
      expect(restarted.customApiBaseUrl, 'https://new.example');
      expect(restarted.apiKey, 'new-key');
      // A reload lets the caller retry its UI edit against the current version.
      final refreshed = await b.load();
      await b.save(refreshed.copyWith(themeMode: AppThemeMode.light));
      expect((await makeStore().load()).themeMode, AppThemeMode.light);
    },
  );

  test(
    'P1-8 simultaneous saves serialize version checks including key-only edits',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'settings_concurrent_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      final a = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final b = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await a.save(
        TranslationConfig.defaults().copyWith(
          apiKey: 'old',
          deepseekApiKey: 'old',
        ),
      );
      final ca = await a.load();
      final cb = await b.load();
      final results = await Future.wait([
        a
            .save(ca.copyWith(apiKey: 'new', deepseekApiKey: 'new'))
            .then<Object?>((_) => null, onError: (Object e) => e),
        b
            .save(cb.copyWith(themeMode: AppThemeMode.light))
            .then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      expect(results.whereType<SettingsWriteConflict>(), hasLength(1));
      expect(results.where((e) => e == null), hasLength(1));
    },
  );

  test(
    'P1-9 credential-bearing API URLs never reach JSON or secret mutations',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'api_url_credentials_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await store.save(TranslationConfig.defaults());
      final before = await file.readAsString();
      final count = secrets.secretMutationCount;
      for (final url in [
        'https://user:password@host/v1?key=secret',
        'https://host/v1?key=secret',
        'https://user:password@host/v1',
      ]) {
        for (final custom in [false, true]) {
          final config = TranslationConfig.defaults().copyWith(
            apiBaseUrl: custom ? null : url,
            customApiBaseUrl: custom ? url : null,
          );
          expect(config.toJson, throwsFormatException);
          await expectLater(store.save(config), throwsFormatException);
          expect(await file.readAsString(), before);
          expect(secrets.secretMutationCount, count);
        }
      }
      // Fragments carry no credentials over HTTP and are allowed (#17), but
      // must round-trip without leaking anything into secrets.
      final okConfig = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://host/v1#section',
      );
      await store.save(okConfig);
      expect(secrets.secretMutationCount, count);
      // A stale legitimate custom URL (non-credential query) must not block
      // saving unrelated settings when DeepSeek is selected (#17).
      final staleLegit = TranslationConfig.defaults().copyWith(
        customApiBaseUrl: 'https://gateway.example.com/v1?tenant=books',
      );
      await store.save(staleLegit);
    },
  );

  test('P1-10 corrupt plaintext config logs no source or API key', () async {
    final temp = await Directory.systemTemp.createTemp('corrupt_secret_logs_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString('{"apiKey":"ultra-private-secret", broken}');
    final output = <String>[];
    void listener(OutputEvent event) {
      output.addAll(event.lines);
      output.add('${event.origin.error}');
    }

    Logger.addOutputListener(listener);
    addTearDown(() => Logger.removeOutputListener(listener));
    final store = SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: _FakeSettingsSecretStore(),
    );
    await store.load();
    expect(store.didCorruptReset, isTrue);
    expect(output.join('\n'), contains('FormatException'));
    expect(output.join('\n'), contains('offset:'));
    expect(output.join('\n'), isNot(contains('ultra-private-secret')));
    expect(output.join('\n'), isNot(contains('apiKey')));
  });
  test('native proxy authentication uses flutter secure storage', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = NativeSettingsSecretStore();
    await store.writeProxyAuthentication('encoded-credentials');
    expect(await store.readProxyAuthentication(), 'encoded-credentials');
    expect(
      await const FlutterSecureStorage().read(key: 'http_proxy_authentication'),
      'encoded-credentials',
    );
    await store.deleteProxyAuthentication();
    expect(await store.readProxyAuthentication(), isNull);
  });
  test(
    'proxy credentials migrate to secure storage and survive reload',
    () async {
      final temp = await Directory.systemTemp.createTemp('proxy_migration_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      const proxy = 'http://alice:p%40ss%3Aword@127.0.0.1:8080';
      await file.writeAsString(
        jsonEncode({
          ...TranslationConfig.defaults().toJson(),
          'httpProxy': proxy,
        }),
      );
      SettingsStore store() => SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await store().load()).httpProxy, proxy);
      expect(secrets.proxyAuthentication, contains('p%40ss%3Aword'));
      final disk = await file.readAsString();
      expect(disk, isNot(contains('alice')));
      expect(disk, isNot(contains('p%40ss')));
      expect(jsonDecode(disk)['httpProxy'], 'http://127.0.0.1:8080');
      expect((await store().load()).httpProxy, proxy);
      final loadedStore = store();
      final loaded = await loadedStore.load();
      await loadedStore.save(loaded.copyWith(httpProxy: 'http://other:8080'));
      expect(secrets.proxyAuthentication, isNull);
      expect((await store().load()).httpProxy, 'http://other:8080');
    },
  );

  test(
    'failed proxy migration retains legacy URL and retries securely',
    () async {
      final temp = await Directory.systemTemp.createTemp('proxy_retry_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      const proxy = 'user:password@localhost:8080';
      final original = jsonEncode({'httpProxy': proxy});
      await file.writeAsString(original);
      final secrets = _FakeSettingsSecretStore()..failWrites = true;
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      expect((await store.load()).httpProxy, proxy);
      expect(await file.readAsString(), original);
      secrets.failWrites = false;
      expect((await store.load()).httpProxy, proxy);
      expect(await file.readAsString(), isNot(contains('password')));
      expect(
        (await SettingsStore(
          settingsFileProvider: () async => file,
          secretStore: secrets,
        ).load()).httpProxy,
        proxy,
      );
    },
  );

  test('new proxy saves never write authentication to settings json', () async {
    final temp = await Directory.systemTemp.createTemp('proxy_save_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final secrets = _FakeSettingsSecretStore();
    final store = SettingsStore(
      settingsFileProvider: () async => file,
      secretStore: secrets,
    );
    final config = await store.load();
    await store.save(
      config.copyWith(httpProxy: 'http://user:secret@host:8080'),
    );
    expect(await file.readAsString(), isNot(contains('secret')));
    expect(secrets.proxyAuthentication, contains('user:secret'));
    // Secure data for a previous endpoint cannot authenticate a new address.
    await file.writeAsString(
      jsonEncode(config.copyWith(httpProxy: 'http://new:8080').toJson()),
    );
    expect(
      (await SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      ).load()).httpProxy,
      'http://new:8080',
    );
  });

  test('proxy toJson strips credentials even from malformed addresses', () {
    for (final proxy in [
      'http://user:password@[broken',
      'user:password@host:8080',
    ]) {
      final json = TranslationConfig.defaults()
          .copyWith(httpProxy: proxy)
          .toJson();
      expect(jsonEncode(json), isNot(contains('password')));
    }
  });

  test(
    'unreadable proxy secret is protected until an explicit proxy edit',
    () async {
      final temp = await Directory.systemTemp.createTemp('proxy_unreadable_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      final first = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      await first.save(
        TranslationConfig.defaults().copyWith(
          httpProxy: 'http://user:secret@host:8080',
        ),
      );
      final stored = secrets.proxyAuthentication;
      secrets.failReads = true;
      final second = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final loaded = await second.load();
      expect(loaded.httpProxy, 'http://host:8080');
      await second.save(loaded.copyWith(bilingual: true));
      expect(secrets.proxyAuthentication, stored);
      await second.save(
        loaded.copyWith(httpProxy: ''),
        explicitSecretMutations: {SettingsSecretSlot.proxy},
      );
      expect(secrets.proxyAuthentication, isNull);
    },
  );

  test(
    'failed new proxy save exposes failure without plaintext fallback',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'proxy_write_failure_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final secrets = _FakeSettingsSecretStore();
      final store = SettingsStore(
        settingsFileProvider: () async => file,
        secretStore: secrets,
      );
      final loaded = await store.load();
      secrets.failWrites = true;
      final updated = loaded.copyWith(
        httpProxy: 'http://user:secret@host:8080',
      );
      await expectLater(store.save(updated), throwsStateError);
      expect(await file.readAsString(), isNot(contains('secret')));
      secrets.failWrites = false;
      await store.save(updated);
      expect(secrets.proxyAuthentication, contains('user:secret'));
    },
  );

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
    expect(secrets.deepSeekApiKey, 'sk-legacy-secure');
    await store.save(
      loaded.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiKey: '',
      ),
    );
    final restarted = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );
    expect((await restarted.load()).deepseekApiKey, 'sk-legacy-secure');
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
      await store.save(loaded.copyWith(themeMode: AppThemeMode.light));
      expect(await settingsFile.readAsString(), contains('sk-legacy'));
      final restarted = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );
      expect((await restarted.load()).apiKey, 'sk-legacy');
      await store.save(
        loaded.copyWith(
          apiProviderSelection: ApiProviderSelection.custom,
          apiKey: '',
        ),
      );
      final afterSwitch = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );
      final switched = await afterSwitch.load();
      expect(switched.apiKey, isEmpty);
      expect(switched.deepseekApiKey, 'sk-legacy');
      secrets.failWrites = false;
      await afterSwitch.load();
      expect(secrets.deepSeekApiKey, 'sk-legacy');
      expect(await settingsFile.readAsString(), isNot(contains('sk-legacy')));
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

  test(
    'legacy migration does not rewrite a readable inactive provider key',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_scoped_readable_key_migration_test_',
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
        ..deepSeekApiKey = 'sk-existing-deepseek'
        ..failDeepSeekWrites = true;
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      final TranslationConfig loaded = await store.load();

      expect(loaded.apiKey, 'sk-legacy-custom');
      expect(secrets.apiKey, 'sk-legacy-custom');
      expect(secrets.deepSeekApiKey, 'sk-existing-deepseek');
      expect(secrets.customApiKey, 'sk-legacy-custom');
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

  test(
    'backs up a corrupt settings.json instead of silently resetting',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_corrupt_settings_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      const String corrupt = '{"outputSuffix": "_x", broken';
      await settingsFile.writeAsString(corrupt);
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: _FakeSettingsSecretStore(),
      );

      final TranslationConfig loaded = await store.load();

      expect(loaded.outputSuffix, TranslationConfig.defaults().outputSuffix);
      final List<File> backups = temp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('settings.json.bad-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), corrupt);
      // The corrupt file was moved aside, so a later save cannot silently
      // overwrite it.
      expect(await settingsFile.exists(), isFalse);
      // The controller surfaces these to the UI notice.
      expect(store.didCorruptReset, isTrue);
      expect(store.lastCorruptBackupPath, backups.single.path);
    },
  );

  test(
    'backs up settings.json when it is valid JSON but not an object',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_non_object_settings_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      await settingsFile.writeAsString('[1, 2, 3]');
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: _FakeSettingsSecretStore(),
      );

      final TranslationConfig loaded = await store.load();

      expect(loaded.model, TranslationConfig.defaults().model);
      final List<File> backups = temp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('settings.json.bad-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), '[1, 2, 3]');
      expect(await settingsFile.exists(), isFalse);
    },
  );

  test('does not back up settings.json when it parses cleanly', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_valid_settings_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    await settingsFile.writeAsString(
      jsonEncode(
        TranslationConfig.defaults().copyWith(outputSuffix: '_kept').toJson(),
      ),
    );
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: _FakeSettingsSecretStore(),
    );

    final TranslationConfig loaded = await store.load();

    expect(loaded.outputSuffix, '_kept');
    expect(temp.listSync().where((e) => e.path.contains('.bad-')), isEmpty);
    expect(await settingsFile.exists(), isTrue);
  });

  test(
    'save without a prior load does not delete keys when reads fail',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_save_before_load_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
        ..apiKey = 'sk-keep'
        ..deepSeekApiKey = 'sk-keep-deepseek'
        ..customApiKey = 'sk-keep-custom'
        ..failReads = true;
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      // Never loaded, and the caller did not explicitly mutate secrets: the
      // store must read first and then protect the unreadable slots instead
      // of deleting them blindly.
      await store.save(
        TranslationConfig.defaults(),
        explicitSecretMutations: const <SettingsSecretSlot>{},
      );

      expect(secrets.apiKey, 'sk-keep');
      expect(secrets.deepSeekApiKey, 'sk-keep-deepseek');
      expect(secrets.customApiKey, 'sk-keep-custom');
      expect(secrets.secretMutationCount, 0);
    },
  );

  test(
    'save without a prior load still persists keys when reads succeed',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_save_before_load_ok_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File settingsFile = File('${temp.path}/settings.json');
      final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
        ..apiKey = 'sk-old';
      final SettingsStore store = SettingsStore(
        settingsFileProvider: () async => settingsFile,
        secretStore: secrets,
      );

      await store.save(TranslationConfig.defaults().copyWith(apiKey: 'sk-new'));

      expect(secrets.apiKey, 'sk-new');
    },
  );

  test('save writes the three secret slots concurrently', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_concurrent_secrets_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _BarrierSecretStore secrets = _BarrierSecretStore();
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    // If the slot writes ran sequentially, the first write would block on the
    // barrier until the 10s timeout and this save would throw.
    await store.save(
      TranslationConfig.defaults().copyWith(
        apiKey: 'sk-legacy',
        deepseekApiKey: 'sk-deepseek',
        customApiKey: 'sk-custom',
      ),
    );

    expect(secrets.apiKey, 'sk-legacy');
    expect(secrets.deepSeekApiKey, 'sk-deepseek');
    expect(secrets.customApiKey, 'sk-custom');
  });

  test('still writes settings json when a secret delete fails', () async {
    // Regression test: save() must not let a secret-store failure (e.g. the
    // Windows DPAPI file being locked so deleteSecret throws StateError)
    // skip _writeSettingsJson, or non-secret settings like
    // apiProviderSelection silently diverge from memory after restart.
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_json_on_secret_failure_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..failDeletes = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      // Non-secret JSON field...
      apiProviderSelection: ApiProviderSelection.custom,
      // ...and an empty key, which takes the delete() path that throws.
      apiKey: '',
    );

    // The secret failure must still surface so the caller can report it...
    await expectLater(store.save(config), throwsA(isA<StateError>()));
    // ...but the non-secret settings must have been persisted anyway.
    final Map<String, dynamic> persisted =
        jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
    expect(persisted['apiProviderSelection'], ApiProviderSelection.custom.name);
  });

  test(
    'failed deletion keeps the saved snapshot and retries the clear',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'failed_secret_delete_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final secrets = _FakeSettingsSecretStore()
        ..apiKey = 'sk-existing'
        ..deepSeekApiKey = 'sk-existing'
        ..failDeletes = true;
      final store = SettingsStore(
        settingsFileProvider: () async => File('${temp.path}/settings.json'),
        secretStore: secrets,
      );
      final loaded = await store.load();
      final cleared = loaded.copyWith(apiKey: '');
      await expectLater(store.save(cleared), throwsStateError);
      expect(secrets.apiKey, 'sk-existing');
      final mutations = secrets.secretMutationCount;
      await expectLater(store.save(cleared), throwsStateError);
      expect(secrets.secretMutationCount, greaterThan(mutations));
      expect((await store.load()).apiKey, 'sk-existing');
    },
  );

  group('settings.json write-error classification', () {
    FileSystemException lockError(int code) => FileSystemException(
      'Cannot access the file because it is being used by another process',
      '/settings.json',
      OSError('The process cannot access the file', code),
    );

    test(
      'Windows sharing violation (32) becomes SettingsFileLockedException',
      () {
        final Object mapped = SettingsStore.mapSettingsWriteError(
          '/settings.json',
          lockError(32),
        );
        expect(mapped, isA<SettingsFileLockedException>());
        expect(
          (mapped as SettingsFileLockedException).filePath,
          '/settings.json',
        );
      },
    );

    test('Windows lock violation (33) becomes SettingsFileLockedException', () {
      expect(
        SettingsStore.mapSettingsWriteError('/settings.json', lockError(33)),
        isA<SettingsFileLockedException>(),
      );
    });

    test('non-lock failures pass through unchanged', () {
      final FileSystemException denied = FileSystemException(
        'Access is denied',
        '/settings.json',
        const OSError('Access is denied', 5),
      );
      expect(
        SettingsStore.mapSettingsWriteError('/settings.json', denied),
        same(denied),
      );
      final StateError other = StateError('boom');
      expect(
        SettingsStore.mapSettingsWriteError('/settings.json', other),
        same(other),
      );
    });
  });

  test('flags secretKeyRotated when the KeyStore key was rotated', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_rotation_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..rotateKeyOnReads = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    final TranslationConfig loaded = await store.load();

    // The rotated key is reported distinctly from a generic read failure
    // so the UI can tell the user to re-enter their keys.
    expect(store.secretKeyRotated, isTrue);
    expect(loaded.apiKey, isEmpty);
  });

  test('secretKeyRotated stays false on ordinary read failures', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'epub_settings_store_rotation_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final File settingsFile = File('${temp.path}/settings.json');
    final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
      ..failReads = true;
    final SettingsStore store = SettingsStore(
      settingsFileProvider: () async => settingsFile,
      secretStore: secrets,
    );

    await store.load();

    expect(store.secretKeyRotated, isFalse);
  });
}

/// A fake secret store whose writes only proceed once all three slots have
/// started writing: proves the slots are written concurrently rather than
/// serially.
class _BarrierSecretStore extends _FakeSettingsSecretStore {
  int _startedWrites = 0;
  final Completer<void> _allStarted = Completer<void>();

  Future<void> _gateWrite(Future<void> Function() write) async {
    _startedWrites += 1;
    if (_startedWrites >= 3 && !_allStarted.isCompleted) {
      _allStarted.complete();
    }
    await _allStarted.future.timeout(const Duration(seconds: 10));
    await write();
  }

  @override
  Future<void> writeApiKey(String value) =>
      _gateWrite(() => super.writeApiKey(value));

  @override
  Future<void> writeDeepSeekApiKey(String value) =>
      _gateWrite(() => super.writeDeepSeekApiKey(value));

  @override
  Future<void> writeCustomApiKey(String value) =>
      _gateWrite(() => super.writeCustomApiKey(value));
}
