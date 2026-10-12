import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:html/dom.dart' as dom;

/// Pre-optimization implementation, retained only as an equivalence oracle
/// and benchmark baseline.
class LegacyHtmlExtractor extends EpubHtmlExtractor {
  const LegacyHtmlExtractor();

  @override
  List<dom.Element> extractTranslatableElements(dom.Document document) {
    final body = document.body;
    if (body != null) _wrap(body);
    return document
        .querySelectorAll(EpubHtmlExtractor.translatableTags.join(', '))
        .where(
          (element) =>
              !hasTranslatableAncestor(element) &&
              !isInsideSkippedAncestor(element) &&
              !isStandaloneProtectedMarkerElement(element),
        )
        .toList();
  }

  void _wrap(dom.Element container) {
    if (EpubHtmlExtractor.translatableTags.contains(container.localName) ||
        EpubHtmlExtractor.nonTextAncestors.contains(container.localName)) {
      return;
    }
    const inlineTags = {
      'span',
      'a',
      'em',
      'strong',
      'b',
      'i',
      'u',
      's',
      'small',
      'sub',
      'sup',
      'abbr',
      'cite',
      'q',
      'time',
      'mark',
      'bdi',
      'bdo',
      'ruby',
      'rt',
      'rp',
      'br',
      'wbr',
      'img',
    };
    bool hasUnclaimedText(dom.Node node) {
      if (node is dom.Text) return node.data.trim().isNotEmpty;
      if (node is! dom.Element ||
          EpubHtmlExtractor.translatableTags.contains(node.localName) ||
          EpubHtmlExtractor.nonTextAncestors.contains(node.localName)) {
        return false;
      }
      return node.nodes.any(hasUnclaimedText);
    }

    final run = <dom.Node>[];
    void flush() {
      if (run.any(hasUnclaimedText)) {
        final wrapper = dom.Element.tag('span');
        final index = container.nodes.indexOf(run.first);
        for (final node in run) {
          node.remove();
          wrapper.nodes.add(node);
        }
        container.nodes.insert(index, wrapper);
      }
      run.clear();
    }

    for (final node in container.nodes.toList()) {
      if (node is! dom.Element || inlineTags.contains(node.localName)) {
        run.add(node);
      } else {
        flush();
        _wrap(node);
      }
    }
    flush();
  }
}
