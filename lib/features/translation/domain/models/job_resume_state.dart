class JobResumeState {
  const JobResumeState({
    required this.jobKey,
    required this.inputFingerprint,
    required this.inputPath,
    required this.outputPath,
    required this.status,
    required this.completedFiles,
    required this.totalFiles,
    required this.completedBlocks,
    required this.totalBlocks,
    required this.cachedBlocks,
    required this.resumedBlocks,
    required this.currentChapter,
    required this.updatedAtIso8601,
  });

  final String jobKey;
  final String inputFingerprint;
  final String inputPath;
  final String outputPath;
  final String status;
  final int completedFiles;
  final int totalFiles;
  final int completedBlocks;
  final int totalBlocks;
  final int cachedBlocks;
  final int resumedBlocks;
  final String currentChapter;
  final String updatedAtIso8601;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'jobKey': jobKey,
      'inputFingerprint': inputFingerprint,
      'inputPath': inputPath,
      'outputPath': outputPath,
      'status': status,
      'completedFiles': completedFiles,
      'totalFiles': totalFiles,
      'completedBlocks': completedBlocks,
      'totalBlocks': totalBlocks,
      'cachedBlocks': cachedBlocks,
      'resumedBlocks': resumedBlocks,
      'currentChapter': currentChapter,
      'updatedAtIso8601': updatedAtIso8601,
    };
  }

  factory JobResumeState.fromJson(Map<String, dynamic> json) {
    return JobResumeState(
      jobKey: _readString(json['jobKey']),
      inputFingerprint: _readString(json['inputFingerprint']),
      inputPath: _readString(json['inputPath']),
      outputPath: _readString(json['outputPath']),
      status: _readString(json['status'], fallback: 'running'),
      completedFiles: _readNonNegativeInt(json['completedFiles']),
      totalFiles: _readNonNegativeInt(json['totalFiles']),
      completedBlocks: _readNonNegativeInt(json['completedBlocks']),
      totalBlocks: _readNonNegativeInt(json['totalBlocks']),
      cachedBlocks: _readNonNegativeInt(json['cachedBlocks']),
      resumedBlocks: _readNonNegativeInt(json['resumedBlocks']),
      currentChapter: _readString(json['currentChapter']),
      updatedAtIso8601: _readString(json['updatedAtIso8601']),
    );
  }

  static String _readString(Object? value, {String fallback = ''}) {
    return value is String ? value : fallback;
  }

  static int _readNonNegativeInt(Object? value) {
    final int? parsed = switch (value) {
      int value => value,
      num value => value.round(),
      String value =>
        int.tryParse(value.trim()) ?? double.tryParse(value.trim())?.round(),
      _ => null,
    };
    if (parsed == null || parsed < 0) {
      return 0;
    }
    return parsed;
  }
}
