import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

dom.Element? epubPrefixedXhtmlRoot(dom.Document document, String markup) {
  if (!markup.contains(':html')) return null;
  final xml.XmlElement sourceRoot;
  try {
    sourceRoot = xml.XmlDocument.parse(markup).rootElement;
  } on xml.XmlParserException {
    return null;
  }
  if (sourceRoot.name.local != 'html' ||
      sourceRoot.name.prefix == null ||
      sourceRoot.namespaceUri != 'http://www.w3.org/1999/xhtml') {
    return null;
  }
  final root = epubElements(document)
      .where(
        (element) =>
            element.localName == sourceRoot.name.qualified.toLowerCase(),
      )
      .firstOrNull;
  if (root == null) {
    throw const FormatException('Generated EPUB markup lost its XHTML root.');
  }
  return root;
}

/// HTML parsers retain XML prefixes in localName. Use the same rules at every
/// EPUB stage, including generated nodes and navigation resources.
String epubLocalName(dom.Element element) {
  final name = element.localName ?? '';
  final colon = name.indexOf(':');
  return (colon < 0 ? name : name.substring(colon + 1)).toLowerCase();
}

String epubQualifiedName(dom.Element context, String tag) {
  final name = context.localName ?? '';
  final colon = name.indexOf(':');
  return colon < 0 ? tag : '${name.substring(0, colon)}:$tag';
}

/// Iterative document-order traversal. The optional cap also bounds work on
/// untrusted trees, without invoking html's recursive selector evaluator.
Iterable<dom.Element> epubElements(dom.Node root, {int? maxDepth}) sync* {
  final stack = <(Iterator<dom.Node>, int)>[(root.nodes.iterator, 1)];
  while (stack.isNotEmpty) {
    final frame = stack.last;
    if (!frame.$1.moveNext()) {
      stack.removeLast();
      continue;
    }
    final node = frame.$1.current;
    if (node is dom.Element) yield node;
    if (node.nodes.isNotEmpty && (maxDepth == null || frame.$2 < maxDepth)) {
      stack.add((node.nodes.iterator, frame.$2 + 1));
    }
  }
}

Iterable<dom.Element> epubTags(dom.Node root, Set<String> tags) => epubElements(
  root,
).where((element) => tags.contains(epubLocalName(element)));

/// Validate an already-built tree before recursive cloning/serialization.
/// Allow the parser-owned html/head/body overhead beyond the markup limit.
void validateEpubDomDepth(dom.Node root, {int maxDepth = 132}) {
  final stack = <(Iterator<dom.Node>, int)>[(root.nodes.iterator, 1)];
  while (stack.isNotEmpty) {
    final frame = stack.last;
    if (!frame.$1.moveNext()) {
      stack.removeLast();
      continue;
    }
    final node = frame.$1.current;
    if (node is! dom.Element) continue;
    if (frame.$2 > maxDepth) {
      throw FormatException(
        'EPUB DOM exceeds the $maxDepth element depth limit.',
      );
    }
    if (node.nodes.isNotEmpty) stack.add((node.nodes.iterator, frame.$2 + 1));
  }
}

/// Quote-aware tokens shared by markup protection and the pre-parser depth
/// guard. Comments and CDATA are single opaque tokens.
final epubMarkupTokens = RegExp(
  r'''<!--[\s\S]*?(?:-->|$)|<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|<(/?)([A-Za-z][\w:.-]*)(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>|<![^>]*>|<\?[^>]*\?>''',
);

void validateEpubMarkupDepth(String markup, {int maxDepth = 128}) {
  const voidTags = {
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };
  final stack = <String>[];
  String? rawTag;
  for (final token in epubMarkupTokens.allMatches(markup)) {
    final tag = token.group(2)?.toLowerCase();
    if (tag == null) continue;
    final closing = token.group(1) == '/';
    if (rawTag != null && !(closing && tag == rawTag)) continue;
    final local = tag.split(':').last;
    if (closing) {
      final index = stack.lastIndexOf(tag);
      if (index >= 0) stack.removeRange(index, stack.length);
      rawTag = null;
    } else if (!voidTags.contains(local) && !token.group(0)!.endsWith('/>')) {
      stack.add(tag);
      if (stack.length > maxDepth) {
        throw FormatException(
          'EPUB markup exceeds the $maxDepth element depth limit.',
        );
      }
      if (local == 'script' || local == 'style') rawTag = tag;
    }
  }
}
