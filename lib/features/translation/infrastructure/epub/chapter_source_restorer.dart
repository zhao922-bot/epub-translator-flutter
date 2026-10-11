import 'dart:convert';

import '../../domain/models/inspected_chapter.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';

/// Reconstructs released source strings without parsing on the UI isolate.
class ChapterSourceRestorer {
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
    final restored = await EpubIsolateWorker.prepareWithProgress(
      operation: _operation(pending),
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
          body: _isLegacyPreview(chapter) ? inspected.body : chapter.body,
        ),
      );
      progress(restored.length, chapters.length);
    }
    return restored;
  };
}
