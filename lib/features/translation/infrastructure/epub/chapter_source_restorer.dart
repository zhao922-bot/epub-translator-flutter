import 'dart:convert';

import '../../domain/models/inspected_chapter.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';
import 'epub_source_guard.dart';

/// Reconstructs released source strings without parsing on the UI isolate.
class ChapterSourceRestorer {
  /// Restore a sampling candidate without retaining sources for other chapters.
  static Future<InspectedChapter> restoreChapter({
    required InspectedChapter chapter,
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
  }) async => (await restore(
    chapters: [chapter],
    isCancelled: isCancelled,
    onProgress: onProgress,
  )).single;

  static Future<List<InspectedChapter>> restore({
    required List<InspectedChapter> chapters,
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
  }) async {
    if (isCancelled()) throw const TranslationCancelledException();
    final pending = <InspectedChapter>[
      for (final chapter in chapters)
        if (chapter.includeInTranslation && _needsSources(chapter)) chapter,
    ];
    if (pending.isEmpty) return chapters;
    // A cancelled/failed run may have released originalHtml from the
    // caller's chapters (e.g. the dashboard drops UI-side sources once the
    // worker spools them). The worker below re-parses from originalHtml,
    // so reload it from the source archive first; without this a retry
    // after cancellation dies with "Source block order changed".
    final withHtml = await _ensureOriginalHtml(pending, isCancelled);
    final restored = await EpubIsolateWorker.prepareWithProgress(
      operation: _operation(withHtml),
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
    if (isCancelled()) throw const TranslationCancelledException();
    final byPath = {for (final chapter in restored) chapter.path: chapter};
    return [for (final chapter in chapters) byPath[chapter.path] ?? chapter];
  }

  static bool _isLegacyPreview(InspectedChapter chapter) =>
      chapter.translatedBody == null && chapter.translatedBlockCount > 0;

  static bool _needsSources(InspectedChapter chapter) =>
      _isLegacyPreview(chapter) ||
      chapter.blocks.any((block) => block.sourceHtml.isEmpty);

  /// Reload original HTML for chapters whose sources were released, grouped
  /// by source archive so each book's zip is opened only once. The archive
  /// fingerprint is verified: a replaced EPUB fails loudly instead of
  /// restoring sources that no longer match the inspected blocks.
  static Future<List<InspectedChapter>> _ensureOriginalHtml(
    List<InspectedChapter> pending,
    bool Function() isCancelled,
  ) async {
    final missing = <InspectedChapter>[
      for (final chapter in pending)
        if (chapter.originalHtml.isEmpty) chapter,
    ];
    if (missing.isEmpty) return pending;
    final groups = <(String, String?), List<InspectedChapter>>{};
    for (final chapter in missing) {
      final identity = chapter.sourceIdentity;
      if (identity == null) {
        throw FormatException(
          'Released chapter has no recoverable source; '
          're-inspect the book: ${chapter.path}',
        );
      }
      final key = (identity.inputPath, identity.sha256);
      (groups[key] ??= <InspectedChapter>[]).add(chapter);
    }
    final reloaded = <String, InspectedChapter>{};
    for (final entry in groups.entries) {
      if (isCancelled()) throw const TranslationCancelledException();
      final wanted = <String>{for (final c in entry.value) c.path};
      final snapshot = await EpubIsolateWorker.loadInspectionSnapshot(
        entry.key.$1,
        selectEntries: (_, _) => wanted,
        isCancelled: isCancelled,
      );
      checkEpubSourceHash(snapshot.fingerprint, entry.key.$2);
      for (final chapter in entry.value) {
        if (isCancelled()) throw const TranslationCancelledException();
        final bytes = snapshot.files[chapter.path];
        if (bytes == null) {
          throw FormatException(
            'Source chapter not found in archive: ${chapter.path}',
          );
        }
        // Lenient decode matches the extractor/decoder convention.
        reloaded[chapter.path] = chapter.copyWith(
          originalHtml: utf8.decode(bytes, allowMalformed: true),
        );
      }
    }
    return [for (final chapter in pending) reloaded[chapter.path] ?? chapter];
  }

  // Build this closure separately so UI callbacks and cancellation tokens do
  // not enter the worker. Only selected chapters needing restoration are sent.
  static List<InspectedChapter> Function(void Function(int, int)) _operation(
    List<InspectedChapter> chapters,
  ) => (progress) {
    final restored = <InspectedChapter>[];
    progress(0, chapters.length);
    for (final chapter in chapters) {
      final inspected = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: chapter.path,
        bytes: utf8.encode(chapter.originalHtml),
      );
      final blocks = inspected.blocks;
      if (blocks.length != chapter.blocks.length) {
        throw FormatException('Source block order changed: ${chapter.path}');
      }
      for (int i = 0; i < blocks.length; i++) {
        if (blocks[i].id != chapter.blocks[i].id ||
            blocks[i].tagName != chapter.blocks[i].tagName ||
            blocks[i].sourceHtml.isEmpty) {
          throw FormatException('Source block order changed: ${chapter.path}');
        }
      }
      restored.add(
        chapter.copyWith(
          blocks: blocks,
          // Legacy previews (translatedBody == null) always need the fresh
          // excerpt, and so does any chapter whose body was released: a
          // completed chapter restored from the archive after a lost spool
          // would otherwise keep an empty body and show a permanently blank
          // source preview.
          body: _isLegacyPreview(chapter) || chapter.body.isEmpty
              ? inspected.body
              : chapter.body,
        ),
      );
      progress(restored.length, chapters.length);
    }
    return restored;
  };
}
