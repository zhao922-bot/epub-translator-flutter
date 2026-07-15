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
      (ref) => SettingsController(ref.watch(settingsStoreProvider)),
    );

final connectionTestProvider =
    StateNotifierProvider<ConnectionTestController, AsyncValue<String?>>(
      (ref) => ConnectionTestController(ref.watch(settingsRepositoryProvider)),
    );

class SettingsController extends StateNotifier<TranslationConfig> {
  SettingsController(this._store) : super(TranslationConfig.defaults()) {
    _initialLoad = _load();
  }

  final SettingsStore _store;
  late final Future<void> _initialLoad;
  Future<void> _pendingSave = Future<void>.value();

  Future<void> _load() async {
    final TranslationConfig loaded = await _store.load();
    if (!mounted) {
      return;
    }
    state = loaded;
  }

  Future<void> _persist(TranslationConfig config) {
    final Future<void> save = _pendingSave.then<void>(
      (_) => _store.save(config),
      onError: (_) => _store.save(config),
    );
    _pendingSave = save.catchError((_) {});
    return save;
  }

  Future<void> _update(
    TranslationConfig Function(TranslationConfig config) update,
  ) async {
    await _initialLoad;
    if (!mounted) {
      return;
    }
    final TranslationConfig next = update(state);
    if (!mounted) {
      return;
    }
    state = next;
    await _persist(next);
  }

  Future<void> setApiBaseUrl(String value) =>
      _update((config) => config.copyWith(apiBaseUrl: value.trim()));

  Future<void> setApiKey(String value) =>
      _update((config) => config.copyWith(apiKey: value.trim()));

  Future<void> setModel(String value) =>
      _update((config) => config.copyWith(model: value.trim()));

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
