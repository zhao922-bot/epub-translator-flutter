/// A prefix bounded by UTF-16 code units without splitting a surrogate pair.
/// Existing malformed input is retained for the caller's normal validation.
String unicodeSafePrefix(String value, int maxCodeUnits) {
  if (maxCodeUnits <= 0) return '';
  if (value.length <= maxCodeUnits) return value;
  var end = maxCodeUnits;
  final previous = value.codeUnitAt(end - 1);
  final next = value.codeUnitAt(end);
  if (previous >= 0xD800 &&
      previous <= 0xDBFF &&
      next >= 0xDC00 &&
      next <= 0xDFFF) {
    end--;
  }
  return value.substring(0, end);
}
