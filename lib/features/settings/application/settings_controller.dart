import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../translation/domain/models/api_provider_preset.dart';
import '../../translation/domain/models/translation_config.dart';
import '../../translation/domain/repositories/translation_repository.dart';
import '../../translation/infrastructure/repositories/epub_translation_repository.dart';
import '../../translation/infrastructure/epub/translation_api_client.dart';
import '../../../shared/security/sensitive_text.dart';
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
            // A save that went through also resolves a pending write
            // conflict (the snapshot is fresh again).
            ref.read(settingsWriteConflictProvider.notifier).state = null;
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
        onSecretsRecovered: () =>
            ref.read(secretKeyRotatedNoticeProvider.notifier).state = null,
        onWriteConflict: () =>
            ref.read(settingsWriteConflictProvider.notifier).state = (
              id: DateTime.now().microsecondsSinceEpoch,
            ),
        onReplayBlocked: () =>
            ref.read(settingsReplayBlockedProvider.notifier).state = (
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

/// Holds the latest cross-instance write-conflict event, if any.
///
/// Another app instance saved settings.json after this instance loaded it,
/// so this instance's snapshot is stale and further saves keep conflicting.
/// The settings page shows a notice with a "reload" action; reloading
/// re-reads the file so the user can review the other instance's values and
/// save again.
///
/// Same event-record pattern as [settingsSaveErrorProvider].
final settingsWriteConflictProvider = StateProvider<({int id})?>((ref) => null);

/// Holds the latest credential replay blocked by a changed service route.
///
/// The queued edit is retained until the user explicitly confirms the new
/// target or discards it. Uses the event-record pattern so repeated blocked
/// replay attempts can each notify the UI.
final settingsReplayBlockedProvider = StateProvider<({int id})?>((ref) => null);

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

final settingsLoadedProvider = FutureProvider<void>((ref) async {
  await ref.watch(settingsProvider.notifier).ready;
});

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

/// An edit whose save failed with [SettingsWriteConflict], kept as a pure
/// transformation so [SettingsController.reloadSettings] can re-apply it
/// onto the fresh snapshot. Replaying the closure (rather than restoring
/// the failed state wholesale) preserves the user's intent without
/// clobbering the other instance's unrelated changes.
typedef _ConflictedEdit = ({
  TranslationConfig Function(TranslationConfig) update,
  Set<SettingsSecretSlot> explicitSecretMutations,
  Set<SettingsSecretSlot> Function(TranslationConfig)? secretMutationsFor,
  ({
    ApiProviderSelection providerSelection,
    String apiBaseUrl,
    String customApiBaseUrl,
    Set<SettingsSecretSlot> secretSlots,
  })
  credentialRoute,
});

class SettingsController extends StateNotifier<TranslationConfig> {
  SettingsController(
    this._store, {
    this.onSaveError,
    this.onCorruptReset,
    this.onSecretKeyRotated,
    this.onSecretsRecovered,
    this.onWriteConflict,
    this.onReplayBlocked,
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
  final void Function()? onSecretsRecovered;

  /// Called when a save fails with [SettingsWriteConflict]: another instance
  /// changed settings.json, so this instance's snapshot is stale. The page
  /// offers a "reload" recovery action.
  final void Function()? onWriteConflict;

  /// Called once per replay pass when credential edits need confirmation
  /// because their target service changed.
  final void Function()? onReplayBlocked;
  final Set<SettingsSecretSlot> _unresolvedSecretFailures = {};
  Timer? _sliderTimer;
  Completer<bool>? _sliderCompletion;
  late final Future<void> _initialLoad;
  Future<void> _pendingSave = Future<void>.value();
  Future<void>? _recoveryLoad;

  /// Edits whose save failed with [SettingsWriteConflict]. [reloadSettings]
  /// re-applies them onto the freshly loaded snapshot instead of silently
  /// discarding the user's work. Automatic load recovery uses the same replay
  /// path; blocked credential edits remain queued until confirmed or discarded.
  final List<_ConflictedEdit> _conflictedEdits = <_ConflictedEdit>[];
  bool _replayingConflictedEdits = false;

  /// The latest debounced (slider) transformation not yet flushed. Slider
  /// setters are absolute, so chaining keeps the effective transformation.
  TranslationConfig Function(TranslationConfig)? _debouncedEdit;

  int providerSelectionRevision = 0;

  /// Monotonic generation of the in-memory state, bumped every time [_load]
  /// replaces the state with a freshly read snapshot. Lets
  /// [_replayConflictedEdits] tell whether a recovery load discarded the
  /// optimistic effects of queued edits mid-pass (P2-#22).
  int _stateGeneration = 0;

  Future<void> get ready => _initialLoad;
  bool get canTestConnection => _loaded && _store.configLoadError == null;
  bool _loaded = false;
  bool secretReadFailed(SettingsSecretSlot slot) =>
      _store.secretReadFailed(slot);

  Future<bool> _load() async {
    final TranslationConfig loaded;
    try {
      loaded = await _store.load();
    } catch (error) {
      if (mounted) onSaveError?.call(error);
      return false;
    }
    if (!mounted) {
      return false;
    }
    _loaded = true;
    state = loaded;
    _stateGeneration++;
    if (_store.didCorruptReset) {
      onCorruptReset?.call(_store.lastCorruptBackupPath);
    }
    if (_store.secretKeyRotated) {
      onSecretKeyRotated?.call();
    }
    return true;
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
    bool debounce = false,
    bool isConflictReplay = false,
    // P2-#22: invoked synchronously right after the transformation is
    // applied to the state, so the replay loop can tell which queued edits
    // actually contributed to a later successful save.
    void Function()? onApplied,
  }) async {
    if (!_loaded) await _initialLoad;
    if (!mounted) {
      return false;
    }
    final bool hadLoadError = _store.configLoadError != null;
    if (hadLoadError && !await _ensureConfigLoaded()) {
      return false;
    }
    if (hadLoadError) await _replayConflictedEdits();
    final slots = secretMutationsFor?.call(state) ?? explicitSecretMutations;
    final credentialRoute = (
      providerSelection: state.apiProviderSelection,
      apiBaseUrl: state.apiBaseUrl,
      customApiBaseUrl: state.customApiBaseUrl,
      secretSlots: Set<SettingsSecretSlot>.of(slots),
    );
    final TranslationConfig next = update(state);
    if (!mounted) {
      return false;
    }
    state = next;
    onApplied?.call();
    if (debounce) {
      _sliderTimer?.cancel();
      final previous = _debouncedEdit;
      _debouncedEdit = previous == null
          ? update
          : (TranslationConfig config) => update(previous(config));
      final completion = _sliderCompletion ??= Completer<bool>();
      _sliderTimer = Timer(
        const Duration(milliseconds: 400),
        () => unawaited(flushSliderChanges()),
      );
      return completion.future;
    }
    final pendingSlider = _sliderCompletion;
    _sliderCompletion = null;
    _sliderTimer?.cancel();
    final debounced = _debouncedEdit;
    _debouncedEdit = null;
    // A non-debounced edit flushes a pending slider edit implicitly: the
    // recorded replay must compose both transformations, otherwise the
    // slider's value would be lost on conflict-replay.
    final effectiveUpdate = debounced == null
        ? update
        : (TranslationConfig config) => update(debounced(config));
    final result = await _saveUpdate(
      next,
      slots,
      pendingEdit: isConflictReplay
          // P2-#23: the replayed edit is already queued; it must not be
          // queued again. But a pending slider (debounced) edit swallowed
          // above is new — if this save conflicts, queue it separately so
          // the just-dragged value is not lost.
          ? (debounced == null
                ? null
                : (
                    update: debounced,
                    explicitSecretMutations: const <SettingsSecretSlot>{},
                    secretMutationsFor: null,
                    credentialRoute: (
                      providerSelection: state.apiProviderSelection,
                      apiBaseUrl: state.apiBaseUrl,
                      customApiBaseUrl: state.customApiBaseUrl,
                      secretSlots: const <SettingsSecretSlot>{},
                    ),
                  ))
          : (
              update: effectiveUpdate,
              explicitSecretMutations: explicitSecretMutations,
              secretMutationsFor: secretMutationsFor,
              credentialRoute: credentialRoute,
            ),
    );
    pendingSlider?.complete(result);
    return result;
  }

  Future<void> flushSliderChanges() async {
    _sliderTimer?.cancel();
    final completion = _sliderCompletion;
    _sliderCompletion = null;
    final debounced = _debouncedEdit;
    _debouncedEdit = null;
    if (completion == null) return;
    completion.complete(
      await _saveUpdate(
        state,
        const {},
        pendingEdit: debounced == null
            ? null
            : (
                update: debounced,
                explicitSecretMutations: const <SettingsSecretSlot>{},
                secretMutationsFor: null,
                credentialRoute: (
                  providerSelection: state.apiProviderSelection,
                  apiBaseUrl: state.apiBaseUrl,
                  customApiBaseUrl: state.customApiBaseUrl,
                  secretSlots: const <SettingsSecretSlot>{},
                ),
              ),
      ),
    );
  }

  Future<bool> _saveUpdate(
    TranslationConfig next,
    Set<SettingsSecretSlot> slots, {
    _ConflictedEdit? pendingEdit,
  }) async {
    try {
      await _persist(next, explicitSecretMutations: slots);
      // Successful saves must retain blocked or newly conflicted replays.
      _unresolvedSecretFailures.removeAll(slots);
      if (mounted) {
        // Secret read status can change even when the displayed value doesn't.
        if (slots.isNotEmpty) state = state.copyWith();
        if (_unresolvedSecretFailures.isEmpty) onSaveError?.call(null);
        if (slots.isNotEmpty && !_store.secretKeyRotated) {
          onSecretsRecovered?.call();
        }
      }
      return true;
    } catch (error) {
      if (error is SettingsSecretSaveException) {
        _unresolvedSecretFailures.addAll(error.failures.keys);
      } else {
        _unresolvedSecretFailures.addAll(slots);
      }
      if (error is SettingsWriteConflict) {
        // The store recorded this as a load error, so the next edit
        // auto-recovers via [_ensureConfigLoaded]; still surface the event
        // so the page can offer an explicit "reload" action right away.
        // Keep the edit as a pure transformation: [reloadSettings]
        // re-applies it onto the fresh snapshot instead of discarding it.
        if (pendingEdit != null) _conflictedEdits.add(pendingEdit);
        if (mounted) onWriteConflict?.call();
      }
      // The UI already shows the new value, so a silent failure would leave
      // it lying about what is actually persisted. Surface it instead of
      // letting the future go unhandled at the call site.
      if (mounted) onSaveError?.call(error);
      return false;
    }
  }

  /// Re-reads settings from disk. Used after a cross-instance write
  /// conflict: the other instance's values become visible and the stale
  /// snapshot is refreshed, so a subsequent save no longer conflicts.
  /// Edits whose save hit the conflict are re-applied onto the fresh
  /// snapshot (same shape as the automatic recovery path) instead of being
  /// silently discarded; replaying the closures (rather than restoring the
  /// failed state wholesale) keeps the other instance's unrelated changes
  /// intact. Clears the store's load error on success.
  Future<void> reloadSettings() async {
    await _pendingSave;
    // P2-#26: flush a pending slider (debounced) edit before reloading.
    // Otherwise _load() replaces the state with the on-disk snapshot and
    // the just-dragged value is lost — while the flush that fires later
    // still reports success for a value that was never persisted.
    await flushSliderChanges();
    if (!await _load()) return;
    await _replayConflictedEdits();
  }

  bool _isReplayBlockedByRouteChange(_ConflictedEdit edit) {
    final route = edit.credentialRoute;
    return route.secretSlots.any(
          (slot) => const {
            SettingsSecretSlot.legacy,
            SettingsSecretSlot.deepSeek,
            SettingsSecretSlot.custom,
          }.contains(slot),
        ) &&
        (route.providerSelection != state.apiProviderSelection ||
            route.apiBaseUrl != state.apiBaseUrl ||
            route.customApiBaseUrl != state.customApiBaseUrl);
  }

  Future<void> _replayConflictedEdits() async {
    if (_replayingConflictedEdits || !mounted) return;
    _replayingConflictedEdits = true;
    final List<_ConflictedEdit> pending = _conflictedEdits.toList();
    // P2-#22: which queue entries were (re-)applied to the state during
    // this pass. A later entry's successful save persists the whole state,
    // including the earlier entries' effects — those earlier entries are
    // then superseded and must be dropped. Otherwise the next retry would
    // re-apply the failed first entry's stale transformation over the
    // second entry's successful values.
    final List<bool> appliedInPass = List<bool>.filled(pending.length, false);
    // The state generation at pass start: a recovery load inside an entry's
    // _update discards earlier entries' optimistic effects (they were never
    // persisted), so superseded-dropping is only valid when the generation
    // is unchanged.
    final int passGeneration = _stateGeneration;
    int blocked = 0;
    try {
      for (int i = 0; i < pending.length; i++) {
        final edit = pending[i];
        if (!mounted) break;
        try {
          // Leave failed, blocked and unprocessed edits in their original
          // order, including when recovery cannot load a fresh snapshot.
          if (_store.configLoadError != null && !await _ensureConfigLoaded()) {
            break;
          }
          if (_isReplayBlockedByRouteChange(edit)) {
            blocked++;
            continue;
          }
          if (await _update(
            edit.update,
            explicitSecretMutations: edit.explicitSecretMutations,
            secretMutationsFor: edit.secretMutationsFor,
            // This edit is still queued; a new conflict must not duplicate it.
            isConflictReplay: true,
            onApplied: () => appliedInPass[i] = true,
          )) {
            _conflictedEdits.remove(edit);
            if (_stateGeneration == passGeneration) {
              // No recovery load replaced the state during this pass, so
              // this save persisted every earlier entry applied above:
              // their intent is durable and they are superseded. (Blocked
              // entries were never applied — their effects are not in the
              // saved state — so they stay queued.)
              for (int j = 0; j < i; j++) {
                if (appliedInPass[j]) {
                  _conflictedEdits.remove(pending[j]);
                }
              }
            }
          }
        } catch (error) {
          if (mounted) onSaveError?.call(error);
          break;
        }
      }
    } finally {
      _replayingConflictedEdits = false;
      if (blocked > 0 && mounted) onReplayBlocked?.call();
    }
  }

  /// Explicitly accepts the current service route for queued credential edits.
  Future<void> confirmBlockedConflictReplays() async {
    if (!mounted) return;
    for (int i = 0; i < _conflictedEdits.length; i++) {
      final edit = _conflictedEdits[i];
      _conflictedEdits[i] = (
        update: edit.update,
        explicitSecretMutations: edit.explicitSecretMutations,
        secretMutationsFor: edit.secretMutationsFor,
        credentialRoute: (
          providerSelection: state.apiProviderSelection,
          apiBaseUrl: state.apiBaseUrl,
          customApiBaseUrl: state.customApiBaseUrl,
          secretSlots: Set<SettingsSecretSlot>.of(
            edit.secretMutationsFor?.call(state) ??
                edit.explicitSecretMutations,
          ),
        ),
      );
    }
    await _replayConflictedEdits();
  }

  /// Discards queued conflict edits, including blocked credential replays.
  void discardBlockedConflictReplays() => _conflictedEdits.clear();

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

  Future<bool> setTargetLanguage(String value) =>
      _update((config) => config.copyWith(targetLanguage: value.trim()));

  Future<void> setBilingual(bool value) =>
      _update((config) => config.copyWith(bilingual: value));

  Future<void> applyTuningPreset(TranslationTuningPreset preset) =>
      _update(preset.applyTo);

  Future<void> setChunkSize(double value) => _update(
    (config) => config.copyWith(chunkSize: value.round()),
    debounce: true,
  );

  Future<void> setMaxConcurrent(double value) => _update(
    (config) => config.copyWith(maxConcurrent: value.round()),
    debounce: true,
  );

  Future<void> setTimeoutSeconds(double value) => _update(
    (config) => config.copyWith(timeoutSeconds: value.round()),
    debounce: true,
  );

  Future<void> setMaxRetries(double value) => _update(
    (config) => config.copyWith(maxRetries: value.round()),
    debounce: true,
  );

  Future<void> setRetryDelaySeconds(double value) => _update(
    (config) => config.copyWith(retryDelaySeconds: value.round()),
    debounce: true,
  );

  Future<bool> setOutputSuffix(String value) =>
      _update((config) => config.copyWith(outputSuffix: value.trim()));

  Future<void> setResidualQualityCheck(bool value) =>
      _update((config) => config.copyWith(residualQualityCheck: value));

  Future<void> setStyleProfileEnabled(bool value) =>
      _update((config) => config.copyWith(styleProfileEnabled: value));

  Future<void> setTextScale(double value) => _update(
    (config) => config.copyWith(textScale: value.clamp(0.9, 1.3)),
    debounce: true,
  );

  Future<bool> setLockedGlossary(String value) =>
      _update((config) => config.copyWith(lockedGlossary: value));

  Future<bool> setHttpProxy(String value) => _update(
    (config) => config.copyWith(httpProxy: value.trim()),
    explicitSecretMutations: const {SettingsSecretSlot.proxy},
  );

  Future<void> applyApiProviderPreset(ApiProviderPreset preset) =>
      _update((config) {
        providerSelectionRevision++;
        return preset.applyTo(config);
      });

  Future<void> reduceConcurrencyForRateLimit() => _update((config) {
    final int next = (config.maxConcurrent - 1).clamp(1, 8);
    return config.copyWith(maxConcurrent: next);
  });

  @override
  void dispose() {
    unawaited(flushSliderChanges());
    super.dispose();
  }
}

class ConnectionTestController extends StateNotifier<AsyncValue<String?>> {
  ConnectionTestController(this._repository)
    : super(const AsyncData<String?>(null));

  final TranslationRepository _repository;
  int _revision = 0;
  CancelToken? _probeCancelToken;

  Future<void> run(TranslationConfig config) async {
    if (!mounted) {
      return;
    }
    final revision = ++_revision;
    _probeCancelToken?.cancel();
    final token = _probeCancelToken = CancelToken();
    state = const AsyncLoading<String?>();
    try {
      final String result = await TranslationApiClient.runWithProbeCancelToken(
        token,
        () => _repository.testConnection(config: config),
      );
      if (!mounted || revision != _revision) {
        return;
      }
      // P1-#5: a successful probe response can echo the request, including
      // the current API key — redact it like the error path does, so the
      // displayed result can never leak the key via screenshot or copy.
      state = AsyncData<String?>(
        SensitiveText.redact(result, configuredApiKey: config.apiKey),
      );
    } catch (error, stackTrace) {
      if (!mounted || revision != _revision) {
        return;
      }
      final ConnectionDiagnostic diagnostic = ConnectionDiagnostic.fromError(
        error,
        config: config,
      );
      state = AsyncError<String?>(diagnostic.message, stackTrace);
    } finally {
      if (identical(_probeCancelToken, token)) _probeCancelToken = null;
    }
  }

  void clear() {
    if (!mounted) {
      return;
    }
    _revision++;
    _probeCancelToken?.cancel();
    _probeCancelToken = null;
    state = const AsyncData<String?>(null);
  }

  @override
  void dispose() {
    _revision++;
    _probeCancelToken?.cancel();
    _probeCancelToken = null;
    super.dispose();
  }
}
