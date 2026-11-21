part of 'epub_chapter_translator.dart';

/// Retains bounded excerpts from the current run and its checkpoint.
class _ChapterMemoryBatch {
  _ChapterMemoryBatch(
    Iterable<_ChapterMemorySample> restored, {
    Set<String> recentFingerprints = const {},
  }) : _chapters = restored.toList(),
       _recentFingerprints = {...recentFingerprints};

  static const int chapterLimit = 4;
  static const int _batchByteThreshold = 3200;
  static final RegExp _fingerprintFormat = RegExp(r'^[a-f0-9]{64}$');
  final List<_ChapterMemorySample> _chapters;
  final Set<String> _recentFingerprints;

  Set<String> get recentFingerprints => Set.unmodifiable(_recentFingerprints);

  // A heterogeneous group can convey a new sequence even when every chapter
  // has appeared before. Only skip a group of the same repeated content.
  bool get repeatsRecentUpdate =>
      _chapters.isNotEmpty &&
      _recentFingerprints.length == 1 &&
      _chapters.every(
        (chapter) => _recentFingerprints.contains(chapter.fingerprint),
      );

  void rememberUpdate({required bool crossedBoundary}) {
    _recentFingerprints.clear();
    if (crossedBoundary ||
        _chapters.any((chapter) => chapter.fingerprint == null)) {
      return;
    }
    _recentFingerprints.addAll(
      _chapters.map((chapter) => chapter.fingerprint!),
    );
  }

  static Set<String> readFingerprints(Object? raw) {
    if (raw == null) return const {};
    if (raw is! List ||
        raw.length > chapterLimit ||
        raw.any(
          (entry) => entry is! String || !_fingerprintFormat.hasMatch(entry),
        )) {
      throw const FormatException('Invalid recent chapter fingerprints.');
    }
    return raw.cast<String>().toSet();
  }

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
    this.sourceExcerpt = '',
    this.fingerprint,
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
  final String sourceExcerpt;
  final String? fingerprint;

  static final _numberedTitle = RegExp(
    r'^\s*(?:chapter|section)\s+(?:[0-9]+|[ivxlcdm]+)\s*$',
    caseSensitive: false,
  );
  static final _plainParagraph = RegExp(
    r'^<p>[^<]+</p>$',
    caseSensitive: false,
  );
  static final _attachmentMarkup = RegExp(
    r'<(?:[\w.-]+:)?(?:a|aside|note)(?=\s|/?>)|(?:epub:type|role)\s*=',
    caseSensitive: false,
  );

  /// Compare only complete, plain short chapters with interchangeable labels.
  /// Exact source and validated target text keeps small but meaningful edits
  /// (including negation, names, and punctuation) from matching.
  static String? fingerprintFor(
    InspectedChapter chapter, {
    required String translatedExcerpt,
    required List<String> newTerms,
  }) {
    if (chapter.category != ChapterCategory.content ||
        !_numberedTitle.hasMatch(chapter.title) ||
        utf8.encode(translatedExcerpt).length >= _substantialChapterBytes ||
        newTerms.isNotEmpty ||
        chapter.blocks.length > 8 ||
        _attachmentMarkup.hasMatch(chapter.originalHtml)) {
      return null;
    }
    final blocks = <(String, String)>[];
    var length = 0;
    for (final block in chapter.blocks) {
      final translated = block.translatedHtml?.trim();
      final source = block.sourceHtml.trim();
      if (translated == null ||
          source.length + translated.length > textLimit - length ||
          !_plainParagraph.hasMatch(source) ||
          !_plainParagraph.hasMatch(translated)) {
        return null;
      }
      length += source.length + translated.length;
      blocks.add((source, translated));
    }
    if (blocks.isEmpty) return null;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final (source, translated) in blocks) [source, translated],
            ]),
          ),
        )
        .toString();
  }

  bool get needsPromptUpdate =>
      startsSection ||
      newTerms.isNotEmpty ||
      textBytes >= _substantialChapterBytes;

  Map<String, Object> toPromptJson({String? excerpt}) => {
    'title': title,
    'category': category.name,
    'text': excerpt ?? text,
    if (newTerms.isNotEmpty) 'newTerms': newTerms,
  };

  Map<String, Object> toCheckpointJson() => {
    ...toPromptJson(),
    'path': path,
    'startsSection': startsSection,
    if (sourceExcerpt.isNotEmpty) 'sourceExcerpt': sourceExcerpt,
    'fingerprint': ?fingerprint,
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
    final sourceExcerpt = raw['sourceExcerpt'] ?? '';
    final fingerprint = raw['fingerprint'];
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
        startsSection is! bool ||
        sourceExcerpt is! String ||
        sourceExcerpt.length > textLimit ||
        (fingerprint != null &&
            (fingerprint is! String ||
                !_ChapterMemoryBatch._fingerprintFormat.hasMatch(
                  fingerprint,
                )))) {
      throw const FormatException('Invalid chapter memory sample fields.');
    }
    return _ChapterMemorySample(
      path: path,
      title: title,
      category: ChapterCategory.values.byName(category),
      text: text,
      newTerms: terms.cast<String>(),
      startsSection: startsSection,
      sourceExcerpt: sourceExcerpt,
      fingerprint: fingerprint as String?,
    );
  }
}
