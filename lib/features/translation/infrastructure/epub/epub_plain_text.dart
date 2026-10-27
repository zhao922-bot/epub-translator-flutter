import 'package:html/dom.dart' as dom;

import 'epub_dom.dart';

const epubTextBoundaryTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'td',
  'th',
  'blockquote',
  'dt',
  'dd',
  'figcaption',
  'caption',
  'summary',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'nav',
  'main',
  'aside',
  'figure',
  'table',
  'tr',
  'ul',
  'ol',
  'dl',
  'pre',
  'hr',
};

/// Read structural whitespace without changing the DOM or splitting words
/// across ordinary inline formatting. Each caller owns its protected regions.
String epubPlainText(dom.Node root, {bool Function(dom.Element)? skipElement}) {
  final buffer = StringBuffer();
  final stack = <(Iterator<dom.Node>, bool)>[
    ([root].iterator, false),
  ];
  while (stack.isNotEmpty) {
    final frame = stack.last;
    if (!frame.$1.moveNext()) {
      if (frame.$2) buffer.write(' ');
      stack.removeLast();
      continue;
    }
    final node = frame.$1.current;
    if (node is dom.Text) {
      buffer.write(node.data);
      continue;
    }
    var boundary = false;
    if (node is dom.Element) {
      if (skipElement?.call(node) ?? false) continue;
      final tag = epubLocalName(node);
      if (tag == 'br') {
        buffer.write(' ');
        continue;
      }
      boundary = epubTextBoundaryTags.contains(tag);
    }
    if (boundary) buffer.write(' ');
    stack.add((node.nodes.iterator, boundary));
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
