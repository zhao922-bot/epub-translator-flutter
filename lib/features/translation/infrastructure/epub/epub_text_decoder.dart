import 'dart:convert';

/// Encoding-aware text decoding for EPUB payloads (chapter HTML and package
/// metadata such as container.xml / OPF / NCX).
///
/// Blindly decoding non-UTF-8 bytes with `allowMalformed: true` turns
/// GBK/Shift-JIS/Big5 chapters into U+FFFD confetti that passes inspection
/// silently and then burns paid translation tokens on garbage. This helper
/// sniffs the declared encoding before decoding, scanning only the
/// ASCII-compatible prefix of the payload: encoding names and markup syntax
/// are pure ASCII, so the scan is safe regardless of the real encoding.
///
/// Sources consulted, in precedence order:
/// - XML prolog: `<?xml ... encoding="..."?>`
/// - `<meta charset="...">`
/// - `<meta http-equiv="Content-Type" content="...; charset=...">`
///
/// Rules:
/// - No declaration, or a UTF-8 declaration (`utf-8` / `utf8`, any case,
///   separators ignored): decode as UTF-8. When [strict] is false (chapter
///   HTML) malformed sequences are replaced, preserving the previous
///   behavior; when true (package metadata) malformed input throws
///   [FormatException] naming the file, because corrupt metadata is more
///   dangerous than a corrupt chapter.
/// - Any other declared encoding: throw [FormatException] naming the file
///   and the declared encoding. Loud failure beats silently translating
///   mojibake, and no charset-decoding dependency is introduced on purpose.
String decodeEpubText({
  required List<int> bytes,
  required String filePath,
  bool strict = false,
}) {
  final String? declared = _sniffDeclaredEncoding(bytes);
  if (declared != null && !_isUtf8Name(declared)) {
    throw FormatException(
      'Unsupported text encoding "$declared" declared by $filePath: '
      'only UTF-8 encoded EPUB content is supported.',
    );
  }
  try {
    return strict
        ? utf8.decode(bytes)
        : utf8.decode(bytes, allowMalformed: true);
  } on FormatException catch (error) {
    throw FormatException('Invalid UTF-8 in $filePath: ${error.message}');
  }
}

bool _isUtf8Name(String declared) {
  final String normalized = declared
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  return normalized == 'utf8';
}

/// XML prologs sit at byte zero, so 2 KB is ample there. HTML meta-charset
/// tags can trail a long head preamble (analytics, stylesheets, preloads),
/// so HTML declarations are scanned in a wider 8 KB window.
String? _sniffDeclaredEncoding(List<int> bytes) {
  final String xmlHead = _asciiHead(bytes, 2048);
  final RegExpMatch? xmlMatch = RegExp(
    '<\\?xml\\b[^>]*?\\bencoding\\s*=\\s*["\']([^"\']+)["\']',
    caseSensitive: false,
  ).firstMatch(xmlHead);
  if (xmlMatch != null) {
    return xmlMatch.group(1)!.trim();
  }
  final String htmlHead = _asciiHead(bytes, 8192);
  for (final RegExpMatch tagMatch
      in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(htmlHead)) {
    final String tagText = tagMatch.group(0)!;
    final bool hasHttpEquiv = RegExp(
      r'\bhttp-equiv\b',
      caseSensitive: false,
    ).hasMatch(tagText);
    if (hasHttpEquiv &&
        !RegExp(
          '\\bhttp-equiv\\s*=\\s*["\']?content-type["\']?',
          caseSensitive: false,
        ).hasMatch(tagText)) {
      continue;
    }
    final RegExpMatch? charsetMatch =
        RegExp(
          '\\bcharset\\s*=\\s*["\']?([A-Za-z0-9_.:\\-;]+)',
          caseSensitive: false,
        ).firstMatch(tagText);
    if (charsetMatch != null) {
      return charsetMatch.group(1)!.trim().split(';').first.trim();
    }
  }
  return null;
}

/// Maps every byte to its ASCII code point, replacing non-ASCII bytes with a
/// space so stray multibyte sequences can never confuse the markup regexes.
String _asciiHead(List<int> bytes, [int maxLength = 2048]) {
  final int length = bytes.length < maxLength ? bytes.length : maxLength;
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < length; i++) {
    final int byte = bytes[i];
    buffer.writeCharCode(byte < 0x80 ? byte : 0x20);
  }
  return buffer.toString();
}
