import 'package:path/path.dart' as path;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'xhtml_html_compatibility.dart';

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

/// EPUB 3 navigation is a manifest resource, not necessarily a spine chapter.
/// Only the table of contents is synchronized; page lists and landmarks keep
/// their original labels and links.
String synchronizeEpub3Navigation({
  required String markup,
  required String documentPath,
  required Map<String, String> labelsByPath,
  required String languageTag,
}) {
  final document = html_parser.parse(
    XhtmlHtmlCompatibility.normalizeForHtmlParser(markup),
  );
  var changed = false;
  for (final nav in document.querySelectorAll('nav')) {
    if (!isEpubTocElement(nav)) continue;
    for (final anchor in nav.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      final uri = Uri.tryParse(href);
      if (href.isEmpty || uri == null || uri.hasScheme || uri.hasAuthority) {
        continue;
      }
      final label = labelsByPath[navigationTargetKey(documentPath, href)];
      if (label == null || anchor.text.trim().isEmpty) continue;
      final textNodes = <dom.Text>[];
      void collect(dom.Node node) {
        if (node is dom.Text && node.data.trim().isNotEmpty) {
          textNodes.add(node);
        }
        if (node is dom.Element &&
            !node.classes.contains('pagenum') &&
            node.attributes['role'] != 'doc-pagebreak') {
          for (final child in node.nodes) {
            collect(child);
          }
        }
      }

      collect(anchor);
      if (textNodes.isEmpty) continue;
      textNodes.first.text = label;
      for (final extra in textNodes.skip(1)) {
        extra.remove();
      }
      anchor.attributes['lang'] = languageTag;
      anchor.attributes['xml:lang'] = languageTag;
      changed = true;
    }
  }
  return changed
      ? XhtmlHtmlCompatibility.normalizeForXhtmlOutput(document.outerHtml)
      : markup;
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
