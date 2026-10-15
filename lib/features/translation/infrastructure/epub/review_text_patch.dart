import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// Apply small, unambiguous text edits without allowing model-generated markup.
/// Attributes, inline formatting and protected content are never edited.
class ReviewTextPatch {
  static String apply(String draft, List edits) {
    if (edits.isEmpty || edits.length > 24) {
      throw const FormatException('Invalid review edit count.');
    }
    final document = html.parseFragment(draft);
    final nodes = <dom.Text>[];
    void visit(dom.Node node) {
      if (node is dom.Element &&
          (const {
                'script',
                'style',
                'code',
                'pre',
                'sup',
                'svg',
                'math',
              }.contains(node.localName) ||
              node.attributes['translate']?.toLowerCase() == 'no' ||
              node.classes.contains('notranslate'))) {
        return;
      }
      if (node is dom.Text) nodes.add(node);
      for (final child in node.nodes) {
        visit(child);
      }
    }

    visit(document);
    final changes = <dom.Text, List<({int start, int end, String value})>>{};
    for (final edit in edits) {
      if (edit is! Map ||
          edit['before'] is! String ||
          edit['after'] is! String ||
          (edit['before'] as String).isEmpty) {
        throw const FormatException('Invalid review edit.');
      }
      final before = edit['before'] as String;
      final matches = <({dom.Text node, int at})>[];
      for (final node in nodes) {
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
