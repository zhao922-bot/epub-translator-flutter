import 'package:html/dom.dart' as dom;

class InvalidEpubXmlCharacterException extends FormatException {
  const InvalidEpubXmlCharacterException(super.message);
}

bool _isXmlCharacter(int scalar) =>
    scalar == 9 ||
    scalar == 10 ||
    scalar == 13 ||
    (scalar >= 0x20 && scalar <= 0xD7FF) ||
    (scalar >= 0xE000 && scalar <= 0xFFFD) ||
    (scalar >= 0x10000 && scalar <= 0x10FFFF);

/// XML 1.0 Char, checked before HTML parsing or UTF-8 encoding can replace
/// illegal scalars. Error messages contain no source/response contents.
void validateEpubXmlCharacters(String text) {
  for (var i = 0; i < text.length; i++) {
    final scalar = text.codeUnitAt(i);
    // Ordinary ASCII and most CJK text need only these two comparisons.
    if (scalar >= 0x20 && scalar < 0xD800) continue;
    if (scalar >= 0xD800 && scalar <= 0xDBFF && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        // Every well-formed pair represents an XML-legal supplementary scalar.
        i++;
        continue;
      }
    }
    if (_isXmlCharacter(scalar)) continue;
    throw InvalidEpubXmlCharacterException(
      'EPUB XML contains an invalid character U+${scalar.toRadixString(16).toUpperCase()}.',
    );
  }
}

final _references = RegExp(
  r'<!--[\s\S]*?(?:-->|$)|<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|&#(?:[xX]([a-fA-F0-9]+)|([0-9]+));?',
);

void validateEpubXmlMarkup(String markup) {
  validateEpubXmlCharacters(markup);
  if (!markup.contains('&#')) return;
  for (final match in _references.allMatches(markup)) {
    final hex = match.group(1);
    final decimal = match.group(2);
    if (hex == null && decimal == null) continue;
    final scalar = int.tryParse(hex ?? decimal!, radix: hex == null ? 10 : 16);
    if (scalar == null || !_isXmlCharacter(scalar)) {
      throw const InvalidEpubXmlCharacterException(
        'EPUB XML contains an invalid character reference.',
      );
    }
  }
}

/// Includes decoded references in text and attributes, without serializing.
void validateEpubDomXmlCharacters(dom.Node root) {
  final stack = <dom.Node>[root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is dom.Text) validateEpubXmlCharacters(node.data);
    if (node is dom.Element) {
      for (final value in node.attributes.values) {
        validateEpubXmlCharacters(value);
      }
    }
    stack.addAll(node.nodes);
  }
}
