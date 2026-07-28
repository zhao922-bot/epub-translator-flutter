import '../domain/models/inspected_chapter.dart';

typedef CacheTranslationReader = Future<String?> Function(String cacheKey);

typedef CacheKeyResolver =
    String Function(InspectedChapter chapter, ExtractedBlock block);

typedef CacheRestorationProgressCallback =
    void Function(CacheRestorationProgress progress);

class CacheRestorationProgress {
  const CacheRestorationProgress({
    required this.scannedBlocks,
    required this.totalBlocks,
    required this.cachedBlocks,
    required this.unreadableBlocks,
  });

  final int scannedBlocks;
  final int totalBlocks;
  final int cachedBlocks;
  final int unreadableBlocks;
}

class CacheRestorationResult {
  const CacheRestorationResult({
    required this.translationsByChapter,
    required this.scannedBlocks,
    required this.cachedBlocks,
    required this.unreadableBlocks,
  });

  final Map<String, Map<String, String>> translationsByChapter;
  final int scannedBlocks;
  final int cachedBlocks;
  final int unreadableBlocks;

  String? translationFor(String chapterPath, String blockId) {
    return translationsByChapter[chapterPath]?[blockId];
  }
}

class CacheRestorationScanner {
  const CacheRestorationScanner({required this.readTranslation});

  final CacheTranslationReader readTranslation;

  Future<CacheRestorationResult> scan({
    required List<InspectedChapter> chapters,
    required CacheKeyResolver cacheKeyFor,
    required void Function() throwIfCancelled,
    CacheRestorationProgressCallback? onProgress,
  }) async {
    final int totalBlocks = chapters.fold<int>(
      0,
      (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
    );
    final Map<String, Map<String, String>> translationsByChapter =
        <String, Map<String, String>>{};
    int scannedBlocks = 0;
    int cachedBlocks = 0;
    int unreadableBlocks = 0;

    for (final InspectedChapter chapter in chapters) {
      for (final ExtractedBlock block in chapter.blocks) {
        throwIfCancelled();
        String? translatedHtml;
        try {
          translatedHtml = await readTranslation(cacheKeyFor(chapter, block));
        } catch (_) {
          unreadableBlocks += 1;
        }
        final String cachedTranslation = translatedHtml?.trim() ?? '';
        if (cachedTranslation.isNotEmpty) {
          translationsByChapter.putIfAbsent(
            chapter.path,
            () => <String, String>{},
          )[block.id] = translatedHtml!;
          cachedBlocks += 1;
        }
        scannedBlocks += 1;
        if (scannedBlocks % 20 == 0 || scannedBlocks == totalBlocks) {
          onProgress?.call(
            CacheRestorationProgress(
              scannedBlocks: scannedBlocks,
              totalBlocks: totalBlocks,
              cachedBlocks: cachedBlocks,
              unreadableBlocks: unreadableBlocks,
            ),
          );
        }
      }
    }

    return CacheRestorationResult(
      translationsByChapter: translationsByChapter,
      scannedBlocks: scannedBlocks,
      cachedBlocks: cachedBlocks,
      unreadableBlocks: unreadableBlocks,
    );
  }
}
