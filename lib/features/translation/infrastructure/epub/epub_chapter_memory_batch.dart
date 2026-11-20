part of 'epub_chapter_translator.dart';

/// Retains bounded excerpts from the current run and its checkpoint.
class _ChapterMemoryBatch {
  _ChapterMemoryBatch(Iterable<_ChapterMemorySample> restored)
    : _chapters = restored.toList();

  static const int chapterLimit = 4;
  static const int _batchByteThreshold = 3200;
  final List<_ChapterMemorySample> _chapters;

  List<_ChapterMemorySample> get chapters => List.unmodifiable(_chapters);
  String? get lastPath => _chapters.isEmpty ? null : _chapters.last.path;

  bool get shouldUpdate =>
      _chapters.length >= chapterLimit ||
      _chapters.any((chapter) => chapter.needsPromptUpdate) ||
      _chapters.fold(0, (size, chapter) => size + chapter.textBytes) >=
          _batchByteThreshold;

  void add(_ChapterMemorySample chapter) {
    // A failed request can leave a full batch queued. Keep the most recent
    // chapter and bound the next attempt's size.
    if (_chapters.length == chapterLimit) _chapters.removeAt(0);
    _chapters.add(chapter);
  }

  void clear() => _chapters.clear();
}

class _ChapterMemorySample {
  _ChapterMemorySample({
    required this.path,
    required this.title,
    required this.category,
    required this.text,
    required this.newTerms,
    required this.startsSection,
  }) : textBytes = utf8.encode(text).length;

  static const int titleLimit = 180;
  static const int textLimit = 1800;
  static const int termLimit = 16;
  static const int termLengthLimit = 100;
  static const int _substantialChapterBytes = 1800;
  static final RegExp sectionTitle = RegExp(
    r'^\s*(?:part|book|act)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five)\b',
    caseSensitive: false,
  );

  final String path;
  final String title;
  final ChapterCategory category;
  final String text;
  final int textBytes;
  final List<String> newTerms;
  final bool startsSection;

  bool get needsPromptUpdate =>
      startsSection ||
      newTerms.isNotEmpty ||
      textBytes >= _substantialChapterBytes;

  Map<String, Object> toPromptJson() => {
    'title': title,
    'category': category.name,
    'text': text,
    if (newTerms.isNotEmpty) 'newTerms': newTerms,
  };

  Map<String, Object> toCheckpointJson() => {
    ...toPromptJson(),
    'path': path,
    'startsSection': startsSection,
  };

  static List<_ChapterMemorySample> readPending(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > _ChapterMemoryBatch.chapterLimit) {
      throw const FormatException('Invalid pending chapter memory.');
    }
    final paths = <String>{};
    return [for (final entry in raw) _readSample(entry, paths)];
  }

  static _ChapterMemorySample _readSample(Object? raw, Set<String> paths) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid chapter memory sample.');
    }
    final path = raw['path'];
    final title = raw['title'];
    final category = raw['category'];
    final text = raw['text'];
    final terms = raw['newTerms'] ?? const [];
    final startsSection = raw['startsSection'];
    if (path is! String ||
        path.isEmpty ||
        !paths.add(path) ||
        title is! String ||
        title.length > titleLimit ||
        category is! String ||
        text is! String ||
        text.isEmpty ||
        text.length > textLimit ||
        terms is! List ||
        terms.length > termLimit ||
        terms.any(
          (term) =>
              term is! String || term.isEmpty || term.length > termLengthLimit,
        ) ||
        startsSection is! bool) {
      throw const FormatException('Invalid chapter memory sample fields.');
    }
    return _ChapterMemorySample(
      path: path,
      title: title,
      category: ChapterCategory.values.byName(category),
      text: text,
      newTerms: terms.cast<String>(),
      startsSection: startsSection,
    );
  }
}
