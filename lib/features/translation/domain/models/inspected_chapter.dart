enum ChapterCategory { content, frontMatter, backMatter, reference, ancillary }

class InspectedChapter {
  const InspectedChapter({
    required this.path,
    required this.title,
    required this.body,
    required this.originalHtml,
    required this.blocks,
    required this.category,
    required this.recommendedForTranslation,
    required this.includeInTranslation,
  });

  final String path;
  final String title;
  final String body;
  final String originalHtml;
  final List<ExtractedBlock> blocks;
  final ChapterCategory category;
  final bool recommendedForTranslation;
  final bool includeInTranslation;

  int get translatedBlockCount => blocks
      .where((ExtractedBlock block) => block.translatedHtml != null)
      .length;

  InspectedChapter copyWith({
    String? path,
    String? title,
    String? body,
    String? originalHtml,
    List<ExtractedBlock>? blocks,
    ChapterCategory? category,
    bool? recommendedForTranslation,
    bool? includeInTranslation,
  }) {
    return InspectedChapter(
      path: path ?? this.path,
      title: title ?? this.title,
      body: body ?? this.body,
      originalHtml: originalHtml ?? this.originalHtml,
      blocks: blocks ?? this.blocks,
      category: category ?? this.category,
      recommendedForTranslation:
          recommendedForTranslation ?? this.recommendedForTranslation,
      includeInTranslation: includeInTranslation ?? this.includeInTranslation,
    );
  }

  String get categoryLabel {
    return switch (category) {
      ChapterCategory.content => 'Content',
      ChapterCategory.frontMatter => 'Front matter',
      ChapterCategory.backMatter => 'Back matter',
      ChapterCategory.reference => 'Reference',
      ChapterCategory.ancillary => 'Skip by default',
    };
  }
}

class ExtractedBlock {
  const ExtractedBlock({
    required this.id,
    required this.tagName,
    required this.sourceHtml,
    required this.sourceText,
    this.translatedHtml,
  });

  final String id;
  final String tagName;
  final String sourceHtml;
  final String sourceText;
  final String? translatedHtml;

  ExtractedBlock copyWith({
    String? id,
    String? tagName,
    String? sourceHtml,
    String? sourceText,
    String? translatedHtml,
    bool clearTranslatedHtml = false,
  }) {
    return ExtractedBlock(
      id: id ?? this.id,
      tagName: tagName ?? this.tagName,
      sourceHtml: sourceHtml ?? this.sourceHtml,
      sourceText: sourceText ?? this.sourceText,
      translatedHtml: clearTranslatedHtml
          ? null
          : translatedHtml ?? this.translatedHtml,
    );
  }
}
