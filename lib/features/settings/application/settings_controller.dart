import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../translation/domain/models/api_provider_preset.dart';
import '../../translation/domain/models/translation_config.dart';
import '../../translation/domain/repositories/translation_repository.dart';
import '../../translation/infrastructure/repositories/epub_translation_repository.dart';
import 'connection_diagnostic.dart';
import '../infrastructure/settings_store.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

final settingsRepositoryProvider = Provider<TranslationRepository>(
  (ref) => EpubTranslationRepository(),
);

final settingsProvider =
    StateNotifierProvider<SettingsController, TranslationConfig>(
      (ref) => SettingsController(
        ref.watch(settingsStoreProvider),
        onSaveError: (Object? error) {
          final notifier = ref.read(settingsSaveErrorProvider.notifier);
          if (error == null) {
            // Successful persist: clear any previous failure notice.
            notifier.state = (
              id: DateTime.now().microsecondsSinceEpoch,
              message: null,
              settingsFileLocked: false,
            );
            return;
          }
          notifier.state = (
            id: DateTime.now().microsecondsSinceEpoch,
            // For a locked settings file the UI shows an actionable
            // localized message; the record carries the file path for it.
            message: error is SettingsFileLockedException
                ? error.filePath
                : '$error',
            settingsFileLocked: error is SettingsFileLockedException,
          );
        },
        onCorruptReset: (String? backupPath) =>
            ref.read(settingsResetNoticeProvider.notifier).state = (
              id: DateTime.now().microsecondsSinceEpoch,
              backupPath: backupPath,
            ),
        onSecretKeyRotated: () =>
            ref.read(secretKeyRotatedNoticeProvider.notifier).state = (
              id: DateTime.now().microsecondsSinceEpoch,
            ),
      ),
    );

/// Holds the latest settings persistence failure event, if any.
///
/// Settings writes (secret store + settings.json) can fail after the UI
/// already shows the new value; this surfaces the failure so the settings
/// page can warn the user instead of failing silently.
///
/// Each failure is wrapped in a distinct event (unique id + message) instead
/// of a plain string: Riverpod suppresses state updates that equal the current
/// value, so two consecutive failures with identical text would otherwise only
/// notify once and the second SnackBar would be swallowed.
final settingsSaveErrorProvider =
    StateProvider<({int id, String? message, bool settingsFileLocked})?>(
      (ref) => null,
    );

/// Holds the latest "settings.json was unreadable/corrupt, defaults were
/// restored" event, if any.
///
/// A corrupt (or transiently locked, on Windows) settings file used to reset
/// a dozen user settings with only a log line to show for it. This surfaces
/// the reset — and the backup location — so the UI can warn the user.
///
/// Same event-record pattern as [settingsSaveErrorProvider]: Riverpod
/// suppresses state updates that equal the current value, so a plain string
/// could swallow a second reset notice.
final settingsResetNoticeProvider =
    StateProvider<({int id, String? backupPath})?>((ref) => null);

/// Holds the "Android KeyStore key was invalidated and regenerated" event,
/// if any. The stored secrets are unrecoverable then, so the settings page
/// shows a warning banner telling the user to re-enter their API keys.
///
/// Same event-record pattern as [settingsSaveErrorProvider].
final secretKeyRotatedNoticeProvider = StateProvider<({int id})?>(
  (ref) => null,
);

final connectionTestProvider =
    StateNotifierProvider<ConnectionTestController, AsyncValue<String?>>((ref) {
      final controller = ConnectionTestController(
        ref.watch(settingsRepositoryProvider),
      );
      ref.listen<TranslationConfig>(settingsProvider, (previous, next) {
        if (previous == null ||
            previous.apiBaseUrl != next.apiBaseUrl ||
            previous.apiKey != next.apiKey ||
            previous.model != next.model ||
            previous.httpProxy != next.httpProxy ||
            previous.targetLanguage != next.targetLanguage) {
          controller.clear();
        }
      });
      return controller;
    });

class SettingsController extends StateNotifier<TranslationConfig> {
  SettingsController(
    this._store, {
    this.onSaveError,
    this.onCorruptReset,
    this.onSecretKeyRotated,
  }) : super(TranslationConfig.defaults()) {
    _initialLoad = _load();
  }

  final SettingsStore _store;

  /// Called with the failure when persisting settings fails, or with null
  /// after a successful persist (clears a previous error).
  final void Function(Object? error)? onSaveError;

  /// Called with the backup path (null when the backup itself failed) when
  /// settings.json was unreadable/corrupt at load and defaults were
  /// restored. Not called on a first run with no settings file.
  final void Function(String? backupPath)? onCorruptReset;

  /// Called once after load when the Android KeyStore key was invalidated
  /// (lock-screen/biometric change) and regenerated: the stored secrets
  /// are unrecoverable, so the UI warns the user to re-enter them.
  final void Function()? onSecretKeyRotated;
  late final Future<void> _initialLoad;
  Future<void> _pendingSave = Future<void>.value();
  Future<void>? _recoveryLoad;
  int providerSelectionRevision = 0;

  Future<void> get ready => _initialLoad;

  Future<void> _load() async {
    final TranslationConfig loaded;
    try {
      loaded = await _store.load();
    } catch (error) {
      if (mounted) onSaveError?.call(error);
      return;
    }
    if (!mounted) {
      return;
    }
    state = loaded;
    if (_store.didCorruptReset) {
      onCorruptReset?.call(_store.lastCorruptBackupPath);
    }
    if (_store.secretKeyRotated) {
      onSecretKeyRotated?.call();
    }
  }

  Future<void> _persist(
    TranslationConfig config, {
    Set<SettingsSecretSlot> explicitSecretMutations =
        const <SettingsSecretSlot>{},
  }) {
    final Future<void> save = _pendingSave.then<void>(
      (_) =>
          _store.save(config, explicitSecretMutations: explicitSecretMutations),
      onError: (_) =>
          _store.save(config, explicitSecretMutations: explicitSecretMutations),
    );
    _pendingSave = save.catchError((_) {});
    return save;
  }

  Future<bool> _ensureConfigLoaded() async {
    if (_store.configLoadError == null) return mounted;
    final recovery = _recoveryLoad ??= _load();
    try {
      await recovery;
    } finally {
      if (identical(_recoveryLoad, recovery)) _recoveryLoad = null;
    }
    return mounted && _store.configLoadError == null;
  }

  Future<bool> _update(
    TranslationConfig Function(TranslationConfig config) update, {
    Set<SettingsSecretSlot> explicitSecretMutations =
        const <SettingsSecretSlot>{},
    Set<SettingsSecretSlot> Function(TranslationConfig)? secretMutationsFor,
  }) async {
    await _initialLoad;
    if (!mounted) {
      return false;
    }
    if (!await _ensureConfigLoaded()) return false;
    final slots = secretMutationsFor?.call(state) ?? explicitSecretMutations;
    final TranslationConfig next = update(state);
    if (!mounted) {
      return false;
    }
    state = next;
    try {
      await _persist(next, explicitSecretMutations: slots);
      if (mounted) onSaveError?.call(null);
      return true;
    } catch (error) {
      // The UI already shows the new value, so a silent failure would leave
      // it lying about what is actually persisted. Surface it instead of
      // letting the future go unhandled at the call site.
      if (mounted) onSaveError?.call(error);
      return false;
    }
  }

  Future<bool> setApiBaseUrl(String value) => _update((config) {
    final String nextUrl = value.trim();
    return config.copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      apiBaseUrl: nextUrl,
      customApiBaseUrl: nextUrl,
      customApiKey: config.apiKey,
      customModel: config.model,
    );
  });

  Future<bool> setApiKey(String value) => _update(
    (config) {
      final String nextKey = value.trim();
      return config.apiProviderSelection == ApiProviderSelection.deepseek
          ? config.copyWith(apiKey: nextKey, deepseekApiKey: nextKey)
          : config.copyWith(apiKey: nextKey, customApiKey: nextKey);
    },
    secretMutationsFor: (config) => <SettingsSecretSlot>{
      SettingsSecretSlot.legacy,
      config.apiProviderSelection == ApiProviderSelection.deepseek
          ? SettingsSecretSlot.deepSeek
          : SettingsSecretSlot.custom,
    },
  );

  Future<bool> setModel(String value) => _update((config) {
    final String nextModel = value.trim();
    return config.copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      apiBaseUrl: config.apiBaseUrl,
      customApiBaseUrl: config.apiBaseUrl,
      customApiKey: config.apiKey,
      model: nextModel,
      customModel: nextModel,
    );
  });

  Future<void> setUiLanguage(UiLanguage value) =>
      _update((config) => config.copyWith(uiLanguage: value));

  Future<void> setThemeMode(AppThemeMode value) =>
      _update((config) => config.copyWith(themeMode: value));

  Future<void> setTargetLanguage(String value) =>
      _update((config) => config.copyWith(targetLanguage: value.trim()));

  Future<void> setBilingual(bool value) =>
      _update((config) => config.copyWith(bilingual: value));

  Future<void> applyTuningPreset(TranslationTuningPreset preset) =>
      _update(preset.applyTo);

  Future<void> setChunkSize(double value) =>
      _update((config) => config.copyWith(chunkSize: value.round()));

  Future<void> setMaxConcurrent(double value) =>
      _update((config) => config.copyWith(maxConcurrent: value.round()));

  Future<void> setTimeoutSeconds(double value) =>
      _update((config) => config.copyWith(timeoutSeconds: value.round()));

  Future<void> setMaxRetries(double value) =>
      _update((config) => config.copyWith(maxRetries: value.round()));

  Future<void> setRetryDelaySeconds(double value) =>
      _update((config) => config.copyWith(retryDelaySeconds: value.round()));

  Future<bool> setOutputSuffix(String value) =>
      _update((config) => config.copyWith(outputSuffix: value.trim()));

  Future<void> setResidualQualityCheck(bool value) =>
      _update((config) => config.copyWith(residualQualityCheck: value));

  Future<void> setStyleProfileEnabled(bool value) =>
      _update((config) => config.copyWith(styleProfileEnabled: value));

  Future<void> setTextScale(double value) =>
      _update((config) => config.copyWith(textScale: value.clamp(0.9, 1.3)));

  Future<bool> setLockedGlossary(String value) =>
      _update((config) => config.copyWith(lockedGlossary: value));

  Future<bool> setHttpProxy(String value) =>
      _update((config) => config.copyWith(httpProxy: value.trim()));

  Future<void> applyApiProviderPreset(ApiProviderPreset preset) =>
      _update((config) {
        providerSelectionRevision++;
        return preset.applyTo(config);
      });

  Future<void> reduceConcurrencyForRateLimit() => _update((config) {
    final int next = (config.maxConcurrent - 1).clamp(1, 8);
    return config.copyWith(maxConcurrent: next);
  });
}

class ConnectionTestController extends StateNotifier<AsyncValue<String?>> {
  ConnectionTestController(this._repository)
    : super(const AsyncData<String?>(null));

  final TranslationRepository _repository;
  int _revision = 0;

  Future<void> run(TranslationConfig config) async {
    if (!mounted) {
      return;
    }
    final revision = ++_revision;
    state = const AsyncLoading<String?>();
    try {
      final String result = await _repository.testConnection(config: config);
      if (!mounted || revision != _revision) {
        return;
      }
      state = AsyncData<String?>(result);
    } catch (error, stackTrace) {
      if (!mounted || revision != _revision) {
        return;
      }
      final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
        error,
        config: config,
      );
      state = AsyncError<String?>(diagnostic.message, stackTrace);
    }
  }

  void clear() {
    if (!mounted) {
      return;
    }
    _revision++;
    state = const AsyncData<String?>(null);
  }
}
