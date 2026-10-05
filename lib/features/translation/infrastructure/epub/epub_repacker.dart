import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    String targetLanguage = 'Chinese',
  }) {
    final Map<String, String> rendered = <String, String>{tocPath: tocHtml};
    _synchronizeHtmlTocLabels(
      rendered,
      chapters,
      targetLanguage: targetLanguage,
    );
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
    _synchronizeHtmlTocLabels(
      translatedHtmlByPath,
      chapters,
      targetLanguage: config.targetLanguage,
      bilingual: config.bilingual,
    );
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
      final String normalizedTranslation = _collapseRedundantWhitespace(
        _normalizeCjkInitialTypography(
          translatedHtml,
          container: _replacementContainerFor(target),
        ),
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
          ? (const {
                  'li',
                  'td',
                  'th',
                  'caption',
                  'summary',
                  'figcaption',
                }.contains(target.localName)
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
        final dom.Element translation = dom.Element.tag(
          source.localName == 'summary' ? 'span' : 'div',
        );
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
    final sources = <dom.Element, dom.Element>{};
    void align(dom.Element source, dom.Element translated) {
      if (source.localName != translated.localName) return;
      sources[translated] = source;
      final translatedChildren = translated.children;
      bool sameTags(List<dom.Element> children) =>
          children.length == translatedChildren.length &&
          List.generate(children.length, (i) => i).every(
            (i) => children[i].localName == translatedChildren[i].localName,
          );
      var sourceChildren = source.children.toList();
      if (!sameTags(sourceChildren)) {
        // CJK preparation unwraps decorative spans. Align promoted children
        // with their original nodes, retaining the original text and lang.
        Iterable<dom.Element> promoted(dom.Element child) sync* {
          final letters = child.text.replaceAll(RegExp('[^A-Za-z]'), '');
          final decorative =
              child.localName == 'span' &&
              !child.attributes.containsKey('id') &&
              !child.attributes.containsKey('name') &&
              !_isNonProseElement(child) &&
              !_isInsideFootnoteMarkerAnchor(child) &&
              child.classes.any(
                (token) =>
                    token.toLowerCase().startsWith('dropcap') ||
                    (_isInitialSmallCapsClass(token) &&
                        letters.isNotEmpty &&
                        letters == letters.toUpperCase()),
              );
          if (decorative) {
            for (final nested in child.children) {
              yield* promoted(nested);
            }
          } else {
            yield child;
          }
        }

        final flattened = sourceChildren.expand(promoted).toList();
        if (sameTags(flattened)) sourceChildren = flattened;
      }
      if (sourceChildren.length == translatedChildren.length &&
          List.generate(sourceChildren.length, (i) => i).every(
            (i) =>
                sourceChildren[i].localName == translatedChildren[i].localName,
          )) {
        for (var i = 0; i < sourceChildren.length; i++) {
          align(sourceChildren[i], translatedChildren[i]);
        }
      } else {
        // A removed decorative span must not shift the remaining em/a/etc.
        // Match unchanged sibling groups in order, never by displayed text.
        for (final tag
            in translatedChildren.map((child) => child.localName).toSet()) {
          final original = sourceChildren
              .where((child) => child.localName == tag)
              .toList();
          final output = translatedChildren
              .where((child) => child.localName == tag)
              .toList();
          if (original.length == output.length) {
            for (var i = 0; i < original.length; i++) {
              align(original[i], output[i]);
            }
          }
        }
        // Stable ids also identify nodes moved out of removed wrappers.
        for (final child in translatedChildren) {
          final id = child.attributes['id'];
          if (id == null || id.isEmpty) continue;
          final matches = source
              .querySelectorAll('[id]')
              .where((element) => element.attributes['id'] == id)
              .toList();
          if (matches.length == 1 && !sources.containsKey(child)) {
            align(matches.single, child);
          }
        }
      }
    }

    if (fragment.children.length == 1) {
      align(target, fragment.children.single);
    }
    for (final element in fragment.querySelectorAll('*')) {
      final String? markedLanguage =
          element.attributes['lang'] ?? element.attributes['xml:lang'];
      final bool isStaleEcho =
          markedLanguage != null &&
          _isStaleLanguageEcho(sources[element], element, markedLanguage);
      if (markedLanguage != null && !isStaleEcho) {
        // The model deliberately marked a foreign-language passage the
        // source did not mark (m6: a kept English quote inside Chinese
        // text): respect it, never overwrite with the target language.
        continue;
      }
      if (element.parentNode == fragment || isStaleEcho) {
        element.attributes['lang'] = languageTag;
        element.attributes['xml:lang'] = languageTag;
      }
    }
    return fragment.outerHtml;
  }

  /// True when the model's language marking on [fragmentElement] merely
  /// echoes a marking the corresponding [sourceElement] already carried, while the
  /// text itself was translated (round2: `<em lang="en">Hello.</em>` →
  /// `<em xml:lang="en">Bonjour.</em>`): the marking is stale and the
  /// translated text takes the target language.
  ///
  /// A marking the source never had — or one whose text the model preserved
  /// verbatim (a genuine foreign-language quote) — is deliberate and must
  /// survive untouched.
  bool _isStaleLanguageEcho(
    dom.Element? sourceElement,
    dom.Element fragmentElement,
    String markedLanguage,
  ) {
    if (sourceElement == null) return false;
    final sourceLanguage =
        sourceElement.attributes['lang'] ??
        sourceElement.attributes['xml:lang'];
    return sourceLanguage == markedLanguage &&
        _collapsedText(sourceElement.text) !=
            _collapsedText(fragmentElement.text);
  }

  String _collapsedText(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

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
    if (tag != 'td' &&
        tag != 'th' &&
        tag != 'caption' &&
        tag != 'summary' &&
        tag != 'figcaption') {
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
              !_isNonProseElement(element) &&
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
        // A single Latin letter is only a stray decorative initial when the
        // translated sentence already opens with its CJK word. If the letter
        // heads a preserved English word (e.g. a proper name the model kept
        // in Latin: `<span class="dropcap">A</span>dam Smith 说`), deleting
        // it corrupts the word — keep the letter and only drop the class.
        // When nothing follows, stay conservative and keep the letter too.
        final String? nextChar = _firstContentCharAfter(dropCap);
        if (nextChar != null && _containsCjk(nextChar)) {
          if (dropCap.attributes.containsKey('id') ||
              dropCap.attributes.containsKey('name')) {
            dropCap.nodes.clear();
            _removeClassesWhere(
              dropCap,
              (className) => className.toLowerCase().startsWith('dropcap'),
            );
          } else {
            dropCap.remove();
          }
        } else {
          _removeClassesWhere(
            dropCap,
            (String className) => className.toLowerCase().startsWith('dropcap'),
          );
        }
      } else {
        _removeClassesWhere(
          dropCap,
          (String className) => className.toLowerCase().startsWith('dropcap'),
        );
      }

      if (followingElement != null &&
          _containsCjk(followingElement.text) &&
          !_isInsideFootnoteMarkerAnchor(followingElement) &&
          !_isNonProseElement(followingElement) &&
          followingElement.classes.any(_isInitialSmallCapsClass)) {
        _removeClassesWhere(followingElement, _isInitialSmallCapsClass);
      }
    }
    for (final dom.Element element in fragment.querySelectorAll('[class]')) {
      if (!_isInsideFootnoteMarkerAnchor(element) &&
          !_isNonProseElement(element) &&
          _containsCjk(element.text) &&
          element.classes.any(_isInitialSmallCapsClass)) {
        _removeClassesWhere(element, _isInitialSmallCapsClass);
      }
    }
    return fragment.outerHtml;
  }

  /// Collapse runs of ASCII whitespace in translated text to a single space.
  ///
  /// Models sometimes emit multiple consecutive spaces; renderers collapse
  /// them visually, but the redundant whitespace litters the EPUB source.
  /// `<pre>` content is left untouched, and non-breaking spaces (U+00A0,
  /// e.g. from `&nbsp;`) are preserved — only ASCII whitespace runs are
  /// collapsed.
  String _collapseRedundantWhitespace(String translatedHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(translatedHtml),
    );
    bool changed = false;
    void collapseNode(dom.Node node, bool insidePre) {
      final bool inPre =
          insidePre || (node is dom.Element && node.localName == 'pre');
      if (node is dom.Text) {
        if (!inPre) {
          final String collapsed = node.text.replaceAll(
            RegExp(r'[ \t\n\r\f\v]+'),
            ' ',
          );
          if (collapsed != node.text) {
            node.text = collapsed;
            changed = true;
          }
        }
        return;
      }
      for (final dom.Node child in node.nodes.toList()) {
        collapseNode(child, inPre);
      }
    }

    collapseNode(fragment, false);
    return changed ? fragment.outerHtml : translatedHtml;
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

  bool _isNonProseElement(dom.Element element) {
    return EpubHtmlExtractor.nonTextAncestors.contains(element.localName) ||
        _extractor.isInsideSkippedAncestor(element);
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

  /// The first non-whitespace character immediately following [element]
  /// among its next siblings: whitespace-only text nodes are skipped, then
  /// the first character of the first non-empty text node (or of the first
  /// element's text) is returned. Null when nothing follows — callers must
  /// treat that as "cannot judge" and keep content rather than delete it.
  String? _firstContentCharAfter(dom.Element element) {
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
      if (sibling is dom.Text) {
        final Match? hit = RegExp(r'\S').firstMatch(sibling.data);
        if (hit != null) {
          return hit.group(0);
        }
      } else if (sibling is dom.Element) {
        final Match? hit = RegExp(r'\S').firstMatch(sibling.text);
        if (hit != null) {
          return hit.group(0);
        }
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
  // Matches both `class="…"` and `class='…'` (older EPUBs use single
  // quotes); group 2 is the class value, group 1 the quote character.
  static final RegExp _classAttributePattern = RegExp(
    'class=(["\'])([\\s\\S]*?)\\1',
  );
  static final RegExp _whitespaceRunPattern = RegExp(r'\s+');

  /// True when the HTML carries `toc` as a whole whitespace-separated class
  /// token. A bare prefix test (`class="toc…`) misfires on ordinary
  /// body-text hooks like `class="toc-entry"` / `class="toclevel1"`,
  /// misclassifying a body chapter as a TOC document — its cross-reference
  /// anchor texts would then be rewritten into chapter titles.
  bool _hasTocClassToken(String html) {
    for (final RegExpMatch match in _classAttributePattern.allMatches(html)) {
      if (match.group(2)!.split(_whitespaceRunPattern).contains('toc')) {
        return true;
      }
    }
    return false;
  }

  bool _isTocLikeChapter(InspectedChapter chapter) {
    // A real TOC stylesheet hook is a whole `toc` class token; keep the
    // check token-precise so body-text hooks like `toc-entry` do not hit.
    if (_hasTocClassToken(chapter.originalHtml)) {
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
    List<InspectedChapter> chapters, {
    required String targetLanguage,
    bool bilingual = false,
  }) {
    final labelsByPath = _navigationLabels(chapters);
    final languageTag = _languageTagForTarget(targetLanguage);
    if (labelsByPath.isEmpty) {
      return;
    }
    for (final InspectedChapter chapter in chapters) {
      if (!_isTocLikeChapter(chapter)) {
        continue;
      }
      // TOCs are normally excluded from paid translation. Their labels can
      // still be synchronized from the already translated heading targets.
      final rendered = renderedByPath[chapter.path] ?? chapter.originalHtml;
      final dom.Document document = html_parser.parse(
        XhtmlHtmlCompatibility.normalizeForHtmlParser(rendered),
      );
      // EPUB 3 nav documents are handled from the manifest in the isolate.
      // Applying this legacy heuristic would also overwrite page-list labels.
      if (document.querySelectorAll('nav').any(isEpubTocElement)) {
        continue;
      }
      bool changed = false;
      for (final dom.Element anchor in document.querySelectorAll('a[href]')) {
        if (bilingual &&
            chapter.includeInTranslation &&
            !isTranslatedNavigationAnchor(anchor)) {
          continue;
        }
        final String href = anchor.attributes['href'] ?? '';
        if (href.isEmpty || Uri.tryParse(href)?.hasScheme == true) {
          continue;
        }
        final targetPath = navigationTargetKey(chapter.path, href);
        final String? label = labelsByPath[targetPath];
        if (label == null || anchor.text.trim().isEmpty) {
          continue;
        }
        changed =
            replaceNavigationAnchorLabel(
              anchor,
              label,
              languageTag: languageTag,
            ) ||
            changed;
      }
      if (changed) {
        renderedByPath[chapter.path] =
            XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml);
      }
    }
  }

  /// Test-only: exposes the translated navigation labels
  /// (`chapterPath` / `chapterPath#fragment` → label) so the fragment-id
  /// registration (heading ids, ancestor ids, EPUB2 empty anchors) is
  /// directly covered by regression tests.
  @visibleForTesting
  Map<String, String> debugNavigationLabels(List<InspectedChapter> chapters) =>
      _navigationLabels(chapters);

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
      // The block fragments above lose document context: block splitting
      // keeps only the heading element's own outerHtml, so ancestor ids
      // (`<section id="…"><h1>`) and preceding empty anchors
      // (`<a id="…"></a><h1>`) never appear in the fragment. Keep the
      // source elements from the same extraction (identical order and id
      // scheme) to resolve those against the full chapter document.
      final sourceElements = _extractor.extractTranslatableTextElements(
        originalDocument,
      );
      final elementsById = <String, dom.Element>{};
      for (
        var k = 0;
        k < originalBlocks.length && k < sourceElements.length;
        k++
      ) {
        elementsById[originalBlocks[k].id] = sourceElements[k];
      }
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
          final dom.Element heading = headings[i];
          for (final element in [
            heading,
            ...heading.querySelectorAll('[id], a[name]'),
          ]) {
            final id = element.attributes['id'] ?? element.attributes['name'];
            if (id != null && id.isNotEmpty) labels['$chapterPath#$id'] = label;
          }
          // Ancestor ids address the same location as the heading: EPUB3
          // `<section id="chapter1"><h1>…` with a nav link to
          // `ch1.xhtml#chapter1` must resolve to this heading's label,
          // otherwise the TOC entry stays in the source language. The
          // first heading claims a shared ancestor (putIfAbsent).
          //
          // Resolved against the full chapter document: the block fragment
          // above contains only the heading element itself, so ancestors
          // and preceding siblings are invisible there.
          final dom.Element contextHeading =
              _documentHeadingFor(elementsById[block.id], i) ?? heading;
          dom.Node? ancestor = contextHeading.parent;
          while (ancestor is dom.Element &&
              ancestor.localName != 'body' &&
              ancestor.localName != 'html') {
            final String? ancestorId = ancestor.attributes['id'];
            if (ancestorId != null && ancestorId.isNotEmpty) {
              labels.putIfAbsent('$chapterPath#$ancestorId', () => label);
            }
            ancestor = ancestor.parent;
          }
          // EPUB2-style empty anchors placed immediately before the heading
          // (`<a id="…"></a><h1>…`) mark the same location. Whitespace text
          // and comments between them don't break the run; anything else
          // does (e.g. a footnote anchor belongs to previous content).
          final dom.Node? headingParent = contextHeading.parent;
          if (headingParent is dom.Element) {
            final List<dom.Node> siblings = headingParent.nodes;
            int index = siblings.indexOf(contextHeading);
            while (index > 0) {
              final dom.Node candidate = siblings[index - 1];
              if (candidate is dom.Text || candidate is dom.Comment) {
                if (candidate is dom.Text && candidate.text.trim().isNotEmpty) {
                  break;
                }
                index -= 1;
                continue;
              }
              if (candidate is! dom.Element ||
                  candidate.localName != 'a' ||
                  candidate.text.trim().isNotEmpty) {
                break;
              }
              final String? anchorId =
                  candidate.attributes['id'] ?? candidate.attributes['name'];
              if (anchorId != null && anchorId.isNotEmpty) {
                labels['$chapterPath#$anchorId'] = label;
              }
              index -= 1;
            }
          }
        }
      }
    }
    return labels;
  }

  /// The i-th heading inside a block's source element in the full chapter
  /// document, mirroring the fragment pairing above (same subtree order).
  /// The block element itself can be the heading (block splitting isolates
  /// `<h1>` into its own block), so it is included in the candidates.
  dom.Element? _documentHeadingFor(dom.Element? sourceElement, int index) {
    if (sourceElement == null) return null;
    final List<dom.Element> headings = <dom.Element>[
      if (_isHeadingElement(sourceElement)) sourceElement,
      ...sourceElement.querySelectorAll('h1,h2,h3,h4,h5,h6'),
    ];
    return index < headings.length ? headings[index] : null;
  }

  bool _isHeadingElement(dom.Element element) {
    final String? tag = element.localName;
    return tag != null &&
        tag.length == 2 &&
        tag.codeUnitAt(0) == 0x68 && // 'h'
        tag.codeUnitAt(1) >= 0x31 && // '1'
        tag.codeUnitAt(1) <= 0x36; // '6'
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
