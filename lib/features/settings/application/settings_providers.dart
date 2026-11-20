part of 'settings_controller.dart';

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
            notifier.state = null;
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
            previous.useStreamingApi != next.useStreamingApi ||
            previous.reasoningEffort != next.reasoningEffort ||
            previous.thinkingMode != next.thinkingMode ||
            previous.customReasoning != next.customReasoning ||
            previous.tokenSavingMode != next.tokenSavingMode ||
            previous.httpProxy != next.httpProxy ||
            previous.targetLanguage != next.targetLanguage) {
          controller.clear();
        }
      });
      return controller;
    });
