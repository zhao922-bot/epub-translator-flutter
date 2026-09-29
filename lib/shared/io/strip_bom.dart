/// Strips a single leading UTF-8 BOM (U+FEFF) from [text].
///
/// Windows Notepad saves UTF-8 *with* BOM by default, so a user hand-editing
/// `settings.json` or `job-history.json` in Notepad produces a file starting
/// with U+FEFF — which `jsonDecode` rejects with a `FormatException`. Without
/// stripping, such a file is misclassified as corrupt: settings would be
/// reset to defaults (with a backup), and job history would be wiped
/// silently on the next persist.
String stripLeadingBom(String text) {
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    return text.substring(1);
  }
  return text;
}
