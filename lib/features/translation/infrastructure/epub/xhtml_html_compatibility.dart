import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Adapts XHTML syntax that an HTML5 parser would otherwise reinterpret.
///
/// EPUB 2 books commonly use self-closing, non-void elements such as
/// `<a id="page12"/>`. In HTML5 an `a` element is not self-closing, so parsing
/// that source verbatim makes the anchor swallow all following content until
/// another balancing tag happens to close it. Expanding those elements before
/// using package:html preserves their intended empty-marker semantics.
class XhtmlHtmlCompatibility {
  const XhtmlHtmlCompatibility._();

  /// Table cells and captions disappear in the default body context. Keep
  /// their source-owned wrapper for structure locking and protected slots.
  static dom.DocumentFragment parseFragment(String source) {
    final root = RegExp(
      r'^\s*(?:<!--[\s\S]*?-->\s*)*<(td|th|caption)(?=[\s/>])',
      caseSensitive: false,
    ).firstMatch(source)?.group(1)?.toLowerCase();
    return html_parser.parseFragment(
      normalizeForHtmlParser(source),
      container: root == 'caption'
          ? 'table'
          : root != null
          ? 'tr'
          : 'body',
    );
  }

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
    return _mapMarkup(source, _normalizeHtmlMarkup, cdataAsText: true);
  }

  static String _normalizeHtmlMarkup(String source) {
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
    return _mapMarkup(_repairDoctypeKeywords(source), _normalizeXhtmlMarkup);
  }

  /// `package:html` drops the PUBLIC/SYSTEM keyword when serializing a
  /// doctype that carries identifiers, e.g.
  /// `<!DOCTYPE html "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">`
  /// which is invalid XML (`">" expected` at the first quoted string).
  /// The keyword is recoverable deterministically: two quoted identifiers
  /// with no keyword can only be a PUBLIC doctype, one can only be SYSTEM.
  /// Without this repair, every EPUB whose chapters declare such a doctype
  /// (e.g. Project Gutenberg's XHTML 1.1 books) fails repack validation.
  static String _repairDoctypeKeywords(String source) {
    String repaired = source.replaceFirstMapped(
      RegExp(
        '<!DOCTYPE\\s+([A-Za-z][^\\s>]*)\\s+"([^"]*)"\\s+"([^"]*)"\\s*>',
        caseSensitive: false,
      ),
      (Match m) =>
          '<!DOCTYPE ${m.group(1)} PUBLIC "${m.group(2)}" "${m.group(3)}">',
    );
    repaired = repaired.replaceFirstMapped(
      RegExp(
        '<!DOCTYPE\\s+([A-Za-z][^\\s>]*)\\s+"([^"]*)"\\s*>',
        caseSensitive: false,
      ),
      (Match m) => '<!DOCTYPE ${m.group(1)} SYSTEM "${m.group(2)}">',
    );
    return repaired;
  }

  static String _normalizeXhtmlMarkup(String source) {
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

  /// Only rewrite markup. CDATA, comments, processing instructions and raw
  /// script/style content may contain tag-shaped strings or literal entities.
  static String _mapMarkup(
    String source,
    String Function(String) transform, {
    bool cdataAsText = false,
  }) {
    final output = StringBuffer();
    var start = 0;
    var cursor = 0;
    while (cursor < source.length) {
      if (source.codeUnitAt(cursor) != _lessThan) {
        cursor++;
        continue;
      }
      String? terminator;
      var prefixLength = 0;
      if (source.startsWith('<!--', cursor)) {
        terminator = '-->';
        prefixLength = 4;
      } else if (source.startsWith('<![CDATA[', cursor)) {
        terminator = ']]>';
        prefixLength = 9;
      } else if (source.startsWith('<?', cursor)) {
        terminator = '?>';
        prefixLength = 2;
      }
      if (terminator != null) {
        final end = source.indexOf(terminator, cursor + prefixLength);
        final next = end < 0 ? source.length : end + terminator.length;
        output.write(transform(source.substring(start, cursor)));
        if (cdataAsText && terminator == ']]>' && end >= 0) {
          // HTML treats CDATA in ordinary elements as a bogus comment.
          // Entity encoding preserves its character data in HTML and foreign
          // content alike. Raw script/style regions are skipped below.
          output.write(
            source
                .substring(cursor + prefixLength, end)
                .replaceAll('&', '&amp;')
                .replaceAll('<', '&lt;')
                .replaceAll('>', '&gt;'),
          );
        } else {
          output.write(source.substring(cursor, next));
        }
        start = cursor = next;
        continue;
      }
      final name = _openingTag.matchAsPrefix(source, cursor);
      if (name == null) {
        cursor++;
        continue;
      }
      var end = name.end;
      int? quote;
      for (; end < source.length; end++) {
        final character = source.codeUnitAt(end);
        if (quote != null) {
          if (character == quote) quote = null;
        } else if (character == _singleQuote || character == _doubleQuote) {
          quote = character;
        } else if (character == _greaterThan) {
          break;
        }
      }
      if (end >= source.length) break;
      final tag = name.group(1)!;
      final selfClosing = source
          .substring(cursor, end)
          .trimRight()
          .endsWith('/');
      cursor = end + 1;
      if (!selfClosing &&
          const {
            'script',
            'style',
            'xmp',
            'iframe',
            'noembed',
            'noframes',
          }.contains(tag.toLowerCase())) {
        final closing = RegExp(
          '</${RegExp.escape(tag)}\\s*>',
          caseSensitive: false,
        );
        final next = _rawTextEnd(source, cursor, closing);
        final raw = source.substring(cursor, next);
        output.write(transform(source.substring(start, cursor)));
        if (cdataAsText && closing.hasMatch(raw)) {
          // HTML raw-text parsing ignores XML CDATA/comment boundaries. Hide
          // a literal closing tag until XHTML serialization, using a comment
          // whose base64 body cannot itself close the HTML raw-text element.
          output.write(
            '/*epub-translator-raw-v1:${base64Encode(utf8.encode(raw))}*/',
          );
        } else if (!cdataAsText) {
          output.write(_restoreRawText(raw));
        } else {
          output.write(raw);
        }
        start = cursor = next;
      }
    }
    output.write(transform(source.substring(start)));
    return output.toString();
  }

  static int _rawTextEnd(String source, int start, RegExp closing) {
    var cursor = start;
    while (cursor < source.length) {
      final match = closing.allMatches(source, cursor).firstOrNull;
      final end = match?.start ?? source.length;
      final cdata = source.indexOf('<![CDATA[', cursor);
      final comment = source.indexOf('<!--', cursor);
      final special = cdata < 0
          ? comment
          : comment < 0
          ? cdata
          : cdata < comment
          ? cdata
          : comment;
      if (special < 0 || special >= end) return end;
      final terminator = special == cdata ? ']]>' : '-->';
      final specialEnd = source.indexOf(
        terminator,
        special + (special == cdata ? 9 : 4),
      );
      if (specialEnd < 0) return source.length;
      cursor = specialEnd + terminator.length;
    }
    return source.length;
  }

  static String _restoreRawText(String raw) {
    final match = RegExp(
      r'^/\*epub-translator-raw-v1:([A-Za-z0-9+/=]+)\*/$',
    ).firstMatch(raw);
    if (match == null) return raw;
    try {
      return utf8.decode(base64Decode(match.group(1)!));
    } on FormatException {
      return raw;
    }
  }

  static const int _lessThan = 0x3C;
  static final RegExp _openingTag = RegExp(r'<([A-Za-z][\w:.-]*)(?=[\s/>])');
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
