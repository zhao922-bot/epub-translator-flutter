enum TranslationJobStatus {
  idle,
  queued,
  running,
  cancelled,
  failed,
  completed,
}

class TranslationJob {
  const TranslationJob({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.status,
    required this.progress,
    this.currentChapter,
    this.currentBlock,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.completedBlocks = 0,
    this.totalBlocks = 0,
    this.cachedBlocks = 0,
    this.resumedBlocks = 0,
  });

  final String id;
  final String inputPath;
  final String outputPath;
  final TranslationJobStatus status;
  final double progress;
  final String? currentChapter;
  final String? currentBlock;
  final int completedFiles;
  final int totalFiles;
  final int completedBlocks;
  final int totalBlocks;
  final int cachedBlocks;
  final int resumedBlocks;

  TranslationJob copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    TranslationJobStatus? status,
    double? progress,
    String? currentChapter,
    String? currentBlock,
    int? completedFiles,
    int? totalFiles,
    int? completedBlocks,
    int? totalBlocks,
    int? cachedBlocks,
    int? resumedBlocks,
  }) {
    return TranslationJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      currentChapter: currentChapter ?? this.currentChapter,
      currentBlock: currentBlock ?? this.currentBlock,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFiles: totalFiles ?? this.totalFiles,
      completedBlocks: completedBlocks ?? this.completedBlocks,
      totalBlocks: totalBlocks ?? this.totalBlocks,
      cachedBlocks: cachedBlocks ?? this.cachedBlocks,
      resumedBlocks: resumedBlocks ?? this.resumedBlocks,
    );
  }
}
