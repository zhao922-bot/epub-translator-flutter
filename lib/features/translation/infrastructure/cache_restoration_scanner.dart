import 'dart:collection';

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

    Iterable<({InspectedChapter chapter, ExtractedBlock block})>
    entries() sync* {
      for (final chapter in chapters) {
        for (final block in chapter.blocks) {
          yield (chapter: chapter, block: block);
        }
      }
    }

    Future<({String? html, bool unreadable})> read(
      InspectedChapter chapter,
      ExtractedBlock block,
    ) async {
      try {
        return (
          html: await readTranslation(cacheKeyFor(chapter, block)),
          unreadable: false,
        );
      } catch (_) {
        return (html: null, unreadable: true);
      }
    }

    final iterator = entries().iterator;
    final pending =
        Queue<
          ({
            InspectedChapter chapter,
            ExtractedBlock block,
            Future<({String? html, bool unreadable})> result,
          })
        >();
    // Sliding prefetch window bounds both disk I/O and retained results.
    // Consume in source order even when the reads finish out of order.
    void fillWindow() {
      while (pending.length < 4) {
        throwIfCancelled();
        if (!iterator.moveNext()) break;
        final entry = iterator.current;
        pending.add((
          chapter: entry.chapter,
          block: entry.block,
          result: read(entry.chapter, entry.block),
        ));
      }
    }

    fillWindow();
    while (pending.isNotEmpty) {
      throwIfCancelled();
      final entry = pending.removeFirst();
      final result = await entry.result;
      throwIfCancelled();
      final chapter = entry.chapter;
      final block = entry.block;
      final translatedHtml = result.html;
      if (result.unreadable) unreadableBlocks += 1;
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
      fillWindow();
    }

    return CacheRestorationResult(
      translationsByChapter: translationsByChapter,
      scannedBlocks: scannedBlocks,
      cachedBlocks: cachedBlocks,
      unreadableBlocks: unreadableBlocks,
    );
  }
}
