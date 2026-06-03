import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/platform/platform_utils.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/models/translation_config.dart';
import '../domain/models/inspected_chapter.dart';
import '../domain/models/inspection_result.dart';
import '../domain/models/translation_job.dart';
import '../domain/models/translation_run_result.dart';
import '../domain/repositories/translation_repository.dart';
import '../infrastructure/translation_cache_store.dart';
import '../infrastructure/repositories/epub_translation_repository.dart';

final translationRepositoryProvider = Provider<TranslationRepository>(
  (ref) => EpubTranslationRepository(
    cacheStore: ref.watch(translationCacheStoreProvider),
  ),
);

final translationDashboardProvider =
    StateNotifierProvider<
      TranslationDashboardController,
      TranslationDashboardState
    >((ref) {
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: ref.watch(translationRepositoryProvider),
          )..syncSettings(ref.read(settingsProvider));
      ref.listen<TranslationConfig>(settingsProvider, (
        TranslationConfig? _,
        TranslationConfig next,
      ) {
        controller.syncSettings(next);
      });
      return controller;
    });

class TranslationDashboardState {
  const TranslationDashboardState({
    required this.config,
    required this.inputPath,
    required this.outputDirectory,
    required this.job,
    required this.inspectedChapters,
    required this.logs,
  });

  final TranslationConfig config;
  final String inputPath;
  final String outputDirectory;
  final TranslationJob? job;
  final List<InspectedChapter> inspectedChapters;
  final List<String> logs;

  factory TranslationDashboardState.initial() {
    return TranslationDashboardState(
      config: TranslationConfig.defaults(),
      inputPath: '',
      outputDirectory: '',
      job: null,
      inspectedChapters: const <InspectedChapter>[],
      logs: const <String>[
        'Ready to inspect an EPUB.',
        'Choose a book and output folder, then inspect the spine to see real progress.',
      ],
    );
  }

  TranslationDashboardState copyWith({
    TranslationConfig? config,
    String? inputPath,
    String? outputDirectory,
    TranslationJob? job,
    List<InspectedChapter>? inspectedChapters,
    List<String>? logs,
  }) {
    return TranslationDashboardState(
      config: config ?? this.config,
      inputPath: inputPath ?? this.inputPath,
      outputDirectory: outputDirectory ?? this.outputDirectory,
      job: job ?? this.job,
      inspectedChapters: inspectedChapters ?? this.inspectedChapters,
      logs: logs ?? this.logs,
    );
  }
}

class TranslationDashboardController
    extends StateNotifier<TranslationDashboardState> {
  TranslationDashboardController({required this.repository})
    : super(TranslationDashboardState.initial());

  final TranslationRepository repository;

  Future<void> pickInputPath() async {
    String? selectedPath;
    try {
      selectedPath = await PlatformUtils.pickEpubFile();
    } catch (error) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Could not select EPUB: $error'],
      );
      return;
    }
    if (selectedPath == null || selectedPath.isEmpty) {
      return;
    }
    if (path.extension(selectedPath).toLowerCase() != '.epub') {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Please choose a .epub file.'],
      );
      return;
    }

    final String inferredOutput = state.outputDirectory.isEmpty
        ? await PlatformUtils.defaultOutputDirectory(selectedPath)
        : state.outputDirectory;
    state = state.copyWith(
      inputPath: selectedPath,
      outputDirectory: inferredOutput,
      inspectedChapters: const <InspectedChapter>[],
      logs: <String>[
        ...state.logs,
        'Selected EPUB: ${path.basename(selectedPath)}',
      ],
    );
  }

  Future<void> pickOutputDirectory() async {
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
    state = state.copyWith(inputPath: value);
  }

  void setOutputDirectory(String value) {
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
    state = state.copyWith(
      config: state.config.copyWith(
        apiBaseUrl: settingsConfig.apiBaseUrl,
        apiKey: settingsConfig.apiKey,
        model: settingsConfig.model,
        uiLanguage: settingsConfig.uiLanguage,
        targetLanguage: settingsConfig.targetLanguage,
        bilingual: settingsConfig.bilingual,
        chunkSize: settingsConfig.chunkSize,
        maxConcurrent: settingsConfig.maxConcurrent,
        timeoutSeconds: settingsConfig.timeoutSeconds,
        maxRetries: settingsConfig.maxRetries,
        retryDelaySeconds: settingsConfig.retryDelaySeconds,
        disableThinking: settingsConfig.disableThinking,
        outputSuffix: settingsConfig.outputSuffix,
      ),
    );
  }

  void toggleChapterInclusion(String chapterPath, bool includeInTranslation) {
    state = state.copyWith(
      inspectedChapters: state.inspectedChapters
          .map(
            (InspectedChapter chapter) => chapter.path == chapterPath
                ? chapter.copyWith(includeInTranslation: includeInTranslation)
                : chapter,
          )
          .toList(),
    );
  }

  void resetChapterSelection() {
    state = state.copyWith(
      inspectedChapters: state.inspectedChapters
          .map(
            (InspectedChapter chapter) => chapter.copyWith(
              includeInTranslation: chapter.recommendedForTranslation,
            ),
          )
          .toList(),
      logs: <String>[
        ...state.logs,
        'Reset chapter selection to the current heuristic defaults.',
      ],
    );
  }

  Future<void> startInspection() async {
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

    state = state.copyWith(
      outputDirectory: outputDirectory,
      job: TranslationJob(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        inputPath: state.inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.queued,
        progress: 0,
      ),
      inspectedChapters: const <InspectedChapter>[],
      logs: <String>[
        ...state.logs,
        'Starting EPUB inspection for ${path.basename(state.inputPath)}',
      ],
    );

    try {
      final InspectionResult result = await repository.startJob(
        inputPath: state.inputPath,
        outputDirectory: outputDirectory,
        config: state.config,
        onProgress: (TranslationJob job, String logLine) {
          state = state.copyWith(
            job: job,
            logs: <String>[...state.logs, logLine],
          );
        },
      );
      state = state.copyWith(
        job: result.job,
        inspectedChapters: result.chapters,
      );
    } catch (error) {
      final TranslationJob failedJob =
          state.job?.copyWith(
            status: TranslationJobStatus.failed,
            currentChapter: 'Inspection failed',
          ) ??
          TranslationJob(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            inputPath: state.inputPath,
            outputPath: outputDirectory,
            status: TranslationJobStatus.failed,
            progress: 0,
            currentChapter: 'Inspection failed',
          );
      state = state.copyWith(
        job: failedJob,
        inspectedChapters: const <InspectedChapter>[],
        logs: <String>[...state.logs, 'Inspection failed: $error'],
      );
    }
  }

  Future<void> startTranslation() async {
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

    state = state.copyWith(
      job:
          state.job?.copyWith(
            status: TranslationJobStatus.queued,
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
            progress: 0,
            currentChapter: 'Queued for translation',
            completedFiles: 0,
            totalFiles: selectedChapters.length,
            completedBlocks: 0,
            totalBlocks: selectedBlocks,
          ),
      logs: <String>[
        ...state.logs,
        'Queued translation for ${selectedChapters.length} chapters and $selectedBlocks blocks.',
      ],
    );

    try {
      final TranslationRunResult result = await repository.translateChapters(
        inputPath: state.inputPath,
        outputDirectory: state.outputDirectory,
        config: state.config,
        chapters: state.inspectedChapters,
        onProgress: (TranslationJob job, String logLine) {
          state = state.copyWith(
            job: job,
            logs: <String>[...state.logs, logLine],
          );
        },
      );
      state = state.copyWith(
        job: result.job,
        inspectedChapters: result.chapters,
        logs: <String>[
          ...state.logs,
          PlatformUtils.isAndroid
              ? 'Translation complete. Use Share EPUB to export the book from Android.'
              : 'Translation complete. Use Open EPUB to view the output file.',
        ],
      );
    } catch (error) {
      state = state.copyWith(
        job:
            state.job?.copyWith(
              status: TranslationJobStatus.failed,
              currentChapter: 'Translation failed',
              currentBlock: null,
            ) ??
            TranslationJob(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              inputPath: state.inputPath,
              outputPath: state.outputDirectory,
              status: TranslationJobStatus.failed,
              progress: 0,
              currentChapter: 'Translation failed',
            ),
        logs: <String>[...state.logs, 'Translation failed: $error'],
      );
    }
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
        logs: <String>[...state.logs, 'Could not export EPUB: $error'],
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
          'Could not save EPUB to Downloads: $error',
        ],
      );
    }
  }

  Future<String?> _completedOutputPath() async {
    final TranslationJob? job = state.job;
    final String outputPath = job?.outputPath ?? '';
    if (job?.status != TranslationJobStatus.completed || outputPath.isEmpty) {
      state = state.copyWith(
        logs: <String>[
          ...state.logs,
          'No completed translated EPUB is available yet.',
        ],
      );
      return null;
    }

    final File outputFile = File(outputPath);
    if (!await outputFile.exists()) {
      state = state.copyWith(
        logs: <String>[...state.logs, 'Output file was not found: $outputPath'],
      );
      return null;
    }

    return outputPath;
  }
}
