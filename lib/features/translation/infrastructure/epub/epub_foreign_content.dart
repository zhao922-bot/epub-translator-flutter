import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;
import 'epub_xml_dom.dart';
import 'epub_xml_names.dart';

const _foreignNamespaces = {
  'http://www.w3.org/2000/svg',
  'http://www.w3.org/1998/Math/MathML',
};
final _foreignRoot = RegExp(
  '<(?:$epubXmlNcName:)?(?:svg|math)(?=[\\s/>])',
  caseSensitive: false,
  unicode: true,
);

/// HTML tokenization lowercases qualified SVG/MathML names and attributes.
/// Restore the source-owned foreign trees from XML before extraction or
/// fragment processing, including XHTML embedded in a foreignObject.
void restoreEpubForeignContent(dom.Node parsed, String source) {
  if (!_foreignRoot.hasMatch(source)) return;
  xml.XmlDocument document;
  try {
    document = xml.XmlDocument.parse(
      source,
      entityMapping: const xml.XmlDefaultEntityMapping.html5(),
    );
  } on xml.XmlParserException {
    try {
      document = xml.XmlDocument.parse(
        '<epub-wrapper>$source</epub-wrapper>',
        entityMapping: const xml.XmlDefaultEntityMapping.html5(),
      );
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
    parent.nodes.insert(
      index,
      epubXmlNodeToHtml(original, inheritNamespaces: true),
    );
  }
}
