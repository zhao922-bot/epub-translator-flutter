part of 'epub_chapter_translator.dart';

/// Secondary cache for complete, validated body requests across EPUB edits.
/// The ordinary cache owns the paid HTML. These records pin the exact cached
/// rows to their original request so a later cache overwrite cannot change
/// the evidence for reuse.
class _EpubIncrementalCache {
  _EpubIncrementalCache({
    required this.artifacts,
    required this.apiClient,
    required this.config,
    required this.bookScope,
    required this.chapter,
    required this.cacheKeyFor,
    required this.throwIfCancelled,
  }) : _sourceIndex = {
         for (var i = 0; i < chapter.blocks.length; i++)
           chapter.blocks[i].id: i,
       };

  final TranslationArtifactCache artifacts;
  final TranslationApiClient apiClient;
  final TranslationConfig config;
  final String bookScope;
  final InspectedChapter chapter;
  final String Function(ExtractedBlock) cacheKeyFor;
  final void Function() throwIfCancelled;
  final Map<String, int> _sourceIndex;
  final _sourceDigests = Expando<String>();

  static String? bookScopeFor({
    required TranslationConfig config,
    required String inputPath,
    required List<InspectedChapter> chapters,
  }) {
    if (!config.tokenSavingMode || config.semanticQualityCheck) return null;
    final source = sourceIdentityForChapters(chapters);
    final publication = source?.reuseFingerprint;
    if (publication == null || publication.isEmpty) return null;
    final file = _EpubTranslatorPaths._normalizeInputPathForCache(inputPath);
    if (_EpubTranslatorPaths._normalizeInputPathForCache(source!.inputPath) !=
        file) {
      return null;
    }
    if (chapters.any(
      (chapter) => chapter.sourceIdentity?.reuseFingerprint != publication,
    )) {
      return null;
    }
    return _hashJson([
      file,
      publication,
      [for (final chapter in chapters) chapter.path],
    ]);
  }

  Future<Map<String, String>> read(
    List<ExtractedBlock> blocks,
    Map<String, dynamic> request,
  ) async {
    final key = _evidenceKey(blocks, request);
    if (key == null) return const {};
    final record = await artifacts.read(key);
    throwIfCancelled();
    final rows = record?['rows'];
    if (rows is! List || rows.length != blocks.length) return const {};
    final translations = <String, String>{};
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final row = rows[i];
      if (row is! Map || row['id'] != block.id) return const {};
      final exactKey = row['cacheKey'];
      final htmlDigest = row['htmlDigest'];
      if (exactKey is! String ||
          htmlDigest is! String ||
          !_digestPattern.hasMatch(exactKey) ||
          !_digestPattern.hasMatch(htmlDigest)) {
        return const {};
      }
      String? html;
      try {
        html = await artifacts.store.getBlockTranslation(exactKey);
        throwIfCancelled();
        if (html == null || _hashText(html) != htmlDigest) return const {};
        // Reapply today's structure, XML, disclaimer, and residual checks to
        // the exact source. A changed/corrupt block falls through to the API.
        final validated = EpubChapterTranslator._lockAndValidateTranslatedBlock(
          config: config,
          block: block,
          translatedHtml: html,
        );
        if (validated != html) return const {};
      } on FileSystemException {
        return const {};
      } on FormatException {
        return const {};
      }
      translations[block.id] = html;
    }
    return translations;
  }

  Future<void> remember(
    List<ExtractedBlock> blocks,
    Map<String, dynamic> request,
    Map<String, String> translations,
  ) async {
    final key = _evidenceKey(blocks, request);
    if (key == null || translations.length != blocks.length) return;
    final rows = <Map<String, String>>[];
    for (final block in blocks) {
      final html = translations[block.id];
      if (html == null || html.isEmpty) return;
      rows.add({
        'id': block.id,
        'cacheKey': cacheKeyFor(block),
        'htmlDigest': _hashText(html),
      });
    }
    await artifacts.write(key, {'rows': rows});
  }

  String? _evidenceKey(
    List<ExtractedBlock> blocks,
    Map<String, dynamic> request,
  ) {
    if (blocks.isEmpty || _sourceIndex.length != chapter.blocks.length) {
      return null;
    }
    final positions = <Object>[];
    for (final block in blocks) {
      final index = _sourceIndex[block.id];
      if (index == null || !identical(block, chapter.blocks[index])) {
        return null;
      }
      positions.add([
        index,
        _sourceDigest(block),
        if (index > 0) _sourceDigest(chapter.blocks[index - 1]) else null,
        if (index + 1 < chapter.blocks.length)
          _sourceDigest(chapter.blocks[index + 1])
        else
          null,
      ]);
    }
    final profile = config.capabilities;
    final reasoning = request['_folioFerryPreferLowReasoning'] == true
        ? profile.ordinaryBodyReasoningParameters
        : profile.reasoningParameters;
    return TranslationArtifactCache.key(config, 'epub-body-request-reuse-v1', [
      EpubChapterTranslator.qualityCacheSchemaVersion,
      bookScope,
      chapter.path,
      chapter.title,
      chapter.category.name,
      config.residualQualityCheck,
      config.useStreamingApi,
      apiClient.normalizedBaseUrl(config.apiBaseUrl),
      request['model'],
      request['temperature'],
      reasoning,
      positions,
      // Messages include the exact ordered rows, selected glossary and style,
      // and read-only context. Per-attempt output headroom is a local budget
      // decision and may vary even when a previously complete result fits.
      request['messages'],
    ]);
  }

  String _sourceDigest(ExtractedBlock block) =>
      _sourceDigests[block] ??= _hashJson([
        block.id,
        block.tagName,
        block.sourceHtml,
        block.sourceText,
        block.isAuthorSignature,
      ]);

  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static String _hashText(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _hashJson(Object value) => _hashText(jsonEncode(value));
}
