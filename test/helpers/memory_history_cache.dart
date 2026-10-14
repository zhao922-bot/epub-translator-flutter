import 'dart:convert';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';

/// Persistence seam for cache doubles; storage integrity has separate disk
/// tests. Keep their existing save failure injection and state recording.
mixin MemoryHistoryCache on TranslationCacheStore {
  final memoryChunks = <String, String>{};
  @override
  Future<void> saveMemoryCheckpoint(
    JobResumeState state, {
    String? chunkHash,
    String? chunk,
  }) async {
    if (chunkHash != null && chunk != null) memoryChunks[chunkHash] = chunk;
    await saveJobState(state);
  }

  @override
  Future<Map<String, dynamic>> readMemoryChunk(String key, String hash) async =>
      jsonDecode(memoryChunks[hash]!) as Map<String, dynamic>;

  Map<String, dynamic> expandMemoryState(Map<String, dynamic> state) {
    final chunks = <Map<String, dynamic>>[];
    String? head = state['timelineHead'] as String?;
    while (head != null) {
      final chunk = jsonDecode(memoryChunks[head]!) as Map<String, dynamic>;
      chunks.add(chunk);
      head = chunk['previous'] as String?;
    }
    return {
        ...state,
      'schema': (state['schema'] as String).replaceFirst(':memory-history-v1', ''),
        'completedChapterPaths': [
          for (final chunk in chunks.reversed) ...chunk['paths'] as List,
        ],
        'memoryTimeline': [
          for (final chunk in chunks.reversed) ...chunk['entries'] as List,
        ],
      }
      ..remove('timelineHead')
      ..remove('timelineFormat')
      ..remove('timelineLength');
  }
}
