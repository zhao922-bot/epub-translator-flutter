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
        onReplayProgressChanged: (value) =>
            ref.read(settingsReplayInProgressProvider.notifier).state = value,
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
final settingsReplayInProgressProvider = StateProvider<bool>((ref) => false);

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
  // P2-#28: field names this transformation modifies, computed at queue
  // time by diffing. Used to drop stale earlier entries when a later entry
  // successfully persists newer values for the same fields.
  Set<String> changedFields,
  int editGeneration,
  ({
    ApiProviderSelection providerSelection,
    String apiBaseUrl,
    String customApiBaseUrl,
    Set<SettingsSecretSlot> secretSlots,
  })
  credentialRoute,
});

/// Returns the names of [TranslationConfig] fields that differ between
/// [before] and [after]. Used by P2-#28 to detect when a later successful
/// replay supersedes an earlier queued edit touching the same fields.
Set<String> _changedFields(TranslationConfig before, TranslationConfig after) {
  final changed = <String>{};
  if (before.apiBaseUrl != after.apiBaseUrl) changed.add('apiBaseUrl');
  if (before.apiKey != after.apiKey) changed.add('apiKey');
  if (before.model != after.model) changed.add('model');
  if (before.apiProviderSelection != after.apiProviderSelection) {
    changed.add('apiProviderSelection');
  }
  if (before.deepseekApiKey != after.deepseekApiKey) {
    changed.add('deepseekApiKey');
  }
  if (before.customApiBaseUrl != after.customApiBaseUrl) {
    changed.add('customApiBaseUrl');
  }
  if (before.customApiKey != after.customApiKey) changed.add('customApiKey');
  if (before.customModel != after.customModel) changed.add('customModel');
  if (before.uiLanguage != after.uiLanguage) changed.add('uiLanguage');
  if (before.themeMode != after.themeMode) changed.add('themeMode');
  if (before.targetLanguage != after.targetLanguage) {
    changed.add('targetLanguage');
  }
  if (before.bilingual != after.bilingual) changed.add('bilingual');
  if (before.chunkSize != after.chunkSize) changed.add('chunkSize');
  if (before.maxConcurrent != after.maxConcurrent) {
    changed.add('maxConcurrent');
  }
  if (before.timeoutSeconds != after.timeoutSeconds) {
    changed.add('timeoutSeconds');
  }
  if (before.maxRetries != after.maxRetries) changed.add('maxRetries');
  if (before.retryDelaySeconds != after.retryDelaySeconds) {
    changed.add('retryDelaySeconds');
  }
  if (before.outputSuffix != after.outputSuffix) changed.add('outputSuffix');
  if (before.residualQualityCheck != after.residualQualityCheck) {
    changed.add('residualQualityCheck');
  }
  if (before.styleProfileEnabled != after.styleProfileEnabled) {
    changed.add('styleProfileEnabled');
  }
  if (before.textScale != after.textScale) changed.add('textScale');
  if (before.lockedGlossary != after.lockedGlossary) {
    changed.add('lockedGlossary');
  }
  if (before.httpProxy != after.httpProxy) changed.add('httpProxy');
  return changed;
}

/// Field names that carry secrets. P2-#28's field-overlap drop never
/// removes entries touching these; the stricter P2-#27 persisted-slots
/// check owns secret superseding.
const _secretRelatedFields = <String>{
  'apiKey',
  'deepseekApiKey',
  'customApiKey',
  'httpProxy',
};

class SettingsController extends StateNotifier<TranslationConfig> {
  SettingsController(
    this._store, {
    this.onSaveError,
    this.onCorruptReset,
    this.onSecretKeyRotated,
    this.onSecretsRecovered,
    this.onWriteConflict,
    this.onReplayBlocked,
    this.onReplayProgressChanged,
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
  final void Function(bool)? onReplayProgressChanged;
  final Set<SettingsSecretSlot> _unresolvedSecretFailures = {};
  Timer? _sliderTimer;
  Completer<bool>? _sliderCompletion;
  late final Future<void> _initialLoad;
  Future<void> _pendingSave = Future<void>.value();
  Future<void>? _recoveryLoad;
  bool _recoveryLoadPhase = false;
  Future<bool>? _sliderFlushInProgress;
  int _noticeRevision = 0;
  int _commitGeneration = 0;
  final Map<SettingsSecretSlot, ({String value, int generation})>
  _lastCommittedSecrets = {};

  /// In-flight [reloadSettings] future, if any (P2-#36). Concurrent reloads
  /// join it instead of starting a second load.
  Future<bool>? _reloadInProgress;

  /// Completes when the load phase of the in-flight [reloadSettings]
  /// finishes (P2-#36). A new edit arriving mid-load waits for the fresh
  /// snapshot instead of interleaving with [_load] (applied to the old
  /// snapshot then discarded, or racing the conflict check). Parked edits
  /// are released as soon as the load finishes — before the conflict
  /// replay runs — so a debounced slider edit is still pending when the
  /// replay swallows it (P2-#23), instead of arriving after the whole
  /// reload and racing the next one.
  Completer<void>? _reloadLoadPhase;

  /// Edits whose save failed with [SettingsWriteConflict]. [reloadSettings]
  /// re-applies them onto the freshly loaded snapshot instead of silently
  /// discarding the user's work. Automatic load recovery uses the same replay
  /// path; blocked credential edits remain queued until confirmed or discarded.
  final List<_ConflictedEdit> _conflictedEdits = <_ConflictedEdit>[];
  bool _replayingConflictedEdits = false;
  bool get isReplayingConflictedEdits => _replayingConflictedEdits;

  /// Slider setters are absolute and independent: retain just the latest
  /// setter per field, including no-op setters. Never nest closures per event.
  final _debouncedSetters = <String, TranslationConfig Function(TranslationConfig)>{};
  TranslationConfig Function(TranslationConfig)? get _debouncedEdit {
    if (_debouncedSetters.isEmpty) return null;
    final setters = _debouncedSetters.values.toList(growable: false);
    return (config) {
      for (final setter in setters) {
        config = setter(config);
      }
      return config;
    };
  }

  /// P2-#28: field names modified by [_debouncedEdit], computed when the
  /// debounced edit is recorded. Needed when the flush save conflicts and
  /// the transformation is queued for replay.
  Set<String>? _debouncedChangedFields;

  int providerSelectionRevision = 0;
  int credentialDiscardRevision = 0;
  TranslationConfig? _lastLoadedConfig;

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
    _lastLoadedConfig = loaded;
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
    if (!_recoveryLoadPhase && _store.configLoadError == null) return mounted;
    _recoveryLoadPhase = true;
    final recovery = _recoveryLoad ??= _recoverConfig();
    try {
      await recovery;
    } finally {
      if (identical(_recoveryLoad, recovery)) {
        _recoveryLoad = null;
        _recoveryLoadPhase = false;
      }
    }
    return mounted && _store.configLoadError == null;
  }

  Future<void> _recoverConfig() async {
    // Ordinary recovery replaces the optimistic slider state. Mid-replay
    // sliders are newer than the queue and must still be swallowed (P2-#29).
    if (!_replayingConflictedEdits) {
      _sliderTimer?.cancel();
      _debouncedSetters.clear();
      _debouncedChangedFields = null;
      _sliderCompletion?.complete(false);
      _sliderCompletion = null;
    }
    await _load();
  }

  Future<bool> _update(
    TranslationConfig Function(TranslationConfig config) update, {
    Set<SettingsSecretSlot> explicitSecretMutations =
        const <SettingsSecretSlot>{},
    Set<SettingsSecretSlot> Function(TranslationConfig)? secretMutationsFor,
    String? debounceField,
    bool isConflictReplay = false,
    // P2-#22: invoked synchronously right after the transformation is
    // applied to the state, so the replay loop can tell which queued edits
    // actually contributed to a later successful save.
    void Function()? onApplied,
    // P2-#28: invoked (replay path only) with the slider field names
    // swallowed by this update. The replay loop merges them into
    // justChanged: the save below persists them too, so earlier queued
    // entries touching the same fields are stale and must be dropped.
    void Function(Set<String> swallowedFields)? onSwallowedSlider,
  }) async {
    if (!_loaded) await _initialLoad;
    // C-P1-1: capture the credential target before reload or recovery changes state.
    final slots = secretMutationsFor?.call(state) ?? explicitSecretMutations;
    final credentialRoute = (
      providerSelection: state.apiProviderSelection,
      apiBaseUrl: state.apiBaseUrl,
      customApiBaseUrl: state.customApiBaseUrl,
      secretSlots: Set<SettingsSecretSlot>.of(slots),
    );
    // P2-#36: an edit arriving while reloadSettings is reading must not
    // interleave with the load (applied to the old snapshot then discarded
    // by _load, or racing the conflict check). Wait for the load phase,
    // then apply onto the fresh snapshot. The wait ends before the
    // conflict replay runs: a debounced slider edit must still be pending
    // when the replay swallows it (P2-#23) — parking it for the whole
    // reload lets it resume after the reload finished and race the next
    // reload instead, losing the value. Conflict replays run inside the
    // reload itself and must not wait on it.
    if (!isConflictReplay) {
      final Future<void>? ongoingLoad = _reloadLoadPhase?.future;
      if (ongoingLoad != null) await ongoingLoad;
    }
    if (!mounted) {
      return false;
    }
    final bool hadLoadError =
        _recoveryLoadPhase || _store.configLoadError != null;
    if (hadLoadError && !await _ensureConfigLoaded()) {
      return false;
    }
    if (hadLoadError) await _replayConflictedEdits();
    if (!mounted) return false;
    // Recovery or a reload can change the service while this edit waits.
    // Keep the original credential target until the user confirms it.
    if (slots.isNotEmpty && _isCredentialRouteChanged(credentialRoute)) {
      _conflictedEdits.add((
        update: update,
        explicitSecretMutations: explicitSecretMutations,
        secretMutationsFor: secretMutationsFor,
        changedFields: _changedFields(state, update(state)),
        editGeneration: _commitGeneration,
        credentialRoute: credentialRoute,
      ));
      _noticeRevision++;
      onReplayBlocked?.call();
      return false;
    }
    final TranslationConfig prevState = state;
    final TranslationConfig next = update(prevState);
    if (!mounted) {
      return false;
    }
    state = next;
    onApplied?.call();
    if (debounceField != null) {
      _sliderTimer?.cancel();
      _debouncedSetters[debounceField] = update;
      // P2-#28: accumulate even fields subsequently changed back.
      final updateFields = _changedFields(prevState, next);
      (_debouncedChangedFields ??= <String>{}).addAll(updateFields);
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
    _debouncedSetters.clear();
    final debouncedFields = _debouncedChangedFields;
    _debouncedChangedFields = null;
    // P2-#28: report the slider fields swallowed by this update. In the
    // replay path the save below persists them as well, so the replay loop
    // merges them into justChanged — otherwise an earlier queued entry
    // touching the same slider field would survive and revert the newer
    // value on the next replay.
    if (isConflictReplay) {
      onSwallowedSlider?.call(debouncedFields ?? const <String>{});
    }
    // A non-debounced edit flushes a pending slider edit implicitly: the
    // recorded replay must compose both transformations, otherwise the
    // slider's value would be lost on conflict-replay.
    //
    // P2-#29: during a conflict replay, the queued [update] is older than
    // the just-swallowed slider edit — apply the slider last so the newer
    // user intent wins. (In the non-replay path the non-debounced edit is
    // newer, so the original order stands.)
    final effectiveUpdate = debounced == null
        ? update
        : isConflictReplay
            ? (TranslationConfig config) => debounced(update(config))
            : (TranslationConfig config) => update(debounced(config));
    // P2-#29: the swallowed slider transformation must also be applied to
    // the state being saved, not just recorded for replay — otherwise the
    // save persists the pre-slider value. Slider setters are absolute, so
    // re-applying the composed transformation onto the pre-update snapshot
    // is idempotent.
    final TranslationConfig effectiveNext = debounced == null
        ? next
        : effectiveUpdate(prevState);
    if (debounced != null) state = effectiveNext;
    final result = await _saveUpdate(
      effectiveNext,
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
                    // P2-#28: use the fields recorded when the slider edit
                    // was made; recomputing against prevState now would be
                    // empty (the slider value is already in prevState).
                    changedFields: debouncedFields ?? const <String>{},
                    editGeneration: _commitGeneration,
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
              // P2-#28: effectiveNext is effectiveUpdate(prevState). Diff
              // against the pre-swallow [next] and union the slider fields
              // recorded when the debounced edit was made: prevState
              // already holds the slider's optimistic value, so diffing
              // effectiveNext against prevState alone would miss the
              // slider fields.
              changedFields: _changedFields(
                prevState,
                next,
              ).union(debouncedFields ?? const <String>{}),
              editGeneration: _commitGeneration,
              credentialRoute: credentialRoute,
            ),
    );
    pendingSlider?.complete(result);
    return result;
  }

  /// Flushes a pending debounced slider edit. Returns true when there was
  /// nothing to flush or the save succeeded. On failure the transformation
  /// was already cleared; a conflict queues it for replay, any other error
  /// surfaces via [onSaveError] and the caller must not proceed as if the
  /// value were persisted (P2-#30).
  Future<bool> flushSliderChanges() {
    final ongoing = _sliderFlushInProgress;
    if (ongoing != null) return ongoing;
    final flush = _flushSliderChanges();
    _sliderFlushInProgress = flush;
    return flush.whenComplete(() {
      if (identical(_sliderFlushInProgress, flush)) {
        _sliderFlushInProgress = null;
      }
    });
  }

  Future<bool> _flushSliderChanges() async {
    bool ok = true;
    while (true) {
      _sliderTimer?.cancel();
      final completion = _sliderCompletion;
      _sliderCompletion = null;
      final debounced = _debouncedEdit;
      _debouncedSetters.clear();
      final debouncedFields = _debouncedChangedFields;
      _debouncedChangedFields = null;
      if (debounced == null) {
        completion?.complete(true);
        return ok;
      }
      final bool step = await _saveUpdate(
        state,
        const {},
        pendingEdit: (
          update: debounced,
          explicitSecretMutations: const <SettingsSecretSlot>{},
          secretMutationsFor: null,
          // P2-#28: fields recorded when the slider edit was made.
          changedFields: debouncedFields ?? const <String>{},
          editGeneration: _commitGeneration,
          credentialRoute: (
            providerSelection: state.apiProviderSelection,
            apiBaseUrl: state.apiBaseUrl,
            customApiBaseUrl: state.customApiBaseUrl,
            secretSlots: const <SettingsSecretSlot>{},
          ),
        ),
      );
      completion?.complete(step);
      ok = ok && step;
      // Slider edits arriving during the save belong to the same flush,
      // but each completion reports the result of its own batch.
    }
  }

  Future<bool> _saveUpdate(
    TranslationConfig next,
    Set<SettingsSecretSlot> slots, {
    _ConflictedEdit? pendingEdit,
  }) async {
    final noticeRevision = _noticeRevision;
    final olderEdits = _conflictedEdits.toList();
    try {
      await _persist(next, explicitSecretMutations: slots);
      // Successful saves must retain blocked or newly conflicted replays.
      _unresolvedSecretFailures.removeAll(slots);
      final persisted = _store.lastPersistedSecretSlots;
      _commitGeneration++;
      for (final slot in persisted) {
        _lastCommittedSecrets[slot] = (
          value: switch (slot) {
            SettingsSecretSlot.legacy => next.apiKey,
            SettingsSecretSlot.deepSeek => next.deepseekApiKey,
            SettingsSecretSlot.custom => next.customApiKey,
            SettingsSecretSlot.proxy => next.httpProxy,
          },
          generation: _commitGeneration,
        );
      }
      // C-07: only the slots this save explicitly targeted may clear their
      // unresolved failures (via removeAll(slots) above). Slots that merely
      // landed through an implicit retry (e.g. a previously failed key
      // re-persisted during an unrelated theme save) must NOT clear the
      // notice: it stays until the user's explicit retry of that action.
      if (pendingEdit != null) {
        final fields = pendingEdit.changedFields;
        _conflictedEdits.removeWhere((edit) =>
            olderEdits.contains(edit) &&
            !_isReplayBlockedByRouteChange(edit) &&
            edit.credentialRoute.secretSlots.every(persisted.contains) &&
            edit.changedFields.any(fields.contains));
      }
      if (mounted) {
        // Secret read status can change even when the displayed value doesn't.
        if (slots.isNotEmpty) state = state.copyWith();
        if (_unresolvedSecretFailures.isEmpty &&
            noticeRevision == _noticeRevision) {
          onSaveError?.call(null);
        }
        if (slots.isNotEmpty && !_store.secretKeyRotated) {
          onSecretsRecovered?.call();
        }
      }
      return true;
    } catch (error) {
      _noticeRevision++;
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
  ///
  /// Returns true when the load (and replay) completed. A failed
  /// pre-reload slider flush aborts the reload (P2-#30): the transformation
  /// was already cleared and cannot be retried, so replacing the state via
  /// _load() would silently discard it. The flush failure was already
  /// surfaced via onSaveError.
  ///
  /// While a reload is loading, new edits wait for the fresh snapshot
  /// instead of interleaving with the load (P2-#36). Concurrent
  /// reloadSettings calls join the in-flight one.
  Future<bool> reloadSettings() async {
    final Future<bool>? ongoing = _reloadInProgress;
    if (ongoing != null) return ongoing;
    final Completer<bool> done = Completer<bool>();
    _reloadInProgress = done.future;
    final Completer<void> loadPhase = Completer<void>();
    _reloadLoadPhase = loadPhase;
    bool ok = false;
    try {
      final ongoingFlush = _sliderFlushInProgress;
      await _pendingSave;
      if (ongoingFlush != null && !await ongoingFlush) return false;
      // P2-#26: flush a pending slider (debounced) edit before reloading.
      // Otherwise _load() replaces the state with the on-disk snapshot and
      // the just-dragged value is lost — while the flush that fires later
      // still reports success for a value that was never persisted.
      // P2-#30: abort when the flush fails.
      if (!await flushSliderChanges()) return false;
      final bool loaded = await _load();
      // P2-#36: the fresh snapshot is in — release parked edits before the
      // conflict replay runs, so a debounced slider edit is still pending
      // when the replay swallows it (P2-#23).
      _reloadLoadPhase = null;
      if (!loadPhase.isCompleted) loadPhase.complete();
      if (!loaded) return false;
      await _replayConflictedEdits();
      ok = true;
      return true;
    } finally {
      _reloadLoadPhase = null;
      if (!loadPhase.isCompleted) loadPhase.complete();
      _reloadInProgress = null;
      if (!done.isCompleted) done.complete(ok);
    }
  }

  bool _isReplayBlockedByRouteChange(_ConflictedEdit edit) =>
      _isCredentialRouteChanged(edit.credentialRoute);

  bool _isCredentialRouteChanged(
    ({
      ApiProviderSelection providerSelection,
      String apiBaseUrl,
      String customApiBaseUrl,
      Set<SettingsSecretSlot> secretSlots,
    })
    route,
  ) {
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
    onReplayProgressChanged?.call(true);
    final List<_ConflictedEdit> pending = _conflictedEdits.toList();
    // P2-#22: which queue entries were (re-)applied to the state during
    // this pass, and at which state generation. A later entry's successful
    // save persists the whole state, including the earlier entries'
    // effects — those earlier entries are then superseded and must be
    // dropped. Otherwise the next retry would re-apply the failed first
    // entry's stale transformation over the second entry's successful
    // values.
    // P2-#28: record the per-entry generation, not just a pass-start
    // snapshot. A recovery load mid-pass discards earlier entries'
    // optimistic effects (they were never persisted), so superseded-
    // dropping is only valid for entries applied at the current generation
    // — a fixed pass-start generation would wrongly keep entries that were
    // applied after the load and then superseded, and their next replay
    // would change the new value back to the old one.
    final List<int?> appliedGeneration = List<int?>.filled(
      pending.length,
      null,
    );
    int blocked = 0;
    try {
      for (int i = 0; i < pending.length; i++) {
        final edit = pending[i];
        // New saves arriving during replay can supersede unprocessed entries.
        await _pendingSave;
        if (!mounted) break;
        if (!_conflictedEdits.contains(edit)) continue;
        try {
          // Leave failed, blocked and unprocessed edits in their original
          // order, including when recovery cannot load a fresh snapshot.
          if (_store.configLoadError != null && !await _ensureConfigLoaded()) {
            break;
          }
          if (!_conflictedEdits.contains(edit)) continue;
          if (_isReplayBlockedByRouteChange(edit)) {
            blocked++;
            continue;
          }
          // P2-#28: slider fields swallowed by this replayed update. The
          // successful save persists them too, so they join justChanged
          // below — otherwise an earlier entry touching the same slider
          // field would survive and revert the newer value next replay.
          Set<String> swallowedSliderFields = const <String>{};
          if (await _update(
            edit.update,
            explicitSecretMutations: edit.explicitSecretMutations,
            secretMutationsFor: edit.secretMutationsFor,
            // This edit is still queued; a new conflict must not duplicate it.
            isConflictReplay: true,
            onApplied: () => appliedGeneration[i] = _stateGeneration,
            onSwallowedSlider: (fields) => swallowedSliderFields = fields,
          )) {
            final toRemove = <_ConflictedEdit>{edit};
            // P2-#27: only drop earlier entries whose effects this save
            // actually persisted. A key entry skipped as unreadable (its
            // slot read failed) is not persisted by a later non-credential
            // save — dropping it would lose the key edit.
            final Set<SettingsSecretSlot> persisted =
                _store.lastPersistedSecretSlots;
            // P2-#28: fields this successful save changed (excluding
            // secret-related fields, which the P2-#27 check owns), plus
            // slider fields swallowed during this replay.
            final Set<String> justChanged = {
              ...edit.changedFields,
              ...swallowedSliderFields,
            }.difference(_secretRelatedFields);
            for (int j = 0; j < i; j++) {
              final other = pending[j];
              if (_isReplayBlockedByRouteChange(other)) continue;
              // P2-#28: drop earlier entries that touch the same non-secret
              // fields, whether or not they were applied in this pass. Their
              // transformations are stale — replaying them would revert the
              // newer values just persisted.
              final bool staleByFieldOverlap =
                  other.credentialRoute.secretSlots.every(persisted.contains) &&
                  justChanged.isNotEmpty &&
                  other.changedFields.any(justChanged.contains);
              final int? appliedAt = appliedGeneration[j];
              if (staleByFieldOverlap ||
                  (appliedAt != null &&
                      appliedAt == _stateGeneration &&
                      other.credentialRoute.secretSlots.every(
                        persisted.contains,
                      ))) {
                toRemove.add(other);
              }
            }
            // Remove before the next await/contains check; pending is a snapshot.
            _conflictedEdits.removeWhere(toRemove.contains);
          }
        } catch (error) {
          if (mounted) onSaveError?.call(error);
          break;
        }
      }
    } finally {
      _replayingConflictedEdits = false;
      if (mounted) {
        if (blocked > 0) {
          _noticeRevision++;
          onReplayBlocked?.call();
        }
        onReplayProgressChanged?.call(false);
      }
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
        changedFields: edit.changedFields,
        editGeneration: edit.editGeneration,
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

  /// Discards only the queued conflict edits currently blocked by a route
  /// change (C-1). Non-blocked queued edits are retained: the UI banner
  /// promises to discard "these" (the N blocked credential edits), and the
  /// method name says "blocked" — clearing the whole queue would silently
  /// drop unrelated pending edits.
  void discardBlockedConflictReplays() {
    if (!mounted) return;
    final blocked = _conflictedEdits
        .where(_isReplayBlockedByRouteChange)
        .toList();
    if (blocked.isEmpty) return;
    final slots = <SettingsSecretSlot>{
      for (final edit in blocked) ...edit.credentialRoute.secretSlots,
    };
    final touchGenerations = <SettingsSecretSlot, int>{};
    for (final edit in blocked) {
      for (final slot in edit.credentialRoute.secretSlots) {
        final previous = touchGenerations[slot];
        if (previous == null || edit.editGeneration > previous) {
          touchGenerations[slot] = edit.editGeneration;
        }
      }
    }
    _conflictedEdits.removeWhere(blocked.contains);
    // C-P1-4: failed commits remain dirty in the text field and may also
    // remain in optimistic state. Discard both, using the fresh load that
    // established the changed route, unless a newer commit saved the slot.
    final loaded = _lastLoadedConfig!;
    String restoredSecret(SettingsSecretSlot slot, String loadedValue) {
      final committed = _lastCommittedSecrets[slot];
      return committed != null && committed.generation > touchGenerations[slot]!
          ? committed.value
          : loadedValue;
    }

    credentialDiscardRevision++;
    state = state.copyWith(
      apiKey: slots.contains(SettingsSecretSlot.legacy)
          ? restoredSecret(SettingsSecretSlot.legacy, loaded.apiKey)
          : null,
      deepseekApiKey: slots.contains(SettingsSecretSlot.deepSeek)
          ? restoredSecret(SettingsSecretSlot.deepSeek, loaded.deepseekApiKey)
          : null,
      customApiKey: slots.contains(SettingsSecretSlot.custom)
          ? restoredSecret(SettingsSecretSlot.custom, loaded.customApiKey)
          : null,
      httpProxy: slots.contains(SettingsSecretSlot.proxy)
          ? restoredSecret(SettingsSecretSlot.proxy, loaded.httpProxy)
          : null,
    );
  }

  /// Number of queued conflict edits currently blocked by a route change
  /// (P2-#37). Surfaced so the settings page can display the blocked
  /// credential queue instead of leaving the user unaware.
  int get blockedReplayCount =>
      _conflictedEdits.where(_isReplayBlockedByRouteChange).length;

  Future<bool> setApiBaseUrl(String value) async {
    if (!_loaded) await _initialLoad;
    if (!mounted) return false;
    // P1-#5: capture the active key at edit time. The direct call keeps the
    // N8 behavior (the user's current key moves to the custom slot), but the
    // replay closure must not re-read key material from the fresh snapshot —
    // after a cross-instance conflict that key may belong to another
    // instance, and binding it here would send another instance's
    // credential to the user-typed address.
    final String editTimeKey = state.apiKey;
    final String editTimeModel = state.model;
    return _update((config) {
      final String nextUrl = value.trim();
      return config.copyWith(
        apiProviderSelection: ApiProviderSelection.custom,
        apiBaseUrl: nextUrl,
        customApiBaseUrl: nextUrl,
        customApiKey: editTimeKey,
        apiKey: editTimeKey,
        customModel: editTimeModel,
      );
    });
  }

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
    debounceField: 'chunkSize',
  );

  Future<void> setMaxConcurrent(double value) => _update(
    (config) => config.copyWith(maxConcurrent: value.round()),
    debounceField: 'maxConcurrent',
  );

  Future<void> setTimeoutSeconds(double value) => _update(
    (config) => config.copyWith(timeoutSeconds: value.round()),
    debounceField: 'timeoutSeconds',
  );

  Future<void> setMaxRetries(double value) => _update(
    (config) => config.copyWith(maxRetries: value.round()),
    debounceField: 'maxRetries',
  );

  Future<void> setRetryDelaySeconds(double value) => _update(
    (config) => config.copyWith(retryDelaySeconds: value.round()),
    debounceField: 'retryDelaySeconds',
  );

  Future<bool> setOutputSuffix(String value) =>
      _update((config) => config.copyWith(outputSuffix: value.trim()));

  Future<void> setResidualQualityCheck(bool value) =>
      _update((config) => config.copyWith(residualQualityCheck: value));

  Future<void> setStyleProfileEnabled(bool value) =>
      _update((config) => config.copyWith(styleProfileEnabled: value));

  Future<void> setTextScale(double value) => _update(
    (config) => config.copyWith(textScale: value.clamp(0.9, 1.3)),
    debounceField: 'textScale',
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
