import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../shared/platform/platform_utils.dart';

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

  Future<String?> readProxyAuthentication();
  Future<void> writeProxyAuthentication(String value);
  Future<void> deleteProxyAuthentication();
}

/// Immutable credential objects. Only a committed JSON reference activates one.
/// Legacy backends remain available for compatibility and existing embedders.
abstract interface class VersionedSettingsSecretStore {
  Future<String?> readCredential(String name);
  Future<void> writeCredential(String name, String value);
  Future<void> deleteCredential(String name);
}

enum SettingsSecretSlot { legacy, deepSeek, custom, proxy }

class NativeSettingsSecretStore
    implements SettingsSecretStore, VersionedSettingsSecretStore {
  const NativeSettingsSecretStore();

  static const String _apiKeyName = 'api_key';
  static const String _deepSeekApiKeyName = 'deepseek_api_key';
  static const String _customApiKeyName = 'custom_api_key';
  static const _secureStorage = FlutterSecureStorage();
  @override
  // Versioned keys need independent native records. A shared encrypted map
  // could still lose a newer key when another process finishes an old write.
  Future<String?> readCredential(String name) => PlatformUtils.readSecret(name);
  @override
  Future<void> writeCredential(String name, String value) =>
      PlatformUtils.writeSecret(name, value);
  @override
  Future<void> deleteCredential(String name) =>
      PlatformUtils.deleteSecret(name);

  static const _proxyAuthenticationName = 'http_proxy_authentication';

  @override
  Future<String?> readProxyAuthentication() =>
      _secureStorage.read(key: _proxyAuthenticationName);

  @override
  Future<void> writeProxyAuthentication(String value) =>
      _secureStorage.write(key: _proxyAuthenticationName, value: value);

  @override
  Future<void> deleteProxyAuthentication() =>
      _secureStorage.delete(key: _proxyAuthenticationName);

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
