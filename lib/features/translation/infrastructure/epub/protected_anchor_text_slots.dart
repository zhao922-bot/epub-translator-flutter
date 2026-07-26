import 'dart:collection';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// A source-owned HTML skeleton with translatable text slots.
///
/// Protected footnote anchors are never exposed as slots. Rendering clones the
/// source DOM and assigns translations to text nodes, so translated strings are
/// always serialized as text rather than parsed as markup.
class ProtectedAnchorTextSlots {
  ProtectedAnchorTextSlots._(this._sourceRoot, List<String> slotTexts)
    : slotTexts = UnmodifiableListView<String>(slotTexts);

  factory ProtectedAnchorTextSlots.parse(String sourceHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(sourceHtml);
    final List<dom.Node> roots = fragment.nodes
        .where(
          (dom.Node node) => node is! dom.Text || node.data.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (roots.length != 1 || roots.single is! dom.Element) {
      throw const FormatException(
        'ProtectedAnchorTextSlots requires exactly one root element.',
      );
    }

    final dom.Element sourceRoot = roots.single as dom.Element;
    final List<dom.Text> slots = _collectSlots(sourceRoot);
    return ProtectedAnchorTextSlots._(
      sourceRoot,
      slots.map((dom.Text slot) => slot.data).toList(growable: false),
    );
  }

  final dom.Element _sourceRoot;

  /// Source text for each translatable slot in document order.
  final List<String> slotTexts;

  /// Renders translations into a fresh clone of the source DOM.
  ///
  /// The number of translations must exactly match [slotTexts]. Source leading
  /// and trailing whitespace is retained at every slot boundary.
  String render(List<String> translatedSlotTexts) {
    if (translatedSlotTexts.length != slotTexts.length) {
      throw ArgumentError.value(
        translatedSlotTexts.length,
        'translatedSlotTexts.length',
        'Expected ${slotTexts.length} translated slot texts.',
      );
    }

    final dom.Element renderedRoot = _sourceRoot.clone(true);
    final List<dom.Text> renderedSlots = _collectSlots(renderedRoot);
    for (int index = 0; index < renderedSlots.length; index += 1) {
      renderedSlots[index].data = _withSourceBoundaryWhitespace(
        source: slotTexts[index],
        translated: translatedSlotTexts[index],
      );
    }
    return renderedRoot.outerHtml;
  }

  static List<dom.Text> _collectSlots(dom.Node root) {
    final List<dom.Text> slots = <dom.Text>[];
    void visit(dom.Node node, {required bool protected}) {
      if (node is dom.Text) {
        if (!protected && node.data.trim().isNotEmpty) {
          slots.add(node);
        }
        return;
      }
      if (node is! dom.Element) {
        return;
      }

      final bool childProtected =
          protected || _isRawTextElement(node) || _isProtectedAnchor(node);
      for (final dom.Node child in node.nodes) {
        visit(child, protected: childProtected);
      }
    }

    visit(root, protected: false);
    return slots;
  }

  static bool _isProtectedAnchor(dom.Element element) {
    if (element.localName != 'a' || !_isShortMarker(element.text)) {
      return false;
    }

    final Set<String> roles = _tokens(element.attributes['role']);
    final Set<String> epubTypes = _tokens(element.attributes['epub:type']);
    final String id = element.attributes['id']?.toLowerCase() ?? '';
    if (id.startsWith('footnote_ref_') ||
        roles.contains('doc-backlink') ||
        roles.contains('doc-noteref') ||
        epubTypes.contains('noteref')) {
      return true;
    }

    final String href = element.attributes['href'] ?? '';
    return _isCrossFileHref(href) && _containsFootnoteMarkerClass(element);
  }

  static bool _isRawTextElement(dom.Element element) {
    return const <String>{
      'iframe',
      'noembed',
      'noframes',
      'noscript',
      'plaintext',
      'script',
      'style',
      'xmp',
    }.contains(element.localName);
  }

  static Set<String> _tokens(String? value) {
    return (value ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String token) => token.isNotEmpty)
        .toSet();
  }

  static bool _isCrossFileHref(String href) {
    final int fragmentIndex = href.indexOf('#');
    return fragmentIndex > 0 && fragmentIndex < href.length - 1;
  }

  static bool _containsFootnoteMarkerClass(dom.Element anchor) {
    return <dom.Element>[anchor, ...anchor.querySelectorAll('*')].any((
      dom.Element element,
    ) {
      final Set<String> classes = element.classes
          .map((String value) => value.toLowerCase())
          .toSet();
      return classes.contains('footnote_ref') ||
          classes.contains('footnote_num');
    });
  }

  static bool _isShortMarker(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length > 10) {
      return false;
    }
    return RegExp(r'^[0-9]+[.)]?$').hasMatch(compact) ||
        RegExp(r'^[\[({（【].+[\])}）】]$').hasMatch(compact) ||
        RegExp(r'^[*†‡+]+$').hasMatch(compact) ||
        RegExp(r'^[A-Za-z][.)]?$').hasMatch(compact) ||
        RegExp(r'^[ivxlcdmIVXLCDM]+[.)]?$').hasMatch(compact) ||
        RegExp(r'^[⁰¹²³⁴⁵⁶⁷⁸⁹]+$').hasMatch(compact) ||
        RegExp(r'^[零一二三四五六七八九十百]+[.)]?$').hasMatch(compact);
  }

  static String _withSourceBoundaryWhitespace({
    required String source,
    required String translated,
  }) {
    final String leading = RegExp(r'^\s*').firstMatch(source)!.group(0)!;
    final String trailing = RegExp(r'\s*$').firstMatch(source)!.group(0)!;
    return '$leading${translated.trim()}$trailing';
  }
}
