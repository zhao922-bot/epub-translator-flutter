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
      jobKey: json['jobKey'] as String? ?? '',
      inputFingerprint: json['inputFingerprint'] as String? ?? '',
      inputPath: json['inputPath'] as String? ?? '',
      outputPath: json['outputPath'] as String? ?? '',
      status: json['status'] as String? ?? 'running',
      completedFiles: json['completedFiles'] as int? ?? 0,
      totalFiles: json['totalFiles'] as int? ?? 0,
      completedBlocks: json['completedBlocks'] as int? ?? 0,
      totalBlocks: json['totalBlocks'] as int? ?? 0,
      cachedBlocks: json['cachedBlocks'] as int? ?? 0,
      resumedBlocks: json['resumedBlocks'] as int? ?? 0,
      currentChapter: json['currentChapter'] as String? ?? '',
      updatedAtIso8601: json['updatedAtIso8601'] as String? ?? '',
    );
  }
}
