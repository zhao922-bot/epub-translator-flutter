class PreviewChapter {
  const PreviewChapter({
    required this.title,
    required this.body,
    required this.path,
    required this.category,
    required this.recommendedForTranslation,
    required this.includeInTranslation,
    required this.blockCount,
    required this.translatedBlockCount,
    this.translatedBody,
    this.degradedBlockCount = 0,
    this.reviewWarningBlockCount = 0,
    this.hasTruncatedExcerpt = false,
  });

  final String title;
  final String body;
  final String? translatedBody;
  final String path;
  final String category;
  final bool recommendedForTranslation;
  final bool includeInTranslation;
  final int blockCount;
  final int translatedBlockCount;
  final int degradedBlockCount;
  final int reviewWarningBlockCount;
  final bool hasTruncatedExcerpt;

  bool get hasWarnings => degradedBlockCount > 0 || reviewWarningBlockCount > 0;
}
