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

  Future<TranslationConfig> load() async {
    final TranslationConfig config = await _loadConfigFromFile();
    final String? storedApiKey = await _readSecretOrNull(
      _secretStore.readApiKey,
    );
    final String? storedDeepSeekKey = await _readSecretOrNull(
      _secretStore.readDeepSeekApiKey,
    );
    final String? storedCustomKey = await _readSecretOrNull(
      _secretStore.readCustomApiKey,
    );
    final String legacyKey = storedApiKey?.isNotEmpty == true
        ? storedApiKey!
        : config.apiKey;
    final String deepSeekKey = storedDeepSeekKey?.isNotEmpty == true
        ? storedDeepSeekKey!
        : config.apiProviderSelection == ApiProviderSelection.deepseek
        ? legacyKey
        : config.deepseekApiKey;
    final String customKey = storedCustomKey?.isNotEmpty == true
        ? storedCustomKey!
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
        await save(resolvedConfig);
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

  Future<String?> _readSecretOrNull(Future<String?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TranslationConfig config) async {
    await _writeOrDeleteSecret(
      config.apiKey,
      write: _secretStore.writeApiKey,
      delete: _secretStore.deleteApiKey,
    );
    await _writeOrDeleteSecret(
      config.deepseekApiKey,
      write: _secretStore.writeDeepSeekApiKey,
      delete: _secretStore.deleteDeepSeekApiKey,
    );
    await _writeOrDeleteSecret(
      config.customApiKey,
      write: _secretStore.writeCustomApiKey,
      delete: _secretStore.deleteCustomApiKey,
    );
    final File file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
  }

  Future<void> _writeOrDeleteSecret(
    String value, {
    required Future<void> Function(String value) write,
    required Future<void> Function() delete,
  }) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? delete() : write(trimmed);
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
