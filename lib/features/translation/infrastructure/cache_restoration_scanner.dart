import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import '../../../shared/io/atomic_file_writer.dart';

import '../../../shared/logging/app_logger.dart';
import '../../../shared/security/sensitive_text.dart';

import '../domain/models/inspected_chapter.dart';

typedef CacheTranslationReader = Future<String?> Function(String cacheKey);

typedef CacheKeyResolver =
    String Function(InspectedChapter chapter, ExtractedBlock block);

typedef CacheRestorationProgressCallback =
    void Function(CacheRestorationProgress progress);

class CacheReadDiagnostic {
  const CacheReadDiagnostic({required this.error, required this.stackTrace});

  /// Redacted text, not the original exception (which may contain secrets).
  final String error;
  final StackTrace stackTrace;
}

class _CacheReadResult {
  const _CacheReadResult({this.html, this.error, this.stackTrace});

  final String? html;
  final Object? error;
  final StackTrace? stackTrace;
}

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
    required this.lastPendingChapterIndex,
    this.fileSystemFailures = 0,
    this.formatFailures = 0,
    this.firstReadError,
  });

  final Map<String, Map<String, String>> translationsByChapter;
  final int scannedBlocks;
  final int cachedBlocks;
  final int unreadableBlocks;
  final int fileSystemFailures;
  final int formatFailures;
  final CacheReadDiagnostic? firstReadError;

  /// Last cache miss in source order, or -1 for a fully cached run. Chapters
  /// are processed monotonically, so later work is an O(1) comparison.
  final int lastPendingChapterIndex;

  bool hasPendingBlocksFromChapter(int startChapterIndex) =>
      lastPendingChapterIndex >= startChapterIndex;

  String? translationFor(String chapterPath, String blockId) {
    return translationsByChapter[chapterPath]?[blockId];
  }
}

class CacheRestorationScanner {
  const CacheRestorationScanner({
    required this.readTranslation,
    this.configuredApiKey,
    this.onReadError,
  });

  final CacheTranslationReader readTranslation;
  final String? configuredApiKey;
  final void Function(CacheReadDiagnostic)? onReadError;

  String _redact(String text) =>
      SensitiveText.redact(
        text,
        configuredApiKey: configuredApiKey,
      ).replaceAllMapped(
        RegExp(r'(https?://)[^\s/]+@', caseSensitive: false),
        (match) => '${match.group(1)}[redacted]@',
      );

  Future<CacheRestorationResult> scan({
    required List<InspectedChapter> chapters,
    required CacheKeyResolver cacheKeyFor,
    required void Function() throwIfCancelled,
    CacheRestorationProgressCallback? onProgress,
    Future<void> Function(String chapterPath, Map<String, String> translations)?
    persistChapter,
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
    int fileSystemFailures = 0;
    int formatFailures = 0;
    CacheReadDiagnostic? firstReadError;
    int lastPendingChapterIndex = -1;
    String? activeChapter;
    Future<void> flushChapter() async {
      final translations = translationsByChapter[activeChapter];
      if (persistChapter == null || translations == null) return;
      try {
        await persistChapter(activeChapter!, translations);
        translationsByChapter.remove(activeChapter);
      } on FileSystemException {
        // Keep the verified hits in memory when temporary storage is full.
        // Losing them would change progress counts or bill cached work again.
        AppLogger.warn(
          'Cache spool unavailable; retaining verified chapter hits.',
          tag: 'cache-restoration',
        );
      }
    }

    Iterable<
      ({int chapterIndex, InspectedChapter chapter, ExtractedBlock block})
    >
    entries() sync* {
      for (int index = 0; index < chapters.length; index++) {
        final chapter = chapters[index];
        for (final block in chapter.blocks) {
          yield (chapterIndex: index, chapter: chapter, block: block);
        }
      }
    }

    Future<_CacheReadResult> read(String cacheKey) async {
      try {
        return _CacheReadResult(html: await readTranslation(cacheKey));
      } catch (error, stackTrace) {
        // Capture prefetched failures as values to avoid unhandled async errors.
        // Only filesystem/format failures are downgraded when consumed below.
        return _CacheReadResult(error: error, stackTrace: stackTrace);
      }
    }

    final iterator = entries().iterator;
    final pending =
        Queue<
          ({
            int chapterIndex,
            InspectedChapter chapter,
            ExtractedBlock block,
            Future<_CacheReadResult> result,
          })
        >();
    // Sliding prefetch window bounds both disk I/O and retained results.
    // Consume in source order even when the reads finish out of order.
    void fillWindow() {
      while (pending.length < 4) {
        throwIfCancelled();
        if (!iterator.moveNext()) break;
        final entry = iterator.current;
        // Resolver bugs must escape directly, outside the disk-read boundary.
        final cacheKey = cacheKeyFor(entry.chapter, entry.block);
        pending.add((
          chapterIndex: entry.chapterIndex,
          chapter: entry.chapter,
          block: entry.block,
          result: read(cacheKey),
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
      if (chapter.path != activeChapter) {
        await flushChapter();
        activeChapter = chapter.path;
      }
      final block = entry.block;
      final translatedHtml = result.html;
      final error = result.error;
      if (error != null) {
        if (error is FileSystemException) {
          fileSystemFailures += 1;
        } else if (error is FormatException) {
          formatFailures += 1;
        } else {
          Error.throwWithStackTrace(error, result.stackTrace!);
        }
        unreadableBlocks += 1;
        if (firstReadError == null) {
          firstReadError = CacheReadDiagnostic(
            error: _redact(error.toString()),
            stackTrace: StackTrace.fromString(
              _redact(result.stackTrace.toString()),
            ),
          );
          if (onReadError != null) {
            onReadError!(firstReadError);
          } else {
            AppLogger.error(
              'Cache read failed; treating entry as a miss',
              tag: 'cache-restoration',
              error: firstReadError.error,
              stackTrace: firstReadError.stackTrace,
            );
          }
        }
      }
      final String cachedTranslation = translatedHtml?.trim() ?? '';
      if (cachedTranslation.isNotEmpty) {
        translationsByChapter.putIfAbsent(
          chapter.path,
          () => <String, String>{},
        )[block.id] = translatedHtml!;
        cachedBlocks += 1;
      } else {
        lastPendingChapterIndex = entry.chapterIndex;
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

    await flushChapter();
    return CacheRestorationResult(
      translationsByChapter: translationsByChapter,
      scannedBlocks: scannedBlocks,
      cachedBlocks: cachedBlocks,
      unreadableBlocks: unreadableBlocks,
      lastPendingChapterIndex: lastPendingChapterIndex,
      fileSystemFailures: fileSystemFailures,
      formatFailures: formatFailures,
      firstReadError: firstReadError,
    );
  }
}

/// A run-owned snapshot: later eviction of the shared cache cannot invalidate
/// a hit counted during the initial scan. Only the current chapter is loaded.
class CacheRestorationSpool {
  Directory? _directory;
  final Set<String> _chapters = {};

  Future<File> _file(String chapter) async {
    _directory ??= await Directory.systemTemp.createTemp(
      'epub-cache-snapshot-',
    );
    return File(
      path.join(
        _directory!.path,
        '${sha256.convert(utf8.encode(chapter))}.json',
      ),
    );
  }

  Future<void> save(String chapter, Map<String, String> translations) async {
    await writeFileAtomically(await _file(chapter), jsonEncode(translations));
    _chapters.add(chapter);
  }

  Future<void> loadChapter(
    CacheRestorationResult result,
    String chapter,
  ) async {
    if (!_chapters.contains(chapter)) return;
    final file = await _file(chapter);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    result.translationsByChapter[chapter] = json.cast<String, String>();
    _chapters.remove(chapter);
    try {
      await file.delete();
    } on FileSystemException {
      // The verified snapshot is already in memory; cleanup can be retried
      // when the run-owned directory is disposed.
    }
  }

  Future<void> dispose() async {
    final directory = _directory;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        AppLogger.warn(
          'Cache snapshot cleanup deferred.',
          tag: 'cache-restoration',
        );
      }
    }
  }
}
