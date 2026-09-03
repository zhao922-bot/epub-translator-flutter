import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../../translation/domain/models/translation_config.dart';

abstract class SettingsSecretStore {
  Future<String?> readApiKey();

  Future<void> writeApiKey(String value);

  Future<void> deleteApiKey();

  Future<String?> readDeepSeekApiKey();

  Future<void> writeDeepSeekApiKey(String value);

  Future<void> deleteDeepSeekApiKey();

  Future<String?> readCustomApiKey();

  Future<void> writeCustomApiKey(String value);

  Future<void> deleteCustomApiKey();
}

enum SettingsSecretSlot { legacy, deepSeek, custom }

enum _SecretReadStatus { value, missing, readFailure }

class _SecretReadResult {
  const _SecretReadResult(this.status, this.value);

  final _SecretReadStatus status;
  final String? value;
}

class NativeSettingsSecretStore implements SettingsSecretStore {
  const NativeSettingsSecretStore();

  static const String _apiKeyName = 'api_key';
  static const String _deepSeekApiKeyName = 'deepseek_api_key';
  static const String _customApiKeyName = 'custom_api_key';

  @override
  Future<void> deleteApiKey() {
    return PlatformUtils.deleteSecret(_apiKeyName);
  }

  @override
  Future<String?> readApiKey() {
    return PlatformUtils.readSecret(_apiKeyName);
  }

  @override
  Future<void> writeApiKey(String value) {
    return PlatformUtils.writeSecret(_apiKeyName, value);
  }

  @override
  Future<void> deleteDeepSeekApiKey() {
    return PlatformUtils.deleteSecret(_deepSeekApiKeyName);
  }

  @override
  Future<String?> readDeepSeekApiKey() {
    return PlatformUtils.readSecret(_deepSeekApiKeyName);
  }

  @override
  Future<void> writeDeepSeekApiKey(String value) {
    return PlatformUtils.writeSecret(_deepSeekApiKeyName, value);
  }

  @override
  Future<void> deleteCustomApiKey() {
    return PlatformUtils.deleteSecret(_customApiKeyName);
  }

  @override
  Future<String?> readCustomApiKey() {
    return PlatformUtils.readSecret(_customApiKeyName);
  }

  @override
  Future<void> writeCustomApiKey(String value) {
    return PlatformUtils.writeSecret(_customApiKeyName, value);
  }
}

class SettingsStore {
  SettingsStore({this.settingsFileProvider, SettingsSecretStore? secretStore})
    : _secretStore = secretStore ?? const NativeSettingsSecretStore();

  final Future<File> Function()? settingsFileProvider;
  final SettingsSecretStore _secretStore;
  final Map<SettingsSecretSlot, _SecretReadStatus> _secretReadStatuses =
      <SettingsSecretSlot, _SecretReadStatus>{};

  Future<TranslationConfig> load() async {
    final TranslationConfig config = await _loadConfigFromFile();
    final _SecretReadResult storedApiKey = await _readSecret(
      SettingsSecretSlot.legacy,
      _secretStore.readApiKey,
    );
    final _SecretReadResult storedDeepSeekKey = await _readSecret(
      SettingsSecretSlot.deepSeek,
      _secretStore.readDeepSeekApiKey,
    );
    final _SecretReadResult storedCustomKey = await _readSecret(
      SettingsSecretSlot.custom,
      _secretStore.readCustomApiKey,
    );
    final String legacyKey = storedApiKey.value?.isNotEmpty == true
        ? storedApiKey.value!
        : config.apiKey;
    final String deepSeekKey = storedDeepSeekKey.value?.isNotEmpty == true
        ? storedDeepSeekKey.value!
        : config.apiProviderSelection == ApiProviderSelection.deepseek
        ? legacyKey
        : config.deepseekApiKey;
    final String customKey = storedCustomKey.value?.isNotEmpty == true
        ? storedCustomKey.value!
        : config.apiProviderSelection == ApiProviderSelection.custom
        ? legacyKey
        : config.customApiKey;
    final String resolvedApiKey =
        config.apiProviderSelection == ApiProviderSelection.deepseek
        ? deepSeekKey
        : customKey;
    final TranslationConfig resolvedConfig = config.copyWith(
      apiKey: resolvedApiKey,
      deepseekApiKey: deepSeekKey,
      customApiKey: customKey,
    );
    if (config.apiKey.isNotEmpty) {
      try {
        await save(
          resolvedConfig,
          explicitSecretMutations: <SettingsSecretSlot>{
            SettingsSecretSlot.legacy,
            config.apiProviderSelection == ApiProviderSelection.deepseek
                ? SettingsSecretSlot.deepSeek
                : SettingsSecretSlot.custom,
          },
        );
      } catch (_) {
        // Loading settings should still succeed if legacy key migration fails.
      }
    }
    return resolvedConfig;
  }

  Future<TranslationConfig> _loadConfigFromFile() async {
    try {
      final File file = await _settingsFile();
      if (!await file.exists()) {
        return TranslationConfig.defaults();
      }
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return TranslationConfig.defaults();
      }
      return TranslationConfig.fromJson(decoded);
    } catch (_) {
      return TranslationConfig.defaults();
    }
  }

  Future<_SecretReadResult> _readSecret(
    SettingsSecretSlot slot,
    Future<String?> Function() read,
  ) async {
    try {
      final String? value = await read();
      final _SecretReadStatus status = value?.trim().isNotEmpty == true
          ? _SecretReadStatus.value
          : _SecretReadStatus.missing;
      _secretReadStatuses[slot] = status;
      return _SecretReadResult(status, value);
    } catch (_) {
      _secretReadStatuses[slot] = _SecretReadStatus.readFailure;
      return const _SecretReadResult(_SecretReadStatus.readFailure, null);
    }
  }

  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    final Set<SettingsSecretSlot> explicit =
        explicitSecretMutations ?? SettingsSecretSlot.values.toSet();
    await _saveSecret(
      SettingsSecretSlot.legacy,
      config.apiKey,
      explicit: explicit,
      write: _secretStore.writeApiKey,
      delete: _secretStore.deleteApiKey,
    );
    await _saveSecret(
      SettingsSecretSlot.deepSeek,
      config.deepseekApiKey,
      explicit: explicit,
      write: _secretStore.writeDeepSeekApiKey,
      delete: _secretStore.deleteDeepSeekApiKey,
    );
    await _saveSecret(
      SettingsSecretSlot.custom,
      config.customApiKey,
      explicit: explicit,
      write: _secretStore.writeCustomApiKey,
      delete: _secretStore.deleteCustomApiKey,
    );
    await _writeSettingsJson(config);
  }

  Future<void> _writeSettingsJson(TranslationConfig config) async {
    final File file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
  }

  Future<void> _saveSecret(
    SettingsSecretSlot slot,
    String value, {
    required Set<SettingsSecretSlot> explicit,
    required Future<void> Function(String value) write,
    required Future<void> Function() delete,
  }) async {
    if (_secretReadStatuses[slot] == _SecretReadStatus.readFailure &&
        !explicit.contains(slot)) {
      return;
    }
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      await delete();
      _secretReadStatuses[slot] = _SecretReadStatus.missing;
    } else {
      await write(trimmed);
      _secretReadStatuses[slot] = _SecretReadStatus.value;
    }
  }

  Future<File> _settingsFile() async {
    final Future<File> Function()? provider = settingsFileProvider;
    if (provider != null) {
      return provider();
    }
    final Directory appDirectory = Directory(
      await PlatformUtils.appDocumentsDirectory(),
    );
    return File(path.join(appDirectory.path, 'settings.json'));
  }
}
