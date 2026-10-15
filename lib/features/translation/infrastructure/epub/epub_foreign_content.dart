import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

const _foreignNamespaces = {
  'http://www.w3.org/2000/svg',
  'http://www.w3.org/1998/Math/MathML',
};
final _foreignRoot = RegExp(
  r'<(?:[A-Za-z][\w.-]*:)?(?:svg|math)(?=[\s/>])',
  caseSensitive: false,
);

/// HTML tokenization lowercases qualified SVG/MathML names and attributes.
/// Restore the source-owned foreign trees from XML before extraction or
/// fragment processing, including XHTML embedded in a foreignObject.
void restoreEpubForeignContent(dom.Node parsed, String source) {
  if (!_foreignRoot.hasMatch(source)) return;
  xml.XmlDocument document;
  try {
    document = xml.XmlDocument.parse(source);
  } on xml.XmlParserException {
    try {
      document = xml.XmlDocument.parse('<epub-wrapper>$source</epub-wrapper>');
    } on xml.XmlParserException {
      // Legacy malformed HTML keeps the existing tolerant parsing behavior.
      return;
    }
  }
  bool foreign(xml.XmlElement e) => _foreignNamespaces.contains(e.namespaceUri);
  final sources = document.descendants
      .whereType<xml.XmlElement>()
      .where(
        (e) =>
            foreign(e) && !e.ancestors.whereType<xml.XmlElement>().any(foreign),
      )
      .toList();
  if (sources.isEmpty) return;
  final candidates = <dom.Element>[];
  final pending = <dom.Node>[parsed];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is dom.Element &&
        const {
          'svg',
          'math',
        }.contains((node.localName ?? '').split(':').last.toLowerCase())) {
      candidates.add(node);
      continue;
    }
    pending.addAll(node.nodes.reversed);
  }
  if (candidates.length != sources.length) {
    throw const FormatException(
      'EPUB foreign-content structure changed during HTML parsing.',
    );
  }
  dom.Node convert(xml.XmlNode node, [int depth = 0]) {
    if (depth > 128) {
      throw const FormatException(
        'EPUB foreign content exceeds the element depth limit.',
      );
    }
    if (node is xml.XmlElement) {
      final element = dom.Document().createElementNS(
        node.namespaceUri,
        node.name.qualified,
      );
      for (final attr in node.attributes) {
        element.attributes[attr.name.qualified] = attr.value;
      }
      element.nodes.addAll(
        node.children.map((child) => convert(child, depth + 1)),
      );
      return element;
    }
    if (node is xml.XmlComment) return dom.Comment(node.value);
    if (node is xml.XmlProcessing) {
      return dom.Comment('?${node.target} ${node.value}?');
    }
    // html's serializer emits unqualified script/style Text without escaping.
    // Keep XML text/CDATA lexemes there so '<' and '&' cannot break XHTML.
    final parent = node.parent;
    if ((node is xml.XmlText || node is xml.XmlCDATA) &&
        parent is xml.XmlElement &&
        parent.name.prefix == null &&
        const {'script', 'style'}.contains(parent.name.local)) {
      return dom.Text(node.toXmlString());
    }
    return dom.Text(node.value ?? '');
  }

  for (var i = 0; i < candidates.length; i++) {
    final old = candidates[i];
    final original = sources[i];
    if ((old.localName ?? '').toLowerCase() !=
        original.name.qualified.toLowerCase()) {
      throw const FormatException(
        'EPUB foreign-content order changed during HTML parsing.',
      );
    }
    final parent = old.parentNode;
    if (parent == null) continue;
    final index = parent.nodes.indexOf(old);
    old.remove();
    parent.nodes.insert(index, convert(original));
  }
}
