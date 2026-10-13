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

/// Tracks one in-flight credential backend operation (P1-#4). [settled]
/// completes after [_SettingsStore._saveSecret] has updated the in-memory
/// snapshot/statuses (or decided the operation was stale), so a stale
/// operation's watcher can wait for the final state before repairing.
class _InflightCredentialOp {
  _InflightCredentialOp(this.op, this.settled);

  final Future<void> op;
  final Future<void> settled;
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

  /// Generation of credential backend operations, bumped at the start of
  /// every [_saveSecrets] call. `Future.timeout` cannot cancel the backend
  /// operation — the platform write keeps running and may land after a
  /// retried save already stored a newer value. The generation lets a late
  /// completion recognize itself as stale so it neither touches in-memory
  /// state nor silently wins in the backend (P1-#4).
  int _credentialGeneration = 0;

  /// In-flight credential backend operations by slot. A timed-out save
  /// releases the settings file lock while its backend write is still
  /// running; a retried save may then issue a newer operation for the same
  /// slot. The record lets a stale operation's watcher wait for the newer
  /// one to fully settle (snapshot updated) before repairing, so the repair
  /// always targets the final value (P1-#4).
  final Map<SettingsSecretSlot, _InflightCredentialOp>
  _inflightCredentialOps = <SettingsSecretSlot, _InflightCredentialOp>{};

  /// Secret slots actually persisted by the most recent [_saveSecrets] call,
  /// as opposed to skipped as unreadable. Lets the settings controller's
  /// conflict-replay drop only entries that really landed (P2-#27): a key
  /// entry skipped because its slot read failed must stay queued even when
  /// a later non-credential save succeeds.
  Set<SettingsSecretSlot> _lastPersistedSecretSlots =
      <SettingsSecretSlot>{};

  /// Slots persisted by the last [_saveSecrets] call. Lets the settings
  /// controller's conflict-replay drop only queue entries whose secret
  /// slots really landed (a slot skipped as unreadable is not persisted).
  Set<SettingsSecretSlot> get lastPersistedSecretSlots =>
      Set<SettingsSecretSlot>.unmodifiable(_lastPersistedSecretSlots);

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

  /// Whether the legacy (pre-schema) credential migration has finished.
  ///
  /// While a legacy key still awaits migration, plain saves must not stamp
  /// `credentialSchemaVersion: 2`: that would permanently disable the legacy
  /// fallback while the legacy slot still holds the only copy of the key,
  /// so a failed migration followed by an unrelated save (e.g. a theme
  /// change) would make the previously usable key disappear on next launch.
  bool _legacyMigrationComplete = false;

  /// Whether the loaded config came from a successfully parsed settings.json
  /// (as opposed to defaults after a missing/corrupt file). The legacy key's
  /// provider association is only trustworthy in that case (P1-#4).
  bool _configFromParsedFile = false;

  /// How long a single secret-store read/write/delete may take before it is
  /// treated as failed (P2-#32). A hung backend must not hold the settings
  /// file lock forever and wedge every later settings operation.
  static const Duration _secretOpTimeout = Duration(seconds: 30);

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
      // Only a *read* value whose fingerprint mismatches the binding means
      // "the process exited between the secure write and the JSON write".
      // A `missing` read (the key was deleted externally, or was never
      // there) must stay `missing` so the UI reports "no key" instead of a
      // bogus read failure. Fail-closed is preserved: the mismatch arm
      // still rejects any uncommitted key, and a missing slot never falls
      // back to stale JSON plaintext (the legacy/plaintext fallbacks below
      // only apply while migration is pending, and a missing secure slot
      // keeps its `missing` status through save, so no old secret is
      // resurrected as the active key).
      if (binding != null &&
          storedKeys[index].status == _SecretReadStatus.value &&
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
    // P1-#4: a legacy key may only fill the provider slot it belongs to.
    // When settings.json was missing or corrupt, the loaded config is
    // defaults and its provider selection is not the user's — filling the
    // legacy key into the default DeepSeek slot would re-bind a Custom
    // user's credential to api.deepseek.com and persist it there.
    final bool providerTrusted = _configFromParsedFile;
    final String deepSeekKey = storedDeepSeekKey.value?.isNotEmpty == true
        ? storedDeepSeekKey.value!
        : providerTrusted &&
              config.apiProviderSelection == ApiProviderSelection.deepseek &&
              legacyKey.isNotEmpty
        ? legacyKey
        : config.deepseekApiKey;
    final String customKey = storedCustomKey.value?.isNotEmpty == true
        ? storedCustomKey.value!
        : providerTrusted &&
              config.apiProviderSelection == ApiProviderSelection.custom &&
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
        // P1-#4: without a trustworthy provider association (missing/corrupt
        // settings.json), a legacy key must not be allocated to the default
        // provider's slot.
        providerTrusted &&
        storedApiKey.value?.isNotEmpty == true &&
        (providerSlot == SettingsSecretSlot.deepSeek
                    ? storedDeepSeekKey
                    : storedCustomKey)
                .status ==
            _SecretReadStatus.missing;
    final bool legacyMigrationNeeded =
        _allowLegacyMigration &&
        (_pendingPlaintextKeys.isNotEmpty || needsSecureAllocation);
    if (!legacyMigrationNeeded) {
      // Schema already migrated, or no legacy key material at all:
      // provider slots (or their absence) are authoritative from here on,
      // so stamping schema 2 on later saves is safe.
      _legacyMigrationComplete = true;
    }
    if (legacyMigrationNeeded &&
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
        // The provider slots now hold the keys: the migration write itself
        // may stamp schema 2.
        _legacyMigrationComplete = true;
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
        if (error is SettingsWriteConflict) {
          // Not a migration failure: another instance saved settings.json
          // concurrently. Classify it as a conflict (like [save] does) so
          // it is not misreported as "migration failed, will retry", and
          // record it as a load error so the controller's recovery path
          // reloads before the next save instead of conflicting again. The
          // migration itself is retried on a later load.
          _configLoadError = error;
          AppLogger.error(
            'Legacy credential migration hit a cross-instance write '
            'conflict (attempt '
            '$_legacyMigrationAttempts/$_maxLegacyMigrationAttempts); '
            'settings loaded, migration will retry on a later load.',
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
    // P1-#4: reset per load; only a successfully parsed file establishes a
    // trustworthy provider association for the legacy key.
    _configFromParsedFile = false;
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
      _configFromParsedFile = true;
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
        _configFromParsedFile = true;
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
    // A schema-2 file already migrated: provider slots are authoritative.
    // Otherwise the flag is decided in [_loadLocked] once the legacy key
    // material (if any) is known.
    _legacyMigrationComplete = decoded['credentialSchemaVersion'] == 2;
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
      // P2-#32: a secret backend that never completes must not hold the
      // settings file lock forever. The timeout surfaces as a read failure
      // (the slot stays protected, never treated as "missing").
      final String? value = await read().timeout(_secretOpTimeout);
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
    final Object? loadError = _configLoadError;
    if (loadError != null) {
      // P2-#35: a conflict-induced load error is recoverable — surface it
      // as a conflict so the caller queues the edit for replay instead of
      // dropping it with a StateError. Genuine load failures still refuse.
      if (loadError is SettingsWriteConflict) throw loadError;
      throw StateError('Settings could not be loaded; reload before saving.');
    }
    // Validate before touching any secret slot, not just before JSON encoding.
    config.toJson();
    final file = await _settingsFile();
    try {
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
    } on SettingsWriteConflict catch (error) {
      // A cross-instance conflict leaves this instance's snapshot stale:
      // every later save would conflict again and the user would be stuck.
      // Record it as a load error so the controller's recovery path reloads
      // before the next save, and the settings page can offer an explicit
      // "reload" action.
      _configLoadError = error;
      rethrow;
    }
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
              // A model must never be persisted against an endpoint it was
              // not saved with: rolling back the endpoint without the model
              // could land "endpoint A + key A + model B" on disk, and the
              // next launch would request a model the old endpoint rejects.
              model: providerFailed ? previous.model : config.model,
              customModel: customFailed
                  ? previous.customModel
                  : config.customModel,
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
    // P1-#4: a new credential operation generation starts here, so a
    // backend write from an earlier (timed-out) call that lands late is
    // recognized as stale and cannot overwrite the values saved now.
    _credentialGeneration++;
    // P2-#27: which slots really landed (vs. skipped as unreadable). Only
    // landed slots count as persisted for conflict-replay superseding.
    final Set<SettingsSecretSlot> persisted = <SettingsSecretSlot>{};
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
          persisted,
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
          persisted,
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
          persisted,
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
          persisted,
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
    _lastPersistedSecretSlots = persisted;
    if (slotsToSave.isNotEmpty && _rotatedSlots.isEmpty) {
      _secretKeyRotated = false;
    }
  }

  /// Tags a secret-slot save with a human-readable slot name so a failed
  /// save says which key was not persisted. Partial writes are possible
  /// (other slots may already have been saved when one slot throws), so
  /// naming the exact slot matters for the "save failed" message.
  /// [persisted] collects the slots whose write actually landed (P2-#27).
  Future<void> _saveSecretTagged(
    SettingsSecretSlot slot,
    Map<SettingsSecretSlot, Object> failures,
    Set<SettingsSecretSlot> persisted,
    Future<bool> save,
  ) async {
    try {
      if (await save) persisted.add(slot);
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
          // The schema stamp is written only once the legacy migration is
          // actually complete: stamping it after a failed migration would
          // permanently disable the legacy fallback while the legacy slot
          // still holds the only copy of the key.
          if (_legacyMigrationComplete) 'credentialSchemaVersion': 2,
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
      // Only retire the legacy fallback once the migration really finished;
      // an unrelated save after a failed migration must keep it alive.
      if (_legacyMigrationComplete) _allowLegacyMigration = false;
      _settingsRevision += 1;
    } catch (error) {
      throw mapSettingsWriteError(file.path, error);
    }
  }

  static String _keyFingerprint(String key) =>
      sha256.convert(utf8.encode(key.trim())).toString();

  /// Saves one secret slot. Returns true when the value actually landed in
  /// the backend (false when the write was skipped as unreadable, or when
  /// the operation turned out stale because a newer save started while it
  /// was in flight).
  Future<bool> _saveSecret(
    SettingsSecretSlot slot,
    String value, {
    required Set<SettingsSecretSlot> explicit,
    required Future<void> Function(String value) write,
    required Future<void> Function() delete,
  }) async {
    if (_secretReadStatuses[slot] == _SecretReadStatus.readFailure &&
        !explicit.contains(slot)) {
      return false;
    }
    final String trimmed = value.trim();
    final int opGeneration = _credentialGeneration;
    final Future<void> backendOp =
        trimmed.isEmpty ? delete() : write(trimmed);
    final Completer<void> settled = Completer<void>();
    _inflightCredentialOps[slot] = _InflightCredentialOp(
      backendOp,
      settled.future,
    );
    // P1-#4: Future.timeout has no cancellation semantics — the backend
    // operation keeps running after the timeout fires and may land after a
    // retried save already stored a newer value. Watch the raw future: a
    // stale completion must not touch in-memory state, and the current
    // snapshot value is re-asserted so the late write cannot silently win.
    _watchCredentialOp(
      slot,
      opGeneration,
      write: write,
      delete: delete,
      backendOp: backendOp,
    );
    try {
      // Bound the backend call; a hung write must not wedge the settings
      // file lock either. On timeout the exception propagates (the
      // operation is recorded as failed) — the watcher above repairs the
      // backend if the abandoned write lands late.
      await backendOp.timeout(_secretOpTimeout);
      if (opGeneration != _credentialGeneration) {
        // A newer save started while this operation was in flight: this
        // completion is stale. In-memory state belongs to the newer save;
        // the watcher re-asserts the backend.
        return false;
      }
      if (trimmed.isEmpty) {
        _secretReadStatuses[slot] = _SecretReadStatus.missing;
      } else {
        _secretReadStatuses[slot] = _SecretReadStatus.value;
      }
      _secretSnapshot?[slot] = trimmed;
      _pendingPlaintextKeys.remove(slot);
      _rotatedSlots.remove(slot);
      return true;
    } finally {
      if (identical(_inflightCredentialOps[slot]?.op, backendOp)) {
        _inflightCredentialOps.remove(slot);
      }
      // Completed after the snapshot/status updates above: a stale
      // operation's watcher waiting on [settled] sees the final state.
      settled.complete();
    }
  }

  /// Watches a credential backend operation for late completion (P1-#4).
  /// When the operation was issued under [opGeneration] but a newer save
  /// has since started, its landing value is outdated — re-assert the
  /// current snapshot value so the stale write cannot silently overwrite
  /// the newer one. Best effort and never throws.
  void _watchCredentialOp(
    SettingsSecretSlot slot,
    int opGeneration, {
    required Future<void> Function(String value) write,
    required Future<void> Function() delete,
    required Future<void> backendOp,
  }) {
    unawaited(
      backendOp.then((_) async {
        if (opGeneration == _credentialGeneration) return;
        // A newer operation for this slot may still be settling; wait for
        // it (bounded) so the re-assert targets the final snapshot value,
        // not a mid-save one.
        final _InflightCredentialOp? newer = _inflightCredentialOps[slot];
        if (newer != null && !identical(newer.op, backendOp)) {
          try {
            await newer.settled.timeout(_secretOpTimeout);
          } catch (_) {
            // Best effort; re-assert anyway.
          }
        }
        _reassertCredentialSlot(slot, write: write, delete: delete);
      }).catchError((Object _) {
        // A failed backend operation changes nothing; nothing to repair.
      }),
    );
  }

  /// Re-asserts the current in-memory credential value for [slot] into the
  /// backend (P1-#4). Called when a stale operation landed late; writes the
  /// value that is current now, so even a late re-assert is harmless. The
  /// re-assert itself is watched: if a still-newer save starts mid-flight,
  /// its watcher takes over the repair.
  void _reassertCredentialSlot(
    SettingsSecretSlot slot, {
    required Future<void> Function(String value) write,
    required Future<void> Function() delete,
  }) {
    unawaited(
      (() async {
        try {
          final File file = await _settingsFile();
          await withSettingsFileLock(file, () async {
            final current = await file.exists()
                ? await file.readAsString()
                : null;
            if (_didLoad && current != _settingsSnapshot) {
              AppLogger.warn(
                'Credential re-assert skipped: settings changed in another instance.',
                tag: 'settings',
              );
              return;
            }
            final Map<SettingsSecretSlot, String>? snapshot = _secretSnapshot;
            if (snapshot == null) return;
            final String value = snapshot[slot] ?? '';
            final int opGeneration = _credentialGeneration;
            final Future<void> backendOp = value.isEmpty
                ? delete()
                : write(value);
            _watchCredentialOp(
              slot,
              opGeneration,
              write: write,
              delete: delete,
              backendOp: backendOp,
            );
            await backendOp.timeout(_secretOpTimeout);
          });
        } catch (error) {
          AppLogger.error(
            'Credential re-assert failed: ${error.runtimeType}',
            tag: 'settings',
          );
        }
      })(),
    );
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
