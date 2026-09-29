import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/platform/android_service_bridge.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../../../shared/security/sensitive_text.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/models/actionable_error.dart';
import '../domain/models/chapter_selection_preset.dart';
import '../domain/models/translation_config.dart';
import '../domain/models/inspected_chapter.dart';
import '../domain/models/inspection_result.dart';
import '../domain/models/translation_job.dart';
import '../domain/models/translation_run_estimate.dart';
import '../domain/models/translation_run_result.dart';
import '../domain/models/translation_style_profile.dart';
import '../domain/repositories/translation_repository.dart';
import '../infrastructure/job_history_store.dart';
import '../infrastructure/session_path_store.dart';
import '../infrastructure/translation_cache_store.dart';
import '../infrastructure/repositories/epub_translation_repository.dart';

final translationRepositoryProvider = Provider<TranslationRepository>(
  (ref) => EpubTranslationRepository(
    cacheStore: ref.watch(translationCacheStoreProvider),
  ),
);

final jobHistoryStoreProvider = Provider<JobHistoryStore>(
  (ref) => JobHistoryStore(),
);

final sessionPathStoreProvider = Provider<SessionPathStore>(
  (ref) => SessionPathStore(),
);

final translationDashboardProvider =
    StateNotifierProvider<
      TranslationDashboardController,
      TranslationDashboardState
    >((ref) {
      final SettingsController settingsController = ref.read(
        settingsProvider.notifier,
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: ref.watch(translationRepositoryProvider),
            historyStore: ref.watch(jobHistoryStoreProvider),
            pathStore: ref.watch(sessionPathStoreProvider),
            settingsReady: () => settingsController.ready,
          )..syncSettings(ref.read(settingsProvider));
      ref.listen<TranslationConfig>(settingsProvider, (
        TranslationConfig? _,
        TranslationConfig next,
      ) {
        controller.syncSettings(next);
      });
      return controller;
    });

const Object _unset = Object();
const int _maxLogLines = 400;

bool _isTranslationRunPhase(TranslationJobPhase phase) {
  return phase == TranslationJobPhase.translation ||
      phase == TranslationJobPhase.cacheRestoration;
}

int _confirmedProgressBlocks(TranslationJob job) {
  return job.phase == TranslationJobPhase.cacheRestoration
      ? job.cachedBlocks
      : job.completedBlocks;
}

class TranslationDashboardState {
  const TranslationDashboardState({
    required this.config,
    required this.inputPath,
    required this.outputDirectory,
    required this.job,
    required this.jobHistory,
    required this.runEstimate,
    required this.inspectedChapters,
    required this.logs,
    this.actionableError,
    this.styleProfile = TranslationStyleProfile.empty,
    this.styleProfileConfirmed = false,
    this.isGeneratingStyleProfile = false,
    // H2: mirrors of the controller's _isSaving/_isSharing re-entrancy
    // guards so the UI can disable the buttons while a save/share runs.
    this.isSaving = false,
    this.isSharing = false,
    // C-M6: bumped every time a permanently-denied storage permission is
    // reported; UI layers can listen and show a Snackbar with an
    // "open app settings" action.
    this.permissionNoticeId = 0,
  });

  final TranslationConfig config;
  final String inputPath;
  final String outputDirectory;
  final TranslationJob? job;
  final List<TranslationJob> jobHistory;
  final TranslationRunEstimate? runEstimate;
  final List<InspectedChapter> inspectedChapters;
  final List<String> logs;
  final ActionableError? actionableError;
  final TranslationStyleProfile styleProfile;
  final bool styleProfileConfirmed;
  final bool isGeneratingStyleProfile;
  final bool isSaving;
  final bool isSharing;
  final int permissionNoticeId;

  bool get isRunActive {
    final TranslationJobStatus? status = job?.status;
    return status == TranslationJobStatus.queued ||
        status == TranslationJobStatus.running ||
        isGeneratingStyleProfile;
  }

  bool get hasStyleProfile => !styleProfile.isEmpty;

  /// When style profiles are enabled, translation should wait for confirmation.
  bool get requiresStyleProfileConfirmation =>
      config.styleProfileEnabled && !styleProfileConfirmed;

  factory TranslationDashboardState.initial() {
    return TranslationDashboardState(
      config: TranslationConfig.defaults(),
      inputPath: '',
      outputDirectory: '',
      job: null,
      jobHistory: const <TranslationJob>[],
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      logs: const <String>[],
      actionableError: null,
      styleProfile: TranslationStyleProfile.empty,
      styleProfileConfirmed: false,
      isGeneratingStyleProfile: false,
    );
  }

  TranslationDashboardState copyWith({
    TranslationConfig? config,
    String? inputPath,
    String? outputDirectory,
    Object? job = _unset,
    List<TranslationJob>? jobHistory,
    Object? runEstimate = _unset,
    List<InspectedChapter>? inspectedChapters,
    List<String>? logs,
    Object? actionableError = _unset,
    Object? styleProfile = _unset,
    bool? styleProfileConfirmed,
    bool? isGeneratingStyleProfile,
    bool? isSaving,
    bool? isSharing,
    int? permissionNoticeId,
  }) {
    return TranslationDashboardState(
      config: config ?? this.config,
      inputPath: inputPath ?? this.inputPath,
      outputDirectory: outputDirectory ?? this.outputDirectory,
      job: identical(job, _unset) ? this.job : job as TranslationJob?,
      jobHistory: jobHistory ?? this.jobHistory,
      runEstimate: identical(runEstimate, _unset)
          ? this.runEstimate
          : runEstimate as TranslationRunEstimate?,
      inspectedChapters: inspectedChapters ?? this.inspectedChapters,
      logs: logs == null ? this.logs : _trimLogs(logs),
      actionableError: identical(actionableError, _unset)
          ? this.actionableError
          : actionableError as ActionableError?,
      styleProfile: identical(styleProfile, _unset)
          ? this.styleProfile
          : styleProfile as TranslationStyleProfile,
      styleProfileConfirmed:
          styleProfileConfirmed ?? this.styleProfileConfirmed,
      isGeneratingStyleProfile:
          isGeneratingStyleProfile ?? this.isGeneratingStyleProfile,
      isSaving: isSaving ?? this.isSaving,
      isSharing: isSharing ?? this.isSharing,
      permissionNoticeId: permissionNoticeId ?? this.permissionNoticeId,
    );
  }

  static List<String> _trimLogs(List<String> logs) {
    if (logs.length <= _maxLogLines) {
      return logs;
    }
    return logs.sublist(logs.length - _maxLogLines);
  }
}

class _ResumeProgressHint {
  const _ResumeProgressHint({
    required this.completedBlocks,
    required this.totalBlocks,
  });

  final int completedBlocks;
  final int totalBlocks;
}

class TranslationDashboardController
    extends StateNotifier<TranslationDashboardState> {
  TranslationDashboardController({
    required this.repository,
    this.historyStore,
    this.pathStore,
    this.settingsReady,
    this.defaultOutputDirectoryResolver,
    this.epubPickerOverride,
    this.directoryPickerOverride,
    this.windowsPathObserverOverride,
  }) : super(TranslationDashboardState.initial()) {
    _initialJobHistoryLoad = _loadJobHistory();
    _loadSessionPaths();
    _checkPendingForegroundServiceTimeout();
  }

  final TranslationRepository repository;
  final JobHistoryStore? historyStore;
  final SessionPathStore? pathStore;
  final Future<void> Function()? settingsReady;
  final Future<String> Function(String? inputPath)?
  defaultOutputDirectoryResolver;
  // Test seams: override the native file pickers so re-entrancy can be tested
  // without a real file dialog.
  final Future<String?> Function({
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  })?
  epubPickerOverride;
  final Future<String?> Function({
    void Function(WindowsPathNotice notice)? onWindowsNotice,
  })?
  directoryPickerOverride;
  // Test seam: overrides the Windows path observation (long-path / OneDrive
  // notices) for drag-drop / manual-entry paths so the wiring can be tested
  // off Windows, where [PlatformUtils.isWindows] is false.
  final Future<void> Function(String path)? windowsPathObserverOverride;
  bool _cancelRequested = false;
  int _cancellationRevision = 0;
  // Synchronous re-entrancy guards: checked and set before the first await so
  // a rapid double-tap cannot start two overlapping async flows.
  bool _styleProfileInFlight = false;
  bool _isRetrying = false;
  // WinForms dialogs have no owner window and may open behind the app, so a
  // user who thinks nothing happened can double-tap the picker buttons.
  // Without this guard two PowerShell + two modal dialogs stack up and the
  // later-finishing one silently overwrites the earlier choice.
  bool _isPicking = false;
  // H2: save/share re-entrancy guards, checked and set before the first
  // await so a rapid double-tap cannot produce duplicate files. Mirrored
  // into state.isSaving/isSharing so the UI can disable the buttons; works
  // together with the native in-flight guard (Track B).
  bool _isSaving = false;
  bool _isSharing = false;
  // C-M7: last values pushed to the Android foreground-service
  // notification; used to throttle updates (every 5% or on chapter change).
  int _lastFgServicePercent = -1;
  String? _lastFgServiceChapter;
  // C-M7: opaque token identifying the current foreground-service run;
  // passed to start/update so the native side never applies one run's
  // stashed notification updates to another run.
  String _fgServiceRunId = '';
  // API key in effect when the current/last run started, used for error
  // redaction even if the user changes the key mid-run.
  String? _runApiKey;
  // Monotonic suffix so two jobs created within the same millisecond still get
  // distinct ids.
  int _jobIdSequence = 0;
  Stopwatch? _translationStopwatch;
  Future<void> _pendingHistorySave = Future<void>.value();
  ({String inputPath, String outputDirectory})? _pendingSessionPaths;
  bool _isSavingSessionPaths = false;
  late final Future<void> _initialJobHistoryLoad;
  int _sessionPathRevision = 0;
  int _inputPathRevision = 0;
  int _historyClearRevision = 0;
  // Milliseconds-since-epoch of the newest clear tombstone this instance has
  // seen. Guards against a second app instance resurrecting cleared history
  // entries through its periodic persistence (see _persistJobHistory).
  int _lastSeenHistoryClearedAt = 0;
  _ResumeProgressHint? _pendingResumeProgressHint;
  String? _activeTranslationHistoryJobId;
  List<String>? _activeTranslationChapterPaths;
  DateTime? _lastProgressHistoryPersistAt;

  AppStrings get _s => AppStrings(state.config.uiLanguage);

  Future<String> _defaultOutputDirectory(String? inputPath) =>
      (defaultOutputDirectoryResolver ?? PlatformUtils.defaultOutputDirectory)(
        inputPath,
      );

  Future<bool> _waitForSettingsReady() async {
    final Future<void> Function()? wait = settingsReady;
    if (wait != null) {
      await wait();
    }
    return mounted;
  }

  Future<void> pickInputPath() async {
    if (_isPicking) {
      // A picker dialog is already open (possibly behind the app window, as
      // the WinForms dialogs have no owner): ignore the duplicate tap
      // instead of stacking a second dialog whose later result would
      // silently overwrite the first choice.
      return;
    }
    if (_logIfRunActive(_s.logSelectAfterRun)) {
      return;
    }
    _isPicking = true;
    try {
      await _pickInputPathGuarded();
    } finally {
      _isPicking = false;
    }
  }

  Future<void> _pickInputPathGuarded() async {
    // Windows path observations (dialog opened / long path / OneDrive) are
    // fired by the bridge; dialogOpened is time-sensitive so it is logged
    // immediately, the path-dependent ones after a path is chosen.
    final List<WindowsPathNotice> pendingNotices = <WindowsPathNotice>[];
    String? selectedPath;
    try {
      // Wait for the initial history load before syncing: syncing an empty
      // list on a cold start would tell the native side that nothing is
      // referenced and let its 7-day sweep delete a source file a history
      // entry may still retry.
      await _initialJobHistoryLoad;
      // Sync the history's input paths to the Android native side:
      // its 7-day stale-import sweep must not delete a source file a
      // history entry may still retry. No-op off Android.
      await PlatformUtils.setProtectedImportPaths(
        state.jobHistory.map((TranslationJob job) => job.inputPath).toList(),
      );
      // Guard against the native side never responding (e.g. the Android
      // activity was destroyed while the picker was open): treat it like a
      // cancelled pick instead of hanging forever.
      selectedPath = await (epubPickerOverride ?? PlatformUtils.pickEpubFile)(
        onWindowsNotice: (WindowsPathNotice notice) {
          if (notice == WindowsPathNotice.dialogOpened) {
            _logWindowsPathNotice(notice, null);
          } else {
            pendingNotices.add(notice);
          }
        },
      ).timeout(const Duration(minutes: 5), onTimeout: () => null);
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _pickErrorLog(error, _s.logCouldNotSelectEpub),
        ],
      );
      return;
    }
    if (selectedPath == null || selectedPath.isEmpty) {
      return;
    }
    for (final WindowsPathNotice notice in pendingNotices) {
      _logWindowsPathNotice(notice, selectedPath);
    }
    await _acceptInputPath(
      selectedPath,
      dropped: false,
      skipWindowsNotices: true,
    );
  }

  /// Returns true when an EPUB path was accepted into state.
  Future<bool> importDroppedEpubPath(String droppedPath) async {
    if (_logIfRunActive(_s.logDropAfterRun)) {
      return false;
    }
    // Unlike the picker dialogs (whose notices the bridge already fired),
    // drag-drop bypasses the observation hook, so run it here.
    return _acceptInputPath(droppedPath, dropped: true);
  }

  Future<void> pickOutputDirectory() async {
    if (_isPicking) {
      // Same guard as pickInputPath: never stack two native dialogs.
      return;
    }
    if (_logIfRunActive(_s.logChangeOutputAfterRun)) {
      return;
    }
    _isPicking = true;
    try {
      await _pickOutputDirectoryGuarded();
    } finally {
      _isPicking = false;
    }
  }

  Future<void> _pickOutputDirectoryGuarded() async {
    if (!PlatformUtils.supportsDirectoryPicker) {
      _sessionPathRevision += 1;
      final String outputDirectory = await _defaultOutputDirectory(
        state.inputPath,
      );
      state = state.copyWith(
        outputDirectory: outputDirectory,
        logs: <String>[...state.logs, _s.logAndroidOutputDir(outputDirectory)],
      );
      return;
    }

    String? selectedDirectory;
    final List<WindowsPathNotice> pendingNotices = <WindowsPathNotice>[];
    try {
      // Same guard as pickInputPath: never let a hanging or crashing native
      // dialog take down the UI or hang forever.
      selectedDirectory =
          await (directoryPickerOverride ?? PlatformUtils.pickDirectory)(
            onWindowsNotice: (WindowsPathNotice notice) {
              if (notice == WindowsPathNotice.dialogOpened) {
                _logWindowsPathNotice(notice, null);
              } else {
                pendingNotices.add(notice);
              }
            },
          ).timeout(const Duration(minutes: 5), onTimeout: () => null);
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _pickErrorLog(error, _s.logCouldNotSelectDirectory),
        ],
      );
      return;
    }
    if (selectedDirectory == null || selectedDirectory.isEmpty) {
      return;
    }
    for (final WindowsPathNotice notice in pendingNotices) {
      _logWindowsPathNotice(notice, selectedDirectory);
    }
    _sessionPathRevision += 1;
    state = state.copyWith(
      outputDirectory: selectedDirectory,
      logs: <String>[...state.logs, _s.logSelectedOutput(selectedDirectory)],
    );
  }

  void setInputPath(String value) {
    if (state.isRunActive) {
      state = state.copyWith(logs: <String>[...state.logs, _s.logInputLocked]);
      return;
    }
    _sessionPathRevision += 1;
    _inputPathRevision += 1;
    state = state.copyWith(
      inputPath: value,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      styleProfile: TranslationStyleProfile.empty,
      styleProfileConfirmed: false,
      isGeneratingStyleProfile: false,
      actionableError: null,
    );
    _persistSessionPaths(
      inputPath: state.inputPath,
      outputDirectory: state.outputDirectory,
    );
    // Manual entry bypasses the picker dialogs: fire the Windows path
    // observations here. Fire-and-forget: the observation never throws and
    // only appends log lines.
    unawaited(_observeWindowsPathIfNeeded(value));
  }

  Future<bool> _acceptInputPath(
    String value, {
    required bool dropped,
    // The picker dialogs already fired the bridge's path observations; the
    // drag-drop and manual-entry paths did not, so they run them here.
    bool skipWindowsNotices = false,
  }) async {
    final String normalizedPath = value.trim();
    if (normalizedPath.isEmpty) {
      return false;
    }
    if (path.extension(normalizedPath).toLowerCase() != '.epub') {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logChooseEpubFile],
      );
      return false;
    }

    _sessionPathRevision += 1;
    final int inputPathRevision = ++_inputPathRevision;
    final String inferredOutput = state.outputDirectory.isEmpty
        ? await _defaultOutputDirectory(normalizedPath)
        : state.outputDirectory;
    if (!mounted || inputPathRevision != _inputPathRevision) {
      return false;
    }
    if (_logIfRunActive(dropped ? _s.logDropAfterRun : _s.logSelectAfterRun)) {
      return false;
    }
    final String outputDirectory = state.outputDirectory.isEmpty
        ? inferredOutput
        : state.outputDirectory;
    final String base = path.basename(normalizedPath);
    state = state.copyWith(
      inputPath: normalizedPath,
      outputDirectory: outputDirectory,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      styleProfile: TranslationStyleProfile.empty,
      styleProfileConfirmed: false,
      isGeneratingStyleProfile: false,
      actionableError: null,
      logs: <String>[
        ...state.logs,
        dropped ? _s.logDroppedEpub(base) : _s.logSelectedEpub(base),
      ],
    );
    _persistSessionPaths(
      inputPath: normalizedPath,
      outputDirectory: outputDirectory,
    );
    if (!skipWindowsNotices) {
      await _observeWindowsPathIfNeeded(normalizedPath);
    }
    return true;
  }

  /// Fires the Windows path observations (long-path-without-policy, OneDrive)
  /// for a path that bypassed the picker dialogs (drag-drop / manual entry).
  /// Best-effort: never throws, and never fires twice for picker flows (the
  /// bridge already observed those via [skipWindowsNotices]).
  Future<void> _observeWindowsPathIfNeeded(String path) async {
    final Future<void> Function(String path)? observerOverride =
        windowsPathObserverOverride;
    if (observerOverride != null) {
      // Test seam: exercised off Windows; the production filtering
      // (dialogOpened / mounted) is irrelevant for the observation itself.
      await observerOverride(path);
      return;
    }
    if (!PlatformUtils.isWindows) {
      return;
    }
    await NativePlatformBridge.observeWindowsPath(path, (
      WindowsPathNotice notice,
    ) {
      if (!mounted || notice == WindowsPathNotice.dialogOpened) {
        return;
      }
      _logWindowsPathNotice(notice, path);
    });
  }

  void setOutputDirectory(String value) {
    if (state.isRunActive) {
      state = state.copyWith(logs: <String>[...state.logs, _s.logOutputLocked]);
      return;
    }
    _sessionPathRevision += 1;
    state = state.copyWith(outputDirectory: value);
    _persistSessionPaths(
      inputPath: state.inputPath,
      outputDirectory: state.outputDirectory,
    );
    // Manual entry bypasses the picker dialog: fire the Windows path
    // observations here (fire-and-forget; never throws).
    unawaited(_observeWindowsPathIfNeeded(value));
  }

  void setTargetLanguage(String value) {
    if (state.isRunActive) {
      return;
    }
    state = state.copyWith(
      config: state.config.copyWith(targetLanguage: value),
    );
  }

  void setBilingual(bool value) {
    if (state.isRunActive) {
      return;
    }
    state = state.copyWith(config: state.config.copyWith(bilingual: value));
  }

  void syncSettings(TranslationConfig settingsConfig) {
    final TranslationConfig nextConfig = state.config.copyWith(
      apiBaseUrl: settingsConfig.apiBaseUrl,
      apiKey: settingsConfig.apiKey,
      model: settingsConfig.model,
      uiLanguage: settingsConfig.uiLanguage,
      themeMode: settingsConfig.themeMode,
      targetLanguage: settingsConfig.targetLanguage,
      bilingual: settingsConfig.bilingual,
      chunkSize: settingsConfig.chunkSize,
      maxConcurrent: settingsConfig.maxConcurrent,
      timeoutSeconds: settingsConfig.timeoutSeconds,
      maxRetries: settingsConfig.maxRetries,
      retryDelaySeconds: settingsConfig.retryDelaySeconds,
      outputSuffix: settingsConfig.outputSuffix,
      residualQualityCheck: settingsConfig.residualQualityCheck,
      styleProfileEnabled: settingsConfig.styleProfileEnabled,
      textScale: settingsConfig.textScale,
      lockedGlossary: settingsConfig.lockedGlossary,
      httpProxy: settingsConfig.httpProxy,
    );
    state = state.copyWith(
      config: nextConfig,
      runEstimate: state.inspectedChapters.isEmpty
          ? state.runEstimate
          : _buildEstimate(config: nextConfig),
    );
  }

  void toggleChapterInclusion(String chapterPath, bool includeInTranslation) {
    if (state.isRunActive) {
      return;
    }
    final List<InspectedChapter> nextChapters = state.inspectedChapters
        .map(
          (InspectedChapter chapter) => chapter.path == chapterPath
              ? chapter.copyWith(
                  includeInTranslation:
                      chapter.blocks.isNotEmpty && includeInTranslation,
                )
              : chapter,
        )
        .toList();
    state = state.copyWith(
      inspectedChapters: nextChapters,
      runEstimate: _buildEstimate(chapters: nextChapters),
    );
  }

  void resetChapterSelection() {
    applyChapterSelectionPreset(ChapterSelectionPreset.recommended);
  }

  void applyChapterSelectionPreset(ChapterSelectionPreset preset) {
    if (state.isRunActive || state.inspectedChapters.isEmpty) {
      return;
    }
    final List<InspectedChapter> nextChapters = preset.apply(
      state.inspectedChapters,
    );
    state = state.copyWith(
      inspectedChapters: nextChapters,
      runEstimate: _buildEstimate(chapters: nextChapters),
      logs: <String>[...state.logs, _s.logAppliedPreset(preset.name)],
    );
  }

  void clearActionableError() {
    state = state.copyWith(actionableError: null);
  }

  Future<void> generateStyleProfile() async {
    if (_styleProfileInFlight) {
      return;
    }
    _styleProfileInFlight = true;
    try {
      await _generateStyleProfile();
    } finally {
      _styleProfileInFlight = false;
    }
  }

  Future<void> _generateStyleProfile() async {
    if (!await _waitForSettingsReady()) {
      return;
    }
    if (!state.config.styleProfileEnabled) {
      state = state.copyWith(
        styleProfile: TranslationStyleProfile.empty,
        styleProfileConfirmed: true,
        isGeneratingStyleProfile: false,
        logs: <String>[...state.logs, _s.logStyleProfileDisabled],
      );
      return;
    }
    if (state.inspectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logInspectBeforeStyleProfile],
      );
      return;
    }
    if (state.isRunActive && !state.isGeneratingStyleProfile) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logRunAlreadyActiveGeneric],
      );
      return;
    }

    _cancelRequested = false;
    _runApiKey = state.config.apiKey;
    state = state.copyWith(
      isGeneratingStyleProfile: true,
      styleProfileConfirmed: false,
      actionableError: null,
      logs: <String>[...state.logs, _s.logGeneratingStyleProfile],
    );

    try {
      final TranslationStyleProfile profile = await repository
          .generateStyleProfile(
            config: state.config,
            chapters: state.inspectedChapters,
            isCancelled: () => _cancelRequested,
          );
      if (_cancelRequested) {
        state = state.copyWith(isGeneratingStyleProfile: false);
        return;
      }
      state = state.copyWith(
        styleProfile: profile,
        // Empty means generic style; keep unconfirmed only when there is content to review.
        styleProfileConfirmed: profile.isEmpty,
        isGeneratingStyleProfile: false,
        logs: <String>[
          ...state.logs,
          profile.isEmpty
              ? _s.logStyleProfileEmpty
              : _s.logStyleProfileReady(profile.summaryLabel),
        ],
      );
    } catch (error) {
      if (_cancelRequested) {
        state = state.copyWith(isGeneratingStyleProfile: false);
        return;
      }
      final String safeError = _safeErrorText(error);
      AppLogger.error(
        'Style profile generation failed',
        tag: 'dashboard',
        error: safeError,
      );
      state = state.copyWith(
        isGeneratingStyleProfile: false,
        styleProfileConfirmed: false,
        logs: <String>[...state.logs, _s.logStyleProfileFailed(safeError)],
      );
    }
  }

  void updateStyleProfile(TranslationStyleProfile profile) {
    if (state.isRunActive && !state.isGeneratingStyleProfile) {
      return;
    }
    state = state.copyWith(styleProfile: profile, styleProfileConfirmed: false);
  }

  void setStyleProfileField({
    String? primaryGenre,
    String? secondaryGenresCsv,
    String? tone,
    String? sentenceStyle,
    String? constraintsText,
    String? avoidText,
    TranslationStyleConfidence? confidence,
  }) {
    if (state.isRunActive && !state.isGeneratingStyleProfile) {
      return;
    }
    final TranslationStyleProfile current = state.styleProfile;
    final List<String> secondary = secondaryGenresCsv == null
        ? current.secondaryGenres
        : secondaryGenresCsv
              .split(RegExp(r'[,;\n]'))
              .map((String part) => part.trim())
              .where((String part) => part.isNotEmpty)
              .toList(growable: false);
    final List<String> constraints = constraintsText == null
        ? current.translationConstraints
        : constraintsText
              .split('\n')
              .map((String part) => part.trim())
              .where((String part) => part.isNotEmpty)
              .toList(growable: false);
    final List<String> avoid = avoidText == null
        ? current.avoid
        : avoidText
              .split('\n')
              .map((String part) => part.trim())
              .where((String part) => part.isNotEmpty)
              .toList(growable: false);
    state = state.copyWith(
      styleProfile: current.copyWith(
        primaryGenre: primaryGenre,
        secondaryGenres: secondary,
        tone: tone,
        sentenceStyle: sentenceStyle,
        translationConstraints: constraints,
        avoid: avoid,
        confidence: confidence,
      ),
      styleProfileConfirmed: false,
    );
  }

  void confirmStyleProfile() {
    if (state.isRunActive && !state.isGeneratingStyleProfile) {
      return;
    }
    if (!state.config.styleProfileEnabled) {
      state = state.copyWith(styleProfileConfirmed: true);
      return;
    }
    // Empty profile is allowed: it means use generic translation style.
    final String label = state.styleProfile.isEmpty
        ? (state.config.uiLanguage == UiLanguage.chinese
              ? '通用风格'
              : 'generic style')
        : state.styleProfile.summaryLabel;
    state = state.copyWith(
      styleProfileConfirmed: true,
      logs: <String>[...state.logs, _s.logStyleProfileConfirmed(label)],
    );
  }

  void clearStyleProfileConfirmation() {
    if (state.isRunActive && !state.isGeneratingStyleProfile) {
      return;
    }
    state = state.copyWith(styleProfileConfirmed: false);
  }

  Future<void> startInspection({
    TranslationStyleProfile? preservedStyleProfile,
    List<String>? chapterSelection,
    bool generateStyle = true,
  }) async {
    if (!await _waitForSettingsReady()) {
      return;
    }
    if (_logIfRunActive(_s.logRunAlreadyActiveInspect)) {
      return;
    }
    if (state.inputPath.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logPickEpubBeforeInspect],
      );
      return;
    }

    final String inputPath = state.inputPath;
    final int inputPathRevision = _inputPathRevision;
    final String inferredOutputDirectory = state.outputDirectory.isEmpty
        ? await _defaultOutputDirectory(inputPath)
        : state.outputDirectory;
    if (!mounted ||
        inputPathRevision != _inputPathRevision ||
        state.inputPath != inputPath) {
      return;
    }
    if (_logIfRunActive(_s.logRunAlreadyActiveInspect)) {
      return;
    }
    final String outputDirectory = state.outputDirectory.isEmpty
        ? inferredOutputDirectory
        : state.outputDirectory;
    _cancelRequested = false;
    _runApiKey = state.config.apiKey;

    state = state.copyWith(
      outputDirectory: outputDirectory,
      actionableError: null,
      job: TranslationJob(
        id: _newJobId(),
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.queued,
        phase: TranslationJobPhase.inspection,
        progress: 0,
      ),
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      styleProfile: preservedStyleProfile ?? TranslationStyleProfile.empty,
      styleProfileConfirmed: preservedStyleProfile != null,
      isGeneratingStyleProfile: false,
      logs: <String>[
        ...state.logs,
        _s.logStartingInspection(path.basename(inputPath)),
      ],
    );
    _persistSessionPaths(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
    );

    try {
      final InspectionResult result = await repository.startJob(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        config: state.config,
        onProgress: (TranslationJob job, String logLine) {
          if (_cancelRequested) {
            return;
          }
          state = state.copyWith(
            job: job,
            logs: <String>[...state.logs, _safeLogText(logLine)],
          );
        },
        isCancelled: () => _cancelRequested,
      );
      if (_cancelRequested) {
        _handleCancellation(const TranslationCancelledException());
        return;
      }
      final inspectedChapters = chapterSelection == null
          ? result.chapters
          : result.chapters
                .map(
                  (chapter) => chapter.copyWith(
                    includeInTranslation: chapterSelection.contains(
                      chapter.path,
                    ),
                  ),
                )
                .toList();
      state = state.copyWith(
        job: result.job.copyWith(phase: TranslationJobPhase.inspection),
        jobHistory: _jobHistoryWith(
          result.job.copyWith(phase: TranslationJobPhase.inspection),
        ),
        runEstimate: _buildEstimate(
          chapters: inspectedChapters,
          job: result.job,
        ),
        inspectedChapters: inspectedChapters,
        styleProfile: preservedStyleProfile ?? TranslationStyleProfile.empty,
        styleProfileConfirmed:
            preservedStyleProfile != null || !state.config.styleProfileEnabled,
        isGeneratingStyleProfile: false,
        actionableError: null,
      );
      if (generateStyle &&
          state.config.styleProfileEnabled &&
          preservedStyleProfile == null &&
          (chapterSelection == null ||
              chapterSelection.every(
                (selected) => inspectedChapters.any(
                  (chapter) => chapter.path == selected,
                ),
              ))) {
        await generateStyleProfile();
      }
    } catch (error) {
      if (_handleCancellation(error)) {
        return;
      }
      final String safeError = _safeErrorText(error);
      AppLogger.error('Inspection failed', tag: 'dashboard', error: safeError);
      final TranslationJob failedJob =
          state.job?.copyWith(
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.inspection,
            currentChapter: _s.jobStatusInspectionFailed,
            errorMessage: safeError,
          ) ??
          TranslationJob(
            id: _newJobId(),
            inputPath: state.inputPath,
            outputPath: outputDirectory,
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.inspection,
            progress: 0,
            currentChapter: _s.jobStatusInspectionFailed,
            errorMessage: safeError,
          );
      state = state.copyWith(
        job: failedJob,
        jobHistory: _jobHistoryWith(failedJob),
        runEstimate: null,
        inspectedChapters: const <InspectedChapter>[],
        styleProfile: TranslationStyleProfile.empty,
        styleProfileConfirmed: false,
        isGeneratingStyleProfile: false,
        logs: <String>[...state.logs, _s.logInspectionFailed(safeError)],
        actionableError: ActionableErrorFactory.fromMessage(
          _s.logInspectionFailed(safeError),
          isChinese: state.config.uiLanguage == UiLanguage.chinese,
          preferredKind: ActionableErrorKind.retryInspection,
        ),
      );
    }
  }

  /// While the repository is still verifying the local block cache, its
  /// progress reports carry the previous run's checkpoint as `progress`.
  /// Drive the progress bar from the verified block count instead so it
  /// never shows a stale checkpoint that jumps back down once the scan
  /// finishes. `completedBlocks` keeps the checkpoint on purpose (see
  /// `_confirmedProgressBlocks`); only the bar is re-based.
  TranslationJob _verifiedCacheProgress(TranslationJob job) {
    if (job.phase != TranslationJobPhase.cacheRestoration) {
      return job;
    }
    final double verified = job.totalBlocks <= 0
        ? 0.0
        : (job.cachedBlocks / job.totalBlocks).clamp(0.0, 1.0).toDouble();
    return job.copyWith(progress: verified);
  }

  /// Starts translation for the inspected selection.
  ///
  /// Returns true when the run actually started; false when a guard stopped
  /// it (settings not ready, another run active, nothing inspected, or the
  /// style-profile confirmation gate).
  Future<bool> startTranslation({bool logRetryContinuation = false}) async {
    if (!await _waitForSettingsReady()) {
      return false;
    }
    if (_logIfRunActive(_s.logRunAlreadyActiveTranslate)) {
      return false;
    }
    if (state.inspectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logInspectBeforeTranslate],
      );
      return false;
    }

    final List<InspectedChapter> selectedChapters = state.inspectedChapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .toList();
    final int selectedBlocks = selectedChapters.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );
    if (selectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logNoChaptersChecked],
      );
      return false;
    }
    if (selectedBlocks > 0 && state.requiresStyleProfileConfirmation) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logConfirmStyleBeforeTranslate],
      );
      return false;
    }

    _cancelRequested = false;
    _runApiKey = state.config.apiKey;
    _translationStopwatch = Stopwatch()..start();
    final TranslationJob? currentJob = state.job;
    final bool currentJobIsResumable =
        currentJob != null &&
        (currentJob.status == TranslationJobStatus.failed ||
            currentJob.status == TranslationJobStatus.cancelled ||
            currentJob.status == TranslationJobStatus.completedWithWarnings) &&
        currentJob.phase != TranslationJobPhase.inspection &&
        currentJob.totalBlocks > 0;
    final _ResumeProgressHint? currentJobHint = currentJobIsResumable
        ? _ResumeProgressHint(
            completedBlocks: currentJob.completedBlocks,
            totalBlocks: currentJob.totalBlocks,
          )
        : null;
    final _ResumeProgressHint? candidateResumeHint =
        _pendingResumeProgressHint ?? currentJobHint;
    final _ResumeProgressHint? resumeHint =
        candidateResumeHint?.totalBlocks == selectedBlocks
        ? candidateResumeHint
        : null;
    _pendingResumeProgressHint = null;
    final int checkpointBlocks = (resumeHint?.completedBlocks ?? 0).clamp(
      0,
      selectedBlocks,
    );
    final selectedPaths = List<String>.unmodifiable(
      selectedChapters.map((chapter) => chapter.path),
    );
    // The checkpoint is unverified until the cache scan runs: the progress
    // bar and block counters start at zero while `resumeCheckpointBlocks`
    // keeps the pending figure (the UI labels it as "to verify").
    final TranslationJob queuedJob =
        state.job?.copyWith(
          selectedChapterPaths: selectedPaths,
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.cacheRestoration,
          progress: 0,
          currentChapter: _s.jobStatusRestoringCache,
          currentBlock: null,
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: 0,
          totalBlocks: selectedBlocks,
          cachedBlocks: 0,
          resumedBlocks: 0,
          resumeCheckpointBlocks: checkpointBlocks,
          cacheScanScannedBlocks: 0,
          cacheScanTotalBlocks: selectedBlocks,
          degradedBlockCount: 0,
          errorMessage: null,
          styleProfile: state.styleProfile,
          styleProfileConfirmed: state.styleProfileConfirmed,
          styleProfileEnabled: state.config.styleProfileEnabled,
        ) ??
        TranslationJob(
          id: _newJobId(),
          inputPath: state.inputPath,
          outputPath: state.outputDirectory,
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.cacheRestoration,
          selectedChapterPaths: selectedPaths,
          progress: 0,
          currentChapter: _s.jobStatusRestoringCache,
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: 0,
          totalBlocks: selectedBlocks,
          resumeCheckpointBlocks: checkpointBlocks,
          cacheScanScannedBlocks: 0,
          cacheScanTotalBlocks: selectedBlocks,
          styleProfile: state.styleProfile,
          styleProfileConfirmed: state.styleProfileConfirmed,
          styleProfileEnabled: state.config.styleProfileEnabled,
        );
    _activeTranslationHistoryJobId = queuedJob.id;
    _activeTranslationChapterPaths = selectedPaths;
    _lastProgressHistoryPersistAt = null;
    final TranslationRunEstimate? estimate = _buildEstimate(job: queuedJob);
    state = state.copyWith(
      job: queuedJob,
      jobHistory: _jobHistoryWith(queuedJob),
      runEstimate: estimate,
      actionableError: null,
      logs: <String>[
        ...state.logs,
        _s.logQueuedTranslation(selectedChapters.length, selectedBlocks),
        // Only logged when the retry path asked for it: this state update
        // happens after every early-return gate, so the line always precedes
        // any run output and only appears when the run really started.
        if (logRetryContinuation) _s.logRetryContinueTranslate,
        if (estimate != null)
          _s.logRoughLoad(
            estimate.estimatedApiBatches,
            estimate.estimatedInputTokens,
            estimate.estimatedSourceChars,
          ),
      ],
    );

    bool cacheRestorationLogged = false;
    // C-M7: keep the run alive under Doze via the Android foreground service
    // (Track B native side); stopped in the finally below on every exit path.
    _startTranslationForegroundService();
    try {
      final TranslationRunResult result = await repository.translateChapters(
        inputPath: state.inputPath,
        outputDirectory: state.outputDirectory,
        config: state.config,
        chapters: state.inspectedChapters,
        confirmedStyleProfile:
            state.config.styleProfileEnabled && state.styleProfileConfirmed
            ? state.styleProfile
            : null,
        onProgress: (TranslationJob job, String logLine) {
          if (_cancelRequested) {
            return;
          }
          final TranslationJob progressJob = _translationHistoryJob(
            _verifiedCacheProgress(job.copyWith(errorMessage: null)),
          );
          final List<String> nextLogs = <String>[
            ...state.logs,
            _safeLogText(logLine),
          ];
          final bool cacheScanComplete =
              progressJob.phase == TranslationJobPhase.cacheRestoration &&
              progressJob.cacheScanTotalBlocks > 0 &&
              progressJob.cacheScanScannedBlocks >=
                  progressJob.cacheScanTotalBlocks;
          if (!cacheRestorationLogged && cacheScanComplete) {
            cacheRestorationLogged = true;
            nextLogs.add(
              progressJob.cachedBlocks >= progressJob.totalBlocks
                  ? _s.logAllBlocksRestoredNoApi(progressJob.totalBlocks)
                  : _s.logCacheRestoredNoApi(progressJob.cachedBlocks),
            );
          }
          state = state.copyWith(
            job: progressJob,
            jobHistory: _jobHistoryWith(progressJob, persist: false),
            runEstimate: _buildEstimate(job: progressJob),
            logs: nextLogs,
          );
          _updateTranslationForegroundService(progressJob);
          _persistProgressHistoryIfDue();
        },
        isCancelled: () => _cancelRequested,
      );
      // A returned terminal result means the repository already committed the
      // EPUB. A cancellation arriving afterward cannot undo that output.
      final bool failedResult =
          result.job.status == TranslationJobStatus.failed;
      final String? safeResultError = failedResult
          ? _safeErrorText(
              result.job.errorMessage ??
                  'Translation did not produce a usable result.',
            )
          : null;
      final TranslationJob terminalJob = _translationHistoryJob(
        result.job.copyWith(
          phase: TranslationJobPhase.translation,
          errorMessage: safeResultError,
        ),
      );
      state = state.copyWith(
        job: terminalJob,
        jobHistory: _jobHistoryWith(terminalJob),
        runEstimate: _buildEstimate(job: terminalJob),
        inspectedChapters: result.chapters,
        actionableError: failedResult
            ? ActionableErrorFactory.fromMessage(
                _s.logTranslationFailed(safeResultError!),
                isChinese: state.config.uiLanguage == UiLanguage.chinese,
                preferredKind: ActionableErrorKind.retryTranslation,
              )
            : null,
        logs: <String>[
          ...state.logs,
          if (failedResult)
            _s.logTranslationFailed(safeResultError!)
          else if (terminalJob.status ==
              TranslationJobStatus.completedWithWarnings)
            _s.logTranslationCompletedWithWarnings(
              terminalJob.degradedBlockCount,
            )
          else if (PlatformUtils.isAndroid)
            _s.logTranslationCompleteAndroid
          else
            _s.logTranslationCompleteDesktop,
          if (result.job.cachedBlocks > 0 || result.job.resumedBlocks > 0)
            _s.logCacheResume(
              result.job.cachedBlocks,
              result.job.resumedBlocks,
            ),
        ],
      );
      _clearActiveTranslationHistory();
      _translationStopwatch?.stop();
    } catch (error) {
      if (_handleCancellation(error)) {
        // The run started and was then cancelled; report it as started.
        return true;
      }
      final String safeError = _safeErrorText(error);
      AppLogger.error('Translation failed', tag: 'dashboard', error: safeError);
      final TranslationJob failedJob = _translationHistoryJob(
        state.job?.copyWith(
              status: TranslationJobStatus.failed,
              phase: TranslationJobPhase.translation,
              currentChapter: _s.jobStatusTranslationFailed,
              currentBlock: null,
              errorMessage: safeError,
            ) ??
            TranslationJob(
              id: _newJobId(),
              inputPath: state.inputPath,
              outputPath: state.outputDirectory,
              status: TranslationJobStatus.failed,
              phase: TranslationJobPhase.translation,
              progress: 0,
              currentChapter: _s.jobStatusTranslationFailed,
              errorMessage: safeError,
            ),
      );
      // completedBlocks already includes cache hits and newly translated blocks.
      final int savedBlocks = failedJob.completedBlocks;
      state = state.copyWith(
        job: failedJob,
        jobHistory: _jobHistoryWith(failedJob),
        logs: <String>[
          ...state.logs,
          _s.logTranslationFailed(safeError),
          if (savedBlocks > 0) _s.logCheckpointed(savedBlocks),
        ],
        actionableError: ActionableErrorFactory.fromMessage(
          _s.logTranslationFailed(safeError),
          isChinese: state.config.uiLanguage == UiLanguage.chinese,
          preferredKind: ActionableErrorKind.retryTranslation,
        ),
      );
      _clearActiveTranslationHistory();
      _translationStopwatch?.stop();
    } finally {
      // C-M7: completion, failure and cancellation (including the early
      // `return true` in the catch path above) all stop the service here.
      _stopTranslationForegroundService();
    }
    return true;
  }

  Future<void> requestCancel() async {
    final TranslationJob? activeJob = state.job;
    if (activeJob == null || !state.isRunActive) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logNoActiveRunToCancel],
      );
      return;
    }

    if (_cancelRequested) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logCancelAlreadyPending],
      );
      return;
    }

    _cancelRequested = true;
    final int cancellationRevision = ++_cancellationRevision;
    await repository.cancelJob(activeJob.id);
    if (!mounted ||
        cancellationRevision != _cancellationRevision ||
        !_cancelRequested ||
        !state.isRunActive ||
        state.job?.id != activeJob.id) {
      return;
    }
    // Style-profile generation runs against a terminal inspection job (the
    // only "active" thing is isGeneratingStyleProfile); the profile
    // coroutine observes _cancelRequested itself and clears
    // isGeneratingStyleProfile. Marking the finished job
    // 'Cancellation requested' would be a display glitch, so skip the job
    // mutation here and just log.
    final bool jobActivelyRunning =
        activeJob.status == TranslationJobStatus.queued ||
        activeJob.status == TranslationJobStatus.running;
    if (!jobActivelyRunning) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logCancellationRequested],
      );
      return;
    }
    final TranslationJob cancellingJob = activeJob.copyWith(
      currentChapter: _s.jobStatusCancellationRequested,
      currentBlock: null,
    );
    final int progressBlocks = _confirmedProgressBlocks(activeJob);
    state = state.copyWith(
      job: cancellingJob,
      logs: <String>[
        ...state.logs,
        _s.logCancellationRequested,
        if (progressBlocks > 0) _s.logCachedProgressSoFar(progressBlocks),
      ],
    );
  }

  Future<void> exportTranslatedEpub() async {
    // H2: synchronous re-entrancy guard — a rapid double-tap cannot open two
    // share sheets / produce duplicate files. Doubled with the native
    // in-flight guard (Track B). UI also disables the button via
    // state.isSharing.
    if (_isSharing) {
      return;
    }
    _isSharing = true;
    state = state.copyWith(isSharing: true);
    try {
      final String? outputPath = await _completedOutputPath();
      if (outputPath == null) {
        return;
      }

      try {
        if (PlatformUtils.isAndroid) {
          await PlatformUtils.shareFile(
            sourcePath: outputPath,
            displayName: path.basename(outputPath),
            // C-M4: localized chooser title (Track C adds the optional
            // `chooserTitle` parameter to the Dart share method).
            chooserTitle: _s.shareChooserTitle,
          );
          state = state.copyWith(
            logs: <String>[
              ...state.logs,
              _s.logOpenedShare(path.basename(outputPath)),
            ],
          );
          return;
        }

        final OpenResult result = await OpenFilex.open(outputPath);
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            result.type == ResultType.done
                ? _s.logOpenedEpub(path.basename(outputPath))
                : _s.logCouldNotOpenEpub(result.message),
          ],
        );
      } catch (error) {
        // C-M6: permanently-denied storage permission gets its own notice.
        if (_handlePermanentPermissionDenial(error)) {
          return;
        }
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            _s.logCouldNotExport(_safeErrorText(error)),
          ],
        );
      }
    } finally {
      _isSharing = false;
      if (mounted) {
        state = state.copyWith(isSharing: false);
      }
    }
  }

  Future<void> saveTranslatedEpubToDownloads() async {
    // H2: same double-tap guard as export; UI disables via state.isSaving.
    if (_isSaving) {
      return;
    }
    _isSaving = true;
    state = state.copyWith(isSaving: true);
    try {
      final String? outputPath = await _completedOutputPath();
      if (outputPath == null) {
        return;
      }

      try {
        final String displayName = path.basename(outputPath);
        final String? savedPath = await PlatformUtils.saveToDownloads(
          sourcePath: outputPath,
          displayName: displayName,
        );
        if (!mounted) {
          // The provider was disposed while the native save ran: assigning
          // state now would throw, and the catch below would throw again on
          // its own state assignment. Bail out quietly; finally still resets
          // the saving flag under its own mounted guard.
          return;
        }
        // C-L4: the native return value is log-only and inconsistent across
        // OS versions — Android 10+ returns a display pseudo-path
        // "Downloads/<name>", Android 9 and below an absolute path. Never
        // join it into a real file path; it is only shown to the user.
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            savedPath == null
                ? _s.logDownloadsAndroidOnly
                : _s.logSavedToDownloads(savedPath),
          ],
        );
      } catch (error) {
        // C-M6: permanently-denied storage permission gets its own notice.
        if (_handlePermanentPermissionDenial(error)) {
          return;
        }
        if (!mounted) {
          return;
        }
        state = state.copyWith(
          logs: <String>[...state.logs, debugSaveErrorLogLine(error)],
        );
      }
    } finally {
      _isSaving = false;
      if (mounted) {
        state = state.copyWith(isSaving: false);
      }
    }
  }

  Future<void> openJobOutput(String jobId) async {
    // H2: same share re-entrancy guard as exportTranslatedEpub (history
    // items share through the same native channel).
    if (_isSharing) {
      return;
    }
    _isSharing = true;
    state = state.copyWith(isSharing: true);
    try {
      final TranslationJob? job = _findKnownJob(jobId);
      final String outputPath = job?.outputPath ?? '';
      if (job == null || !job.hasExportableEpub) {
        state = state.copyWith(
          logs: <String>[...state.logs, _s.logNoOutputForHistory],
        );
        return;
      }

      final File outputFile = File(outputPath);
      final FileSystemEntityType type = await FileSystemEntity.type(outputPath);
      if (type != FileSystemEntityType.file || !await outputFile.exists()) {
        state = state.copyWith(
          logs: <String>[...state.logs, _s.logOutputNotFound(outputPath)],
        );
        return;
      }

      try {
        if (PlatformUtils.isAndroid) {
          await PlatformUtils.shareFile(
            sourcePath: outputPath,
            displayName: path.basename(outputPath),
            // C-M4: localized chooser title (Track C adds the optional
            // `chooserTitle` parameter to the Dart share method).
            chooserTitle: _s.shareChooserTitle,
          );
          state = state.copyWith(
            logs: <String>[
              ...state.logs,
              _s.logOpenedShare(path.basename(outputPath)),
            ],
          );
          return;
        }
        final OpenResult result = await OpenFilex.open(outputPath);
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            result.type == ResultType.done
                ? _s.logOpenedEpub(path.basename(outputPath))
                : _s.logCouldNotOpenEpub(result.message),
          ],
        );
      } catch (error) {
        // C-M6: permanently-denied storage permission gets its own notice.
        if (_handlePermanentPermissionDenial(error)) {
          return;
        }
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            _s.logCouldNotOpenJobOutput(_safeErrorText(error)),
          ],
        );
      }
    } finally {
      _isSharing = false;
      if (mounted) {
        state = state.copyWith(isSharing: false);
      }
    }
  }

  Future<void> retryJob(String jobId) async {
    if (_isRetrying) {
      return;
    }
    _isRetrying = true;
    try {
      await _retryJob(jobId);
    } finally {
      _isRetrying = false;
    }
  }

  Future<void> _retryJob(String jobId) async {
    if (!await _waitForSettingsReady()) {
      return;
    }
    if (_logIfRunActive(_s.logRetryWait)) {
      return;
    }
    final TranslationJob? job = _findKnownJob(jobId);
    if (job == null) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logHistoryNotFound],
      );
      return;
    }
    if (job.status != TranslationJobStatus.failed &&
        job.status != TranslationJobStatus.cancelled &&
        job.status != TranslationJobStatus.completedWithWarnings) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logOnlyFailedOrCancelled],
      );
      return;
    }
    if (job.inputPath.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logHistoryMissingPath],
      );
      return;
    }

    final String outputDirectory = _outputDirectoryForRetry(job);
    final bool styleModeMatches =
        job.styleProfileEnabled == null ||
        job.styleProfileEnabled == state.config.styleProfileEnabled;
    final TranslationStyleProfile? preservedStyleProfile =
        job.styleProfileConfirmed && styleModeMatches ? job.styleProfile : null;
    // The phase (not the display string) decides whether the failed job was
    // a translation run: currentChapter is localized now and must not be
    // matched on.
    final bool wasTranslationFailure = _isTranslationRunPhase(job.phase);
    _pendingResumeProgressHint = wasTranslationFailure && job.totalBlocks > 0
        ? _ResumeProgressHint(
            completedBlocks: job.completedBlocks,
            totalBlocks: job.totalBlocks,
          )
        : null;
    _sessionPathRevision += 1;
    _inputPathRevision += 1;
    state = state.copyWith(
      inputPath: job.inputPath,
      outputDirectory: outputDirectory,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      styleProfile: preservedStyleProfile ?? TranslationStyleProfile.empty,
      styleProfileConfirmed: preservedStyleProfile != null,
      isGeneratingStyleProfile: false,
      logs: <String>[
        ...state.logs,
        _s.logRetrying(path.basename(job.inputPath)),
      ],
    );
    await startInspection(
      preservedStyleProfile: preservedStyleProfile,
      chapterSelection: wasTranslationFailure
          ? job.selectedChapterPaths ?? const <String>[]
          : null,
      generateStyle:
          !wasTranslationFailure ||
          job.selectedChapterPaths?.isNotEmpty == true,
    );
    if (!mounted) {
      return;
    }
    if (!wasTranslationFailure) {
      _pendingResumeProgressHint = null;
      return;
    }
    if (state.job?.status != TranslationJobStatus.inspected) {
      _pendingResumeProgressHint = null;
      return;
    }
    final selection = job.selectedChapterPaths;
    if (selection == null ||
        selection.isEmpty ||
        selection.any(
          (selected) => !state.inspectedChapters.any(
            (chapter) => chapter.path == selected,
          ),
        )) {
      _pendingResumeProgressHint = null;
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          selection == null
              ? _s.logRetrySelectionUnknown
              : _s.logRetrySelectionChanged,
        ],
      );
      return;
    }
    final bool readyToTranslate = state.inspectedChapters.any(
      (InspectedChapter chapter) =>
          chapter.includeInTranslation && chapter.blocks.isNotEmpty,
    );
    if (state.job?.status == TranslationJobStatus.inspected &&
        readyToTranslate) {
      // The "continuing" line is appended inside startTranslation at queue
      // time so it always precedes run output; if the style-profile
      // confirmation gate stops startTranslation, it already logs
      // logConfirmStyleBeforeTranslate itself.
      await startTranslation(logRetryContinuation: true);
      return;
    }
    _pendingResumeProgressHint = null;
  }

  /// Clears the job history. Awaits the tombstone write so a user who closes
  /// the app immediately afterwards cannot lose the clear: the old
  /// fire-and-forget persist was dropped by the `!mounted` guard on dispose,
  /// and the next launch resurrected the "cleared" history.
  ///
  /// Returns false when the clear did not happen (a run is active) or the
  /// tombstone could not be persisted — the caller surfaces that to the user.
  Future<bool> clearJobHistory() async {
    // A run in progress would re-insert its job on the next progress callback
    // and silently undo the clear.
    if (_logIfRunActive(_s.logRunAlreadyActiveGeneric)) {
      return false;
    }
    _historyClearRevision += 1;
    // Our own clear is the newest tombstone by definition; keep it
    // strictly monotonic so a same-millisecond double clear cannot tie.
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs > _lastSeenHistoryClearedAt) {
      _lastSeenHistoryClearedAt = nowMs;
    }
    state = state.copyWith(
      jobHistory: const <TranslationJob>[],
      logs: <String>[...state.logs, _s.logClearedHistory],
    );
    // Wait for the chained save to actually land the tombstone on disk.
    // _pendingHistorySave swallows errors by design (it is a shared chain),
    // so await the error-propagating future instead: on disk failure the
    // "cleared" history would resurrect on next launch, and the user must
    // be told the clear did not stick.
    try {
      await _persistJobHistoryWithError();
    } catch (_) {
      if (mounted) {
        state = state.copyWith(
          logs: <String>[...state.logs, _s.logClearHistoryFailed],
        );
      }
      return false;
    }
    return true;
  }

  /// Maps a save-to-Downloads failure to its log line.
  ///
  /// Extracted (and marked test-only) so the SAVE_NO_SPACE → localized
  /// notice mapping stays covered by unit tests: the native bridge cannot
  /// be driven on a desktop test host, but the mapping itself must never
  /// regress to surfacing the raw English native text.
  @visibleForTesting
  String debugSaveErrorLogLine(Object error) {
    // A7: no free space for the save — show the localized notice, not
    // the raw English native text.
    if (error is PlatformException && error.code == 'SAVE_NO_SPACE') {
      return _s.logNotEnoughSpace;
    }
    final String safeError = _safeErrorText(error);
    // H3: the 5-minute Dart-side timeout only stops *waiting* — the
    // native worker keeps running to completion in the background,
    // so tell the user where to find the finished file.
    return safeError.contains('timed out')
        ? _s.saveTimeoutContinuesBackground
        : _s.logCouldNotSaveDownloads(safeError);
  }

  Future<String?> _completedOutputPath() async {
    final TranslationJob? job = state.job;
    final String outputPath = job?.outputPath ?? '';
    if (job == null || !job.hasExportableEpub) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logNoCompletedEpub],
      );
      return null;
    }

    final File outputFile = File(outputPath);
    final FileSystemEntityType type = await FileSystemEntity.type(outputPath);
    if (type != FileSystemEntityType.file || !await outputFile.exists()) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logOutputNotFound(outputPath)],
      );
      return null;
    }

    return outputPath;
  }

  /// Unique-enough job id: wall-clock millis plus a process-local monotonic
  /// suffix so two jobs created within the same millisecond cannot collide.
  String _newJobId() {
    _jobIdSequence += 1;
    return '${DateTime.now().millisecondsSinceEpoch}-$_jobIdSequence';
  }

  bool _logIfRunActive(String message) {
    if (!state.isRunActive) {
      return false;
    }
    state = state.copyWith(logs: <String>[...state.logs, message]);
    return true;
  }

  /// Maps a Windows path observation from the native bridge to a localized
  /// log line. Best-effort: never throws.
  void _logWindowsPathNotice(WindowsPathNotice notice, String? selectedPath) {
    final String message;
    switch (notice) {
      case WindowsPathNotice.dialogOpened:
        message = _s.logFileDialogOpened;
        break;
      case WindowsPathNotice.longPathWithoutPolicy:
        final String? path = selectedPath;
        if (path == null || path.isEmpty) {
          return;
        }
        message = _s.logLongPathWithoutPolicy(path);
        break;
      case WindowsPathNotice.oneDrivePlaceholder:
        message = _s.logOneDrivePlaceholderHint;
        break;
    }
    state = state.copyWith(logs: <String>[...state.logs, message]);
  }

  String _safeErrorText(Object error) {
    // Redact with the key that was in effect when the run started (an error
    // may surface the old key after the user changes it mid-run) as well as
    // the current key.
    String redacted = SensitiveText.redact(
      error.toString(),
      configuredApiKey: _runApiKey,
    );
    final String currentKey = state.config.apiKey;
    if (_runApiKey != currentKey) {
      redacted = SensitiveText.redact(redacted, configuredApiKey: currentKey);
    }
    return redacted;
  }

  /// Maps a file-picker failure to its log line. A path the WinForms dialog
  /// itself cannot handle gets an actionable localized message instead of
  /// a raw .NET stack trace; everything else keeps the generic wording.
  String _pickErrorLog(Object error, String Function(String error) genericLog) {
    if (error is WindowsLongPathException) {
      AppLogger.warn(
        'Windows dialog path too long: ${error.detail}',
        tag: 'picker',
      );
      return _s.logWindowsDialogPathTooLong;
    }
    if (error is PlatformException && error.code == 'PICK_NO_SPACE') {
      return _s.logNotEnoughSpace;
    }
    return genericLog(_safeErrorText(error));
  }

  /// C-M6: surfaces a permanently-denied storage permission (native error
  /// code `PERMISSION_PERMANENTLY_DENIED`) as a log line plus a notice id
  /// the UI can listen on to show a Snackbar whose action opens the system
  /// app-settings screen. Returns true when the error was handled.
  bool _handlePermanentPermissionDenial(Object error) {
    if (error is! PlatformException ||
        error.code != 'PERMISSION_PERMANENTLY_DENIED') {
      return false;
    }
    state = state.copyWith(
      permissionNoticeId: state.permissionNoticeId + 1,
      logs: <String>[...state.logs, _s.storagePermissionPermanentlyDenied],
    );
    return true;
  }

  /// C-M7: starts the Android foreground service that keeps translation
  /// alive under Doze. No-op off Android (also guarded inside the bridge,
  /// so desktop builds pay nothing).
  void _startTranslationForegroundService() {
    if (!PlatformUtils.isAndroid) {
      return;
    }
    _lastFgServicePercent = -1;
    _lastFgServiceChapter = null;
    // Opaque run token so the native side only applies stashed
    // notification updates to the run that produced them.
    _fgServiceRunId = DateTime.now().microsecondsSinceEpoch.toString();
    // The notification Stop action reaches back into Dart through this
    // handler and cancels the run via the normal cancel path.
    AndroidServiceBridge.setNotificationCancelHandler(requestCancel);
    // Android 15+ may stop the service after ~6h in the background. The
    // process then loses its foreground protection, so the run is wound
    // down through the normal cancel path instead of burning API tokens
    // in a process the system may kill at any moment. Block cache and
    // checkpoints survive, so the user can resume after reopening.
    AndroidServiceBridge.setForegroundServiceTimeoutHandler(() async {
      if (!state.isRunActive) {
        return;
      }
      // The native side may have persisted a timeout notice (notifications
      // were disabled, so the final system notification was dropped);
      // consume it now that the live callback arrived, so the next app
      // start doesn't surface the same timeout in-app a second time.
      unawaited(AndroidServiceBridge.consumePendingForegroundServiceTimeout());
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logForegroundServiceTimeout],
      );
      await requestCancel();
    });
    unawaited(
      AndroidServiceBridge.startTranslationService(
        title: _s.foregroundServiceTitle,
        text: path.basename(state.inputPath),
        stopLabel: _s.foregroundServiceStopAction,
        timeoutText: _s.foregroundServiceTimeoutText,
        runId: _fgServiceRunId,
      ).then((bool started) {
        // Android 12+ can refuse the start when the app is in the
        // background: the keep-alive is lost but the translation itself
        // continues — warn instead of failing silently.
        if (!started && mounted) {
          state = state.copyWith(
            logs: <String>[
              ...state.logs,
              _s.logForegroundServiceBackgroundDenied,
            ],
          );
        }
      }),
    );
  }

  /// C-M7: throttled notification refresh — every 5% of progress or on
  /// chapter change, so per-block progress callbacks don't spam the channel.
  void _updateTranslationForegroundService(TranslationJob job) {
    if (!PlatformUtils.isAndroid) {
      return;
    }
    final int percent = (job.progress.clamp(0.0, 1.0) * 100).round();
    final String? chapter = job.currentChapter;
    if (percent - _lastFgServicePercent < 5 &&
        chapter == _lastFgServiceChapter) {
      return;
    }
    _lastFgServicePercent = percent;
    _lastFgServiceChapter = chapter;
    unawaited(
      AndroidServiceBridge.updateTranslationNotification(
        progress: percent,
        text: _s.foregroundServiceText,
        runId: _fgServiceRunId,
      ),
    );
  }

  /// C-M7: stops the foreground service; always called from a finally block
  /// so completion, failure and cancellation all clean up.
  void _stopTranslationForegroundService() {
    if (!PlatformUtils.isAndroid) {
      return;
    }
    AndroidServiceBridge.setNotificationCancelHandler(null);
    AndroidServiceBridge.setForegroundServiceTimeoutHandler(null);
    unawaited(AndroidServiceBridge.stopTranslationService());
  }

  String _safeLogText(String logLine) {
    return SensitiveText.redact(logLine, configuredApiKey: state.config.apiKey);
  }

  bool _handleCancellation(Object error) {
    if (!_cancelRequested && error is! TranslationCancelledException) {
      return false;
    }
    final TranslationJob? currentJob = state.job;
    final TranslationJob cancelledJob = _translationHistoryJob(
      currentJob?.copyWith(
            status: TranslationJobStatus.cancelled,
            currentChapter: _s.jobStatusLabel(TranslationJobStatus.cancelled),
            currentBlock: null,
          ) ??
          TranslationJob(
            id: _newJobId(),
            inputPath: state.inputPath,
            outputPath: state.outputDirectory,
            status: TranslationJobStatus.cancelled,
            progress: 0,
            currentChapter: _s.jobStatusLabel(TranslationJobStatus.cancelled),
          ),
    );
    final bool translationRun = _isTranslationRunPhase(cancelledJob.phase);
    final int progressBlocks = _confirmedProgressBlocks(cancelledJob);
    state = state.copyWith(
      job: cancelledJob,
      jobHistory: _jobHistoryWith(cancelledJob),
      logs: <String>[
        ...state.logs,
        _s.logRunCancelled,
        if (progressBlocks > 0 && translationRun)
          _s.logResumeHint(progressBlocks),
      ],
      actionableError: ActionableErrorFactory.fromMessage(
        translationRun
            ? (state.config.uiLanguage == UiLanguage.chinese
                  ? '翻译已取消'
                  : 'Translation cancelled')
            : (state.config.uiLanguage == UiLanguage.chinese
                  ? '检查已取消'
                  : 'Inspection cancelled'),
        isChinese: state.config.uiLanguage == UiLanguage.chinese,
        preferredKind: translationRun
            ? ActionableErrorKind.retryTranslation
            : ActionableErrorKind.retryInspection,
      ),
    );
    _clearActiveTranslationHistory();
    _translationStopwatch?.stop();
    return true;
  }

  /// Surfaces a persisted foreground-service timeout notice on app start.
  /// When Android 15+ stops the service for exceeding its background time
  /// budget while notifications are disabled, the native side persists the
  /// timeout instead of posting a notification that would be silently
  /// dropped. If the live Dart callback never ran (the process died with
  /// the service), the notice is still pending here: show it in-app once.
  /// The live timeout handler consumes the notice itself, so a timeout
  /// that already wound the run down never shows twice.
  Future<void> _checkPendingForegroundServiceTimeout() async {
    if (!PlatformUtils.isAndroid) {
      return;
    }
    try {
      if (await AndroidServiceBridge.consumePendingForegroundServiceTimeout()) {
        if (!mounted) {
          return;
        }
        state = state.copyWith(
          logs: <String>[
            ...state.logs,
            _s.logForegroundServiceTimeoutRecovered,
          ],
        );
      }
    } catch (_) {
      // Best effort: a missing notice must not fail startup.
    }
  }

  Future<void> _loadSessionPaths() async {
    final SessionPathStore? store = pathStore;
    if (store == null) {
      return;
    }
    final int revisionBeforeLoad = _sessionPathRevision;
    final ({String inputPath, String outputDirectory}) paths = await store
        .load();
    if (!mounted) {
      return;
    }
    if (_sessionPathRevision != revisionBeforeLoad ||
        (paths.inputPath.isEmpty && paths.outputDirectory.isEmpty)) {
      return;
    }
    // A remembered EPUB may have been moved, renamed, or deleted between
    // sessions; only restore it when the file still exists. The output
    // directory is restored as-is: translation creates it when missing.
    final bool inputExists =
        paths.inputPath.isNotEmpty && await File(paths.inputPath).exists();
    state = state.copyWith(
      inputPath: inputExists ? paths.inputPath : state.inputPath,
      outputDirectory: paths.outputDirectory.isEmpty
          ? state.outputDirectory
          : paths.outputDirectory,
      logs: <String>[
        ...state.logs,
        if (inputExists) _s.logRestoredEpub(path.basename(paths.inputPath)),
        if (!inputExists && paths.inputPath.isNotEmpty)
          _s.logSkippedMissingInputPath(path.basename(paths.inputPath)),
        if (paths.outputDirectory.isNotEmpty)
          _s.logRestoredOutput(paths.outputDirectory),
      ],
    );
    // The picker/drag-drop/manual-entry flows run the Windows path
    // observations; a restored session path used to bypass them and lost
    // the early long-path/OneDrive warning. Fire-and-forget, like the
    // manual-entry flow.
    if (inputExists) {
      unawaited(_observeWindowsPathIfNeeded(paths.inputPath));
    }
    if (paths.outputDirectory.isNotEmpty) {
      unawaited(_observeWindowsPathIfNeeded(paths.outputDirectory));
    }
  }

  void _persistSessionPaths({
    required String inputPath,
    required String outputDirectory,
  }) {
    final SessionPathStore? store = pathStore;
    if (store == null) {
      return;
    }
    _pendingSessionPaths = (
      inputPath: inputPath,
      outputDirectory: outputDirectory,
    );
    if (_isSavingSessionPaths) {
      return;
    }
    _isSavingSessionPaths = true;
    unawaited(_drainSessionPathSaves(store));
  }

  Future<void> _drainSessionPathSaves(SessionPathStore store) async {
    while (_pendingSessionPaths != null) {
      final paths = _pendingSessionPaths!;
      _pendingSessionPaths = null;
      try {
        await store.save(
          inputPath: paths.inputPath,
          outputDirectory: paths.outputDirectory,
        );
      } catch (error) {
        AppLogger.warn('Failed to persist session paths: $error', tag: 'paths');
      }
    }
    _isSavingSessionPaths = false;
  }

  TranslationJob _translationHistoryJob(TranslationJob job) {
    final String? historyJobId = _activeTranslationHistoryJobId;
    return historyJobId == null
        ? job
        : job.copyWith(
            id: historyJobId,
            selectedChapterPaths: _activeTranslationChapterPaths,
          );
  }

  void _clearActiveTranslationHistory() {
    _activeTranslationHistoryJobId = null;
    _activeTranslationChapterPaths = null;
    _lastProgressHistoryPersistAt = null;
  }

  void _persistProgressHistoryIfDue() {
    final DateTime now = DateTime.now();
    final DateTime? lastPersist = _lastProgressHistoryPersistAt;
    if (lastPersist != null &&
        now.difference(lastPersist) < const Duration(seconds: 1)) {
      return;
    }
    _lastProgressHistoryPersistAt = now;
    _persistJobHistory();
  }

  List<TranslationJob> _jobHistoryWith(
    TranslationJob job, {
    bool persist = true,
  }) {
    final List<TranslationJob> history = <TranslationJob>[
      job,
      ...state.jobHistory.where(
        (TranslationJob historyJob) => historyJob.id != job.id,
      ),
    ].take(20).toList(growable: false);
    if (persist) {
      _persistJobHistory();
    }
    return history;
  }

  TranslationRunEstimate? _buildEstimate({
    List<InspectedChapter>? chapters,
    TranslationConfig? config,
    TranslationJob? job,
  }) {
    final List<InspectedChapter> sourceChapters =
        chapters ?? state.inspectedChapters;
    if (sourceChapters.isEmpty) {
      return null;
    }
    return TranslationRunEstimate.fromChapters(
      sourceChapters,
      chunkSize: (config ?? state.config).chunkSize,
      job: job ?? state.job,
      elapsed: _translationStopwatch?.elapsed,
    );
  }

  TranslationJob? _findKnownJob(String jobId) {
    final TranslationJob? currentJob = state.job;
    if (currentJob?.id == jobId) {
      return currentJob;
    }
    for (final TranslationJob job in state.jobHistory) {
      if (job.id == jobId) {
        return job;
      }
    }
    return null;
  }

  String _outputDirectoryForRetry(TranslationJob job) {
    if (job.outputPath.isEmpty) {
      return state.outputDirectory;
    }
    if (path.extension(job.outputPath).toLowerCase() == '.epub') {
      return path.dirname(job.outputPath);
    }
    return job.outputPath;
  }

  Future<void> _loadJobHistory() async {
    final JobHistoryStore? store = historyStore;
    if (store == null) {
      return;
    }
    final int clearRevisionBeforeLoad = _historyClearRevision;
    final ({List<TranslationJob> jobs, int clearedAt}) loaded = await store
        .loadWithTombstone();
    // Never move the tombstone backwards: a clear that landed while this
    // load was in flight already recorded a newer timestamp, and adopting
    // the stale file value here would let a later persist overwrite a fresh
    // tombstone with 0.
    if (loaded.clearedAt > _lastSeenHistoryClearedAt) {
      _lastSeenHistoryClearedAt = loaded.clearedAt;
    }
    final List<TranslationJob> history = loaded.jobs
        .map(_restoreInterruptedJob)
        .toList(growable: false);
    if (!mounted) {
      return;
    }
    if (_historyClearRevision != clearRevisionBeforeLoad || history.isEmpty) {
      return;
    }
    state = state.copyWith(jobHistory: _mergeJobHistory(history));
  }

  TranslationJob _restoreInterruptedJob(TranslationJob job) {
    if (job.status != TranslationJobStatus.queued &&
        job.status != TranslationJobStatus.running) {
      return job;
    }
    return job.copyWith(
      status: TranslationJobStatus.cancelled,
      currentChapter: _isTranslationRunPhase(job.phase)
          ? _s.jobStatusTranslationInterrupted
          : _s.jobStatusInspectionInterrupted,
      currentBlock: null,
      // Note: the retry heuristic reads `phase`, not this display string,
      // so currentChapter is safe to localize.
      errorMessage: _s.jobInterruptedOnRestart,
    );
  }

  List<TranslationJob> _mergeJobHistory(List<TranslationJob> jobs) {
    final Set<String> included = <String>{};
    final List<TranslationJob> merged = <TranslationJob>[
      ...state.jobHistory,
      ...jobs,
    ];
    return merged
        .where((TranslationJob job) => included.add(job.id))
        .take(20)
        .toList(growable: false);
  }

  void _persistJobHistory() {
    unawaited(_persistJobHistoryWithError());
  }

  /// Persists the job history, returning a future that completes with an
  /// error when the write fails (unlike the shared [_pendingHistorySave]
  /// chain, which swallows errors by design so later passes are not
  /// poisoned).
  Future<void> _persistJobHistoryWithError() {
    final JobHistoryStore? store = historyStore;
    if (store == null) {
      return Future<void>.value();
    }
    final Future<void> save = _pendingHistorySave.then<void>(
      (_) => debugPersistJobHistoryNow(),
      onError: (_) => debugPersistJobHistoryNow(),
    );
    _pendingHistorySave = save.catchError((_) {});
    return save;
  }

  /// Test-only: runs a single history persistence pass, including the
  /// cross-instance clear-tombstone guard.
  @visibleForTesting
  Future<void> debugPersistJobHistoryNow() async {
    final JobHistoryStore? store = historyStore;
    if (store == null) {
      return;
    }
    await _initialJobHistoryLoad;
    if (!mounted) {
      return;
    }
    // Cross-instance guard: if another app instance cleared the history
    // after our last read, its tombstone wins — skip this write instead of
    // resurrecting the cleared entries.
    final int fileClearedAt = (await store.loadWithTombstone()).clearedAt;
    if (fileClearedAt > _lastSeenHistoryClearedAt) {
      _lastSeenHistoryClearedAt = fileClearedAt;
      // Our in-memory entries predate that clear, so they are stale: drop
      // them now. Skipping just this one write is not enough — the next
      // persistence pass (progress tick, run end) would write the stale
      // entries back and resurrect the cleared history. The active run is
      // unaffected: it is tracked via state.job and re-inserted into the
      // history on completion.
      if (state.jobHistory.isNotEmpty) {
        state = state.copyWith(jobHistory: const <TranslationJob>[]);
      }
      return;
    }
    await store.save(
      state.jobHistory,
      clearedAtEpochMs: _lastSeenHistoryClearedAt,
    );
  }
}
