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
  // NUL bytes are not valid in XML 1.0 documents at all and are the
  // hallmark of UTF-16/UTF-32 payloads (every other byte is NUL for ASCII
  // text). Declaration sniffing cannot help here: the declaration itself
  // is unreadable in a 16-bit encoding, so fail loudly instead of
  // producing U+FFFD confetti.
  if (bytes.contains(0)) {
    throw FormatException(
      'Unsupported text encoding in $filePath: the file contains NUL '
      'bytes (likely UTF-16/UTF-32). Only UTF-8 encoded EPUB content is '
      'supported; convert the file to UTF-8 first.',
    );
  }
  final String? declared = _sniffDeclaredEncoding(bytes);
  if (declared != null && !_isUtf8Name(declared)) {
    throw FormatException(
      'Unsupported text encoding "$declared" declared by $filePath: '
      'only UTF-8 encoded EPUB content is supported.',
    );
  }
  late final String decoded;
  try {
    decoded = strict
        ? utf8.decode(bytes)
        : utf8.decode(bytes, allowMalformed: true);
  } on FormatException catch (error) {
    throw FormatException('Invalid UTF-8 in $filePath: ${error.message}');
  }
  if (!strict) {
    _throwIfMostlyUndecodable(decoded, filePath);
  }
  return decoded;
}

/// Heuristic safety net for bytes the declaration sniff cannot see: GBK
/// without a declaration, or a declaration past the 8 KB scan window.
/// Decoding such bytes with `allowMalformed` silently produces U+FFFD runs
/// that would burn paid translation tokens on garbage, so reject loudly
/// when the replacement-character ratio is too high to be stray bytes.
void _throwIfMostlyUndecodable(String decoded, String filePath) {
  int replacements = 0;
  for (int i = 0; i < decoded.length; i++) {
    if (decoded.codeUnitAt(i) == 0xFFFD) {
      replacements++;
    }
  }
  // The ratio clause alone has a blind spot in large files: 200 destroyed
  // chars in a 50k-char chapter is only 0.4%, yet it is a whole paragraph
  // of garbage that would be sent to translation. An absolute count of 100+
  // replacements (about a paragraph of destroyed text) therefore fails
  // loudly regardless of file size, while a few stray bytes in a large
  // file still pass.
  if (replacements >= 8 &&
      (replacements >= 100 || replacements / decoded.length >= 0.01)) {
    throw FormatException(
      'Could not decode $filePath as UTF-8 '
      '($replacements undecodable sequences): the file is probably in a '
      'legacy encoding such as GBK without a charset declaration. Only '
      'UTF-8 encoded EPUB content is supported; convert the file to UTF-8 '
      'first.',
    );
  }
}

bool _isUtf8Name(String declared) {
  final String normalized = declared.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
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
  final String htmlHead = _stripIgnorableMarkup(_asciiHead(bytes, 8192));
  final RegExp metaTagRegex = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
  final RegExp attrRegex = RegExp(
    r'''([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
    caseSensitive: false,
  );
  final RegExp contentCharsetRegex = RegExp(
    '\\bcharset\\s*=\\s*["\']?([A-Za-z0-9._-]+)',
    caseSensitive: false,
  );
  for (final RegExpMatch tagMatch in metaTagRegex.allMatches(htmlHead)) {
    final String tagText = tagMatch.group(0)!;
    String? httpEquiv;
    String? contentValue;
    // Match attributes by NAME, not by a bare `charset=` scan over the tag:
    // a bare scan also fires inside quoted attribute values (e.g.
    // `<meta name="desc" content="see charset=gbk">`), which would sniff the
    // wrong encoding from unrelated text.
    for (final RegExpMatch attr in attrRegex.allMatches(tagText)) {
      final String name = attr.group(1)!.toLowerCase();
      final String raw = attr.group(2)!;
      final String value =
          raw.length >= 2 &&
              ((raw.startsWith('"') && raw.endsWith('"')) ||
                  (raw.startsWith("'") && raw.endsWith("'")))
          ? raw.substring(1, raw.length - 1)
          : raw;
      if (name == 'charset') {
        final String charset = value.trim().split(';').first.trim();
        if (charset.isNotEmpty) {
          return charset;
        }
      } else if (name == 'http-equiv') {
        httpEquiv = value.trim().toLowerCase();
      } else if (name == 'content') {
        contentValue = value;
      }
    }
    // `<meta http-equiv="Content-Type" content="text/html; charset=Big5">`:
    // here the charset lives inside the content VALUE rather than in an
    // attribute name. Only honor it for a content-type http-equiv, so
    // unrelated text like `<meta name="desc" content="see charset=gbk">`
    // is still ignored.
    if (httpEquiv == 'content-type' && contentValue != null) {
      final RegExpMatch? inContent = contentCharsetRegex.firstMatch(
        contentValue,
      );
      if (inContent != null) {
        return inContent.group(1)!;
      }
    }
  }
  return null;
}

/// Removes HTML comments and script/style element *contents* from a scan
/// window before charset sniffing: a `<meta charset="gbk">` inside a
/// comment or a JS string is not a real declaration, and sniffing it would
/// reject a perfectly good UTF-8 book.
String _stripIgnorableMarkup(String head) {
  String stripped = head.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');
  stripped = stripped.replaceAll(
    RegExp(
      r'<script\b[^>]*>.*?</script\s*>',
      caseSensitive: false,
      dotAll: true,
    ),
    ' ',
  );
  stripped = stripped.replaceAll(
    RegExp(r'<style\b[^>]*>.*?</style\s*>', caseSensitive: false, dotAll: true),
    ' ',
  );
  return stripped;
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
