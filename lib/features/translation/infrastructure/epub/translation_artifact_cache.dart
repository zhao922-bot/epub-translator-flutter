import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/models/translation_config.dart';
import '../translation_cache_store.dart';
import '../../../../shared/logging/app_logger.dart';

/// Metadata shares the bounded, atomic, checksummed cache with block HTML.
/// Base64 keeps JSON values distinct from HTML character-reference validation.
class TranslationArtifactCache {
  const TranslationArtifactCache(this.store);
  final TranslationCacheStore store;

  static String key(TranslationConfig config, String kind, Object source) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'translation-artifact-v1',
                kind,
                config.apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
                config.model.trim(),
                config.targetLanguage.trim(),
                config.effectiveReasoningEffort,
                config.maxOutputTokens,
                config.lockedGlossary.trim(),
                source,
              ]),
            ),
          )
          .toString();

  Future<Map<String, dynamic>?> read(String key) async {
    try {
      final raw = await store.getBlockTranslation(key);
      if (raw == null) return null;
      if (!raw.startsWith('{"artifactVersion":1,')) return null;
      final envelope = jsonDecode(raw);
      if (envelope is! Map ||
          envelope['artifactVersion'] != 1 ||
          envelope['payload'] is! String) {
        return null;
      }
      final decoded = jsonDecode(
        utf8.decode(base64Decode(envelope['payload'] as String)),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error) {
      AppLogger.warn(
        'Metadata cache unreadable (${error.runtimeType}); regenerating.',
        tag: 'cache',
      );
      return null;
    }
  }

  Future<void> write(String key, Map<String, dynamic> payload) async {
    try {
      await store.putBlockTranslation(
        key,
        jsonEncode({
          'artifactVersion': 1,
          'payload': base64Encode(utf8.encode(jsonEncode(payload))),
        }),
      );
    } catch (error) {
      AppLogger.warn(
        'Metadata cache write failed (${error.runtimeType}); keeping API result.',
        tag: 'cache',
      );
    }
  }
}
