import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart' as xml;

import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';
import 'protected_anchor_text_slots.dart';
import 'xhtml_html_compatibility.dart';

/// Renders translated chapters and writes a new EPUB via isolate ZIP work.
class EpubRepacker {
  EpubRepacker({EpubHtmlExtractor? extractor})
    : _extractor = extractor ?? const EpubHtmlExtractor();

  final EpubHtmlExtractor _extractor;
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
''';

  Map<String, String> renderNavigationMetadataForTest({
    required Map<String, List<int>> archiveFiles,
    required List<InspectedChapter> chapters,
    required String targetLanguage,
  }) {
    return _renderNavigationMetadata(
      archiveFiles: archiveFiles,
      chapters: chapters,
      targetLanguage: targetLanguage,
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
  }) async {
    void throwIfCancelled() {
      if (cancelToken?.isCancelled == true || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
    }

    throwIfCancelled();
    final Map<String, String> translatedHtmlByPath = <String, String>{
      for (final InspectedChapter chapter in chapters)
        if (chapter.includeInTranslation)
          chapter.path: renderTranslatedChapter(
            chapter: chapter,
            bilingual: config.bilingual,
            targetLanguage: config.targetLanguage,
          ),
    };
    _synchronizeHtmlTocLabels(translatedHtmlByPath, chapters);
    final Map<String, List<int>> archiveFiles =
        await EpubIsolateWorker.loadArchiveFiles(inputPath);
    translatedHtmlByPath.addAll(
      _renderNavigationMetadata(
        archiveFiles: archiveFiles,
        chapters: chapters,
        targetLanguage: config.targetLanguage,
      ),
    );
    _validateXmlReplacements(translatedHtmlByPath);
    throwIfCancelled();
    final bool committed = await EpubIsolateWorker.writeTranslatedEpub(
      inputPath: inputPath,
      outputFilePath: outputFilePath,
      translatedHtmlByPath: translatedHtmlByPath,
      // Isolate cannot be hard-interrupted; refuse final commit on cancel.
      shouldCommit: () =>
          !(cancelToken?.isCancelled == true || (isCancelled?.call() ?? false)),
    );
    if (!committed) {
      throw const TranslationCancelledException();
    }
    throwIfCancelled();
  }

  String renderTranslatedChapter({
    required InspectedChapter chapter,
    required bool bilingual,
    String targetLanguage = 'Chinese',
  }) {
    final dom.Document document = html_parser.parse(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(chapter.originalHtml),
    );
    final List<dom.Element> targets = _extractor
        .extractTranslatableTextElements(document);
    final int count = min(targets.length, chapter.blocks.length);
    bool containsCjkTranslation = false;
    for (int index = 0; index < count; index += 1) {
      final dom.Element target = targets[index];
      final ExtractedBlock block = chapter.blocks[index];
      final String translatedHtml = block.translatedHtml?.trim() ?? '';
      if (translatedHtml.isEmpty) {
        continue;
      }
      final String normalizedTranslation = _normalizeCjkInitialTypography(
        translatedHtml,
      );
      containsCjkTranslation =
          containsCjkTranslation || _containsCjk(normalizedTranslation);
      final String replacement = bilingual
          ? '${target.outerHtml}\n${_sanitizeForBilingual(normalizedTranslation)}'
          : normalizedTranslation;
      _replaceNodeWithHtml(target, replacement);
    }
    if (containsCjkTranslation) {
      _applyCjkReadingCompatibility(
        document,
        languageTag: _languageTagForTarget(targetLanguage),
      );
    }
    return XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml);
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
      container: target.parent?.localName ?? 'body',
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

  String _sanitizeForBilingual(String translatedHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(translatedHtml),
    );
    for (final dom.Element element in fragment.querySelectorAll('[id]')) {
      element.attributes.remove('id');
      element.attributes['data-translation'] = 'true';
    }
    return fragment.outerHtml;
  }

  String _normalizeCjkInitialTypography(String translatedHtml) {
    final String parserSafe = XhtmlHtmlCompatibility.normalizeForHtmlParser(
      translatedHtml,
    );
    final dom.DocumentFragment fragment = html_parser.parseFragment(parserSafe);
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

  void _applyCjkReadingCompatibility(
    dom.Document document, {
    required String? languageTag,
  }) {
    final dom.Element? body = document.body;
    if (body == null) {
      return;
    }
    body.classes.add('epub-translator-cjk');
    final dom.Element? root = document.documentElement;
    if (root != null && languageTag != null) {
      root.attributes['lang'] = languageTag;
      root.attributes['xml:lang'] = languageTag;
    }
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

  Map<String, String> _renderNavigationMetadata({
    required Map<String, List<int>> archiveFiles,
    required List<InspectedChapter> chapters,
    required String targetLanguage,
  }) {
    final String? languageTag = _languageTagForTarget(targetLanguage);
    if (languageTag == null) {
      return const <String, String>{};
    }
    final List<int>? containerBytes = archiveFiles['META-INF/container.xml'];
    if (containerBytes == null) {
      return const <String, String>{};
    }
    final xml.XmlDocument container = xml.XmlDocument.parse(
      utf8.decode(containerBytes),
    );
    final xml.XmlElement rootFile = container.descendants
        .whereType<xml.XmlElement>()
        .firstWhere(
          (xml.XmlElement element) => element.name.local == 'rootfile',
          orElse: () => xml.XmlElement(xml.XmlName('missing')),
        );
    final String opfPath = rootFile.getAttribute('full-path') ?? '';
    final List<int>? opfBytes = archiveFiles[opfPath];
    if (opfPath.isEmpty || opfBytes == null) {
      return const <String, String>{};
    }

    final xml.XmlDocument opf = xml.XmlDocument.parse(utf8.decode(opfBytes));
    for (final xml.XmlElement language
        in opf.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'language',
        )) {
      language.innerText = languageTag;
    }

    final Map<String, String> replacements = <String, String>{
      opfPath: opf.toXmlString(),
    };
    final xml.XmlElement? spine = opf.descendants
        .whereType<xml.XmlElement>()
        .where((xml.XmlElement element) => element.name.local == 'spine')
        .firstOrNull;
    final String ncxId = spine?.getAttribute('toc') ?? '';
    xml.XmlElement? ncxItem;
    for (final xml.XmlElement item
        in opf.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'item',
        )) {
      if ((ncxId.isNotEmpty && item.getAttribute('id') == ncxId) ||
          item.getAttribute('media-type') == 'application/x-dtbncx+xml') {
        ncxItem = item;
        break;
      }
    }
    final String ncxHref = ncxItem?.getAttribute('href') ?? '';
    if (ncxHref.isEmpty) {
      return replacements;
    }
    final String ncxPath = path.posix.normalize(
      path.posix.join(path.posix.dirname(opfPath), ncxHref),
    );
    final List<int>? ncxBytes = archiveFiles[ncxPath];
    if (ncxBytes == null) {
      return replacements;
    }

    final Map<String, String> labelsByPath = <String, String>{};
    for (final InspectedChapter chapter in chapters) {
      final String? label = _navigationLabelForChapter(chapter);
      if (label != null) {
        labelsByPath[path.posix.normalize(chapter.path)] = label;
      }
    }
    final xml.XmlDocument ncx = xml.XmlDocument.parse(utf8.decode(ncxBytes));
    ncx.rootElement.setAttribute('xml:lang', languageTag);
    for (final xml.XmlElement navPoint
        in ncx.descendants.whereType<xml.XmlElement>().where(
          (xml.XmlElement element) => element.name.local == 'navPoint',
        )) {
      final xml.XmlElement? content = navPoint.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'content')
          .firstOrNull;
      final String source = content?.getAttribute('src') ?? '';
      if (source.isEmpty) {
        continue;
      }
      final String chapterPath = path.posix.normalize(
        path.posix.join(path.posix.dirname(ncxPath), source.split('#').first),
      );
      final String? label = labelsByPath[chapterPath];
      if (label == null) {
        continue;
      }
      final xml.XmlElement? text = navPoint.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement element) => element.name.local == 'text')
          .firstOrNull;
      if (text != null) {
        text.innerText = label;
      }
    }
    replacements[ncxPath] = ncx.toXmlString();
    return replacements;
  }

  void _synchronizeHtmlTocLabels(
    Map<String, String> renderedByPath,
    List<InspectedChapter> chapters,
  ) {
    final Map<String, String> labelsByPath = <String, String>{
      for (final InspectedChapter chapter in chapters)
        if (_navigationLabelForChapter(chapter) case final String label)
          path.posix.normalize(chapter.path): label,
    };
    if (labelsByPath.isEmpty) {
      return;
    }
    for (final InspectedChapter chapter in chapters) {
      final String token = '${chapter.path} ${chapter.title}'.toLowerCase();
      final bool looksLikeToc =
          token.contains('toc') ||
          token.contains('contents') ||
          chapter.originalHtml.contains('class="toc');
      if (!looksLikeToc) {
        continue;
      }
      final String? rendered = renderedByPath[chapter.path];
      if (rendered == null) {
        continue;
      }
      final dom.Document document = html_parser.parse(rendered);
      bool changed = false;
      for (final dom.Element anchor in document.querySelectorAll('a[href]')) {
        final String href = anchor.attributes['href'] ?? '';
        if (href.isEmpty || Uri.tryParse(href)?.hasScheme == true) {
          continue;
        }
        final String targetPath = path.posix.normalize(
          path.posix.join(
            path.posix.dirname(chapter.path),
            href.split('#').first,
          ),
        );
        final String? label = labelsByPath[targetPath];
        if (label == null || anchor.text.trim().isEmpty) {
          continue;
        }
        anchor.text = label;
        changed = true;
      }
      if (changed) {
        renderedByPath[chapter.path] =
            XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml);
      }
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
      final String extension = path.posix
          .extension(replacement.key)
          .toLowerCase();
      if (extension != '.htm' &&
          extension != '.html' &&
          extension != '.xhtml' &&
          extension != '.opf' &&
          extension != '.ncx' &&
          extension != '.xml') {
        continue;
      }
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
