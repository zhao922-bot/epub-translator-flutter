import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/platform/platform_utils.dart';
import '../../translation/domain/models/translation_config.dart';

abstract class SettingsSecretStore {
  Future<String?> readApiKey();

  Future<void> writeApiKey(String value);

  Future<void> deleteApiKey();
}

class NativeSettingsSecretStore implements SettingsSecretStore {
  const NativeSettingsSecretStore();

  static const String _apiKeyName = 'api_key';

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
}

class SettingsStore {
  SettingsStore({this.settingsFileProvider, SettingsSecretStore? secretStore})
    : _secretStore = secretStore ?? const NativeSettingsSecretStore();

  final Future<File> Function()? settingsFileProvider;
  final SettingsSecretStore _secretStore;

  Future<TranslationConfig> load() async {
    final TranslationConfig config = await _loadConfigFromFile();
    final String? storedApiKey = await _readApiKeyOrNull();
    final String resolvedApiKey = storedApiKey?.isNotEmpty == true
        ? storedApiKey!
        : config.apiKey;
    final TranslationConfig resolvedConfig = config.copyWith(
      apiKey: resolvedApiKey,
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

  Future<String?> _readApiKeyOrNull() async {
    try {
      return await _secretStore.readApiKey();
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TranslationConfig config) async {
    if (config.apiKey.trim().isEmpty) {
      await _secretStore.deleteApiKey();
    } else {
      await _secretStore.writeApiKey(config.apiKey);
    }
    final File file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
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
