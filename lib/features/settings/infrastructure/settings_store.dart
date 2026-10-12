import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;

import '../../../shared/logging/app_logger.dart';
import '../../../shared/platform/native_platform_bridge.dart';
import '../../../shared/platform/platform_utils.dart';
import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/io/strip_bom.dart';
import '../../../shared/io/settings_file_lock.dart';
import '../../translation/domain/models/translation_config.dart';
import '../../translation/infrastructure/epub_isolate_worker.dart';

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

enum SettingsSecretSlot { legacy, deepSeek, custom, proxy }

/// Original errors remain available for classification, never for display.
class SettingsSecretSaveException extends StateError {
  SettingsSecretSaveException(Map<SettingsSecretSlot, Object> failures)
    : failures = Map.unmodifiable(failures),
      super(
        failures.entries
            .map(
              (entry) =>
                  'Failed to save ${SettingsStore._slotLabel(entry.key)}: ${entry.value.runtimeType}',
            )
            .join('; '),
      );

  final Map<SettingsSecretSlot, Object> failures;
  bool get isUnsupported =>
      failures.values.any((error) => error is UnsupportedError);
}

class SettingsWriteConflict implements Exception {
  @override
  String toString() =>
      'Settings changed in another instance; reload before saving.';
}

/// settings.json could not be written because another program holds a
/// Windows file lock (sharing violation) on it — e.g. a second app instance,
/// antivirus, or a file indexer. Carries the file path so the UI can show an
/// actionable localized message instead of a raw English OS error.
class SettingsFileLockedException implements Exception {
  SettingsFileLockedException(this.filePath);

  final String filePath;

  @override
  String toString() => 'SettingsFileLockedException: $filePath';
}

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
  static const _secureStorage = FlutterSecureStorage();
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

class SettingsStore {
  SettingsStore({
    this.settingsFileProvider,
    SettingsSecretStore? secretStore,
    @visibleForTesting this.settingsJsonWriter,
  }) : _secretStore = secretStore ?? const NativeSettingsSecretStore();

  final Future<File> Function()? settingsFileProvider;
  final Future<void> Function(File, String)? settingsJsonWriter;
  final SettingsSecretStore _secretStore;
  final Map<SettingsSecretSlot, _SecretReadStatus> _secretReadStatuses =
      <SettingsSecretSlot, _SecretReadStatus>{};

  // Compare against this instance's last loaded/saved values. An unchanged
  // local snapshot must not overwrite keys another app instance updated.
  Map<SettingsSecretSlot, String>? _secretSnapshot;
  String? _settingsSnapshot;
  TranslationConfig? _loadedConfig;
  bool _allowLegacyMigration = true;
  int _settingsRevision = 0;
  final Map<SettingsSecretSlot, String> _pendingPlaintextKeys = {};

  /// Set when an Android KeyStore read reported SECRET_KEY_ROTATED (the
  /// device key was invalidated and regenerated): previously stored keys
  /// are unrecoverable and the user must re-enter them. Surfaced to the
  /// settings page via [SettingsController].
  bool _secretKeyRotated = false;
  final Set<SettingsSecretSlot> _rotatedSlots = {};

  /// Whether the Android KeyStore key was rotated (invalidated and
  /// regenerated) during the last secret load. The settings page shows a
  /// warning banner when true.
  bool get secretKeyRotated => _secretKeyRotated;

  bool secretReadFailed(SettingsSecretSlot slot) =>
      _secretReadStatuses[slot] == _SecretReadStatus.readFailure;

  /// Whether the secret read statuses are populated (via [load] or a
  /// read-first [save]). Guards [_saveSecret] against deleting keys whose
  /// state was never observed.
  bool _didLoad = false;

  /// Whether the legacy plaintext key migration already failed
  /// deterministically: a secret backend that is explicitly unsupported must
  /// not respawn helper processes on every load.
  bool _legacyMigrationFailed = false;

  /// Transient migration failures (D-Bus not ready, keyring locked, timeout)
  /// are retried on a later load instead of being marked permanently failed;
  /// the counter caps attempts per store instance so a persistently flaky
  /// backend cannot spin forever.
  int _legacyMigrationAttempts = 0;
  static const int _maxLegacyMigrationAttempts = 3;

  /// Lazily GCs stale atomic-write temp files once per store instance.
  bool _cleanedTempFiles = false;

  /// Whether the last [load] fell back to defaults because settings.json was
  /// unreadable or corrupt (as opposed to a first run with no settings file).
  bool didCorruptReset = false;

  /// Backup path of the corrupt settings file when [didCorruptReset] is true,
  /// or null when the backup itself failed. The UI surfaces this so the user
  /// knows their settings were reset and where the original file went.
  String? lastCorruptBackupPath;

  Object? _configLoadError;
  Object? get configLoadError => _configLoadError;
  Map<String, String> _credentialBindings = {};

  Future<TranslationConfig> load() async {
    try {
      final file = await _settingsFile();
      // Include lock acquisition and file discovery in the load error boundary.
      return await withSettingsFileLock(file, _loadLocked);
    } catch (error) {
      _configLoadError = error;
      rethrow;
    }
  }

  Future<TranslationConfig> _loadLocked() async {
    final TranslationConfig config;
    try {
      config = await _loadConfigFromFile();
      _configLoadError = null;
    } catch (error) {
      _configLoadError = error;
      rethrow;
    }
    final List<_SecretReadResult> storedKeys = await _readAllSecrets();
    for (final slot in [
      SettingsSecretSlot.deepSeek,
      SettingsSecretSlot.custom,
    ]) {
      final index = slot == SettingsSecretSlot.deepSeek ? 1 : 2;
      final binding = _credentialBindings[slot.name];
      if (binding != null &&
          storedKeys[index].status != _SecretReadStatus.readFailure &&
          binding != _keyFingerprint(storedKeys[index].value ?? '')) {
        // A process may have exited between secure storage and JSON writes.
        // Never attach that uncommitted key to the previous endpoint.
        _secretReadStatuses[slot] = _SecretReadStatus.readFailure;
        storedKeys[index] = const _SecretReadResult(
          _SecretReadStatus.readFailure,
          null,
        );
      }
    }
    final _SecretReadResult storedApiKey = storedKeys[0];
    final _SecretReadResult storedDeepSeekKey = storedKeys[1];
    final _SecretReadResult storedCustomKey = storedKeys[2];
    final String legacyKey = !_allowLegacyMigration
        ? ''
        : storedApiKey.value?.isNotEmpty == true
        ? storedApiKey.value!
        : config.apiKey;
    final String deepSeekKey = storedDeepSeekKey.value?.isNotEmpty == true
        ? storedDeepSeekKey.value!
        : config.apiProviderSelection == ApiProviderSelection.deepseek &&
              legacyKey.isNotEmpty
        ? legacyKey
        : config.deepseekApiKey;
    final String customKey = storedCustomKey.value?.isNotEmpty == true
        ? storedCustomKey.value!
        : config.apiProviderSelection == ApiProviderSelection.custom &&
              legacyKey.isNotEmpty
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
      httpProxy: _resolveProxy(config, storedKeys[3].value),
    );
    _secretSnapshot = _secretValues(resolvedConfig);
    final providerSlot =
        config.apiProviderSelection == ApiProviderSelection.deepseek
        ? SettingsSecretSlot.deepSeek
        : SettingsSecretSlot.custom;
    // Keep the original provider association even if the user switches providers
    // while the secure backend is unavailable.
    _pendingPlaintextKeys.clear();
    if (config.httpProxyAuthentication.isNotEmpty) {
      _pendingPlaintextKeys[SettingsSecretSlot.proxy] = _proxySecret(config);
    }
    if (config.deepseekApiKey.isNotEmpty) {
      _pendingPlaintextKeys[SettingsSecretSlot.deepSeek] =
          config.deepseekApiKey;
    }
    if (config.customApiKey.isNotEmpty) {
      _pendingPlaintextKeys[SettingsSecretSlot.custom] = config.customApiKey;
    }
    if (config.apiKey.isNotEmpty) {
      _pendingPlaintextKeys[providerSlot] = config.apiKey;
    }
    final bool needsSecureAllocation =
        _allowLegacyMigration &&
        storedApiKey.value?.isNotEmpty == true &&
        (providerSlot == SettingsSecretSlot.deepSeek
                    ? storedDeepSeekKey
                    : storedCustomKey)
                .status ==
            _SecretReadStatus.missing;
    if ((_pendingPlaintextKeys.isNotEmpty || needsSecureAllocation) &&
        !_legacyMigrationFailed &&
        _legacyMigrationAttempts < _maxLegacyMigrationAttempts) {
      _legacyMigrationAttempts += 1;
      try {
        final Set<SettingsSecretSlot> migrationSlots = <SettingsSecretSlot>{
          if (config.apiKey.isNotEmpty) SettingsSecretSlot.legacy,
          ..._pendingPlaintextKeys.keys,
          if (needsSecureAllocation) providerSlot,
        };
        final file = await _settingsFile();
        final current = await file.exists() ? await file.readAsString() : null;
        if (current != _settingsSnapshot) throw SettingsWriteConflict();
        resolvedConfig.toJson();
        await _saveSecrets(
          resolvedConfig,
          slotsToSave: migrationSlots,
          explicit: migrationSlots,
        );
        await _writeSettingsJson(resolvedConfig);
      } on UnsupportedError catch (error) {
        // Deterministic: the platform has no usable secret backend at all
        // (UnimplementedError is a subtype of UnsupportedError, so it lands
        // here too). Retrying would respawn helper processes on every load
        // for nothing.
        _legacyMigrationFailed = true;
        AppLogger.error(
          'Legacy credential migration is not supported on this backend; will not retry.',
          tag: 'settings',
          error: error,
        );
      } catch (error) {
        if (error is SettingsSecretSaveException && error.isUnsupported) {
          _legacyMigrationFailed = true;
          AppLogger.error(
            'Legacy credential migration is not supported on this backend; will not retry.',
            tag: 'settings',
            error: error,
          );
          _loadedConfig = resolvedConfig;
          return resolvedConfig;
        }
        // Transient (D-Bus not ready, keyring locked, timeout): loading
        // settings must still succeed, and the migration is retried on a
        // later load (up to _maxLegacyMigrationAttempts attempts) instead
        // of being abandoned forever.
        AppLogger.error(
          'Legacy credential migration failed (attempt '
          '$_legacyMigrationAttempts/$_maxLegacyMigrationAttempts); '
          'will retry on a later load.',
          tag: 'settings',
          error: error,
        );
      }
    }
    _loadedConfig = resolvedConfig;
    return resolvedConfig;
  }

  /// Reads all secret slots concurrently, recording per-slot read statuses so
  /// later [save] calls can tell "missing" from "unreadable". Marks the store
  /// as loaded.
  Future<List<_SecretReadResult>> _readAllSecrets() async {
    // Read the secret slots concurrently: on Windows each read spawns a
    // PowerShell process, so sequential reads would add seconds to startup.
    // _readSecret already swallows per-slot failures, so Future.wait is safe.
    final List<_SecretReadResult> storedKeys =
        await Future.wait(<Future<_SecretReadResult>>[
          _readSecret(SettingsSecretSlot.legacy, _secretStore.readApiKey),
          _readSecret(
            SettingsSecretSlot.deepSeek,
            _secretStore.readDeepSeekApiKey,
          ),
          _readSecret(SettingsSecretSlot.custom, _secretStore.readCustomApiKey),
          _readSecret(
            SettingsSecretSlot.proxy,
            _secretStore.readProxyAuthentication,
          ),
        ]);
    _didLoad = true;
    return storedKeys;
  }

  Future<TranslationConfig> _loadConfigFromFile() async {
    didCorruptReset = false;
    lastCorruptBackupPath = null;
    final File file = await _settingsFile();
    if (!await file.exists()) {
      _credentialBindings = {};
      _settingsSnapshot = null;
      _settingsRevision = 0;
      didCorruptReset = false;
      lastCorruptBackupPath = null;
      return TranslationConfig.defaults();
    }
    try {
      final TranslationConfig config = await _readConfigFile(file);
      didCorruptReset = false;
      lastCorruptBackupPath = null;
      return config;
    } catch (error) {
      // A transient Windows lock (antivirus/OneDrive sharing violation)
      // fails the first read; retry once before declaring the file corrupt,
      // otherwise a momentary lock would rename a healthy settings.json
      // aside and reset a dozen user settings.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final TranslationConfig config = await _readConfigFile(file);
        didCorruptReset = false;
        lastCorruptBackupPath = null;
        return config;
      } catch (retryError) {
        // An unreadable file is not corrupt. Keep it in place and refuse
        // saves until a later load succeeds, rather than persisting defaults.
        if (retryError is! FormatException && retryError is! TypeError) {
          rethrow;
        }
        // Back the corrupt file up before it gets overwritten by the next
        // save: a silent reset would lose every setting with no way to
        // recover. The backup path is exposed via [lastCorruptBackupPath]
        // so the UI can tell the user where their settings went.
        lastCorruptBackupPath = await _backupCorruptSettingsFile(file);
        if (await file.exists()) rethrow;
        _settingsSnapshot = null;
        _settingsRevision = 0;
        didCorruptReset = true;
        AppLogger.error(
          'Failed to parse settings.json; using defaults.',
          tag: 'settings',
          error: retryError,
        );
        return TranslationConfig.defaults();
      }
    }
  }

  Future<TranslationConfig> _readConfigFile(File file) async {
    final String raw = await file.readAsString();
    // Windows Notepad writes UTF-8 with BOM; without stripping, a
    // hand-edited settings.json is misclassified as corrupt and the user's
    // settings get reset to defaults.
    final Object? decoded = jsonDecode(stripLeadingBom(raw));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('settings.json is not a JSON object');
    }
    _settingsSnapshot = raw;
    final bindings = decoded['credentialBindings'];
    _credentialBindings = bindings is Map
        ? {
            for (final entry in bindings.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          }
        : {};
    _allowLegacyMigration = decoded['credentialSchemaVersion'] != 2;
    _settingsRevision = decoded['settingsRevision'] is int
        ? decoded['settingsRevision'] as int
        : 0;
    return TranslationConfig.fromJson(decoded);
  }

  /// Renames a corrupt settings file aside (best effort) so a later save
  /// cannot silently destroy the user's settings with no recovery path.
  /// Returns the backup path, or null when the backup itself failed.
  Future<String?> _backupCorruptSettingsFile(File file) async {
    try {
      // Build with path.join (not string interpolation on file.path): the
      // File may have been constructed with '/' separators while the
      // platform listing (and callers comparing paths) use '\' on Windows.
      final String backupPath = path.join(
        file.parent.path,
        '${path.basename(file.path)}.bad-${DateTime.now().microsecondsSinceEpoch}',
      );
      await file.rename(backupPath);
      try {
        await _pruneCorruptBackups(
          file.parent,
          '${path.basename(file.path)}.bad-',
        );
      } catch (_) {
        // Retention failure must not hide a successfully preserved backup.
      }
      AppLogger.warn(
        'Backed up corrupt settings file to $backupPath',
        tag: 'settings',
      );
      return backupPath;
    } catch (_) {
      // Best effort: the backup must never break startup.
      return null;
    }
  }

  /// Maximum number of corrupt-settings backups to keep: every corrupt load
  /// creates one, and without a cap a chronically broken file would pile up
  /// `settings.json.bad-*` files forever.
  static const int _maxCorruptBackups = 5;

  /// Deletes the oldest corrupt-settings backups beyond [_maxCorruptBackups].
  /// The timestamp suffix sorts chronologically, so the oldest names come
  /// first.
  Future<void> _pruneCorruptBackups(Directory dir, String prefix) async {
    final List<FileSystemEntity> entries = await dir.list().toList();
    final List<File> backups =
        entries
            .whereType<File>()
            .where((File f) => path.basename(f.path).startsWith(prefix))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    for (int i = 0; i + _maxCorruptBackups < backups.length; i++) {
      await backups[i].delete();
    }
  }

  Future<_SecretReadResult> _readSecret(
    SettingsSecretSlot slot,
    Future<String?> Function() read,
  ) async {
    try {
      final String? value = await read();
      // Normalize once: callers check `value?.isNotEmpty`, so a
      // whitespace-only stored secret must not count as a valid key.
      final String? trimmed = value?.trim();
      final _SecretReadStatus status = trimmed?.isNotEmpty == true
          ? _SecretReadStatus.value
          : _SecretReadStatus.missing;
      _secretReadStatuses[slot] = status;
      return _SecretReadResult(status, trimmed);
    } on SecretKeyRotatedException {
      // The Android KeyStore key was invalidated (lock-screen/biometric
      // change) and regenerated: the stored ciphertext is unrecoverable.
      // Record it distinctly from a generic read failure so the UI can
      // tell the user to re-enter their keys.
      _secretKeyRotated = true;
      _rotatedSlots.add(slot);
      _secretReadStatuses[slot] = _SecretReadStatus.readFailure;
      return const _SecretReadResult(_SecretReadStatus.readFailure, null);
    } catch (_) {
      _secretReadStatuses[slot] = _SecretReadStatus.readFailure;
      return const _SecretReadResult(_SecretReadStatus.readFailure, null);
    }
  }

  Future<void> save(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    if (_configLoadError != null) {
      throw StateError('Settings could not be loaded; reload before saving.');
    }
    // Validate before touching any secret slot, not just before JSON encoding.
    config.toJson();
    final file = await _settingsFile();
    await withSettingsFileLock(file, () async {
      final current = await file.exists() ? await file.readAsString() : null;
      if (_didLoad && current != _settingsSnapshot) {
        throw SettingsWriteConflict();
      }
      await _saveLocked(
        config,
        explicitSecretMutations: explicitSecretMutations,
      );
    });
  }

  Future<void> _saveLocked(
    TranslationConfig config, {
    Set<SettingsSecretSlot>? explicitSecretMutations,
  }) async {
    if (_configLoadError != null) {
      throw StateError('Settings could not be loaded; reload before saving.');
    }
    final Set<SettingsSecretSlot> explicit =
        explicitSecretMutations ??
        (_secretSnapshot == null
            ? SettingsSecretSlot.values.toSet()
            : const <SettingsSecretSlot>{});
    if (!_didLoad) {
      // A store that never loaded has no secret read statuses: _saveSecret
      // could not tell "key was cleared" from "backend is broken" and might
      // delete keys it never saw. Read once so unreadable slots stay
      // protected instead of being deleted blindly.
      await _readAllSecrets();
    }
    final values = _secretValues(config);
    final baseline = _secretSnapshot ??= Map.of(values);
    final slotsToSave = <SettingsSecretSlot>{
      ...explicit,
      for (final slot in SettingsSecretSlot.values)
        if (values[slot] != baseline[slot]) slot,
    };
    final previous = _loadedConfig;
    if (previous != null &&
        secretReadFailed(SettingsSecretSlot.custom) &&
        !explicit.contains(SettingsSecretSlot.custom) &&
        (config.customApiBaseUrl != previous.customApiBaseUrl ||
            (config.apiProviderSelection == ApiProviderSelection.custom &&
                config.apiBaseUrl !=
                    (previous.apiProviderSelection ==
                            ApiProviderSelection.custom
                        ? previous.apiBaseUrl
                        : previous.customApiBaseUrl)))) {
      throw StateError(
        'Custom API key could not be read; confirm the key before changing its endpoint.',
      );
    }
    final oldSnapshot = Map<SettingsSecretSlot, String>.of(baseline);
    final oldStatuses = Map<SettingsSecretSlot, _SecretReadStatus>.of(
      _secretReadStatuses,
    );
    final oldPending = Map<SettingsSecretSlot, String>.of(
      _pendingPlaintextKeys,
    );
    // Persist the old key binding BEFORE touching secure storage. If the
    // process dies in the following window, load rejects the new key rather
    // than sending it to the old endpoint. No plaintext secret is journaled.
    if (previous != null &&
        slotsToSave.any(
          (slot) =>
              slot == SettingsSecretSlot.custom ||
              slot == SettingsSecretSlot.deepSeek,
        )) {
      for (final slot in [
        SettingsSecretSlot.custom,
        SettingsSecretSlot.deepSeek,
      ]) {
        if (slotsToSave.contains(slot) && secretReadFailed(slot)) {
          // With no readable old key, an absent binding must not admit a new
          // credential after a crash. Retain an existing binding or reserve
          // the empty/fallback snapshot, which rejects any new nonempty key.
          _credentialBindings.putIfAbsent(
            slot.name,
            () => _keyFingerprint(oldSnapshot[slot] ?? ''),
          );
        }
      }
      await _writeSettingsJson(previous);
    }
    // The JSON write sits in a finally block on purpose: a secret-store
    // failure (e.g. the Windows DPAPI file being locked so deleteSecret
    // throws StateError) must not silently discard the non-secret settings
    // the user just changed. The secret error still propagates so the
    // caller reports the failed key save and the user can retry.
    bool secretsSaved = false;
    try {
      await _saveSecrets(config, slotsToSave: slotsToSave, explicit: explicit);
      secretsSaved = true;
    } finally {
      // Endpoint and credentials form one unit. A partial secret failure
      // must not publish a changed endpoint with credentials from an old run.
      final customFailed =
          values[SettingsSecretSlot.custom] !=
          _secretSnapshot?[SettingsSecretSlot.custom];
      final deepSeekFailed =
          values[SettingsSecretSlot.deepSeek] !=
          _secretSnapshot?[SettingsSecretSlot.deepSeek];
      final proxyFailed =
          values[SettingsSecretSlot.proxy] !=
          _secretSnapshot?[SettingsSecretSlot.proxy];
      final providerFailed =
          config.apiProviderSelection == ApiProviderSelection.custom
          ? customFailed
          : deepSeekFailed;
      final safeConfig = !secretsSaved && previous != null
          ? config.copyWith(
              apiBaseUrl: providerFailed
                  ? previous.apiBaseUrl
                  : config.apiBaseUrl,
              apiProviderSelection: providerFailed
                  ? previous.apiProviderSelection
                  : config.apiProviderSelection,
              customApiBaseUrl: customFailed
                  ? previous.customApiBaseUrl
                  : config.customApiBaseUrl,
              httpProxy: proxyFailed ? previous.httpProxy : config.httpProxy,
            )
          : config;
      try {
        await _writeSettingsJson(safeConfig);
      } catch (writeError) {
        // A failed transaction must be reloaded before another UI edit can
        // publish an in-memory key snapshot that never committed to JSON.
        _configLoadError = writeError;
        if (previous != null) {
          final restorable = slotsToSave
              .where(
                (slot) => oldStatuses[slot] != _SecretReadStatus.readFailure,
              )
              .toSet();
          try {
            await _saveSecrets(
              previous.copyWith(
                apiKey: oldSnapshot[SettingsSecretSlot.legacy],
                deepseekApiKey: oldSnapshot[SettingsSecretSlot.deepSeek],
                customApiKey: oldSnapshot[SettingsSecretSlot.custom],
              ),
              slotsToSave: restorable,
              explicit: restorable,
            );
            _secretSnapshot = oldSnapshot;
            _secretReadStatuses.addAll(oldStatuses);
            _pendingPlaintextKeys.addAll(oldPending);
          } catch (error) {
            // The durable old binding still prevents a credential leak when
            // the backend also refuses rollback. Never log secret values.
            AppLogger.error(
              'Credential rollback failed: ${error.runtimeType}',
              tag: 'settings',
            );
          }
        }
        rethrow;
      }
      _loadedConfig = safeConfig;
    }
  }

  static Map<SettingsSecretSlot, String> _secretValues(
    TranslationConfig config,
  ) => <SettingsSecretSlot, String>{
    SettingsSecretSlot.legacy: config.apiKey.trim(),
    SettingsSecretSlot.deepSeek: config.deepseekApiKey.trim(),
    SettingsSecretSlot.custom: config.customApiKey.trim(),
    SettingsSecretSlot.proxy: _proxySecret(config),
  };

  // Bind authentication to its endpoint: a stale instance changing the proxy
  // address must never send credentials belonging to a different proxy.
  static String _proxySecret(TranslationConfig config) =>
      config.httpProxyAuthentication.isEmpty
      ? ''
      : jsonEncode({
          'address': config.httpProxyAddress,
          'authentication': config.httpProxyAuthentication,
        });

  static String _resolveProxy(TranslationConfig config, String? secret) {
    if (secret != null && secret.isNotEmpty) {
      try {
        final decoded = jsonDecode(secret);
        if (decoded is Map &&
            decoded['address'] == config.httpProxyAddress &&
            decoded['authentication'] is String) {
          return TranslationConfig.authenticatedProxy(
            config.httpProxyAddress,
            decoded['authentication'] as String,
          );
        }
      } catch (_) {
        // Invalid secure data does not replace a usable legacy URL.
      }
    }
    return config.httpProxy;
  }

  Future<void> _saveSecrets(
    TranslationConfig config, {
    required Set<SettingsSecretSlot> slotsToSave,
    required Set<SettingsSecretSlot> explicit,
  }) async {
    // The slots are independent (separate files / keychain items); on Windows
    // each write spawns a PowerShell process, so run them concurrently rather
    // than serially. _saveSecret touches only its own slot's read status.
    final List<Future<void>> pending = <Future<void>>[];
    final failures = <SettingsSecretSlot, Object>{};
    if (slotsToSave.contains(SettingsSecretSlot.proxy)) {
      pending.add(
        _saveSecretTagged(
          SettingsSecretSlot.proxy,
          failures,
          _saveSecret(
            SettingsSecretSlot.proxy,
            _proxySecret(config),
            explicit: explicit,
            write: _secretStore.writeProxyAuthentication,
            delete: _secretStore.deleteProxyAuthentication,
          ),
        ),
      );
    }
    if (slotsToSave.contains(SettingsSecretSlot.legacy)) {
      pending.add(
        _saveSecretTagged(
          SettingsSecretSlot.legacy,
          failures,
          _saveSecret(
            SettingsSecretSlot.legacy,
            config.apiKey,
            explicit: explicit,
            write: _secretStore.writeApiKey,
            delete: _secretStore.deleteApiKey,
          ),
        ),
      );
    }
    if (slotsToSave.contains(SettingsSecretSlot.deepSeek)) {
      pending.add(
        _saveSecretTagged(
          SettingsSecretSlot.deepSeek,
          failures,
          _saveSecret(
            SettingsSecretSlot.deepSeek,
            config.deepseekApiKey,
            explicit: explicit,
            write: _secretStore.writeDeepSeekApiKey,
            delete: _secretStore.deleteDeepSeekApiKey,
          ),
        ),
      );
    }
    if (slotsToSave.contains(SettingsSecretSlot.custom)) {
      pending.add(
        _saveSecretTagged(
          SettingsSecretSlot.custom,
          failures,
          _saveSecret(
            SettingsSecretSlot.custom,
            config.customApiKey,
            explicit: explicit,
            write: _secretStore.writeCustomApiKey,
            delete: _secretStore.deleteCustomApiKey,
          ),
        ),
      );
    }
    // eagerError: false lets every slot finish before the aggregate error is
    // thrown: the slots are independent and a partial write is possible, so
    // the caller sees every failure (each names its own slot) instead of
    // just the first one.
    await Future.wait(pending, eagerError: false);
    if (failures.isNotEmpty) throw SettingsSecretSaveException(failures);
    if (slotsToSave.isNotEmpty && _rotatedSlots.isEmpty) {
      _secretKeyRotated = false;
    }
  }

  /// Tags a secret-slot save with a human-readable slot name so a failed
  /// save says which key was not persisted. Partial writes are possible
  /// (other slots may already have been saved when one slot throws), so
  /// naming the exact slot matters for the "save failed" message.
  Future<void> _saveSecretTagged(
    SettingsSecretSlot slot,
    Map<SettingsSecretSlot, Object> failures,
    Future<void> save,
  ) async {
    try {
      await save;
    } catch (error) {
      // Secret backend exceptions may contain the value passed to write.
      failures[slot] = error;
    }
  }

  static String _slotLabel(SettingsSecretSlot slot) {
    switch (slot) {
      case SettingsSecretSlot.legacy:
        return 'API key';
      case SettingsSecretSlot.deepSeek:
        return 'DeepSeek key';
      case SettingsSecretSlot.custom:
        return 'custom key';
      case SettingsSecretSlot.proxy:
        return 'proxy authentication';
    }
  }

  /// Maps a settings.json write failure to the exception the UI should
  /// surface: a Windows sharing violation becomes a classified
  /// [SettingsFileLockedException] (actionable localized message); anything
  /// else passes through unchanged.
  ///
  /// Visible for testing: a real sharing violation needs an actual Windows
  /// file lock, so the mapping is tested with synthetic exceptions.
  @visibleForTesting
  static Object mapSettingsWriteError(String filePath, Object error) {
    if (error is FileSystemException &&
        EpubIsolateWorker.isFileLockError(error)) {
      return SettingsFileLockedException(filePath);
    }
    return error;
  }

  Future<void> _writeSettingsJson(TranslationConfig config) async {
    final File file = await _settingsFile();
    await file.parent.create(recursive: true);
    // Atomic write: a kill mid-save must not leave a truncated settings.json
    // behind (that would silently reset all settings on next load).
    try {
      final bindings = Map<String, String>.of(_credentialBindings);
      for (final slot in [
        SettingsSecretSlot.deepSeek,
        SettingsSecretSlot.custom,
      ]) {
        if (!secretReadFailed(slot)) {
          bindings[slot.name] = _keyFingerprint(
            _secretSnapshot?[slot] ?? _secretValues(config)[slot]!,
          );
        }
      }
      final encoded = const JsonEncoder.withIndent('  ').convert(
        <String, dynamic>{
          ...config.toJson(),
          // Provider-specific slots are authoritative after the first write.
          // A failed legacy deletion can never migrate into another provider.
          'credentialSchemaVersion': 2,
          'credentialBindings': bindings,
          'settingsRevision': _settingsRevision + 1,
          // Only retain an existing legacy value while migration is pending.
          // Its original endpoint binding must survive unrelated saves.
          if (_pendingPlaintextKeys[SettingsSecretSlot.proxy] case final proxy?)
            'httpProxy': _pendingProxyUrl(proxy),
          if (_pendingPlaintextKeys.containsKey(SettingsSecretSlot.deepSeek))
            'deepseekApiKey':
                _pendingPlaintextKeys[SettingsSecretSlot.deepSeek],
          if (_pendingPlaintextKeys.containsKey(SettingsSecretSlot.custom))
            'customApiKey': _pendingPlaintextKeys[SettingsSecretSlot.custom],
        },
      );
      await (settingsJsonWriter ?? writeFileAtomically)(file, encoded);
      _settingsSnapshot = encoded;
      _credentialBindings = bindings;
      _allowLegacyMigration = false;
      _settingsRevision += 1;
    } catch (error) {
      throw mapSettingsWriteError(file.path, error);
    }
  }

  static String _keyFingerprint(String key) =>
      sha256.convert(utf8.encode(key.trim())).toString();

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
    _secretSnapshot?[slot] = trimmed;
    _pendingPlaintextKeys.remove(slot);
    _rotatedSlots.remove(slot);
  }

  static String _pendingProxyUrl(String secret) {
    final value = jsonDecode(secret) as Map<String, dynamic>;
    return TranslationConfig.authenticatedProxy(
      value['address'] as String,
      value['authentication'] as String,
    );
  }

  Future<File> _settingsFile() async {
    final Future<File> Function()? provider = settingsFileProvider;
    final File file;
    if (provider != null) {
      file = await provider();
    } else {
      final Directory appDirectory = Directory(
        await PlatformUtils.appDocumentsDirectory(),
      );
      file = File(path.join(appDirectory.path, 'settings.json'));
    }
    if (!_cleanedTempFiles) {
      _cleanedTempFiles = true;
      // Lazily GC `.tmp.*` files left behind by interrupted atomic writes,
      // once per store (not on every save).
      unawaited(cleanStaleAtomicTempFiles(file.parent));
    }
    return file;
  }
}
