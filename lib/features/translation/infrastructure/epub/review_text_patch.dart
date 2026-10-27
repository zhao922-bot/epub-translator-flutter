import 'package:html/dom.dart' as dom;
import 'epub_dom.dart';
import 'xhtml_html_compatibility.dart';

/// Apply small, unambiguous text edits without allowing model-generated markup.
/// Attributes, inline formatting and protected content are never edited.
class ReviewTextPatch {
  /// Shared by review text extraction, risk selection and editable segments.
  /// Qualified XHTML names must have the same protection as ordinary names.
  static bool isProtectedElement(dom.Element node) =>
      const {
        'script',
        'style',
        'code',
        'pre',
        'var',
        'kbd',
        'samp',
        'sup',
        'svg',
        'math',
      }.contains(epubLocalName(node)) ||
      node.attributes['translate']?.toLowerCase() == 'no' ||
      node.classes.contains('notranslate');

  static dom.DocumentFragment _parse(String draft) {
    validateEpubMarkupDepth(draft);
    final fragment = XhtmlHtmlCompatibility.parseFragment(draft);
    validateEpubDomDepth(fragment);
    return fragment;
  }

  static List<dom.Text> _editableNodes(dom.Node document) {
    final nodes = <dom.Text>[];
    final stack = <Iterator<dom.Node>>[
      [document].iterator,
    ];
    while (stack.isNotEmpty) {
      if (!stack.last.moveNext()) {
        stack.removeLast();
        continue;
      }
      final node = stack.last.current;
      if (node is dom.Element && isProtectedElement(node)) continue;
      if (node is dom.Text) nodes.add(node);
      if (node.nodes.isNotEmpty) stack.add(node.nodes.iterator);
    }
    return nodes;
  }

  /// Stable request-local node IDs permit repeated words without returning
  /// model-authored HTML. They never address attributes or protected content.
  static List<Map<String, String>> segments(String draft) {
    final nodes = _editableNodes(_parse(draft));
    return [
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i].data.trim().isNotEmpty)
          {'node': 'n$i', 'text': nodes[i].data},
    ];
  }

  static String apply(String draft, List edits) {
    if (edits.isEmpty || edits.length > 24) {
      throw const FormatException('Invalid review edit count.');
    }
    final document = _parse(draft);
    final nodes = _editableNodes(document);
    final changes = <dom.Text, List<({int start, int end, String value})>>{};
    for (final edit in edits) {
      if (edit is! Map ||
          edit['before'] is! String ||
          edit['after'] is! String ||
          (edit['before'] as String).isEmpty) {
        throw const FormatException('Invalid review edit.');
      }
      final before = edit['before'] as String;
      Iterable<dom.Text> scope = nodes;
      if (edit.containsKey('node')) {
        final id = edit['node'];
        if (id is! String || !RegExp(r'^n(?:0|[1-9][0-9]*)$').hasMatch(id)) {
          throw const FormatException('Invalid review node.');
        }
        final index = int.tryParse(id.substring(1));
        if (index == null || index >= nodes.length) {
          throw const FormatException('Missing review node.');
        }
        scope = [nodes[index]];
      }
      final matches = <({dom.Text node, int at})>[];
      for (final node in scope) {
        for (
          var at = node.data.indexOf(before);
          at >= 0;
          at = node.data.indexOf(before, at + 1)
        ) {
          matches.add((node: node, at: at));
        }
      }
      if (matches.length != 1) {
        throw const FormatException('Review edit is missing or ambiguous.');
      }
      final match = matches.single;
      (changes[match.node] ??= []).add((
        start: match.at,
        end: match.at + before.length,
        value: edit['after'] as String,
      ));
    }
    for (final entry in changes.entries) {
      final edits = entry.value..sort((a, b) => a.start.compareTo(b.start));
      for (var i = 1; i < edits.length; i++) {
        if (edits[i].start < edits[i - 1].end) {
          throw const FormatException('Overlapping review edits.');
        }
      }
      var text = entry.key.data;
      for (final edit in edits.reversed) {
        text = text.replaceRange(edit.start, edit.end, edit.value);
      }
      entry.key.data = text;
    }
    return document.outerHtml;
  }
}
