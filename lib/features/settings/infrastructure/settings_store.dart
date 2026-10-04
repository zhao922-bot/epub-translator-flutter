import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../shared/logging/app_logger.dart';
import '../../../shared/platform/native_platform_bridge.dart';
import '../../../shared/platform/platform_utils.dart';
import '../../../shared/io/atomic_file_writer.dart';
import '../../../shared/io/strip_bom.dart';
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
}

enum SettingsSecretSlot { legacy, deepSeek, custom }

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

  // Compare against this instance's last loaded/saved values. An unchanged
  // local snapshot must not overwrite keys another app instance updated.
  Map<SettingsSecretSlot, String>? _secretSnapshot;

  /// Set when an Android KeyStore read reported SECRET_KEY_ROTATED (the
  /// device key was invalidated and regenerated): previously stored keys
  /// are unrecoverable and the user must re-enter them. Surfaced to the
  /// settings page via [SettingsController].
  bool _secretKeyRotated = false;

  /// Whether the Android KeyStore key was rotated (invalidated and
  /// regenerated) during the last secret load. The settings page shows a
  /// warning banner when true.
  bool get secretKeyRotated => _secretKeyRotated;

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

  Future<TranslationConfig> load() async {
    final TranslationConfig config;
    try {
      config = await _loadConfigFromFile();
      _configLoadError = null;
    } catch (error) {
      _configLoadError = error;
      rethrow;
    }
    final List<_SecretReadResult> storedKeys = await _readAllSecrets();
    final _SecretReadResult storedApiKey = storedKeys[0];
    final _SecretReadResult storedDeepSeekKey = storedKeys[1];
    final _SecretReadResult storedCustomKey = storedKeys[2];
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
    _secretSnapshot = _secretValues(resolvedConfig);
    if (config.apiKey.isNotEmpty &&
        !_legacyMigrationFailed &&
        _legacyMigrationAttempts < _maxLegacyMigrationAttempts) {
      _legacyMigrationAttempts += 1;
      try {
        final Set<SettingsSecretSlot> migrationSlots = <SettingsSecretSlot>{
          SettingsSecretSlot.legacy,
          config.apiProviderSelection == ApiProviderSelection.deepseek
              ? SettingsSecretSlot.deepSeek
              : SettingsSecretSlot.custom,
        };
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
          'Legacy API key migration is not supported on this backend; will not retry.',
          tag: 'settings',
          error: error,
        );
      } catch (error) {
        // Transient (D-Bus not ready, keyring locked, timeout): loading
        // settings must still succeed, and the migration is retried on a
        // later load (up to _maxLegacyMigrationAttempts attempts) instead
        // of being abandoned forever.
        AppLogger.error(
          'Legacy API key migration failed (attempt '
          '$_legacyMigrationAttempts/$_maxLegacyMigrationAttempts); '
          'will retry on a later load.',
          tag: 'settings',
          error: error,
        );
      }
    }
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
        ]);
    _didLoad = true;
    return storedKeys;
  }

  Future<TranslationConfig> _loadConfigFromFile() async {
    didCorruptReset = false;
    lastCorruptBackupPath = null;
    final File file = await _settingsFile();
    if (!await file.exists()) {
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
    // The JSON write sits in a finally block on purpose: a secret-store
    // failure (e.g. the Windows DPAPI file being locked so deleteSecret
    // throws StateError) must not silently discard the non-secret settings
    // the user just changed. The secret error still propagates so the
    // caller reports the failed key save and the user can retry.
    try {
      await _saveSecrets(config, slotsToSave: slotsToSave, explicit: explicit);
    } finally {
      await _writeSettingsJson(config);
    }
  }

  static Map<SettingsSecretSlot, String> _secretValues(
    TranslationConfig config,
  ) => <SettingsSecretSlot, String>{
    SettingsSecretSlot.legacy: config.apiKey.trim(),
    SettingsSecretSlot.deepSeek: config.deepseekApiKey.trim(),
    SettingsSecretSlot.custom: config.customApiKey.trim(),
  };

  Future<void> _saveSecrets(
    TranslationConfig config, {
    required Set<SettingsSecretSlot> slotsToSave,
    required Set<SettingsSecretSlot> explicit,
  }) async {
    // The slots are independent (separate files / keychain items); on Windows
    // each write spawns a PowerShell process, so run them concurrently rather
    // than serially. _saveSecret touches only its own slot's read status.
    final List<Future<void>> pending = <Future<void>>[];
    if (slotsToSave.contains(SettingsSecretSlot.legacy)) {
      pending.add(
        _saveSecretTagged(
          SettingsSecretSlot.legacy,
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
  }

  /// Tags a secret-slot save with a human-readable slot name so a failed
  /// save says which key was not persisted. Partial writes are possible
  /// (other slots may already have been saved when one slot throws), so
  /// naming the exact slot matters for the "save failed" message.
  Future<void> _saveSecretTagged(
    SettingsSecretSlot slot,
    Future<void> save,
  ) async {
    try {
      await save;
    } catch (error) {
      throw StateError('Failed to save ${_slotLabel(slot)}: $error');
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
      await writeFileAtomically(
        file,
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    } catch (error) {
      throw mapSettingsWriteError(file.path, error);
    }
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
    _secretSnapshot?[slot] = trimmed;
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
