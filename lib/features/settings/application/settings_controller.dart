import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../translation/domain/models/translation_config.dart';
import '../../translation/domain/repositories/translation_repository.dart';
import '../../translation/infrastructure/repositories/epub_translation_repository.dart';
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
    _load();
  }

  final SettingsStore _store;

  Future<void> _load() async {
    state = await _store.load();
  }

  Future<void> _persist() {
    return _store.save(state);
  }

  Future<void> setApiBaseUrl(String value) async {
    state = state.copyWith(apiBaseUrl: value);
    await _persist();
  }

  Future<void> setApiKey(String value) async {
    state = state.copyWith(apiKey: value);
    await _persist();
  }

  Future<void> setModel(String value) async {
    state = state.copyWith(model: value);
    await _persist();
  }

  Future<void> setUiLanguage(UiLanguage value) async {
    state = state.copyWith(uiLanguage: value);
    await _persist();
  }

  Future<void> setTargetLanguage(String value) async {
    state = state.copyWith(targetLanguage: value);
    await _persist();
  }

  Future<void> setBilingual(bool value) async {
    state = state.copyWith(bilingual: value);
    await _persist();
  }

  Future<void> setChunkSize(double value) async {
    state = state.copyWith(chunkSize: value.round());
    await _persist();
  }

  Future<void> setMaxConcurrent(double value) async {
    state = state.copyWith(maxConcurrent: value.round());
    await _persist();
  }

  Future<void> setTimeoutSeconds(double value) async {
    state = state.copyWith(timeoutSeconds: value.round());
    await _persist();
  }

  Future<void> setMaxRetries(double value) async {
    state = state.copyWith(maxRetries: value.round());
    await _persist();
  }

  Future<void> setRetryDelaySeconds(double value) async {
    state = state.copyWith(retryDelaySeconds: value.round());
    await _persist();
  }

  Future<void> setDisableThinking(bool value) async {
    state = state.copyWith(disableThinking: value);
    await _persist();
  }

  Future<void> setOutputSuffix(String value) async {
    state = state.copyWith(outputSuffix: value);
    await _persist();
  }
}

class ConnectionTestController extends StateNotifier<AsyncValue<String?>> {
  ConnectionTestController(this._repository)
    : super(const AsyncData<String?>(null));

  final TranslationRepository _repository;

  Future<void> run(TranslationConfig config) async {
    state = const AsyncLoading<String?>();
    state = await AsyncValue.guard<String?>(() async {
      final String result = await _repository.testConnection(config: config);
      return result;
    });
  }

  void clear() {
    state = const AsyncData<String?>(null);
  }
}
