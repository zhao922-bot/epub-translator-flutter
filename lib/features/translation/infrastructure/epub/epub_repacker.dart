import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';
import '../../../../shared/localization/app_strings.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';
import 'epub_navigation.dart';
import 'epub_source_guard.dart';
import 'proper_name_normalizer.dart';
import 'protected_anchor_text_slots.dart';
import 'xhtml_html_compatibility.dart';

/// Renders translated chapters and writes a new EPUB via isolate ZIP work.
class EpubRepacker {
  EpubRepacker({EpubHtmlExtractor? extractor})
    : _extractor = extractor ?? const EpubHtmlExtractor();

  final EpubHtmlExtractor _extractor;

  /// Chapter-scoped key for a degraded block. Block ids restart per chapter
  /// (`p-1` exists in nearly every chapter), so a bare block id would collide
  /// across chapters and mis-mark innocent blocks as untranslated.
  /// [EpubChapterTranslator] records degradation with this key and passes the
  /// accumulated set back here for the final render.
  static String degradedKeyForBlock({
    required String chapterPath,
    required String blockId,
  }) {
    return '$chapterPath\u0000$blockId';
  }

  static const String _cjkCompatibilityStyleTitle =
      'EPUB Translator CJK compatibility';
  static const String _cjkCompatibilityCss = '''
body.epub-translator-cjk {
  line-height: 1.65;
  color: inherit;
  background-color: transparent;
  font-family: inherit;
}
body.epub-translator-cjk p,
body.epub-translator-cjk li,
body.epub-translator-cjk blockquote,
body.epub-translator-cjk dt,
body.epub-translator-cjk dd,
body.epub-translator-cjk h1,
body.epub-translator-cjk h2,
body.epub-translator-cjk h3,
body.epub-translator-cjk h4,
body.epub-translator-cjk h5,
body.epub-translator-cjk h6,
body.epub-translator-cjk div,
body.epub-translator-cjk span,
body.epub-translator-cjk td,
body.epub-translator-cjk th {
  color: inherit;
  font-family: inherit;
}
body.epub-translator-cjk p,
body.epub-translator-cjk li,
body.epub-translator-cjk blockquote,
body.epub-translator-cjk dt,
body.epub-translator-cjk dd { line-height: 1.65; }
body.epub-translator-cjk h1,
body.epub-translator-cjk h2,
body.epub-translator-cjk h3,
body.epub-translator-cjk h4,
body.epub-translator-cjk h5,
body.epub-translator-cjk h6 { border-color: currentColor !important; }
body.epub-translator-cjk .epub-translator-anchor-marker {
  color: inherit !important;
  text-decoration: none !important;
  border-bottom: 0 !important;
}
/* Bilingual mode: translated paragraphs are appended right after the
 * source text. Give them a subtle visual cue (a thin leading rule) so
 * readers can tell translation apart from source without overriding the
 * book's own typography. 双语模式：译文段落跟在原文后，用细竖线做低调区分，
 * 不覆盖书籍原有排版。 */
body.epub-translator-cjk [data-translation="true"] {
  border-left: 0.18em solid #8a8a8a;
  padding-left: 0.6em;
  margin-top: 0.5em;
}
''';

  Map<String, String> renderNavigationMetadataForTest({
    required Map<String, List<int>> archiveFiles,
    required List<InspectedChapter> chapters,
    required String targetLanguage,
  }) {
    final labelsByPath = _navigationLabels(chapters);
    return EpubIsolateWorker.renderNavigationMetadata(
      archiveFiles: archiveFiles,
      labelsByPath: labelsByPath,
      languageTag: _languageTagForTarget(targetLanguage),
    );
  }

  String synchronizeHtmlTocForTest({
    required String tocPath,
    required String tocHtml,
    required List<InspectedChapter> chapters,
  }) {
    final Map<String, String> rendered = <String, String>{tocPath: tocHtml};
    _synchronizeHtmlTocLabels(rendered, chapters);
    return rendered[tocPath]!;
  }

  Future<void> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const <String>{},
  }) async {
    void throwIfCancelled() {
      if (cancelToken?.isCancelled == true || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
    }

    throwIfCancelled();
    final ProperNameBookState properNameState =
        ProperNameNormalizer.bookState();
    // Rendered chapter by chapter (not in one collection literal) so a
    // pending cancellation is honored between chapters instead of only
    // before the isolate ZIP step. Repacking makes no API calls, so this is
    // purely about cancel responsiveness on large books.
    final Map<String, String> translatedHtmlByPath = <String, String>{};
    for (final InspectedChapter chapter in chapters) {
      throwIfCancelled();
      if (!chapter.includeInTranslation) {
        continue;
      }
      translatedHtmlByPath[chapter.path] = renderTranslatedChapter(
        chapter: chapter,
        bilingual: config.bilingual,
        targetLanguage: config.targetLanguage,
        lockedGlossary: config.lockedGlossary,
        properNameState: properNameState,
        degradedBlockIds: degradedBlockIds,
      );
    }
    _synchronizeHtmlTocLabels(translatedHtmlByPath, chapters);
    // Navigation metadata (OPF language + translated NCX labels) is rendered
    // inside the isolate from the same decoded archive, so the whole book is
    // never loaded into the main isolate just to read three small XML files.
    final navigationLabelsByPath = _navigationLabels(chapters);
    _validateXmlReplacements(translatedHtmlByPath);
    throwIfCancelled();
    final bool committed;
    try {
      committed = await EpubIsolateWorker.writeTranslatedEpub(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        translatedHtmlByPath: translatedHtmlByPath,
        navigationLabelsByPath: navigationLabelsByPath,
        navigationLanguageTag: _languageTagForTarget(config.targetLanguage),
        bilingual: config.bilingual,
        expectedSourceFingerprint: sourceIdentityForChapters(chapters)?.sha256,
        // Isolate cannot be hard-interrupted; refuse final commit on cancel.
        shouldCommit: () =>
            !(cancelToken?.isCancelled == true ||
                (isCancelled?.call() ?? false)),
        // A lock probe before translation cannot close the TOCTOU window, so
        // the commit failure itself carries the localized message (with the
        // preserved temp path) instead of a raw FileSystemException.
        lockedMessage: (String outputPath, String tempPath) => AppStrings(
          config.uiLanguage,
        ).outputFileLockedAtCommit(outputPath, tempPath),
      );
    } on InputFileLockedException catch (error) {
      // The user opened the source EPUB in a reader mid-run (Windows sharing
      // violation): fail loudly with an actionable message instead of a raw
      // English OS error. The block cache is intact, so the retry is cheap.
      throw StateError(
        AppStrings(config.uiLanguage).inputFileLocked(error.inputPath),
      );
    } on EpubDecompressionLimitException {
      throw StateError(
        AppStrings(config.uiLanguage).epubDecompressionLimit(inputPath),
      );
    }
    if (!committed) {
      throw const TranslationCancelledException();
    }
    // The final EPUB is already visible. Cancellation after this point must
    // not report the committed output as an aborted translation.
  }

  String renderTranslatedChapter({
    required InspectedChapter chapter,
    required bool bilingual,
    String targetLanguage = 'Chinese',
    String lockedGlossary = '',
    ProperNameBookState? properNameState,
    Set<String> degradedBlockIds = const <String>{},
  }) {
    final List<ProperNameMap> nameMappings = ProperNameNormalizer.parseGlossary(
      lockedGlossary,
    );
    final dom.Document document = html_parser.parse(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(chapter.originalHtml),
    );
    final List<dom.Element> targets = _extractor
        .extractTranslatableTextElements(document);
    final int count = min(targets.length, chapter.blocks.length);
    final languageTag = _languageTagForTarget(targetLanguage);
    bool containsCjkTranslation = false;
    bool hasTranslation = false;
    for (int index = 0; index < count; index += 1) {
      final dom.Element target = targets[index];
      final ExtractedBlock block = chapter.blocks[index];
      final String translatedHtml = block.translatedHtml?.trim() ?? '';
      if (translatedHtml.isEmpty) {
        continue;
      }
      hasTranslation = true;
      final isDegraded = degradedBlockIds.contains(
        degradedKeyForBlock(chapterPath: chapter.path, blockId: block.id),
      );
      final String normalizedTranslation = _normalizeCjkInitialTypography(
        translatedHtml,
        container: _replacementContainerFor(target),
      );
      containsCjkTranslation =
          containsCjkTranslation || _containsCjk(normalizedTranslation);
      String translationPart = bilingual
          ? _sanitizeForBilingual(
              _safelyUnwrapReplacementForStructuralTag(
                target,
                normalizedTranslation,
              ),
              container: _replacementContainerFor(target),
              languageTag: isDegraded ? null : languageTag,
            )
          : _safelyUnwrapReplacementForStructuralTag(
              target,
              normalizedTranslation,
            );
      if (nameMappings.isNotEmpty) {
        // The normalizer only ever sees the translation: in bilingual mode
        // the source paragraphs must stay byte-identical, and the
        // first-occurrence book state advances on translation hits alone.
        translationPart = ProperNameNormalizer.normalizeHtml(
          translationPart,
          nameMappings,
          targetLanguage: targetLanguage,
          state: properNameState,
        );
      }
      if (languageTag != null && !isDegraded) {
        translationPart = _labelTranslationLanguage(
          translationPart,
          target,
          languageTag,
        );
      }
      var replacement = bilingual
          ? (const {'li', 'td', 'th', 'caption'}.contains(target.localName)
                ? _bilingualStructuralItem(target, translationPart)
                : '${target.outerHtml}\n$translationPart')
          : translationPart;
      if (isDegraded) {
        // This block fell back to source/partial content. Leave an HTML
        // comment so the untranslated paragraph can be located in the EPUB
        // source. It trails the replacement so node-replacement mechanics
        // (first-node swap, td/th wrapper check) behave exactly as before.
        replacement = '$replacement<!-- UNTRANSLATED -->';
      }
      _replaceNodeWithHtml(target, replacement);
    }
    if (hasTranslation && !bilingual && languageTag != null) {
      // Keep the original inherited language for unselected / degraded text.
      // Each translated block carries its own target-language override.
      final body = document.body;
      final originalLanguage =
          document.documentElement?.attributes['xml:lang'] ??
          document.documentElement?.attributes['lang'];
      if (body != null &&
          originalLanguage != null &&
          !body.attributes.containsKey('lang') &&
          !body.attributes.containsKey('xml:lang')) {
        body.attributes['lang'] = originalLanguage;
        body.attributes['xml:lang'] = originalLanguage;
      }
      document.documentElement?.attributes['lang'] = languageTag;
      document.documentElement?.attributes['xml:lang'] = languageTag;
    }
    if (containsCjkTranslation) {
      _applyCjkReadingCompatibility(document);
    }
    return XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml);
  }

  /// Preserve list numbering and the table grid (including row/col spans).
  /// Translations are content inside the original structural element.
  String _bilingualStructuralItem(dom.Element source, String translationHtml) {
    final dom.Element item = source.clone(true);
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      translationHtml,
      container: _replacementContainerFor(source),
    );
    for (final dom.Node node in fragment.nodes.toList()) {
      if (node is dom.Element && node.localName == source.localName) {
        final dom.Element translation = dom.Element.tag('div');
        translation.attributes.addAll(node.attributes);
        translation.attributes.remove('value');
        translation.attributes.remove('rowspan');
        translation.attributes.remove('colspan');
        translation.attributes.remove('headers');
        translation.attributes.remove('scope');
        translation.nodes.addAll(node.nodes.toList());
        item.append(translation);
      } else {
        item.nodes.add(node);
      }
    }
    return item.outerHtml;
  }

  String _labelTranslationLanguage(
    String markup,
    dom.Element target,
    String languageTag,
  ) {
    final fragment = html_parser.parseFragment(
      markup,
      container: _replacementContainerFor(target),
    );
    // A bare-text API response also needs a local language boundary.
    for (final node in fragment.nodes.toList()) {
      if (node is dom.Text && node.data.trim().isNotEmpty) {
        final wrapper = dom.Element.tag('span');
        final index = fragment.nodes.indexOf(node);
        node.remove();
        wrapper.nodes.add(node);
        fragment.nodes.insert(index, wrapper);
      }
    }
    for (final element in fragment.querySelectorAll('*')) {
      if (element.parentNode == fragment ||
          element.attributes.containsKey('lang') ||
          element.attributes.containsKey('xml:lang')) {
        element.attributes['lang'] = languageTag;
        element.attributes['xml:lang'] = languageTag;
      }
    }
    return fragment.outerHtml;
  }

  /// The `parseFragment` container hint for a replacement: table cells need
  /// the `tr` context to keep their `<td>`/`<th>` wrapper, but every other
  /// caption needs `table`; other targets fall back to `body`. A non-cell target with a `tr` parent can
  /// only come from invalid source nesting; parsing its replacement in row
  /// context would trigger HTML5 foster parenting and displace the node,
  /// so the honest `body` context keeps it in place.
  String _replacementContainerFor(dom.Element target) {
    final String tag = target.localName ?? '';
    if (tag == 'caption') return 'table';
    if (tag == 'td' || tag == 'th') {
      return target.parent?.localName ?? 'body';
    }
    return 'body';
  }

  /// Table cells and captions must keep their wrapper element or the table
  /// layout collapses. The model is allowed to return the inner content
  /// without the cell wrapper (`<p>…</p>` instead of `<td>…</td>`), so if the
  /// first node of the replacement is not the same structural tag, we wrap it
  /// back with the original tag and its attributes.
  String _safelyUnwrapReplacementForStructuralTag(
    dom.Element target,
    String replacementHtml,
  ) {
    final String tag = target.localName ?? '';
    if (tag != 'td' && tag != 'th' && tag != 'caption') {
      return replacementHtml;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(replacementHtml),
      container: _replacementContainerFor(target),
    );
    final dom.Node? first = fragment.nodes.isEmpty
        ? null
        : fragment.nodes.first;
    if (first is dom.Element && first.localName == tag) {
      // The model supplies text, not table layout or anchor identities.
      // Restore source attributes even when it returned a full cell wrapper.
      first.attributes
        ..clear()
        ..addAll(target.attributes);
      return fragment.outerHtml;
    }
    final StringBuffer attrs = StringBuffer();
    for (final MapEntry<Object, String> entry in target.attributes.entries) {
      attrs.write(' ${entry.key}="${_escapeAttr(entry.value)}"');
    }
    return '<$tag$attrs>$replacementHtml</$tag>';
  }

  static String _escapeAttr(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  void _replaceNodeWithHtml(dom.Element target, String replacementHtml) {
    final dom.Node? parentNode = target.parentNode;
    if (parentNode == null) {
      return;
    }
    final int index = parentNode.nodes.indexOf(target);
    if (index < 0) {
      return;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(replacementHtml),
      container: _replacementContainerFor(target),
    );
    final List<dom.Node> replacementNodes = fragment.nodes.toList();
    if (replacementNodes.isEmpty) {
      return;
    }
    parentNode.nodes[index] = replacementNodes.first;
    for (int i = 1; i < replacementNodes.length; i += 1) {
      parentNode.nodes.insert(index + i, replacementNodes[i]);
    }
  }

  /// Sanitizes a translation fragment for bilingual rendering: duplicate
  /// `id`s are removed (the source block keeps its own) and every top-level
  /// translation element is marked with `data-translation="true"` so styles
  /// and reading systems can tell translation paragraphs apart from source
  /// paragraphs. When [languageTag] is given, the mark also carries the
  /// target language. [container] gives the HTML parser the table context
  /// (`tr`) it needs to keep `<td>`/`<th>` wrappers instead of dropping
  /// them as stray table cells.
  String _sanitizeForBilingual(
    String translatedHtml, {
    String? container,
    String? languageTag,
  }) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(translatedHtml),
      container: container ?? 'body',
    );
    for (final dom.Element element in fragment.querySelectorAll('[id]')) {
      element.attributes.remove('id');
    }
    for (final anchor in fragment.querySelectorAll('a[name]')) {
      anchor.attributes.remove('name');
    }
    for (final dom.Node node in fragment.nodes) {
      if (node is dom.Element) {
        node.attributes['data-translation'] = 'true';
        if (languageTag != null) {
          node.attributes['lang'] = languageTag;
          node.attributes['xml:lang'] = languageTag;
        }
      }
    }
    return fragment.outerHtml;
  }

  String _normalizeCjkInitialTypography(
    String translatedHtml, {
    String container = 'body',
  }) {
    final String parserSafe = XhtmlHtmlCompatibility.normalizeForHtmlParser(
      translatedHtml,
    );
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      parserSafe,
      container: container,
    );
    if (!_containsCjk(fragment.text ?? '')) {
      return parserSafe;
    }

    final List<dom.Element> dropCaps = fragment
        .querySelectorAll('[class]')
        .where(
          (dom.Element element) =>
              !_isInsideFootnoteMarkerAnchor(element) &&
              element.classes.any(
                (String className) =>
                    className.toLowerCase().startsWith('dropcap'),
              ),
        )
        .toList();
    for (final dom.Element dropCap in dropCaps) {
      final dom.Element? followingElement = _nextNonWhitespaceElement(dropCap);
      final String dropCapText = dropCap.text.trim();
      if (RegExp(r'^[A-Za-z]$').hasMatch(dropCapText)) {
        // The translated sentence already contains its CJK opening word.
        // Keeping the original decorative initial leaves a stray Latin letter.
        dropCap.remove();
      } else {
        _removeClassesWhere(
          dropCap,
          (String className) => className.toLowerCase().startsWith('dropcap'),
        );
      }

      if (followingElement != null &&
          _containsCjk(followingElement.text) &&
          !_isInsideFootnoteMarkerAnchor(followingElement) &&
          followingElement.classes.any(_isInitialSmallCapsClass)) {
        _removeClassesWhere(followingElement, _isInitialSmallCapsClass);
      }
    }
    for (final dom.Element element in fragment.querySelectorAll('[class]')) {
      if (!_isInsideFootnoteMarkerAnchor(element) &&
          _containsCjk(element.text) &&
          element.classes.any(_isInitialSmallCapsClass)) {
        _removeClassesWhere(element, _isInitialSmallCapsClass);
      }
    }
    return fragment.outerHtml;
  }

  bool _isInsideFootnoteMarkerAnchor(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      if (current.localName == 'a' && _containsFootnoteMarkerClass(current)) {
        return true;
      }
      current = current.parentNode;
    }
    return false;
  }

  bool _containsFootnoteMarkerClass(dom.Element element) {
    return ProtectedAnchorTextSlots.hasFootnoteMarkerClass(element);
  }

  dom.Element? _nextNonWhitespaceElement(dom.Element element) {
    final dom.Node? parent = element.parentNode;
    if (parent == null) {
      return null;
    }
    final int elementIndex = parent.nodes.indexOf(element);
    if (elementIndex < 0) {
      return null;
    }
    for (
      int index = elementIndex + 1;
      index < parent.nodes.length;
      index += 1
    ) {
      final dom.Node sibling = parent.nodes[index];
      if (sibling is dom.Element) {
        return sibling;
      }
      if (sibling is dom.Text && sibling.data.trim().isNotEmpty) {
        return null;
      }
    }
    return null;
  }

  bool _isInitialSmallCapsClass(String className) {
    final String normalized = className.toLowerCase();
    return normalized == 'small' ||
        normalized == 'small-caps' ||
        normalized == 'smallcaps';
  }

  void _removeClassesWhere(
    dom.Element element,
    bool Function(String className) shouldRemove,
  ) {
    element.classes.removeWhere(shouldRemove);
    if (element.classes.isEmpty) {
      element.attributes.remove('class');
    }
  }

  void _applyCjkReadingCompatibility(dom.Document document) {
    final dom.Element? body = document.body;
    if (body == null) {
      return;
    }
    body.classes.add('epub-translator-cjk');
    for (final dom.Element anchor in body.querySelectorAll('a:not([href])')) {
      anchor.classes.add('epub-translator-anchor-marker');
    }

    final dom.Element? head = document.head;
    if (head == null) {
      return;
    }
    final dom.Element style =
        head.querySelector('style[title="$_cjkCompatibilityStyleTitle"]') ??
        head.querySelector('#epub-translator-cjk-compat') ??
        dom.Element.tag('style');
    style.attributes.remove('id');
    style.attributes['type'] = 'text/css';
    style.attributes['title'] = _cjkCompatibilityStyleTitle;
    style.text = _cjkCompatibilityCss;
    if (style.parentNode == null) {
      head.append(style);
    }
  }

  bool _containsCjk(String value) {
    return RegExp(
      r'[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]',
    ).hasMatch(value);
  }

  /// Filenames / title words that identify a table-of-contents document.
  /// Matching is on whole stems and whole words on purpose: substring
  /// matching (e.g. `contains('toc')`) misfires on ordinary words like
  /// "Protocols" or "Stockholm" and would silently rewrite body-text
  /// cross-references into chapter titles.
  static const Set<String> _tocDocumentNames = <String>{
    'toc',
    'nav',
    'contents',
    'table-of-contents',
    'tableofcontents',
    'inhalt',
    'sommaire',
  };

  static final RegExp _wordTokenPattern = RegExp(r'[a-z0-9]+');

  bool _isTocLikeChapter(InspectedChapter chapter) {
    // A real TOC stylesheet hook is precise; keep it as-is.
    if (chapter.originalHtml.contains('class="toc')) {
      return true;
    }
    // Whole filename-stem match: "toc.xhtml" hits, "protocols.xhtml" does
    // not. ZIP entry names always use '/' separators.
    final String fileName = chapter.path.toLowerCase().split('/').last;
    final String stem = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    if (_tocDocumentNames.contains(stem)) {
      return true;
    }
    // Whole-word title match: "Table of Contents" hits, "Protocols" does not.
    for (final RegExpMatch match in _wordTokenPattern.allMatches(
      chapter.title.toLowerCase(),
    )) {
      if (_tocDocumentNames.contains(match.group(0))) {
        return true;
      }
    }
    return false;
  }

  void _synchronizeHtmlTocLabels(
    Map<String, String> renderedByPath,
    List<InspectedChapter> chapters,
  ) {
    final labelsByPath = _navigationLabels(chapters);
    if (labelsByPath.isEmpty) {
      return;
    }
    for (final InspectedChapter chapter in chapters) {
      if (!_isTocLikeChapter(chapter)) {
        continue;
      }
      final String? rendered = renderedByPath[chapter.path];
      if (rendered == null) {
        continue;
      }
      final dom.Document document = html_parser.parse(rendered);
      // EPUB 3 nav documents are handled from the manifest in the isolate.
      // Applying this legacy heuristic would also overwrite page-list labels.
      if (document.querySelectorAll('nav').any(isEpubTocElement)) {
        continue;
      }
      bool changed = false;
      for (final dom.Element anchor in document.querySelectorAll('a[href]')) {
        final String href = anchor.attributes['href'] ?? '';
        if (href.isEmpty || Uri.tryParse(href)?.hasScheme == true) {
          continue;
        }
        final targetPath = navigationTargetKey(chapter.path, href);
        final String? label = labelsByPath[targetPath];
        if (label == null || anchor.text.trim().isEmpty) {
          continue;
        }
        _setAnchorLabelPreservingNestedElements(anchor, label);
        changed = true;
      }
      if (changed) {
        renderedByPath[chapter.path] =
            XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml);
      }
    }
  }

  Map<String, String> _navigationLabels(List<InspectedChapter> chapters) {
    final labels = <String, String>{};
    for (final chapter in chapters) {
      if (!chapter.includeInTranslation) continue;
      final chapterPath = path.posix.normalize(chapter.path);
      final chapterLabel = _navigationLabelForChapter(chapter);
      if (chapterLabel != null) labels[chapterPath] = chapterLabel;
      // Translation releases sourceHtml after caching. Recreate the same
      // extraction boundaries from the retained chapter document for export.
      final originalDocument = html_parser.parse(
        XhtmlHtmlCompatibility.normalizeForHtmlParser(chapter.originalHtml),
      );
      final originalBlocks = _extractor.extractBlocks(
        originalDocument,
        chapterPath: chapter.path,
      );
      final sourcesById = {for (final block in originalBlocks) block.id: block};
      for (final block in chapter.blocks) {
        if (block.translatedHtml?.trim().isNotEmpty != true) continue;
        final source = html_parser.parseFragment(
          XhtmlHtmlCompatibility.normalizeForHtmlParser(
            sourcesById[block.id]?.sourceHtml ?? block.sourceHtml,
          ),
        );
        final translated = html_parser.parseFragment(block.translatedHtml!);
        final headings = source.querySelectorAll('h1,h2,h3,h4,h5,h6');
        final translatedHeadings = translated.querySelectorAll(
          'h1,h2,h3,h4,h5,h6',
        );
        // Only pair structurally matching headings; preserve unknown labels.
        if (headings.length != translatedHeadings.length) continue;
        for (var i = 0; i < headings.length; i++) {
          final label = translatedHeadings[i].text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (label.isEmpty) continue;
          for (final element in [
            headings[i],
            ...headings[i].querySelectorAll('[id], a[name]'),
          ]) {
            final id = element.attributes['id'] ?? element.attributes['name'];
            if (id != null && id.isNotEmpty) labels['$chapterPath#$id'] = label;
          }
        }
      }
    }
    return labels;
  }

  /// Replace label text even when wrapped in formatting spans. Keep the
  /// nested elements and page-number text intact instead of flattening them.
  void _setAnchorLabelPreservingNestedElements(
    dom.Element anchor,
    String label,
  ) {
    final textNodes = <dom.Text>[];
    void collect(dom.Node node) {
      if (node is dom.Text && node.data.trim().isNotEmpty) textNodes.add(node);
      if (node is dom.Element &&
          !node.classes.contains('pagenum') &&
          node.attributes['role'] != 'doc-pagebreak') {
        for (final child in node.nodes) {
          collect(child);
        }
      }
    }

    collect(anchor);
    if (textNodes.isEmpty) {
      return;
    }
    textNodes.first.text = label;
    for (final dom.Text extra in textNodes.skip(1)) {
      extra.remove();
    }
  }

  String? _navigationLabelForChapter(InspectedChapter chapter) {
    final List<String> headings = chapter.blocks
        .where(
          (ExtractedBlock block) =>
              block.translatedHtml?.trim().isNotEmpty == true &&
              RegExp(r'^h[1-3]$').hasMatch(block.tagName),
        )
        .map(
          (ExtractedBlock block) =>
              (html_parser.parseFragment(block.translatedHtml!).text ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
        )
        .where((String value) => value.isNotEmpty)
        .toSet()
        .take(2)
        .toList(growable: false);
    if (headings.isEmpty) {
      return null;
    }
    if (headings.length == 1) {
      return headings.first;
    }
    if (RegExp(r'^\d{1,3}$').hasMatch(headings.first)) {
      return '${headings.first}. ${headings[1]}';
    }
    return '${headings.first}: ${headings[1]}';
  }

  void _validateXmlReplacements(Map<String, String> replacements) {
    for (final MapEntry<String, String> replacement in replacements.entries) {
      // Every replacement here is an XHTML chapter, regardless of its suffix.
      try {
        xml.XmlDocument.parse(replacement.value);
      } on xml.XmlParserException catch (error) {
        throw FormatException(
          'Generated EPUB markup is invalid at ${replacement.key}: $error',
        );
      }
    }
  }

  String? _languageTagForTarget(String targetLanguage) {
    final String normalized = targetLanguage.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.contains('traditional') ||
        normalized.contains('繁體') ||
        normalized.contains('繁体')) {
      return 'zh-TW';
    }
    if (normalized.contains('chinese') ||
        normalized.contains('中文') ||
        normalized.contains('汉语') ||
        normalized.contains('漢語')) {
      return 'zh-CN';
    }
    if (normalized.contains('japanese') || normalized.contains('日语')) {
      return 'ja';
    }
    if (normalized.contains('korean') || normalized.contains('韩语')) {
      return 'ko';
    }
    const Map<String, String> common = <String, String>{
      'english': 'en',
      'french': 'fr',
      'german': 'de',
      'spanish': 'es',
      'italian': 'it',
      'portuguese': 'pt',
      'russian': 'ru',
    };
    return common[normalized] ??
        (RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$').hasMatch(normalized)
            ? normalized
            : null);
  }
}
