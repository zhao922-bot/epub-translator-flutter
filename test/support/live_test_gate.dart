import 'dart:io';

/// Returns a skip reason unless a live test was explicitly enabled and all
/// required credentials/fixtures are available.
String? liveTestSkipReason({
  bool requireApiKey = true,
  bool requireEpub = true,
}) {
  if (Platform.environment['LIVE_TRANSLATION_E2E'] != '1') {
    return 'Set LIVE_TRANSLATION_E2E=1 to run live API tests.';
  }
  if (requireApiKey &&
      (Platform.environment['LIVE_TRANSLATION_API_KEY'] ?? '').trim().isEmpty) {
    return 'Set LIVE_TRANSLATION_API_KEY to run this live test.';
  }
  if (requireEpub) {
    final String path =
        (Platform.environment['LIVE_TRANSLATION_EPUB_PATH'] ?? '').trim();
    if (path.isEmpty || !File(path).existsSync()) {
      return 'Set LIVE_TRANSLATION_EPUB_PATH to an existing EPUB file.';
    }
  }
  return null;
}
