import 'package:path/path.dart' as path;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'xhtml_html_compatibility.dart';
import 'epub_semantics.dart';
import 'epub_html_extractor.dart';

bool isEpubTocElement(dom.Element element) {
  for (final attribute in element.attributes.entries) {
    final name = attribute.key.toString();
    if (!name.endsWith(':type')) continue;
    final prefix = name.substring(0, name.length - ':type'.length);
    var isEpub = prefix == 'epub';
    dom.Element? ancestor = element;
    while (ancestor != null) {
      final namespace = ancestor.attributes['xmlns:$prefix'];
      if (namespace != null) {
        isEpub = namespace == 'http://www.idpf.org/2007/ops';
        break;
      }
      ancestor = ancestor.parent;
    }
    if (isEpub && attribute.value.split(RegExp(r'\s+')).contains('toc')) {
      return true;
    }
  }
  return false;
}

/// Both legacy HTML and EPUB 3 TOCs share the same label protection and
/// language rules. Page markers and note references remain source-owned.
bool replaceNavigationAnchorLabel(
  dom.Element anchor,
  String label, {
  String? languageTag,
}) {
  final textNodes = <dom.Text>[];
  void collect(dom.Node node) {
    if (node is dom.Text && node.data.trim().isNotEmpty) textNodes.add(node);
    if (node is! dom.Element) return;
    final types = EpubSemantics.typesOf(node);
    final roles = (node.attributes['role'] ?? '').split(RegExp(r'\s+'));
    if (EpubHtmlExtractor.nonTextAncestors.contains(node.localName) ||
        node.classes.contains('pagenum') ||
        types.any(const {'pagebreak', 'noteref', 'backlink'}.contains) ||
        roles.any(
          const {'doc-pagebreak', 'doc-noteref', 'doc-backlink'}.contains,
        )) {
      return;
    }
    for (final child in node.nodes) {
      collect(child);
    }
  }

  collect(anchor);
  if (textNodes.isEmpty) return false;
  final labelNode = textNodes.first;
  labelNode.text = label;
  if (languageTag != null) {
    // A nested explicit language overrides the anchor's language. Mark the
    // actual text, keeping adjacent page numbers and references unchanged.
    final parent = labelNode.parentNode;
    if (parent is dom.Element && parent.nodes.length == 1) {
      parent.attributes['lang'] = languageTag;
      parent.attributes['xml:lang'] = languageTag;
    } else if (parent != null) {
      final index = parent.nodes.indexOf(labelNode);
      final translatedLabel = dom.Element.tag('span')
        ..attributes['lang'] = languageTag
        ..attributes['xml:lang'] = languageTag;
      labelNode.remove();
      translatedLabel.nodes.add(labelNode);
      parent.nodes.insert(index, translatedLabel);
    }
  }
  for (final extra in textNodes.skip(1)) {
    extra.remove();
  }
  return true;
}

/// EPUB 3 navigation is a manifest resource, not necessarily a spine chapter.
/// Only the table of contents is synchronized; page lists and landmarks keep
/// their original labels and links.
String synchronizeEpub3Navigation({
  required String markup,
  required String documentPath,
  required Map<String, String> labelsByPath,
  required String languageTag,
  bool preserveSourceLabels = false,
}) {
  final document = html_parser.parse(
    XhtmlHtmlCompatibility.normalizeForHtmlParser(markup),
  );
  var changed = false;
  for (final nav in document.querySelectorAll('nav')) {
    if (!isEpubTocElement(nav)) continue;
    for (final anchor in nav.querySelectorAll('a[href]')) {
      if (preserveSourceLabels && !isTranslatedNavigationAnchor(anchor)) {
        continue;
      }
      final href = anchor.attributes['href'] ?? '';
      final uri = Uri.tryParse(href);
      if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
        continue;
      }
      final label = labelsByPath[navigationTargetKey(documentPath, href)];
      if (label == null || anchor.text.trim().isEmpty) continue;
      changed =
          replaceNavigationAnchorLabel(
            anchor,
            label,
            languageTag: languageTag,
          ) ||
          changed;
    }
  }
  return changed
      ? XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml)
      : markup;
}

/// Translation markers live on block ancestors as well as anchors.
bool isTranslatedNavigationAnchor(dom.Element anchor) {
  dom.Element? current = anchor;
  while (current != null) {
    if (current.attributes['data-translation'] == 'true') return true;
    current = current.parent;
  }
  return false;
}

/// Navigation keys retain the section fragment as well as the archive path.
/// Unknown anchors must not fall back to a whole-chapter title.
String navigationTargetKey(String documentPath, String href) {
  final hash = href.indexOf('#');
  final rawPath = (hash < 0 ? href : href.substring(0, hash)).split('?').first;
  final filePath = rawPath.isEmpty
      ? documentPath
      : path.posix.join(path.posix.dirname(documentPath), _decode(rawPath));
  final fragment = hash < 0 ? '' : _decode(href.substring(hash + 1));
  return '${path.posix.normalize(filePath)}${fragment.isEmpty ? '' : '#$fragment'}';
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}
