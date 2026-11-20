/// Canonical base URI used by the Chat Completions transport and its registry.
Uri? normalizedChatApiBaseUri(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  if (uri == null) return null;

  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length >= 2 &&
      segments[segments.length - 2].toLowerCase() == 'chat' &&
      segments[segments.length - 1].toLowerCase() == 'completions') {
    segments.removeRange(segments.length - 2, segments.length);
  }
  // Z.AI's official Chat Completions API uses /api/paas/v4 and the coding
  // plan uses /api/coding/paas/v4. Other custom gateway prefixes keep the
  // application's existing /v1 completion behavior.
  if (uri.scheme == 'https' &&
      uri.host == 'api.z.ai' &&
      uri.port == 443 &&
      const {
        'api/paas/v4',
        'api/coding/paas/v4',
      }.contains(segments.join('/'))) {
    return uri.replace(pathSegments: segments);
  }
  if (segments.isEmpty || segments.last.toLowerCase() != 'v1') {
    segments.add('v1');
  } else {
    segments[segments.length - 1] = 'v1';
  }
  return uri.replace(pathSegments: segments);
}
