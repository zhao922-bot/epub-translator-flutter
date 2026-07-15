import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

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
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: ref.watch(translationRepositoryProvider),
            historyStore: ref.watch(jobHistoryStoreProvider),
            pathStore: ref.watch(sessionPathStoreProvider),
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

  bool get isRunActive {
    final TranslationJobStatus? status = job?.status;
    return status == TranslationJobStatus.queued ||
        status == TranslationJobStatus.running;
  }

  factory TranslationDashboardState.initial() {
    return TranslationDashboardState(
      config: TranslationConfig.defaults(),
      inputPath: '',
      outputDirectory: '',
      job: null,
      jobHistory: const <TranslationJob>[],
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      logs: const <String>[
        'Ready to inspect an EPUB.',
        'Choose a book and output folder, then inspect the spine to see real progress.',
      ],
      actionableError: null,
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
    );
  }

  static List<String> _trimLogs(List<String> logs) {
    if (logs.length <= _maxLogLines) {
      return logs;
    }
    return logs.sublist(logs.length - _maxLogLines);
  }
}

class TranslationDashboardController
    extends StateNotifier<TranslationDashboardState> {
  TranslationDashboardController({
    required this.repository,
    this.historyStore,
    this.pathStore,
  }) : super(TranslationDashboardState.initial()) {
    _loadJobHistory();
    _loadSessionPaths();
  }

  final TranslationRepository repository;
  final JobHistoryStore? historyStore;
  final SessionPathStore? pathStore;
  bool _cancelRequested = false;
  Stopwatch? _translationStopwatch;
  Future<void> _pendingHistorySave = Future<void>.value();

  Future<void> pickInputPath() async {
    if (_logIfRunActive('Select a new EPUB after the current run finishes.')) {
      return;
    }
    String? selectedPath;
    try {
      selectedPath = await PlatformUtils.pickEpubFile();
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Could not select EPUB: ${_safeErrorText(error)}',
        ],
      );
      return;
    }
    if (selectedPath == null || selectedPath.isEmpty) {
      return;
    }
    await _acceptInputPath(selectedPath, sourceLabel: 'Selected EPUB');
  }

  Future<void> importDroppedEpubPath(String droppedPath) async {
    if (_logIfRunActive('Drop a new EPUB after the current run finishes.')) {
      return;
    }
    await _acceptInputPath(droppedPath, sourceLabel: 'Dropped EPUB');
  }

  Future<void> pickOutputDirectory() async {
    if (_logIfRunActive(
      'Change the output directory after the current run finishes.',
    )) {
      return;
    }
    if (!PlatformUtils.supportsDirectoryPicker) {
      final String outputDirectory = await PlatformUtils.defaultOutputDirectory(
        state.inputPath,
      );
      state = state.copyWith(
        outputDirectory: outputDirectory,
        logs: <String>[
          ...state.logs,
          'Android uses an app-managed output directory: $outputDirectory',
        ],
      );
      return;
    }

    final String? selectedDirectory = await PlatformUtils.pickDirectory();
    if (selectedDirectory == null || selectedDirectory.isEmpty) {
      return;
    }
    state = state.copyWith(
      outputDirectory: selectedDirectory,
      logs: <String>[
        ...state.logs,
        'Selected output directory: $selectedDirectory',
      ],
    );
  }

  void setInputPath(String value) {
    if (state.isRunActive) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Input path is locked while a run is in progress.',
        ],
      );
      return;
    }
    state = state.copyWith(
      inputPath: value,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
    );
  }

  Future<void> _acceptInputPath(
    String value, {
    required String sourceLabel,
  }) async {
    final String normalizedPath = value.trim();
    if (normalizedPath.isEmpty) {
      return;
    }
    if (path.extension(normalizedPath).toLowerCase() != '.epub') {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Please choose a .epub file.'],
      );
      return;
    }

    final String inferredOutput = state.outputDirectory.isEmpty
        ? await PlatformUtils.defaultOutputDirectory(normalizedPath)
        : state.outputDirectory;
    state = state.copyWith(
      inputPath: normalizedPath,
      outputDirectory: inferredOutput,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      actionableError: null,
      logs: <String>[
        ...state.logs,
        '$sourceLabel: ${path.basename(normalizedPath)}',
      ],
    );
    _persistSessionPaths(
      inputPath: normalizedPath,
      outputDirectory: inferredOutput,
    );
  }

  void setOutputDirectory(String value) {
    if (state.isRunActive) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Output directory is locked while a run is in progress.',
        ],
      );
      return;
    }
    state = state.copyWith(outputDirectory: value);
  }

  void setTargetLanguage(String value) {
    state = state.copyWith(
      config: state.config.copyWith(targetLanguage: value),
    );
  }

  void setBilingual(bool value) {
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
    final List<InspectedChapter> nextChapters = state.inspectedChapters
        .map(
          (InspectedChapter chapter) => chapter.path == chapterPath
              ? chapter.copyWith(includeInTranslation: includeInTranslation)
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
    if (state.inspectedChapters.isEmpty) {
      return;
    }
    final List<InspectedChapter> nextChapters = preset.apply(
      state.inspectedChapters,
    );
    state = state.copyWith(
      inspectedChapters: nextChapters,
      runEstimate: _buildEstimate(chapters: nextChapters),
      logs: <String>[
        ...state.logs,
        'Applied chapter selection preset: ${preset.name}.',
      ],
    );
  }

  void clearActionableError() {
    state = state.copyWith(actionableError: null);
  }

  Future<void> startInspection() async {
    if (_logIfRunActive(
      'A run is already in progress. Cancel it or wait before starting inspection.',
    )) {
      return;
    }
    if (state.inputPath.isEmpty) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Pick an EPUB file before starting inspection.',
        ],
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
      logs: <String>[
        ...state.logs,
        'Starting EPUB inspection for ${path.basename(state.inputPath)}',
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
        actionableError: null,
      );
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
        logs: <String>[...state.logs, 'Inspection failed: $safeError'],
        actionableError: ActionableErrorFactory.fromMessage(
          'Inspection failed: $safeError',
          isChinese: state.config.uiLanguage == UiLanguage.chinese,
        ),
      );
    }
  }

  Future<void> startTranslation() async {
    if (_logIfRunActive(
      'A run is already in progress. Cancel it or wait before starting translation.',
    )) {
      return;
    }
    if (state.inspectedChapters.isEmpty) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Inspect an EPUB before starting translation.',
        ],
      );
      return;
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
        logs: <String>[
          ...state.logs,
          'No chapters are checked for translation yet.',
        ],
      );
      return;
    }

    _cancelRequested = false;
    _translationStopwatch = Stopwatch()..start();
    final TranslationJob queuedJob =
        state.job?.copyWith(
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.translation,
          progress: 0,
          currentChapter: 'Queued for translation',
          currentBlock: null,
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: 0,
          totalBlocks: selectedBlocks,
        ) ??
        TranslationJob(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          inputPath: state.inputPath,
          outputPath: state.outputDirectory,
          status: TranslationJobStatus.queued,
          phase: TranslationJobPhase.translation,
          progress: 0,
          currentChapter: 'Queued for translation',
          completedFiles: 0,
          totalFiles: selectedChapters.length,
          completedBlocks: 0,
          totalBlocks: selectedBlocks,
        );
    final TranslationRunEstimate? estimate = _buildEstimate(job: queuedJob);
    state = state.copyWith(
      job: queuedJob,
      runEstimate: estimate,
      actionableError: null,
      logs: <String>[
        ...state.logs,
        'Queued translation for ${selectedChapters.length} chapters and $selectedBlocks blocks.',
        if (estimate != null)
          'Rough load: ~${estimate.estimatedApiBatches} API batches, ~${estimate.estimatedInputTokens} input tokens (source chars ${estimate.estimatedSourceChars}).',
      ],
    );

    try {
      final TranslationRunResult result = await repository.translateChapters(
        inputPath: state.inputPath,
        outputDirectory: state.outputDirectory,
        config: state.config,
        chapters: state.inspectedChapters,
        onProgress: (TranslationJob job, String logLine) {
          if (_cancelRequested) {
            return;
          }
          state = state.copyWith(
            job: job,
            runEstimate: _buildEstimate(job: job),
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
              ? 'Translation complete. Use Share EPUB to export the book from Android.'
              : 'Translation complete. Use Open EPUB to view the output file.',
          if (result.job.cachedBlocks > 0 || result.job.resumedBlocks > 0)
            'Cache/resume: ${result.job.cachedBlocks} cached, ${result.job.resumedBlocks} resumed blocks.',
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
          'Translation failed: $safeError',
          if (savedBlocks > 0)
            'Progress was checkpointed (~$savedBlocks blocks). Tap Translate again to resume from cache.',
        ],
        actionableError: ActionableErrorFactory.fromMessage(
          'Translation failed: $safeError',
          isChinese: state.config.uiLanguage == UiLanguage.chinese,
        ),
      );
      _translationStopwatch?.stop();
    }
  }

  Future<void> requestCancel() async {
    final TranslationJob? activeJob = state.job;
    if (activeJob == null || !state.isRunActive) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'No active run is available to cancel.'],
      );
      return;
    }

    if (_cancelRequested) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Cancellation is already pending. In-flight HTTP requests are being aborted when possible.',
        ],
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
        'Cancellation requested. Aborting in-flight API calls when possible.',
        if (progressBlocks > 0)
          'Cached progress so far: ~$progressBlocks blocks. After cancel, press Translate selected to resume.',
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
            'Opened Android share sheet for ${path.basename(outputPath)}.',
          ],
        );
        return;
      }

      final OpenResult result = await OpenFilex.open(outputPath);
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          result.type == ResultType.done
              ? 'Opened translated EPUB: ${path.basename(outputPath)}'
              : 'Could not open translated EPUB: ${result.message}',
        ],
      );
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Could not export EPUB: ${_safeErrorText(error)}',
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
              ? 'Saving to Downloads is only available on Android.'
              : 'Saved translated EPUB to $savedPath.',
        ],
      );
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Could not save EPUB to Downloads: ${_safeErrorText(error)}',
        ],
      );
    }
  }

  Future<void> openJobOutput(String jobId) async {
    final TranslationJob? job = _findKnownJob(jobId);
    final String outputPath = job?.outputPath ?? '';
    if (job == null || !job.hasExportableEpub) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'No output file is available for this history item.',
        ],
      );
      return;
    }

    final File outputFile = File(outputPath);
    final FileSystemEntityType type = await FileSystemEntity.type(outputPath);
    if (type != FileSystemEntityType.file || !await outputFile.exists()) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Output file was not found: $outputPath'],
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
            'Opened Android share sheet for ${path.basename(outputPath)}.',
          ],
        );
        return;
      }
      final OpenResult result = await OpenFilex.open(outputPath);
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          result.type == ResultType.done
              ? 'Opened translated EPUB: ${path.basename(outputPath)}'
              : 'Could not open translated EPUB: ${result.message}',
        ],
      );
    } catch (error) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Could not open job output: ${_safeErrorText(error)}',
        ],
      );
    }
  }

  Future<void> retryJob(String jobId) async {
    if (_logIfRunActive(
      'Wait for the current run to finish before retrying a history item.',
    )) {
      return;
    }
    final TranslationJob? job = _findKnownJob(jobId);
    if (job == null) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Could not find that history item.'],
      );
      return;
    }
    if (job.status != TranslationJobStatus.failed &&
        job.status != TranslationJobStatus.cancelled) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Only failed or cancelled jobs can be retried.',
        ],
      );
      return;
    }
    if (job.inputPath.isEmpty) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'This history item does not include an EPUB path to retry.',
        ],
      );
      return;
    }

    final String outputDirectory = _outputDirectoryForRetry(job);
    final bool wasTranslationFailure =
        (job.currentChapter ?? '').toLowerCase().contains('translation') ||
        job.totalBlocks > 0 ||
        job.completedBlocks > 0;
    state = state.copyWith(
      inputPath: job.inputPath,
      outputDirectory: outputDirectory,
      job: null,
      runEstimate: null,
      inspectedChapters: const <InspectedChapter>[],
      logs: <String>[
        ...state.logs,
        'Retrying ${path.basename(job.inputPath)} from history.',
      ],
    );
    await startInspection();
    if (!mounted) {
      return;
    }
    if (!wasTranslationFailure) {
      return;
    }
    final bool readyToTranslate = state.inspectedChapters.any(
      (InspectedChapter chapter) =>
          chapter.includeInTranslation && chapter.blocks.isNotEmpty,
    );
    if (state.job?.status == TranslationJobStatus.inspected &&
        readyToTranslate) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'Inspection ready. Continuing with translation for the retry.',
        ],
      );
      await startTranslation();
    }
  }

  void clearJobHistory() {
    state = state.copyWith(
      jobHistory: const <TranslationJob>[],
      logs: <String>[...state.logs, 'Cleared job history.'],
    );
    _persistJobHistory(const <TranslationJob>[]);
  }

  Future<String?> _completedOutputPath() async {
    final TranslationJob? job = state.job;
    final String outputPath = job?.outputPath ?? '';
    if (job == null || !job.hasExportableEpub) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'No completed translated EPUB is available yet.',
        ],
      );
      return null;
    }

    final File outputFile = File(outputPath);
    final FileSystemEntityType type = await FileSystemEntity.type(outputPath);
    if (type != FileSystemEntityType.file || !await outputFile.exists()) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Output file was not found: $outputPath'],
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
        'Run cancelled.',
        if (progressBlocks > 0 &&
            cancelledJob.phase == TranslationJobPhase.translation)
          'You can resume translation later; about $progressBlocks blocks are already cached.',
      ],
      actionableError: ActionableErrorFactory.fromMessage(
        cancelledJob.phase == TranslationJobPhase.translation
            ? 'Translation cancelled'
            : 'Inspection cancelled',
        isChinese: state.config.uiLanguage == UiLanguage.chinese,
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
    final ({String inputPath, String outputDirectory}) paths = await store
        .load();
    if (!mounted) {
      return;
    }
    if (paths.inputPath.isEmpty && paths.outputDirectory.isEmpty) {
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
          'Restored last EPUB: ${path.basename(paths.inputPath)}',
        if (paths.outputDirectory.isNotEmpty)
          'Restored last output directory: ${paths.outputDirectory}',
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
    _persistJobHistory(history);
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
    final List<TranslationJob> history = await store.load();
    if (!mounted) {
      return;
    }
    if (history.isEmpty) {
      return;
    }
    state = state.copyWith(jobHistory: _mergeJobHistory(history));
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

  void _persistJobHistory(List<TranslationJob> history) {
    final JobHistoryStore? store = historyStore;
    if (store == null) {
      return;
    }
    final Future<void> save = _pendingHistorySave.then<void>(
      (_) => store.save(history),
      onError: (_) => store.save(history),
    );
    _pendingHistorySave = save.catchError((_) {});
  }
}
