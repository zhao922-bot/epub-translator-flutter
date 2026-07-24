/// Adapts XHTML syntax that an HTML5 parser would otherwise reinterpret.
///
/// EPUB 2 books commonly use self-closing, non-void elements such as
/// `<a id="page12"/>`. In HTML5 an `a` element is not self-closing, so parsing
/// that source verbatim makes the anchor swallow all following content until
/// another balancing tag happens to close it. Expanding those elements before
/// using package:html preserves their intended empty-marker semantics.
class XhtmlHtmlCompatibility {
  const XhtmlHtmlCompatibility._();

  static const Set<String> _htmlVoidTags = <String>{
    'area',
    'base',
    'br',
    'col',
    'command',
    'embed',
    'hr',
    'img',
    'input',
    'keygen',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };

  static String normalizeForHtmlParser(String source) {
    if (!source.contains('/>')) {
      return source;
    }

    final StringBuffer output = StringBuffer();
    int copyFrom = 0;
    int cursor = 0;
    while (cursor < source.length) {
      if (source.codeUnitAt(cursor) != _lessThan ||
          cursor + 1 >= source.length ||
          !_isAsciiLetter(source.codeUnitAt(cursor + 1))) {
        cursor += 1;
        continue;
      }

      final int nameStart = cursor + 1;
      int nameEnd = nameStart;
      while (nameEnd < source.length &&
          _isQualifiedNameCharacter(source.codeUnitAt(nameEnd))) {
        nameEnd += 1;
      }
      if (nameEnd == nameStart) {
        cursor += 1;
        continue;
      }

      int? quote;
      int tagEnd = nameEnd;
      for (; tagEnd < source.length; tagEnd += 1) {
        final int character = source.codeUnitAt(tagEnd);
        if (quote != null) {
          if (character == quote) {
            quote = null;
          }
          continue;
        }
        if (character == _singleQuote || character == _doubleQuote) {
          quote = character;
          continue;
        }
        if (character == _greaterThan) {
          break;
        }
        if (character == _lessThan) {
          break;
        }
      }
      if (tagEnd >= source.length ||
          source.codeUnitAt(tagEnd) != _greaterThan) {
        cursor += 1;
        continue;
      }

      int slash = tagEnd - 1;
      while (slash > nameEnd && _isWhitespace(source.codeUnitAt(slash))) {
        slash -= 1;
      }
      if (source.codeUnitAt(slash) != _slash) {
        cursor = tagEnd + 1;
        continue;
      }

      final String qualifiedName = source.substring(nameStart, nameEnd);
      final String localName = qualifiedName.split(':').last.toLowerCase();
      if (!_htmlVoidTags.contains(localName)) {
        output
          ..write(source.substring(copyFrom, cursor))
          ..write(source.substring(cursor, slash))
          ..write('></$qualifiedName>');
        copyFrom = tagEnd + 1;
      }
      cursor = tagEnd + 1;
    }
    if (copyFrom == 0) {
      return source;
    }
    output.write(source.substring(copyFrom));
    return output.toString();
  }

  /// Converts package:html output back to XML-compatible XHTML for EPUB.
  ///
  /// HTML serialization emits void elements as `<meta>` / `<br>` and uses the
  /// HTML-only `&nbsp;` named entity. EPUB 2 content documents are XHTML, so
  /// strict readers require `<meta />` / `<br />` and an XML-safe entity.
  static String normalizeForXhtmlOutput(String source) {
    final String xmlEntitySafe = source.replaceAll('&nbsp;', '&#160;');
    final StringBuffer output = StringBuffer();
    int copyFrom = 0;
    int cursor = 0;
    while (cursor < xmlEntitySafe.length) {
      if (xmlEntitySafe.codeUnitAt(cursor) != _lessThan ||
          cursor + 1 >= xmlEntitySafe.length ||
          !_isAsciiLetter(xmlEntitySafe.codeUnitAt(cursor + 1))) {
        cursor += 1;
        continue;
      }

      final int nameStart = cursor + 1;
      int nameEnd = nameStart;
      while (nameEnd < xmlEntitySafe.length &&
          _isQualifiedNameCharacter(xmlEntitySafe.codeUnitAt(nameEnd))) {
        nameEnd += 1;
      }

      int? quote;
      int tagEnd = nameEnd;
      for (; tagEnd < xmlEntitySafe.length; tagEnd += 1) {
        final int character = xmlEntitySafe.codeUnitAt(tagEnd);
        if (quote != null) {
          if (character == quote) {
            quote = null;
          }
          continue;
        }
        if (character == _singleQuote || character == _doubleQuote) {
          quote = character;
          continue;
        }
        if (character == _greaterThan) {
          break;
        }
        if (character == _lessThan) {
          break;
        }
      }
      if (tagEnd >= xmlEntitySafe.length ||
          xmlEntitySafe.codeUnitAt(tagEnd) != _greaterThan) {
        cursor += 1;
        continue;
      }

      final String qualifiedName = xmlEntitySafe.substring(nameStart, nameEnd);
      final String localName = qualifiedName.split(':').last.toLowerCase();
      if (!_htmlVoidTags.contains(localName)) {
        cursor = tagEnd + 1;
        continue;
      }

      int lastContent = tagEnd - 1;
      while (lastContent > nameEnd &&
          _isWhitespace(xmlEntitySafe.codeUnitAt(lastContent))) {
        lastContent -= 1;
      }
      if (xmlEntitySafe.codeUnitAt(lastContent) != _slash) {
        output
          ..write(xmlEntitySafe.substring(copyFrom, tagEnd))
          ..write(' />');
        copyFrom = tagEnd + 1;
      }
      cursor = tagEnd + 1;
    }
    if (copyFrom == 0) {
      return xmlEntitySafe;
    }
    output.write(xmlEntitySafe.substring(copyFrom));
    return output.toString();
  }

  static const int _lessThan = 0x3C;
  static const int _greaterThan = 0x3E;
  static const int _slash = 0x2F;
  static const int _singleQuote = 0x27;
  static const int _doubleQuote = 0x22;

  static bool _isAsciiLetter(int character) {
    return (character >= 0x41 && character <= 0x5A) ||
        (character >= 0x61 && character <= 0x7A);
  }

  static bool _isQualifiedNameCharacter(int character) {
    return _isAsciiLetter(character) ||
        (character >= 0x30 && character <= 0x39) ||
        character == 0x3A ||
        character == 0x2E ||
        character == 0x5F ||
        character == 0x2D;
  }

  static bool _isWhitespace(int character) {
    return character == 0x20 ||
        character == 0x09 ||
        character == 0x0A ||
        character == 0x0D ||
        character == 0x0C;
  }
}
