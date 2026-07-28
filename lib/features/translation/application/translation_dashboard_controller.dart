import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/logging/app_logger.dart';
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
  }) : super(TranslationDashboardState.initial()) {
    _initialJobHistoryLoad = _loadJobHistory();
    _loadSessionPaths();
  }

  final TranslationRepository repository;
  final JobHistoryStore? historyStore;
  final SessionPathStore? pathStore;
  final Future<void> Function()? settingsReady;
  bool _cancelRequested = false;
  Stopwatch? _translationStopwatch;
  Future<void> _pendingHistorySave = Future<void>.value();
  late final Future<void> _initialJobHistoryLoad;
  int _sessionPathRevision = 0;
  int _historyClearRevision = 0;
  _ResumeProgressHint? _pendingResumeProgressHint;

  AppStrings get _s => AppStrings(state.config.uiLanguage);

  Future<bool> _waitForSettingsReady() async {
    final Future<void> Function()? wait = settingsReady;
    if (wait != null) {
      await wait();
    }
    return mounted;
  }

  Future<void> pickInputPath() async {
    if (_logIfRunActive(_s.logSelectAfterRun)) {
      return;
    }
    String? selectedPath;
    try {
      selectedPath = await PlatformUtils.pickEpubFile();
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _s.logCouldNotSelectEpub(_safeErrorText(error)),
        ],
      );
      return;
    }
    if (selectedPath == null || selectedPath.isEmpty) {
      return;
    }
    await _acceptInputPath(selectedPath, dropped: false);
  }

  /// Returns true when an EPUB path was accepted into state.
  Future<bool> importDroppedEpubPath(String droppedPath) async {
    if (_logIfRunActive(_s.logDropAfterRun)) {
      return false;
    }
    return _acceptInputPath(droppedPath, dropped: true);
  }

  Future<void> pickOutputDirectory() async {
    if (_logIfRunActive(_s.logChangeOutputAfterRun)) {
      return;
    }
    if (!PlatformUtils.supportsDirectoryPicker) {
      _sessionPathRevision += 1;
      final String outputDirectory = await PlatformUtils.defaultOutputDirectory(
        state.inputPath,
      );
      state = state.copyWith(
        outputDirectory: outputDirectory,
        logs: <String>[...state.logs, _s.logAndroidOutputDir(outputDirectory)],
      );
      return;
    }

    final String? selectedDirectory = await PlatformUtils.pickDirectory();
    if (selectedDirectory == null || selectedDirectory.isEmpty) {
      return;
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
    state = state.copyWith(
      inputPath: value,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      styleProfile: TranslationStyleProfile.empty,
      styleProfileConfirmed: false,
      isGeneratingStyleProfile: false,
    );
  }

  Future<bool> _acceptInputPath(String value, {required bool dropped}) async {
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
    final String inferredOutput = state.outputDirectory.isEmpty
        ? await PlatformUtils.defaultOutputDirectory(normalizedPath)
        : state.outputDirectory;
    final String base = path.basename(normalizedPath);
    state = state.copyWith(
      inputPath: normalizedPath,
      outputDirectory: inferredOutput,
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
      outputDirectory: inferredOutput,
    );
    return true;
  }

  void setOutputDirectory(String value) {
    if (state.isRunActive) {
      state = state.copyWith(logs: <String>[...state.logs, _s.logOutputLocked]);
      return;
    }
    _sessionPathRevision += 1;
    state = state.copyWith(outputDirectory: value);
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

    final String outputDirectory = state.outputDirectory.isEmpty
        ? await PlatformUtils.defaultOutputDirectory(state.inputPath)
        : state.outputDirectory;
    _cancelRequested = false;

    state = state.copyWith(
      outputDirectory: outputDirectory,
      actionableError: null,
      job: TranslationJob(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        inputPath: state.inputPath,
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
        _s.logStartingInspection(path.basename(state.inputPath)),
      ],
    );
    _persistSessionPaths(
      inputPath: state.inputPath,
      outputDirectory: outputDirectory,
    );

    try {
      final InspectionResult result = await repository.startJob(
        inputPath: state.inputPath,
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
      state = state.copyWith(
        job: result.job.copyWith(phase: TranslationJobPhase.inspection),
        jobHistory: _jobHistoryWith(
          result.job.copyWith(phase: TranslationJobPhase.inspection),
        ),
        runEstimate: _buildEstimate(chapters: result.chapters, job: result.job),
        inspectedChapters: result.chapters,
        styleProfile: preservedStyleProfile ?? TranslationStyleProfile.empty,
        styleProfileConfirmed:
            preservedStyleProfile != null || !state.config.styleProfileEnabled,
        isGeneratingStyleProfile: false,
        actionableError: null,
      );
      if (state.config.styleProfileEnabled && preservedStyleProfile == null) {
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
            currentChapter: 'Inspection failed',
            errorMessage: safeError,
          ) ??
          TranslationJob(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            inputPath: state.inputPath,
            outputPath: outputDirectory,
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.inspection,
            progress: 0,
            currentChapter: 'Inspection failed',
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

  Future<void> startTranslation() async {
    if (!await _waitForSettingsReady()) {
      return;
    }
    if (_logIfRunActive(_s.logRunAlreadyActiveTranslate)) {
      return;
    }
    if (state.inspectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logInspectBeforeTranslate],
      );
      return;
    }

    final List<InspectedChapter> selectedChapters = state.inspectedChapters
        .where(
          (InspectedChapter chapter) =>
              chapter.includeInTranslation && chapter.blocks.isNotEmpty,
        )
        .toList();
    final int selectedBlocks = selectedChapters.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );
    if (selectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logNoChaptersChecked],
      );
      return;
    }
    if (state.requiresStyleProfileConfirmation) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logConfirmStyleBeforeTranslate],
      );
      return;
    }

    _cancelRequested = false;
    _translationStopwatch = Stopwatch()..start();
    final _ResumeProgressHint? resumeHint =
        _pendingResumeProgressHint?.totalBlocks == selectedBlocks
        ? _pendingResumeProgressHint
        : null;
    _pendingResumeProgressHint = null;
    final int checkpointBlocks = (resumeHint?.completedBlocks ?? 0).clamp(
      0,
      selectedBlocks,
    );
    final double checkpointProgress = selectedBlocks == 0
        ? 0
        : checkpointBlocks / selectedBlocks;
    final TranslationJob queuedJob =
        state.job?.copyWith(
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.cacheRestoration,
          progress: checkpointProgress,
          currentChapter: 'Restoring cached translations',
          currentBlock: null,
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: checkpointBlocks,
          totalBlocks: selectedBlocks,
          cachedBlocks: 0,
          resumedBlocks: 0,
          resumeCheckpointBlocks: checkpointBlocks,
          cacheScanScannedBlocks: 0,
          cacheScanTotalBlocks: selectedBlocks,
          styleProfile: state.styleProfile,
          styleProfileConfirmed: state.styleProfileConfirmed,
          styleProfileEnabled: state.config.styleProfileEnabled,
        ) ??
        TranslationJob(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          inputPath: state.inputPath,
          outputPath: state.outputDirectory,
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.cacheRestoration,
          progress: checkpointProgress,
          currentChapter: 'Restoring cached translations',
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: checkpointBlocks,
          totalBlocks: selectedBlocks,
          resumeCheckpointBlocks: checkpointBlocks,
          cacheScanScannedBlocks: 0,
          cacheScanTotalBlocks: selectedBlocks,
          styleProfile: state.styleProfile,
          styleProfileConfirmed: state.styleProfileConfirmed,
          styleProfileEnabled: state.config.styleProfileEnabled,
        );
    final TranslationRunEstimate? estimate = _buildEstimate(job: queuedJob);
    state = state.copyWith(
      job: queuedJob,
      jobHistory: _jobHistoryWith(queuedJob),
      runEstimate: estimate,
      actionableError: null,
      logs: <String>[
        ...state.logs,
        _s.logQueuedTranslation(selectedChapters.length, selectedBlocks),
        if (estimate != null)
          _s.logRoughLoad(
            estimate.estimatedApiBatches,
            estimate.estimatedInputTokens,
            estimate.estimatedSourceChars,
          ),
      ],
    );

    bool cacheRestorationLogged = false;
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
          final List<String> nextLogs = <String>[
            ...state.logs,
            _safeLogText(logLine),
          ];
          final bool cacheScanComplete =
              job.phase == TranslationJobPhase.cacheRestoration &&
              job.cacheScanTotalBlocks > 0 &&
              job.cacheScanScannedBlocks >= job.cacheScanTotalBlocks;
          if (!cacheRestorationLogged && cacheScanComplete) {
            cacheRestorationLogged = true;
            nextLogs.add(
              job.cachedBlocks >= job.totalBlocks
                  ? _s.logAllBlocksRestoredNoApi(job.totalBlocks)
                  : _s.logCacheRestoredNoApi(job.cachedBlocks),
            );
          }
          state = state.copyWith(
            job: job,
            runEstimate: _buildEstimate(job: job),
            logs: nextLogs,
          );
        },
        isCancelled: () => _cancelRequested,
      );
      if (_cancelRequested) {
        _handleCancellation(const TranslationCancelledException());
        return;
      }
      state = state.copyWith(
        job: result.job.copyWith(phase: TranslationJobPhase.translation),
        jobHistory: _jobHistoryWith(
          result.job.copyWith(phase: TranslationJobPhase.translation),
        ),
        runEstimate: _buildEstimate(job: result.job),
        inspectedChapters: result.chapters,
        actionableError: null,
        logs: <String>[
          ...state.logs,
          PlatformUtils.isAndroid
              ? _s.logTranslationCompleteAndroid
              : _s.logTranslationCompleteDesktop,
          if (result.job.cachedBlocks > 0 || result.job.resumedBlocks > 0)
            _s.logCacheResume(
              result.job.cachedBlocks,
              result.job.resumedBlocks,
            ),
        ],
      );
      _translationStopwatch?.stop();
    } catch (error) {
      if (_handleCancellation(error)) {
        return;
      }
      final String safeError = _safeErrorText(error);
      AppLogger.error('Translation failed', tag: 'dashboard', error: safeError);
      final TranslationJob failedJob =
          state.job?.copyWith(
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.translation,
            currentChapter: 'Translation failed',
            currentBlock: null,
            errorMessage: safeError,
          ) ??
          TranslationJob(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            inputPath: state.inputPath,
            outputPath: state.outputDirectory,
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.translation,
            progress: 0,
            currentChapter: 'Translation failed',
            errorMessage: safeError,
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
      _translationStopwatch?.stop();
    }
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
    await repository.cancelJob(activeJob.id);
    final TranslationJob cancellingJob = activeJob.copyWith(
      currentChapter: 'Cancellation requested',
      currentBlock: null,
    );
    // completedBlocks already includes cache hits; do not sum cache/resume/done.
    final int progressBlocks = activeJob.completedBlocks;
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
    final String? outputPath = await _completedOutputPath();
    if (outputPath == null) {
      return;
    }

    try {
      if (PlatformUtils.isAndroid) {
        await PlatformUtils.shareFile(
          sourcePath: outputPath,
          displayName: path.basename(outputPath),
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
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _s.logCouldNotExport(_safeErrorText(error)),
        ],
      );
    }
  }

  Future<void> saveTranslatedEpubToDownloads() async {
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
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          savedPath == null
              ? _s.logDownloadsAndroidOnly
              : _s.logSavedToDownloads(savedPath),
        ],
      );
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _s.logCouldNotSaveDownloads(_safeErrorText(error)),
        ],
      );
    }
  }

  Future<void> openJobOutput(String jobId) async {
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
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          _s.logCouldNotOpenJobOutput(_safeErrorText(error)),
        ],
      );
    }
  }

  Future<void> retryJob(String jobId) async {
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
        job.status != TranslationJobStatus.cancelled) {
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
    final bool wasTranslationFailure =
        (job.currentChapter ?? '').toLowerCase().contains('translation') ||
        job.totalBlocks > 0 ||
        job.completedBlocks > 0;
    _pendingResumeProgressHint = wasTranslationFailure && job.totalBlocks > 0
        ? _ResumeProgressHint(
            completedBlocks: job.completedBlocks,
            totalBlocks: job.totalBlocks,
          )
        : null;
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
    await startInspection(preservedStyleProfile: preservedStyleProfile);
    if (!mounted) {
      return;
    }
    if (!wasTranslationFailure) {
      _pendingResumeProgressHint = null;
      return;
    }
    final bool readyToTranslate = state.inspectedChapters.any(
      (InspectedChapter chapter) =>
          chapter.includeInTranslation && chapter.blocks.isNotEmpty,
    );
    if (state.job?.status == TranslationJobStatus.inspected &&
        readyToTranslate) {
      state = state.copyWith(
        logs: <String>[...state.logs, _s.logRetryContinueTranslate],
      );
      await startTranslation();
      return;
    }
    _pendingResumeProgressHint = null;
  }

  void clearJobHistory() {
    _historyClearRevision += 1;
    state = state.copyWith(
      jobHistory: const <TranslationJob>[],
      logs: <String>[...state.logs, _s.logClearedHistory],
    );
    _persistJobHistory();
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

  bool _logIfRunActive(String message) {
    if (!state.isRunActive) {
      return false;
    }
    state = state.copyWith(logs: <String>[...state.logs, message]);
    return true;
  }

  String _safeErrorText(Object error) {
    return SensitiveText.redact(
      error.toString(),
      configuredApiKey: state.config.apiKey,
    );
  }

  String _safeLogText(String logLine) {
    return SensitiveText.redact(logLine, configuredApiKey: state.config.apiKey);
  }

  bool _handleCancellation(Object error) {
    if (!_cancelRequested && error is! TranslationCancelledException) {
      return false;
    }
    final TranslationJob? currentJob = state.job;
    final TranslationJob cancelledJob =
        currentJob?.copyWith(
          status: TranslationJobStatus.cancelled,
          currentChapter: 'Cancelled',
          currentBlock: null,
        ) ??
        TranslationJob(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          inputPath: state.inputPath,
          outputPath: state.outputDirectory,
          status: TranslationJobStatus.cancelled,
          progress: 0,
          currentChapter: 'Cancelled',
        );
    // completedBlocks already includes cache hits; do not sum cache/resume/done.
    final int progressBlocks = cancelledJob.completedBlocks;
    state = state.copyWith(
      job: cancelledJob,
      jobHistory: _jobHistoryWith(cancelledJob),
      logs: <String>[
        ...state.logs,
        _s.logRunCancelled,
        if (progressBlocks > 0 &&
            cancelledJob.phase == TranslationJobPhase.translation)
          _s.logResumeHint(progressBlocks),
      ],
      actionableError: ActionableErrorFactory.fromMessage(
        cancelledJob.phase == TranslationJobPhase.translation
            ? (state.config.uiLanguage == UiLanguage.chinese
                  ? '翻译已取消'
                  : 'Translation cancelled')
            : (state.config.uiLanguage == UiLanguage.chinese
                  ? '检查已取消'
                  : 'Inspection cancelled'),
        isChinese: state.config.uiLanguage == UiLanguage.chinese,
        preferredKind: cancelledJob.phase == TranslationJobPhase.translation
            ? ActionableErrorKind.retryTranslation
            : ActionableErrorKind.retryInspection,
      ),
    );
    _translationStopwatch?.stop();
    return true;
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
    state = state.copyWith(
      inputPath: paths.inputPath.isEmpty ? state.inputPath : paths.inputPath,
      outputDirectory: paths.outputDirectory.isEmpty
          ? state.outputDirectory
          : paths.outputDirectory,
      logs: <String>[
        ...state.logs,
        if (paths.inputPath.isNotEmpty)
          _s.logRestoredEpub(path.basename(paths.inputPath)),
        if (paths.outputDirectory.isNotEmpty)
          _s.logRestoredOutput(paths.outputDirectory),
      ],
    );
  }

  void _persistSessionPaths({
    required String inputPath,
    required String outputDirectory,
  }) {
    final SessionPathStore? store = pathStore;
    if (store == null) {
      return;
    }
    // Fire-and-forget so UI interactions never block on disk IO.
    store
        .save(inputPath: inputPath, outputDirectory: outputDirectory)
        .catchError((Object error) {
          AppLogger.warn(
            'Failed to persist session paths: $error',
            tag: 'paths',
          );
        });
  }

  List<TranslationJob> _jobHistoryWith(TranslationJob job) {
    final List<TranslationJob> history = <TranslationJob>[
      job,
      ...state.jobHistory.where(
        (TranslationJob historyJob) => historyJob.id != job.id,
      ),
    ].take(20).toList(growable: false);
    _persistJobHistory();
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
    final List<TranslationJob> history = (await store.load())
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
      currentChapter: job.phase == TranslationJobPhase.translation
          ? 'Translation interrupted'
          : 'Inspection interrupted',
      currentBlock: null,
      errorMessage: 'The application closed before this task finished.',
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
    final JobHistoryStore? store = historyStore;
    if (store == null) {
      return;
    }
    Future<void> saveLatestHistory() async {
      await _initialJobHistoryLoad;
      if (!mounted) {
        return;
      }
      await store.save(state.jobHistory);
    }

    final Future<void> save = _pendingHistorySave.then<void>(
      (_) => saveLatestHistory(),
      onError: (_) => saveLatestHistory(),
    );
    _pendingHistorySave = save.catchError((_) {});
  }
}
