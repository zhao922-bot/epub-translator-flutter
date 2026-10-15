import 'package:html/dom.dart' as dom;

/// EPUB semantic attributes are identified by namespace, not prefix spelling.
class EpubSemantics {
  const EpubSemantics._();
  static const namespace = 'http://www.idpf.org/2007/ops';

  static String? _binding(dom.Element element, String prefix) {
    dom.Element? current = element;
    while (current != null) {
      final value = current.attributes['xmlns:$prefix'];
      if (value != null) return value;
      current = current.parent;
    }
    return null;
  }

  static Set<String> typesOf(dom.Element element) {
    final types = <String>{};
    for (final entry in element.attributes.entries) {
      final name = entry.key.toString();
      if (!name.endsWith(':type')) continue;
      final prefix = name.substring(0, name.length - 5);
      final binding = _binding(element, prefix);
      // Older books/fragments omit the declaration for conventional epub.
      if (binding != namespace && !(binding == null && prefix == 'epub')) {
        continue;
      }
      types.addAll(
        entry.value
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((token) => token.isNotEmpty),
      );
    }
    return types;
  }

  /// Retain inherited bindings when a paragraph is detached for API/cache
  /// processing. Local descendant declarations continue to override them.
  static String sourceHtmlWithBindings(dom.Element element) {
    return _elementWithBindings(element).outerHtml;
  }

  static dom.Element cloneWithBindings(dom.Element element) =>
      _elementWithBindings(element).clone(true);

  static dom.Element _elementWithBindings(dom.Element element) {
    final inherited = <String, String>{};
    for (final node in [element, ...element.querySelectorAll('*')]) {
      final name = node.localName ?? '';
      final colon = name.indexOf(':');
      if (colon > 0) {
        final prefix = name.substring(0, colon);
        final binding = _binding(element, prefix);
        if (const {
              'http://www.w3.org/2000/svg',
              'http://www.w3.org/1998/Math/MathML',
            }.contains(binding) &&
            !element.attributes.containsKey('xmlns:$prefix')) {
          inherited['xmlns:$prefix'] = binding!;
        }
      }
      for (final name in node.attributes.keys.map((key) => key.toString())) {
        if (name.contains(':') &&
            !name.startsWith('xmlns:') &&
            _binding(element, name.split(':').first) ==
                'http://www.w3.org/1999/xlink' &&
            !element.attributes.containsKey('xmlns:${name.split(':').first}')) {
          inherited['xmlns:${name.split(':').first}'] =
              'http://www.w3.org/1999/xlink';
        }
        if (!name.endsWith(':type')) continue;
        final prefix = name.substring(0, name.length - 5);
        if (_binding(element, prefix) == namespace &&
            !element.attributes.containsKey('xmlns:$prefix')) {
          inherited['xmlns:$prefix'] = namespace;
        }
      }
    }
    if (inherited.isEmpty) return element;
    final clone = element.clone(true)..attributes.addAll(inherited);
    return clone;
  }
}
