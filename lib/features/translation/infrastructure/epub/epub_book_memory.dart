part of 'epub_chapter_translator.dart';

/// Owns book-memory sampling, style response parsing, and rolling updates.
/// Memory models below keep their serialization, merge rules, and limits here.
/// Requests use the invocation owner's shared HTTP budget.
class _EpubBookMemory {
  _EpubBookMemory(this.owner);

  final EpubChapterTranslator owner;

  /// Dedicated style analysis, rather than piggybacking on book-memory summary.
  Future<TranslationStyleProfile> generateStyleProfile({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    void Function()? throwIfCancelled,
  }) async {
    throwIfCancelled?.call();
    final List<Map<String, String>> sourceChapters =
        await restoredStyleProfileSourceChapters(
          chapters,
          isCancelled: () {
            throwIfCancelled?.call();
            return cancelToken?.isCancelled ?? false;
          },
        );
    if (sourceChapters.isEmpty) {
      throw FormatException(
        AppStrings(config.uiLanguage).logStyleProfileNoSamples,
      );
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'styleProfile',
      'targetLanguage': config.targetLanguage,
      'chapters': sourceChapters,
    };
    final Map<String, dynamic> jsonPayload = await requestJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'You analyze an EPUB before translation. Return strict JSON only. '
          'Required top-level object keys: primaryGenre, secondaryGenres, tone, '
          'sentenceStyle, translationConstraints, avoid, confidence. '
          'primaryGenre must be a practical book type such as business nonfiction, '
          'science fiction, romance, historical fiction, literary fiction, mystery, '
          'fantasy, memoir, self-help, biography, or philosophy. '
          'secondaryGenres is a short string array. tone and sentenceStyle are short phrases. '
          'translationConstraints and avoid may be either string arrays or single strings. '
          'Write notes for translators into ${config.targetLanguage}. '
          'confidence must be one of: high, medium, low. '
          'Prefer executable style rules over marketing labels. '
          'Never instruct translators to keep whole English quotations, dialogue, or epigraphs untranslated when the target language is not English; only proper names, work titles, URLs, and short technical terms may remain in the source language. '
          'If evidence is thin, still provide a best-effort primaryGenre with confidence low. '
          'Do not wrap the JSON in markdown fences.',
      cancelToken: cancelToken,
      throwIfCancelled: throwIfCancelled,
    );
    return _parseStyleProfileResponse(jsonPayload);
  }

  Future<_BookMemory> generateInitialBookMemory({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
  }) async {
    final List<Map<String, String>> sourceChapters =
        _initialMemorySourceChapters(chapters);
    if (sourceChapters.isEmpty) {
      return _BookMemory.empty;
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'initialBookMemory',
      'targetLanguage': config.targetLanguage,
      'styleProfileEnabled': config.styleProfileEnabled,
      'chapters': sourceChapters,
    };
    final String styleProfilePrompt = config.styleProfileEnabled
        ? ' Also return styleProfile as an object with keys: primaryGenre, secondaryGenres, tone, sentenceStyle, translationConstraints, avoid, confidence. primaryGenre should be a practical book type such as business nonfiction, science fiction, romance, historical fiction, literary fiction, mystery, fantasy, memoir, or self-help. secondaryGenres is a short string array. tone and sentenceStyle are short phrases. translationConstraints and avoid are short actionable string arrays for translators. confidence must be one of: high, medium, low. If evidence is weak, set confidence to low and keep constraints conservative. Prefer executable style rules over marketing labels. Never instruct translators to keep whole English quotations, dialogue, or epigraphs untranslated when the target language is not English; only proper names, work titles, URLs, and short technical terms may remain in the source language.'
        : ' Do not invent a styleProfile.';
    final Map<String, dynamic> jsonPayload = await requestJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'Create a compact translation memory for an EPUB before chapter translation begins. Return strict JSON only with keys: bookSummary, styleGuide, glossary, recentChapters${config.styleProfileEnabled ? ', styleProfile' : ''}. Keep bookSummary under 120 words. styleGuide is a short string array. glossary is an array of objects with source and target. recentChapters should be empty for the initial memory. Write target terms and notes for ${config.targetLanguage}.$styleProfilePrompt',
      cancelToken: cancelToken,
    );
    final _BookMemory memory = _BookMemory.fromJson(jsonPayload);
    if (!config.styleProfileEnabled) {
      return memory.copyWith(clearStyleProfile: true);
    }
    return memory;
  }

  Future<_BookMemory> updateBookMemoryAfterChapter({
    required Dio dio,
    required TranslationConfig config,
    required _BookMemory currentMemory,
    required InspectedChapter chapter,
    CancelToken? cancelToken,
  }) async {
    final String chapterText = _chapterMemoryText(
      chapter,
      preferTranslated: true,
    );
    if (chapterText.isEmpty) {
      return currentMemory;
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'chapterMemory',
      'targetLanguage': config.targetLanguage,
      'bookMemory': currentMemory.toJson(),
      'chapter': <String, String>{
        'title': chapter.title,
        'category': chapter.category.name,
        'text': chapterText,
      },
    };
    final Map<String, dynamic> jsonPayload = await requestJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'Summarize the just-translated EPUB chapter into rolling translation memory. Return strict JSON only with keys: title, summary, continuityNotes, glossary. Keep summary under 100 words. continuityNotes is a short string array focused on unresolved plot, tone, names, and terminology for later chapters. glossary is an array of objects with source and target. Write notes for ${config.targetLanguage}.',
      cancelToken: cancelToken,
    );
    final _ChapterMemory chapterMemory = _ChapterMemory.fromJson(jsonPayload);
    // The model is not asked for the path; stamp it locally so positional
    // memory snapshots can attribute each entry to its chapter.
    final _ChapterMemory stamped = chapterMemory.path.isEmpty
        ? _ChapterMemory(
            title: chapterMemory.title,
            summary: chapterMemory.summary,
            path: chapter.path,
            continuityNotes: chapterMemory.continuityNotes,
            glossary: chapterMemory.glossary,
          )
        : chapterMemory;
    return currentMemory.mergeChapter(stamped);
  }

  Future<Map<String, dynamic>> requestJson({
    required Dio dio,
    required TranslationConfig config,
    required Map<String, dynamic> payload,
    required String systemPrompt,
    CancelToken? cancelToken,
    void Function()? throwIfCancelled,
  }) {
    return owner._apiClient.runRetried<Map<String, dynamic>>(
      config: config,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      throwIfCancelled: throwIfCancelled,
      operation: () async {
        throwIfCancelled?.call();
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final Response<dynamic> response = await owner._postChatCompletions(
          dio: dio,
          data: <String, dynamic>{
            'model': config.model,
            'temperature': 0.1,
            'max_tokens': 900,
            'messages': <Map<String, String>>[
              <String, String>{'role': 'system', 'content': systemPrompt},
              <String, String>{'role': 'user', 'content': jsonEncode(payload)},
            ],
          },
          cancelToken: cancelToken,
        );
        throwIfCancelled?.call();
        return owner._apiClient.decodeBatchJsonPayload(response.data);
      },
    );
  }

  static const int _initialMemoryFrontMatterLimit = 2;
  static const int _initialMemoryContentLimit = 2;
  static const int _memoryChapterTextLimit = 2400;
  static const int _minimumRepresentativeStyleCharacters = 240;
  static const int _memoryListLimit = 8;
  static const int _memoryGlossaryLimit = 32;
  static const int _recentChapterMemoryLimit = 2;

  /// Samples meaningful front matter plus early/middle/late body chapters.
  ///
  /// Indexes, contents, copyright pages, credits and other structural matter
  /// must not influence the inferred writing style even when an EPUB uses
  /// opaque filenames or generic document titles.
  static List<Map<String, String>> _styleProfileSourceChapters(
    List<InspectedChapter> chapters,
  ) => [
    for (final entry in _styleProfileCandidates(chapters))
      _styleSample(entry.chapter, entry.role),
  ].where((sample) => sample['text']!.isNotEmpty).toList(growable: false);

  static Map<String, String> _styleSample(
    InspectedChapter chapter,
    String role,
  ) => {
    'path': chapter.path,
    'title': chapter.title,
    'category': chapter.category.name,
    'role': role,
    'text': _representativeStyleText(chapter.blocks),
  };

  static Future<List<Map<String, String>>> restoredStyleProfileSourceChapters(
    List<InspectedChapter> chapters, {
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
  }) async {
    if (isCancelled()) throw const TranslationCancelledException();
    // Selection uses retained chapter metadata/source excerpts. Do not parse
    // all released HTML just to decide which three body chapters to sample.
    final candidates = _styleProfileCandidates(chapters);
    final samples = <Map<String, String>>[];
    for (final entry in candidates) {
      final chapter = await ChapterSourceRestorer.restoreChapter(
        chapter: entry.chapter,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
      final sample = _styleSample(chapter, entry.role);
      if (sample['text']!.isNotEmpty) samples.add(sample);
      // Only the bounded text survives this iteration, not restored blocks.
    }
    if (isCancelled()) throw const TranslationCancelledException();
    return samples;
  }

  static List<({InspectedChapter chapter, String role})>
  _styleProfileCandidates(List<InspectedChapter> chapters) {
    final List<InspectedChapter> eligible = chapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .where((InspectedChapter chapter) => chapter.blocks.isNotEmpty)
        .where(
          (InspectedChapter chapter) => !_excludeFromStyleSampling(chapter),
        )
        .toList(growable: false);
    if (eligible.isEmpty) {
      return const [];
    }

    final List<InspectedChapter> selected = <InspectedChapter>[];
    final Map<String, String> rolesByPath = <String, String>{};
    void add(InspectedChapter chapter, String role) {
      if (selected.any((InspectedChapter c) => c.path == chapter.path)) {
        return;
      }
      selected.add(chapter);
      rolesByPath[chapter.path] = role;
    }

    for (final InspectedChapter chapter
        in eligible
            .where(
              (InspectedChapter c) => c.category == ChapterCategory.frontMatter,
            )
            .where(_isMeaningfulFrontMatter)
            .take(2)) {
      add(chapter, 'frontMatter');
    }

    final List<InspectedChapter> contentCandidates = eligible
        .where((InspectedChapter c) => c.category == ChapterCategory.content)
        .toList(growable: false);
    final List<InspectedChapter> substantialContent = contentCandidates
        .where(
          (InspectedChapter chapter) =>
              chapter.blocks.every((block) => block.sourceText.isEmpty)
              ? _normalizedStyleLength([
                      ExtractedBlock(
                        id: '',
                        tagName: '',
                        sourceHtml: '',
                        sourceText: chapter.body,
                      ),
                    ], _minimumRepresentativeStyleCharacters) >=
                    _minimumRepresentativeStyleCharacters
              : _hasRepresentativeStyleText(chapter.blocks),
        )
        .toList(growable: false);
    final int desiredRepresentativeCount = min(3, contentCandidates.length);
    final List<InspectedChapter> content =
        desiredRepresentativeCount > 0 &&
            substantialContent.length >= desiredRepresentativeCount
        ? substantialContent
        : contentCandidates;
    final List<InspectedChapter> representativeContent =
        _representativeContentChapters(content);
    for (int index = 0; index < representativeContent.length; index += 1) {
      final String role = switch (index) {
        0 => 'earlyContent',
        1 when representativeContent.length >= 3 => 'middleContent',
        _ => 'lateContent',
      };
      add(representativeContent[index], role);
    }

    if (selected.length < 2) {
      for (final InspectedChapter chapter in eligible) {
        add(chapter, 'fallback');
        if (selected.length >= 4) {
          break;
        }
      }
    }

    return [
      for (final chapter in selected)
        (chapter: chapter, role: rolesByPath[chapter.path] ?? 'fallback'),
    ];
  }

  static List<InspectedChapter> _representativeContentChapters(
    List<InspectedChapter> content,
  ) {
    if (content.length <= 3) {
      return content;
    }
    return <InspectedChapter>[
      content.first,
      content[content.length ~/ 2],
      content.last,
    ];
  }

  static bool _excludeFromStyleSampling(InspectedChapter chapter) {
    if (chapter.category == ChapterCategory.ancillary ||
        chapter.category == ChapterCategory.reference ||
        chapter.category == ChapterCategory.backMatter) {
      return true;
    }
    final String normalizedPath = chapter.path
        .replaceAll('\\', '/')
        .toLowerCase();
    final String fileName = normalizedPath.split('/').last;
    final String normalizedTitle = chapter.title.trim().toLowerCase();
    if (RegExp(r'^(nav|navigation)(\.[^.]+)?$').hasMatch(fileName) ||
        RegExp(r'(^|[-_.])(fn|footnotes?)([-_.]|$)').hasMatch(fileName) ||
        <String>{
          'footnote',
          'footnotes',
          'navigation',
          'table of contents',
          'contents',
        }.contains(normalizedTitle)) {
      return true;
    }
    // Match title and basename independently: directory names and words such
    // as discovery/recovery must not turn a body chapter into a cover page.
    // Dart \b treats '_' as a word character, so \bcover\b misses
    // cover_page.xhtml: use an explicit non-alphanumeric boundary instead.
    final excludedWords = RegExp(
      r'(?:^|[^A-Za-z0-9])(?:index|table[\s_-]+of[\s_-]+contents|contents|'
      r'copyright|cover|title[\s_-]+page|acknowledg(?:e?ments?|ement)?|'
      r'illustrations?|about[\s_-]+the[\s_-]+author|bibliography|endnotes?|'
      r'about[\s_-]+the[\s_-]+publisher|book[\s_-]+perk|card[\s_-]+page|'
      r'advertisements?|also[\s_-]+by|books[\s_-]+by)(?:$|[^A-Za-z0-9])',
      caseSensitive: false,
    );
    return excludedWords.hasMatch(fileName) ||
        excludedWords.hasMatch(normalizedTitle) ||
        const ['_ind_', '_toc_', '_cop_', '_cvi_', '_tp_', '_ack_', '_ill_', '_ata_']
            .any(normalizedPath.contains);
  }

  static bool _isMeaningfulFrontMatter(InspectedChapter chapter) {
    // Same underscore-aware boundary as _excludeFromStyleSampling: \b
    // misses prologue_page.xhtml because '_' counts as a word character.
    final words = RegExp(
      r'(?:^|[^A-Za-z0-9])(?:preface|foreword|introduction|prologue)(?:$|[^A-Za-z0-9])',
      caseSensitive: false,
    );
    final fileName = chapter.path.replaceAll('\\', '/').split('/').last;
    return words.hasMatch(chapter.title) || words.hasMatch(fileName) ||
        chapter.path.toLowerCase().contains('_prf_');
  }

  static String _representativeStyleText(List<ExtractedBlock> blocks) {
    final List<ExtractedBlock> texts = blocks
        .where(
          (ExtractedBlock block) =>
              _styleNonWhitespace.hasMatch(block.sourceText),
        )
        .toList(growable: false);
    if (texts.isEmpty) {
      return '';
    }
    if (texts.length <= 12) {
      return _boundedStyleText(texts, _memoryChapterTextLimit);
    }

    const int segmentBlocks = 4;
    const int segmentCharacterLimit = _memoryChapterTextLimit ~/ 3;
    final int middleStart = max(0, (texts.length - segmentBlocks) ~/ 2);
    final int endingStart = max(0, texts.length - segmentBlocks);
    final List<ExtractedBlock> opening = texts.take(segmentBlocks).toList();
    final List<ExtractedBlock> middle = texts
        .skip(middleStart)
        .take(segmentBlocks)
        .toList();
    final List<ExtractedBlock> ending = texts
        .skip(endingStart)
        .take(segmentBlocks)
        .toList();

    return <String>[
      '[Opening]\n${_boundedStyleText(opening, segmentCharacterLimit)}',
      '[Middle]\n${_boundedStyleText(middle, segmentCharacterLimit)}',
      '[Ending]\n${_boundedStyleText(ending, segmentCharacterLimit)}',
    ].join('\n');
  }

  static bool _hasRepresentativeStyleText(List<ExtractedBlock> blocks) {
    // The opening four nonempty blocks occur in either sampling layout.
    // Stop as soon as their normalized prefix meets the threshold. For thin
    // openings retain the historical middle/ending and label length rules.
    const threshold = _minimumRepresentativeStyleCharacters;
    final nonempty = blocks.where(
      (block) => _styleNonWhitespace.hasMatch(block.sourceText),
    );
    if (_normalizedStyleLength(nonempty.take(4), threshold) >= threshold) {
      return true;
    }
    final texts = nonempty.toList(growable: false);
    if (texts.length <= 12) {
      return _normalizedStyleLength(texts, threshold) >= threshold;
    }
    int length = '[Opening]\n\n[Middle]\n\n[Ending]\n'.length;
    for (final start in [0, (texts.length - 4) ~/ 2, texts.length - 4]) {
      length += _normalizedStyleLength(
        texts.skip(start).take(4),
        threshold - length,
      );
      if (length >= threshold) return true;
    }
    return false;
  }

  static int _normalizedStyleLength(
    Iterable<ExtractedBlock> blocks,
    int stopAt,
  ) {
    final whitespace = RegExp(r'\s');
    int length = 0;
    bool pendingSpace = false;
    for (final block in blocks) {
      final text = block.sourceText;
      final (start, end) = _styleTextBounds(text);
      for (int index = start; index < end; index++) {
        if (whitespace.hasMatch(text[index])) {
          pendingSpace = length > 0;
          continue;
        }
        if (pendingSpace) length++;
        pendingSpace = false;
        length++;
        if (length >= stopAt) return stopAt;
      }
      pendingSpace = length > 0;
    }
    return length;
  }

  static String _boundedStyleText(Iterable<ExtractedBlock> blocks, int limit) {
    final buffer = StringBuffer();
    final whitespace = RegExp(r'\s');
    bool pendingSpace = false;
    for (final block in blocks) {
      final text = block.sourceText;
      final (start, end) = _styleTextBounds(text);
      for (int index = start; index < end; index++) {
        final character = text[index];
        if (whitespace.hasMatch(character)) {
          pendingSpace = buffer.isNotEmpty;
          continue;
        }
        if (pendingSpace) buffer.write(' ');
        pendingSpace = false;
        buffer.write(character);
        // Read one extra normalized character to preserve the old <= limit
        // boundary (an exactly-full sample must not acquire an ellipsis).
        if (buffer.length > limit) {
          return '${buffer.toString().substring(0, limit - 3)}...';
        }
      }
      pendingSpace = buffer.isNotEmpty;
    }
    return buffer.toString();
  }

  // String.trim additionally removes NEXT LINE (U+0085), unlike RegExp \s.
  // Preserve block-edge trimming without allocating whole-block substrings.
  static final RegExp _styleTrimWhitespace = RegExp(r'[\s\u0085]');
  static final RegExp _styleNonWhitespace = RegExp(r'[^\s\u0085]');

  static (int, int) _styleTextBounds(String text) {
    int start = 0;
    int end = text.length;
    while (start < end && _styleTrimWhitespace.hasMatch(text[start])) {
      start++;
    }
    while (end > start && _styleTrimWhitespace.hasMatch(text[end - 1])) {
      end--;
    }
    return (start, end);
  }

  static TranslationStyleProfile _parseStyleProfileResponse(
    Map<String, dynamic> jsonPayload,
  ) {
    Object? candidate = jsonPayload['styleProfile'];
    if (candidate is! Map) {
      candidate = jsonPayload;
    }
    final Map<String, Object?> styleJson = <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in candidate.entries)
        entry.key.toString(): entry.value,
    };
    // Common alternate key names from model drift.
    styleJson.putIfAbsent(
      'primaryGenre',
      () => styleJson['genre'] ?? styleJson['primary_genre'],
    );
    styleJson.putIfAbsent(
      'secondaryGenres',
      () => styleJson['secondary'] ?? styleJson['tags'],
    );
    styleJson.putIfAbsent(
      'translationConstraints',
      () => styleJson['constraints'] ?? styleJson['do'],
    );
    final TranslationStyleProfile profile = TranslationStyleProfile.fromJson(
      styleJson,
    );
    if (!profile.isEmpty) {
      return profile;
    }
    // Last-resort: if model only returned a genre-like string field.
    final String genre = TranslationStyleProfile.fromJson(<String, Object?>{
      'primaryGenre': styleJson['primaryGenre'],
    }).primaryGenre;
    if (genre.isEmpty) {
      return TranslationStyleProfile.empty;
    }
    return TranslationStyleProfile(
      primaryGenre: genre,
      confidence: TranslationStyleConfidenceParsing.parse(
        styleJson['confidence'],
      ),
    );
  }

  static List<Map<String, String>> _initialMemorySourceChapters(
    List<InspectedChapter> chapters,
  ) {
    final List<InspectedChapter> eligibleChapters = chapters
        .where(
          (InspectedChapter chapter) =>
              chapter.includeInTranslation &&
              !FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
        )
        .toList(growable: false);
    final List<InspectedChapter> selected = <InspectedChapter>[];

    void addChapter(InspectedChapter chapter) {
      if (selected.any(
        (InspectedChapter selectedChapter) =>
            selectedChapter.path == chapter.path,
      )) {
        return;
      }
      selected.add(chapter);
    }

    for (final InspectedChapter chapter
        in eligibleChapters
            .where(
              (InspectedChapter chapter) =>
                  chapter.category == ChapterCategory.frontMatter,
            )
            .take(_initialMemoryFrontMatterLimit)) {
      addChapter(chapter);
    }
    for (final InspectedChapter chapter
        in eligibleChapters
            .where(
              (InspectedChapter chapter) =>
                  chapter.category == ChapterCategory.content,
            )
            .take(_initialMemoryContentLimit)) {
      addChapter(chapter);
    }
    if (selected.isEmpty) {
      for (final InspectedChapter chapter in eligibleChapters.take(
        _initialMemoryFrontMatterLimit + _initialMemoryContentLimit,
      )) {
        addChapter(chapter);
      }
    }

    return selected
        .map(
          (InspectedChapter chapter) => <String, String>{
            'title': chapter.title,
            'category': chapter.category.name,
            'text': _chapterMemoryText(chapter),
          },
        )
        .where((Map<String, String> chapter) => chapter['text']!.isNotEmpty)
        .toList(growable: false);
  }

  static String _chapterMemoryText(
    InspectedChapter chapter, {
    bool preferTranslated = false,
  }) {
    final StringBuffer excerpt = StringBuffer();
    final RegExp whitespace = RegExp(r'\s');
    bool pendingSpace = false;
    // Only parse blocks needed for this excerpt. Collapse whitespace while
    // copying into a bounded buffer, rather than joining the entire chapter
    // and allocating another whole-chapter string to normalize it.
    for (final ExtractedBlock block in chapter.blocks) {
      final String? translatedHtml = block.translatedHtml;
      final String text =
          preferTranslated &&
              translatedHtml != null &&
              translatedHtml.trim().isNotEmpty
          ? _plainTextFromHtmlFragment(translatedHtml)
          : block.sourceText;
      for (int index = 0; index < text.length; index += 1) {
        final String character = text[index];
        if (whitespace.hasMatch(character)) {
          pendingSpace = excerpt.isNotEmpty;
          continue;
        }
        if (pendingSpace) {
          excerpt.write(' ');
          pendingSpace = false;
        }
        if (excerpt.length < _memoryChapterTextLimit) {
          excerpt.write(character);
        }
        if (excerpt.length >= _memoryChapterTextLimit) {
          return '${excerpt.toString().substring(0, _memoryChapterTextLimit - 3)}...';
        }
      }
      // The old newline between nonempty blocks collapses to one space.
      pendingSpace = excerpt.isNotEmpty;
    }
    return excerpt.toString();
  }

  static String _plainTextFromHtmlFragment(String value) {
    return XhtmlHtmlCompatibility.parseFragment(value).text ?? '';
  }

  static TranslationStyleProfile _styleProfileFromBookMemoryJson(
    Map<String, Object?>? bookMemory,
  ) {
    if (bookMemory == null) {
      return TranslationStyleProfile.empty;
    }
    final Object? raw = bookMemory['styleProfile'];
    if (raw is Map<String, Object?>) {
      return TranslationStyleProfile.fromJson(raw);
    }
    if (raw is Map) {
      return TranslationStyleProfile.fromJson(
        raw.map(
          (dynamic key, dynamic value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
    }
    return TranslationStyleProfile.empty;
  }

  static bool _styleProfileConfirmedFromBookMemoryJson(
    Map<String, Object?>? bookMemory,
  ) {
    if (bookMemory == null) {
      return false;
    }
    final Object? raw = bookMemory['styleProfileConfirmed'];
    return raw == true;
  }
}

class _BookMemory {
  const _BookMemory({
    this.bookSummary = '',
    this.styleGuide = const <String>[],
    this.glossary = const <Map<String, String>>[],
    this.recentChapters = const <_ChapterMemory>[],
    this.styleProfile = TranslationStyleProfile.empty,
    this.styleProfileConfirmed = false,
  });

  static const _BookMemory empty = _BookMemory();

  factory _BookMemory.fromJson(
    Map<String, Object?> json, {
    bool trustedLocks = false,
  }) {
    final Object? rawStyleProfile = json['styleProfile'];
    final TranslationStyleProfile styleProfile =
        rawStyleProfile is Map<String, Object?>
        ? TranslationStyleProfile.fromJson(rawStyleProfile)
        : rawStyleProfile is Map
        ? TranslationStyleProfile.fromJson(
            rawStyleProfile.map(
              (dynamic key, dynamic value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
          )
        : TranslationStyleProfile.empty;
    return _BookMemory(
      bookSummary: _stringValue(json['bookSummary']),
      styleGuide: _stringList(
        json['styleGuide'],
        limit: _EpubBookMemory._memoryListLimit,
      ),
      glossary: _mergeGlossary(
        _glossaryList(json['glossary'], trustedLocks: trustedLocks),
        const [],
      ),
      recentChapters: _chapterMemoryList(
        json['recentChapters'],
        trustedLocks: trustedLocks,
      ),
      styleProfile: styleProfile,
      styleProfileConfirmed: json['styleProfileConfirmed'] == true,
    );
  }

  final String bookSummary;
  final List<String> styleGuide;
  final List<Map<String, String>> glossary;
  final List<_ChapterMemory> recentChapters;
  final TranslationStyleProfile styleProfile;
  final bool styleProfileConfirmed;

  bool get isEmpty =>
      bookSummary.trim().isEmpty &&
      styleGuide.isEmpty &&
      glossary.isEmpty &&
      recentChapters.isEmpty &&
      styleProfile.isEmpty;

  _BookMemory copyWith({
    String? bookSummary,
    List<String>? styleGuide,
    List<Map<String, String>>? glossary,
    List<_ChapterMemory>? recentChapters,
    TranslationStyleProfile? styleProfile,
    bool? styleProfileConfirmed,
    bool clearStyleProfile = false,
  }) {
    return _BookMemory(
      bookSummary: bookSummary ?? this.bookSummary,
      styleGuide: styleGuide ?? this.styleGuide,
      glossary: glossary ?? this.glossary,
      recentChapters: recentChapters ?? this.recentChapters,
      styleProfile: clearStyleProfile
          ? TranslationStyleProfile.empty
          : (styleProfile ?? this.styleProfile),
      styleProfileConfirmed: clearStyleProfile
          ? false
          : (styleProfileConfirmed ?? this.styleProfileConfirmed),
    );
  }

  _BookMemory mergeChapter(_ChapterMemory chapter) {
    final List<_ChapterMemory> mergedRecent = <_ChapterMemory>[
      ...recentChapters,
      chapter,
    ];
    final List<_ChapterMemory> limitedRecent =
        mergedRecent.length <= _EpubBookMemory._recentChapterMemoryLimit
        ? mergedRecent
        : mergedRecent.sublist(
            mergedRecent.length - _EpubBookMemory._recentChapterMemoryLimit,
          );

    return _BookMemory(
      bookSummary: bookSummary,
      styleGuide: styleGuide,
      glossary: _mergeGlossary(glossary, chapter.glossary),
      recentChapters: List<_ChapterMemory>.unmodifiable(limitedRecent),
      styleProfile: styleProfile,
      styleProfileConfirmed: styleProfileConfirmed,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (bookSummary.trim().isNotEmpty) 'bookSummary': bookSummary.trim(),
      'styleGuide': styleGuide,
      'glossary': glossary,
      'recentChapters': recentChapters
          .map((_ChapterMemory chapter) => chapter.toJson())
          .toList(growable: false),
      if (!styleProfile.isEmpty) 'styleProfile': styleProfile.toJson(),
      if (styleProfileConfirmed) 'styleProfileConfirmed': true,
    };
  }

  static String _stringValue(Object? value) {
    return value is String ? value.trim() : '';
  }

  static List<String> _stringList(Object? value, {required int limit}) {
    if (value is! List<dynamic>) {
      return const <String>[];
    }
    return value
        .whereType<String>()
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }

  static List<Map<String, String>> _glossaryList(
    Object? value, {
    bool trustedLocks = false,
  }) {
    if (value is! List<dynamic>) {
      return const <Map<String, String>>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> item) {
          final String source = _stringValue(item['source']);
          final String target = _stringValue(item['target']);
          if (source.isEmpty || target.isEmpty) {
            return null;
          }
           // A model-declared locked:true is never trusted: only
           // user-supplied locks (withLockedGlossary) and restored
           // checkpoints (trustedLocks) may mark an entry locked. Otherwise
           // a model lock could freeze a stale model term against the user's
           // explicit lock.
           return <String, String>{
             'source': source,
             'target': target,
             if (trustedLocks &&
                 (item['locked'] == true || item['locked'] == 'true'))
               'locked': 'true',
             if (int.tryParse('${item['lastUsed']}') != null)
               'lastUsed': '${item['lastUsed']}',
           };
        })
        .whereType<Map<String, String>>()
        .toList(growable: false);
  }

  static List<_ChapterMemory> _chapterMemoryList(
    Object? value, {
    bool trustedLocks = false,
  }) {
    if (value is! List<dynamic>) {
      return const <_ChapterMemory>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> item) => _ChapterMemory.fromJson(
            item.map(
              (dynamic key, dynamic value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
            trustedLocks: trustedLocks,
          ),
        )
        .where((_ChapterMemory chapter) => !chapter.isEmpty)
        .take(_EpubBookMemory._recentChapterMemoryLimit)
        .toList(growable: false);
  }

  static List<Map<String, String>> _mergeGlossary(
    List<Map<String, String>> existing,
    List<Map<String, String>> incoming,
  ) {
    // Logical monotonic timestamps are deterministic and survive checkpoints;
    // an incoming mention is a use, not merely a newly inserted mapping.
    final merged = <String, Map<String, String>>{};
    int clock = 0;
    for (final entry in existing) {
      clock = max(clock, int.tryParse(entry['lastUsed'] ?? '') ?? 0);
    }
    for (final entry in existing) {
      merged[entry['source']!.toLowerCase()] = {
        ...entry,
        'lastUsed': entry['lastUsed'] ?? '${++clock}',
      };
    }
    for (final entry in incoming) {
      final key = entry['source']!.toLowerCase();
      final previous = merged[key];
      final bool previousLocked = previous?['locked'] == 'true';
      final bool incomingLocked = entry['locked'] == 'true';
      merged[key] = {
        ...entry,
        // A previously user-locked target survives model updates, but an
        // explicit new user lock always replaces the old one: user intent
        // outranks both model declarations and earlier locks.
        if (previousLocked && !incomingLocked) ...previous!,
        'lastUsed': '${++clock}',
      };
    }
    while (merged.length > _EpubBookMemory._memoryGlossaryLimit) {
      final candidates = merged.entries.where((entry) => entry.value['locked'] != 'true').toList();
      // Locked entries are exempt even when the user locks more than 32 terms.
      if (candidates.isEmpty) break;
      candidates.sort((a, b) {
        final age = int.parse(a.value['lastUsed']!).compareTo(int.parse(b.value['lastUsed']!));
        return age != 0 ? age : a.key.compareTo(b.key);
      });
      final evicted = candidates.first;
      merged.remove(evicted.key);
      AppLogger.warn('Rolling glossary LRU evicted: ${evicted.value['source']}', tag: 'book-memory');
    }
    return merged.values.toList(growable: false);
  }

  /// LRU by last incoming mention, with lexical ties; user locks never expire.
  static const String glossaryEvictionPolicy = 'lru-unlocked-last-mention-v1';

  _BookMemory withLockedGlossary(String mappings) {
    final locked = <Map<String, String>>[];
    for (final line in mappings.split('\n')) {
      final match = RegExp(r'^\s*(.+?)\s*(?:=>|=|→|：|:)\s*(.+?)\s*$').firstMatch(line);
      if (match != null) {
        locked.add({'source': match[1]!, 'target': match[2]!, 'locked': 'true'});
      }
    }
    return copyWith(glossary: _mergeGlossary(glossary, locked));
  }
}

class _ChapterMemory {
  const _ChapterMemory({
    required this.title,
    required this.summary,
    this.path = '',
    this.continuityNotes = const <String>[],
    this.glossary = const <Map<String, String>>[],
  });

  factory _ChapterMemory.fromJson(
    Map<String, Object?> json, {
    bool trustedLocks = false,
  }) {
    return _ChapterMemory(
      title: _BookMemory._stringValue(json['title']),
      summary: _BookMemory._stringValue(json['summary']),
      path: _BookMemory._stringValue(json['path']),
      continuityNotes: _BookMemory._stringList(
        json['continuityNotes'],
        limit: _EpubBookMemory._memoryListLimit,
      ),
      glossary: _BookMemory._glossaryList(
        json['glossary'],
        trustedLocks: trustedLocks,
      ),
    );
  }

  final String title;
  final String summary;

  /// Source chapter path, recorded so a positional memory snapshot can tell
  /// which chapter an entry belongs to. Optional: older checkpoints omit it.
  final String path;
  final List<String> continuityNotes;
  final List<Map<String, String>> glossary;

  bool get isEmpty =>
      title.trim().isEmpty &&
      summary.trim().isEmpty &&
      continuityNotes.isEmpty &&
      glossary.isEmpty;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (title.trim().isNotEmpty) 'title': title.trim(),
      if (summary.trim().isNotEmpty) 'summary': summary.trim(),
      if (path.trim().isNotEmpty) 'path': path.trim(),
      'continuityNotes': continuityNotes,
      'glossary': glossary,
    };
  }
}

/// A companion in the non-evictable jobs directory, saved before progress.
/// Reuses the cache store's atomic checkpoint writer without modifying its
/// third-batch implementation or the public JobResumeState schema. The JSON
/// memory envelope lives in currentChapter on this internal-only checkpoint.
class _BookMemoryCheckpoint {
  _BookMemoryCheckpoint(this.cacheStore, this.jobKey, this.chunkSize);
  final TranslationCacheStore cacheStore;
  final String jobKey;
  final int chunkSize;

  /// Incremental-persist watermark: JSON of the timeline entries already
  /// written by a previous save, and how many in-memory entries they cover.
  /// Timeline entries are append-only in book order, so each save only
  /// serializes the suffix appended since the previous one (O(new entries)
  /// per save instead of O(all entries), i.e. O(n) total, not O(n^2)).
  final List<Map<String, Object?>> _persistedTimelineJson =
      <Map<String, Object?>>[];
  int _persistedTimelineLength = 0;

  String get key => sha256.convert(utf8.encode('$jobKey:book-memory')).toString();

  Future<({ _BookMemory memory, Set<String> completedChapterPaths, List<({String path, _BookMemory memory})> timeline })?> load() async {
    try {
      final state = await cacheStore.loadJobState(key);
      if (state == null) {
        AppLogger.info('No compatible memory checkpoint for chunkSize=$chunkSize; older identities are not reused.', tag: 'book-memory');
        return null;
      }
      final decoded = jsonDecode(state.currentChapter);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != EpubChapterTranslator.qualityCacheSchemaVersion ||
          decoded['chunkSize'] != chunkSize || decoded['jobKey'] != jobKey ||
          decoded['memory'] is! Map<String, dynamic>) {
        AppLogger.warn('Book memory checkpoint schema/chunkSize mismatch; discarding.', tag: 'book-memory');
        return null;
      }
      final memoryJson = decoded['memory'] as Map<String, dynamic>;
      // A checkpoint whose envelope is intact but whose memory internals
      // are damaged (wrong types, malformed glossary entries) must be
      // discarded, not silently normalized to empty values: the caller
      // rebuilds the memory via the API instead of translating blind.
      if (!_isIntactMemoryJson(memoryJson)) {
        AppLogger.warn('Book memory checkpoint internals damaged; discarding.', tag: 'book-memory');
        return null;
      }
      final rawPaths = decoded['completedChapterPaths'];
      if (rawPaths != null && rawPaths is! List) {
        AppLogger.warn('Book memory checkpoint chapter list damaged; discarding.', tag: 'book-memory');
        return null;
      }
      final timeline = _timelineFromJson(decoded['memoryTimeline']);
      // Seed the incremental-persist watermark so the first save after a
      // resume does not re-serialize the restored prefix.
      _persistedTimelineJson
        ..clear()
        ..addAll([
          for (final entry in timeline)
            {'path': entry.path, 'memory': entry.memory.toJson()},
        ]);
      _persistedTimelineLength = timeline.length;
      return (
        memory: _BookMemory.fromJson(memoryJson, trustedLocks: true),
        completedChapterPaths: ((rawPaths as List<dynamic>?) ?? [])
            .whereType<String>().toSet(),
        timeline: timeline,
      );
    } catch (error) {
      AppLogger.warn('Book memory checkpoint unreadable (${error.runtimeType}); discarding.', tag: 'book-memory');
      return null;
    }
  }

  /// Structural integrity check for the memory payload: every present key
  /// must have the expected JSON type, and glossary / recent-chapter
  /// entries must be well-formed objects. Lenient parsing happens later;
  /// this gate decides whether the checkpoint is trustworthy at all.
  static bool _isIntactMemoryJson(Map<String, dynamic> memory) {
    if (memory['bookSummary'] != null && memory['bookSummary'] is! String) {
      return false;
    }
    if (memory['styleGuide'] != null && memory['styleGuide'] is! List) {
      return false;
    }
    if (memory['styleProfile'] != null && memory['styleProfile'] is! Map) {
      return false;
    }
    final glossary = memory['glossary'];
    if (glossary != null) {
      if (glossary is! List) return false;
      for (final entry in glossary) {
        if (entry is! Map ||
            entry['source'] is! String ||
            entry['target'] is! String) {
          return false;
        }
      }
    }
    final recentChapters = memory['recentChapters'];
    if (recentChapters != null) {
      if (recentChapters is! List) return false;
      for (final entry in recentChapters) {
        if (entry is! Map) return false;
      }
    }
    return true;
  }

  /// Positional memory history: after each chapter's rolling-memory update,
  /// the snapshot is appended in book order. A retranslated earlier chapter
  /// later looks up the newest entry before its own position instead of
  /// receiving memory that already contains later chapters.
  static List<({String path, _BookMemory memory})> _timelineFromJson(Object? raw) {
    if (raw is! List) return const [];
    final timeline = <({String path, _BookMemory memory})>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final Map map = entry;
      final path = map['path'];
      final memory = map['memory'];
      if (path is! String || path.isEmpty || memory is! Map<String, dynamic>) {
        continue;
      }
      if (!_isIntactMemoryJson(memory)) continue;
      timeline.add((path: path, memory: _BookMemory.fromJson(memory, trustedLocks: true)));
    }
    return timeline;
  }

  Future<void> save(_BookMemory memory, {
    Set<String> completedChapterPaths = const {},
    List<({String path, _BookMemory memory})> timeline = const [],
    String schema = EpubChapterTranslator.qualityCacheSchemaVersion,
  }) {
    // Incremental timeline persist: entries are append-only in book order
    // (see recordMemoryTimeline), so only the suffix appended since the
    // previous save is serialized. The on-disk envelope still carries the
    // full merged timeline, so a resume sees every entry exactly once.
    // This pairs with the record-before-persist order (A-2): the entry
    // recorded for the just-finished chapter is included in this save.
    if (timeline.length < _persistedTimelineLength) {
      // The timeline was rebuilt (e.g. a fresh run reusing this
      // checkpoint): the cached prefix no longer applies.
      _persistedTimelineJson.clear();
      _persistedTimelineLength = 0;
    }
    for (int i = _persistedTimelineLength; i < timeline.length; i++) {
      final entry = timeline[i];
      _persistedTimelineJson.add(
        {'path': entry.path, 'memory': entry.memory.toJson()},
      );
    }
    _persistedTimelineLength = timeline.length;
    return cacheStore.saveJobState(JobResumeState(
      jobKey: key, inputFingerprint: jobKey, inputPath: '', outputPath: '',
      status: 'book-memory', completedFiles: completedChapterPaths.length,
      totalFiles: 0, completedBlocks: 0, totalBlocks: 0, cachedBlocks: 0,
      resumedBlocks: 0,
      currentChapter: jsonEncode({
        'schema': schema, 'jobKey': jobKey, 'chunkSize': chunkSize,
        'memory': memory.toJson(), 'completedChapterPaths': completedChapterPaths.toList(),
        'memoryTimeline': _persistedTimelineJson,
        'glossaryEvictionPolicy': _BookMemory.glossaryEvictionPolicy,
      }),
      updatedAtIso8601: DateTime.now().toIso8601String(),
    ));
  }
}

/// Source strings are spooled before clearing every invocation-owned list.
/// The exact prepared sources are available for retries even after release.
class _ChapterSourceSpool {
  // Publicly named test injection, privately held lazy directory.
  // ignore: prefer_initializing_formals
  _ChapterSourceSpool({Directory? directory}) : _directory = directory;
  Directory? _directory;
  bool _ownsDirectory = false;

  /// JSON codecs run on a worker isolate. These stay static and synchronous
  /// so the [Isolate.run] closure captures only its sendable argument: an
  /// inline closure inside the async [release]/[restore] scopes would also
  /// capture the surrounding async context, including the unsendable
  /// cancellation callback.
  static Future<String> _encodeJsonOnWorker(Map<String, Object?> payload) =>
      Isolate.run(() => jsonEncode(payload));

  static Future<Map<String, dynamic>> _decodeJsonOnWorker(String raw) =>
      Isolate.run(() => jsonDecode(raw) as Map<String, dynamic>);

  Future<File> _file(String chapterPath) async {
    if (_directory == null) {
      _directory = await Directory.systemTemp.createTemp('epub-chapter-sources-');
      _ownsDirectory = true;
    }
    return File(path.join(_directory!.path, '${sha256.convert(utf8.encode(chapterPath))}.json'));
  }

  Future<InspectedChapter> release(InspectedChapter chapter) async {
    try {
      final Map<String, Object?> payload = {
        'originalHtml': chapter.originalHtml, 'body': chapter.body,
        'blocks': [for (final block in chapter.blocks) {
          'id': block.id, 'sourceHtml': block.sourceHtml, 'sourceText': block.sourceText,
        }],
      };
      // Whole-chapter JSON encoding is CPU-bound: run it off the UI isolate
      // so progress emission and the cancellation watchdog stay responsive.
      final String json = await _encodeJsonOnWorker(payload);
      await writeFileAtomically(await _file(chapter.path), json);
      return chapter.copyWith(originalHtml: '', body: '', blocks: [
        for (final block in chapter.blocks) block.copyWith(sourceHtml: '', sourceText: ''),
      ]);
    } catch (error) {
      // A disk-full spool must not discard the only retry/repack source.
      AppLogger.warn('Source release skipped (${error.runtimeType}); keeping retry sources.', tag: 'translate');
      return chapter;
    }
  }

  Future<InspectedChapter> restore(
    InspectedChapter chapter, {
    bool blocks = true,
    bool Function()? isCancelled,
  }) async {
    if (chapter.originalHtml.isNotEmpty &&
        (!blocks || chapter.blocks.every((b) => b.sourceHtml.isNotEmpty))) {
      return chapter;
    }
    bool cancelled() => isCancelled?.call() ?? false;
    final file = await _file(chapter.path);
    if (!await file.exists()) {
      // Reload from the guarded archive when the spool is unavailable. Legacy
      // releases still carry originalHtml and only need reparsing.
      var source = chapter;
      if (source.originalHtml.isEmpty) {
        if (cancelled()) throw const TranslationCancelledException();
        final identity = source.sourceIdentity;
        if (identity == null) {
          throw FormatException('Released chapter has no recoverable source: ${chapter.path}');
        }
        final chapterPath = chapter.path;
        final snapshot = await EpubIsolateWorker.loadInspectionSnapshot(
          identity.inputPath, selectEntries: (_, _) => {chapterPath},
        );
        if (cancelled()) throw const TranslationCancelledException();
        checkEpubSourceHash(snapshot.fingerprint, identity.sha256);
        final bytes = snapshot.files[chapterPath];
        if (bytes == null) throw FormatException('Source chapter not found: $chapterPath');
        // Lenient decode matches the extractor/decoder convention: a damaged
        // byte must not fail the whole restore.
        source = source.copyWith(originalHtml: utf8.decode(bytes, allowMalformed: true));
      }
      final restored = await ChapterSourceRestorer.restoreChapter(
        chapter: source,
        isCancelled: cancelled,
      );
      final translations = {for (final block in chapter.blocks) block.id: block.translatedHtml};
      return restored.copyWith(blocks: [for (final block in restored.blocks)
        block.copyWith(translatedHtml: translations[block.id]),
      ]);
    }
    final String raw = await file.readAsString();
    if (cancelled()) throw const TranslationCancelledException();
    // Whole-chapter JSON decoding is CPU-bound: keep it off the UI isolate.
    // The worker entry is a static closure over sendable data only; it must
    // not be created inside this async scope, whose context also holds the
    // (unsendable) cancellation callback.
    final Map<String, dynamic> json = await _decodeJsonOnWorker(raw);
    final sources = {for (final item in json['blocks'] as List<dynamic>)
      (item as Map<String, dynamic>)['id'] as String: item};
    return chapter.copyWith(
      originalHtml: json['originalHtml'] as String,
      // Final preview needs the extractor's bounded source excerpt, while
      // full per-block sources stay on disk until an actual retry needs them.
      body: json['body'] as String,
      blocks: blocks ? [for (final block in chapter.blocks) block.copyWith(
        sourceHtml: sources[block.id]?['sourceHtml'] as String?,
        sourceText: sources[block.id]?['sourceText'] as String?,
      )] : chapter.blocks,
    );
  }

  Future<void> dispose() async {
    if (!_ownsDirectory) return;
    try {
      await _directory?.delete(recursive: true);
    } catch (error) {
      AppLogger.warn('Source spool cleanup failed (${error.runtimeType}).', tag: 'translate');
    }
  }
}

/// UTF-8 byte/4 is a common Latin-text token estimate. Byte counts also avoid
/// undercounting non-Latin text; 1.2 headroom covers markup and JSON escaping.
class _TranslationRequestBudget {
  static const int bytesPerToken = 4;
  static const double conservativeFactor = 1.2;

  /// Provider-agnostic guard for the max_tokens request parameter: no
  /// legitimate batch (bounded by the chunk-size planner) needs more output
  /// than this, while an unbounded estimate risks a provider-side 400 for an
  /// out-of-range parameter. Providers with a stricter output cap surface a
  /// context-overflow 400, which takes the shrink fallback instead of
  /// aborting the run (see TranslationApiClient.isContextOverflowError).
  static const int maxOutputTokensCeiling = 32768;

  /// Absolute sanity bound for the adaptive single-block ceiling below: no
  /// current model accepts more output tokens than this, so a larger
  /// max_tokens would be rejected outright instead of degrading gracefully.
  /// This is intentionally not per-model: providers with a stricter cap
  /// surface a 400 that the shrink/degrade path already handles.
  static const int maxAdaptiveOutputTokens = 131072;

  static int estimateTokens(String value) =>
      (utf8.encode(value).length / bytesPerToken * conservativeFactor).ceil();

  static ({int fixedTokens, int payloadTokens, int totalTokens}) forRequest(Map<String, dynamic> data) {
    final messages = data['messages'] as List<Map<String, String>>;
    final fixed = messages.where((m) => m['role'] != 'user').map((m) => m['content'] ?? '').join('\n');
    final payload = messages.where((m) => m['role'] == 'user').map((m) => m['content'] ?? '').join('\n');
    final fixedTokens = estimateTokens(fixed);
    final payloadTokens = estimateTokens(payload);
    return (fixedTokens: fixedTokens, payloadTokens: payloadTokens,
      totalTokens: fixedTokens + payloadTokens);
  }

  static void apply(Map<String, dynamic> data) {
    final budget = forRequest(data);
    // Equivalent upward budget: the HTML/JSON baseline plus every fixed
    // instruction, including style, locks and idiomatic rules. No private
    // accounting fields are sent to OpenAI-compatible gateways. The model
    // output ceiling keeps a misestimated input from sending a max_tokens
    // value the provider rejects outright.
    data['max_tokens'] =
        min(_adaptiveCeiling(data), max(256, budget.totalTokens));
  }

  /// Ceiling for [apply]: the default [maxOutputTokensCeiling] for normal
  /// multi-block batches, or — when a single block occupies the whole batch
  /// (e.g. one giant block alone after the shrink fallbacks) — an adaptive
  /// ceiling scaled from that block's own estimated output tokens, so the
  /// translation is not truncated mid-block. Bounded by
  /// [maxAdaptiveOutputTokens] as the model-side sanity limit.
  static int _adaptiveCeiling(Map<String, dynamic> data) {
    final String? blockText = _singleBlockText(data);
    if (blockText == null) return maxOutputTokensCeiling;
    // Translation output tracks input size; estimateTokens already carries
    // the conservative headroom, so it doubles as the output estimate.
    return min(
      maxAdaptiveOutputTokens,
      max(maxOutputTokensCeiling, estimateTokens(blockText)),
    );
  }

  /// Returns the source text when the request payload carries exactly one
  /// translatable block, else null. Every batch payload is a JSON object
  /// with a top-level "blocks" array; non-batch requests (memory, style
  /// profile, ...) never match and keep the default ceiling.
  static String? _singleBlockText(Map<String, dynamic> data) {
    try {
      final messages = data['messages'];
      if (messages is! List) return null;
      for (final message in messages) {
        if (message is! Map || message['role'] != 'user') continue;
        final content = message['content'];
        if (content is! String) continue;
        final decoded = jsonDecode(content);
        if (decoded is! Map) continue;
        final blocks = decoded['blocks'];
        if (blocks is! List || blocks.length != 1) continue;
        final block = blocks.single;
        if (block is! Map) continue;
        final html = block['html'];
        if (html is String && html.isNotEmpty) return html;
        final slots = block['slots'];
        if (slots is List) {
          final texts = <String>[
            for (final slot in slots)
              if (slot is Map && slot['text'] is String)
                slot['text'] as String,
          ];
          if (texts.isNotEmpty) return texts.join('\n');
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
