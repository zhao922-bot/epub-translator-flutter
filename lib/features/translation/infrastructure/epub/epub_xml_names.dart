// XML 1.0 (fifth edition) NCName characters. A colon separates the two
// NCNames in a qualified name; it is not itself a prefix/name character.
const epubXmlNameStart =
    r'[A-Z_a-z\u00C0-\u00D6\u00D8-\u00F6'
    r'\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C-\u200D'
    r'\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF'
    r'\uFDF0-\uFFFD\u{10000}-\u{EFFFF}]';
const epubXmlNameCharacter =
    r'[A-Z_a-z0-9.\-\u00B7\u0300-\u036F\u203F-\u2040'
    r'\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D'
    r'\u037F-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF'
    r'\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\u{10000}-\u{EFFFF}]';
const epubXmlNcName = '$epubXmlNameStart$epubXmlNameCharacter*';
const epubXmlQualifiedName = '$epubXmlNcName(?::$epubXmlNcName)?';
