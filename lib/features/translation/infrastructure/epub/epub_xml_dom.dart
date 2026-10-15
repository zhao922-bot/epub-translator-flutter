import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

final _factory = dom.Document();

/// Preserve XML qualified names rather than sending them through an HTML
/// tokenizer, which lowercases names and rejects some legal initial letters.
dom.Node epubXmlNodeToHtml(
  xml.XmlNode node, {
  int depth = 0,
  bool inheritNamespaces = false,
}) {
  if (depth > 128) {
    throw const FormatException('EPUB XML exceeds the element depth limit.');
  }
  if (node is xml.XmlElement) {
    final element = _factory.createElementNS(
      node.namespaceUri ?? 'http://www.w3.org/1999/xhtml',
      node.name.qualified,
    );
    for (final attribute in node.attributes) {
      element.attributes[attribute.name.qualified] = attribute.value;
    }
    if (inheritNamespaces) {
      // The restored subtree may be detached later. Retain the exact in-scope
      // spelling, taking the nearest declaration before any outer binding.
      for (final ancestor in node.ancestors.whereType<xml.XmlElement>()) {
        for (final attribute in ancestor.attributes) {
          final name = attribute.name.qualified;
          if (name == 'xmlns' || attribute.name.prefix == 'xmlns') {
            element.attributes.putIfAbsent(name, () => attribute.value);
          }
        }
      }
    }
    element.nodes.addAll([
      for (final child in node.children)
        epubXmlNodeToHtml(child, depth: depth + 1),
    ]);
    return element;
  }
  if (node is xml.XmlComment) return dom.Comment(node.value);
  if (node is xml.XmlDoctype) {
    return dom.DocumentType(
      node.name,
      node.externalId?.publicId,
      node.externalId?.systemId,
    );
  }
  if (node is xml.XmlProcessing) {
    return dom.Comment('?${node.target} ${node.value}?');
  }
  if (node is xml.XmlDeclaration) return dom.Comment('?xml ${node.value}?');
  // HTML's unqualified script/style serializer writes raw text. Preserve the
  // XML lexeme there, including CDATA/escapes, so serialization remains XML.
  final parent = node.parent;
  if ((node is xml.XmlText || node is xml.XmlCDATA) &&
      parent is xml.XmlElement &&
      parent.name.prefix == null &&
      const {'script', 'style'}.contains(parent.name.local)) {
    return dom.Text(node.toXmlString());
  }
  return dom.Text(node.value ?? '');
}
