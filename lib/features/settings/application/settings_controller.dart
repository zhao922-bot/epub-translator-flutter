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
        onSaveError: (String? error) =>
            ref.read(settingsSaveErrorProvider.notifier).state = (
              id: DateTime.now().microsecondsSinceEpoch,
              message: error,
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
    StateProvider<({int id, String? message})?>((ref) => null);

final connectionTestProvider =
    StateNotifierProvider<ConnectionTestController, AsyncValue<String?>>(
      (ref) => ConnectionTestController(ref.watch(settingsRepositoryProvider)),
    );

class SettingsController extends StateNotifier<TranslationConfig> {
  SettingsController(this._store, {this.onSaveError})
    : super(TranslationConfig.defaults()) {
    _initialLoad = _load();
  }

  final SettingsStore _store;

  /// Called with the failure message when persisting settings fails, or with
  /// null after a successful persist (clears a previous error).
  final void Function(String? error)? onSaveError;
  late final Future<void> _initialLoad;
  Future<void> _pendingSave = Future<void>.value();

  Future<void> get ready => _initialLoad;

  Future<void> _load() async {
    final TranslationConfig loaded = await _store.load();
    if (!mounted) {
      return;
    }
    state = loaded;
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

  Future<void> _update(
    TranslationConfig Function(TranslationConfig config) update, {
    Set<SettingsSecretSlot> explicitSecretMutations =
        const <SettingsSecretSlot>{},
  }) async {
    await _initialLoad;
    if (!mounted) {
      return;
    }
    final TranslationConfig next = update(state);
    if (!mounted) {
      return;
    }
    state = next;
    try {
      await _persist(next, explicitSecretMutations: explicitSecretMutations);
      onSaveError?.call(null);
    } catch (error) {
      // The UI already shows the new value, so a silent failure would leave
      // it lying about what is actually persisted. Surface it instead of
      // letting the future go unhandled at the call site.
      onSaveError?.call('$error');
    }
  }

  Future<void> setApiBaseUrl(String value) => _update((config) {
    final String nextUrl = value.trim();
    return config.copyWith(
      apiProviderSelection: ApiProviderSelection.custom,
      apiBaseUrl: nextUrl,
      customApiBaseUrl: nextUrl,
      customApiKey: config.apiKey,
      customModel: config.model,
    );
  });

  Future<void> setApiKey(String value) async {
    await _initialLoad;
    if (!mounted) {
      return;
    }
    final Set<SettingsSecretSlot> slots = <SettingsSecretSlot>{
      SettingsSecretSlot.legacy,
      state.apiProviderSelection == ApiProviderSelection.deepseek
          ? SettingsSecretSlot.deepSeek
          : SettingsSecretSlot.custom,
    };
    await _update((config) {
      final String nextKey = value.trim();
      return config.apiProviderSelection == ApiProviderSelection.deepseek
          ? config.copyWith(apiKey: nextKey, deepseekApiKey: nextKey)
          : config.copyWith(apiKey: nextKey, customApiKey: nextKey);
    }, explicitSecretMutations: slots);
  }

  Future<void> setModel(String value) => _update((config) {
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

  Future<void> setOutputSuffix(String value) =>
      _update((config) => config.copyWith(outputSuffix: value.trim()));

  Future<void> setResidualQualityCheck(bool value) =>
      _update((config) => config.copyWith(residualQualityCheck: value));

  Future<void> setStyleProfileEnabled(bool value) =>
      _update((config) => config.copyWith(styleProfileEnabled: value));

  Future<void> setTextScale(double value) =>
      _update((config) => config.copyWith(textScale: value.clamp(0.9, 1.3)));

  Future<void> setLockedGlossary(String value) =>
      _update((config) => config.copyWith(lockedGlossary: value));

  Future<void> applyApiProviderPreset(ApiProviderPreset preset) =>
      _update(preset.applyTo);

  Future<void> reduceConcurrencyForRateLimit() => _update((config) {
    final int next = (config.maxConcurrent - 1).clamp(1, 8);
    return config.copyWith(maxConcurrent: next);
  });
}

class ConnectionTestController extends StateNotifier<AsyncValue<String?>> {
  ConnectionTestController(this._repository)
    : super(const AsyncData<String?>(null));

  final TranslationRepository _repository;

  Future<void> run(TranslationConfig config) async {
    if (!mounted) {
      return;
    }
    state = const AsyncLoading<String?>();
    try {
      final String result = await _repository.testConnection(config: config);
      if (!mounted) {
        return;
      }
      state = AsyncData<String?>(result);
    } catch (error, stackTrace) {
      if (!mounted) {
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
    state = const AsyncData<String?>(null);
  }
}
