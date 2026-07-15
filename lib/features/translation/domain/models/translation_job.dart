enum TranslationJobStatus {
  idle,
  queued,
  running,

  /// Spine inspection finished; chapters are ready for translation.
  inspected,
  cancelled,
  failed,

  /// Translation finished and a translated EPUB path is available.
  completed,
}

/// Distinguishes inspection runs from translation runs in history/UI.
enum TranslationJobPhase { inspection, translation }

const Object _unset = Object();

class TranslationJob {
  const TranslationJob({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.status,
    required this.progress,
    this.phase = TranslationJobPhase.inspection,
    this.currentChapter,
    this.currentBlock,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.completedBlocks = 0,
    this.totalBlocks = 0,
    this.cachedBlocks = 0,
    this.resumedBlocks = 0,
    this.errorMessage,
  });

  final String id;
  final String inputPath;
  final String outputPath;
  final TranslationJobStatus status;
  final TranslationJobPhase phase;
  final double progress;
  final String? currentChapter;
  final String? currentBlock;
  final int completedFiles;
  final int totalFiles;
  final int completedBlocks;
  final int totalBlocks;
  final int cachedBlocks;
  final int resumedBlocks;
  final String? errorMessage;

  /// True when this job represents a finished translation with an EPUB output.
  bool get hasExportableEpub {
    if (status != TranslationJobStatus.completed) {
      return false;
    }
    if (phase != TranslationJobPhase.translation) {
      return false;
    }
    final String normalized = outputPath.trim().toLowerCase();
    return normalized.endsWith('.epub');
  }

  bool get canResumeTranslation {
    return phase == TranslationJobPhase.translation &&
        (status == TranslationJobStatus.failed ||
            status == TranslationJobStatus.cancelled) &&
        (cachedBlocks > 0 || resumedBlocks > 0 || completedBlocks > 0);
  }

  factory TranslationJob.fromJson(Map<String, dynamic> json) {
    final String id = _readString(json['id']);
    if (id.isEmpty) {
      throw const FormatException('Translation job id is required.');
    }
    return TranslationJob(
      id: id,
      inputPath: _readString(json['inputPath']),
      outputPath: _readString(json['outputPath']),
      status: _readStatus(json['status']),
      phase: _readPhase(json['phase'], status: _readStatus(json['status'])),
      progress: _readProgress(json['progress']),
      currentChapter: _readNullableString(json['currentChapter']),
      currentBlock: _readNullableString(json['currentBlock']),
      completedFiles: _readNonNegativeInt(json['completedFiles']),
      totalFiles: _readNonNegativeInt(json['totalFiles']),
      completedBlocks: _readNonNegativeInt(json['completedBlocks']),
      totalBlocks: _readNonNegativeInt(json['totalBlocks']),
      cachedBlocks: _readNonNegativeInt(json['cachedBlocks']),
      resumedBlocks: _readNonNegativeInt(json['resumedBlocks']),
      errorMessage: _readNullableString(json['errorMessage']),
    );
  }

  TranslationJob copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    TranslationJobStatus? status,
    TranslationJobPhase? phase,
    double? progress,
    Object? currentChapter = _unset,
    Object? currentBlock = _unset,
    int? completedFiles,
    int? totalFiles,
    int? completedBlocks,
    int? totalBlocks,
    int? cachedBlocks,
    int? resumedBlocks,
    Object? errorMessage = _unset,
  }) {
    return TranslationJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      status: status ?? this.status,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      currentChapter: identical(currentChapter, _unset)
          ? this.currentChapter
          : currentChapter as String?,
      currentBlock: identical(currentBlock, _unset)
          ? this.currentBlock
          : currentBlock as String?,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFiles: totalFiles ?? this.totalFiles,
      completedBlocks: completedBlocks ?? this.completedBlocks,
      totalBlocks: totalBlocks ?? this.totalBlocks,
      cachedBlocks: cachedBlocks ?? this.cachedBlocks,
      resumedBlocks: resumedBlocks ?? this.resumedBlocks,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'inputPath': inputPath,
      'outputPath': outputPath,
      'status': status.name,
      'phase': phase.name,
      'progress': progress,
      'currentChapter': currentChapter,
      'currentBlock': currentBlock,
      'completedFiles': completedFiles,
      'totalFiles': totalFiles,
      'completedBlocks': completedBlocks,
      'totalBlocks': totalBlocks,
      'cachedBlocks': cachedBlocks,
      'resumedBlocks': resumedBlocks,
      'errorMessage': errorMessage,
    };
  }
}

String _readString(Object? value) => value is String ? value : '';

String? _readNullableString(Object? value) => value is String ? value : null;

int _readNonNegativeInt(Object? value) {
  final int? parsed = switch (value) {
    int value => value,
    double value => value.round(),
    String value => int.tryParse(value),
    _ => null,
  };
  if (parsed == null || parsed < 0) {
    return 0;
  }
  return parsed;
}

double _readProgress(Object? value) {
  final double? parsed = switch (value) {
    int value => value.toDouble(),
    double value => value,
    String value => double.tryParse(value),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite) {
    return 0;
  }
  return parsed.clamp(0, 1);
}

TranslationJobStatus _readStatus(Object? value) {
  if (value is String) {
    for (final TranslationJobStatus status in TranslationJobStatus.values) {
      if (status.name == value) {
        return status;
      }
    }
  }
  return TranslationJobStatus.idle;
}

TranslationJobPhase _readPhase(
  Object? value, {
  required TranslationJobStatus status,
}) {
  if (value is String) {
    for (final TranslationJobPhase phase in TranslationJobPhase.values) {
      if (phase.name == value) {
        return phase;
      }
    }
  }
  // Legacy history: completed with .epub path => translation.
  if (status == TranslationJobStatus.completed) {
    return TranslationJobPhase.translation;
  }
  if (status == TranslationJobStatus.inspected) {
    return TranslationJobPhase.inspection;
  }
  return TranslationJobPhase.inspection;
}
