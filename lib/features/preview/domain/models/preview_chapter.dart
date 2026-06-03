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
  });

  final String title;
  final String body;
  final String path;
  final String category;
  final bool recommendedForTranslation;
  final bool includeInTranslation;
  final int blockCount;
  final int translatedBlockCount;
}
