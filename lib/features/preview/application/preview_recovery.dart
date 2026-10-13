import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../translation/domain/models/inspected_chapter.dart';
import '../../translation/infrastructure/epub/epub_html_extractor.dart';
import '../../translation/infrastructure/epub/xhtml_html_compatibility.dart';
import '../domain/models/preview_chapter.dart';

bool needsPreviewRecovery(InspectedChapter chapter) =>
    chapter.translatedBody == null && chapter.translatedBlockCount > 0;

/// Synchronous compatibility helper for existing callers. The UI provider
/// uses cached isolate results instead.
PreviewChapter previewChapterFromInspected(InspectedChapter chapter) {
  String source = chapter.body;
  String? translated = chapter.translatedBody;
  if (needsPreviewRecovery(chapter)) {
    source = chapter.originalHtml.isNotEmpty
        ? const EpubHtmlExtractor()
              .inspectChapterBytes(
                chapterPath: chapter.path,
                bytes: utf8.encode(chapter.originalHtml),
              )
              .body
        : chapter.body.isNotEmpty
        ? chapter.body
        : chapter.blocks.take(12).map((b) => b.sourceText).join('\n\n').trim();
    translated = chapter.blocks
        .map((b) => b.translatedHtml)
        .whereType<String>()
        .take(12)
        .map(
          (html) => (XhtmlHtmlCompatibility.parseFragment(html).text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        )
        .where((text) => text.isNotEmpty)
        .join('\n\n');
  }
  return projectPreviewChapter(chapter, source: source, translated: translated);
}

PreviewChapter projectPreviewChapter(
  InspectedChapter chapter, {
  required String source,
  required String? translated,
}) => PreviewChapter(
  title: chapter.title,
  // Limit both recovery joins and already cached excerpts at the shared data
  // projection. Twelve blocks can still be one enormous block; bounding here
  // also protects the provider's direct path without changing the renderer.
  body: EpubHtmlExtractor.limitPreviewText(source),
  translatedBody: translated == null
      ? null
      : EpubHtmlExtractor.limitPreviewText(translated),
  path: chapter.path,
  category: chapter.categoryLabel,
  recommendedForTranslation: chapter.recommendedForTranslation,
  includeInTranslation: chapter.includeInTranslation,
  blockCount: chapter is _PreviewRecoveryPayload
      ? chapter.blockCount
      : chapter.blocks.length,
  translatedBlockCount: chapter.translatedBlockCount,
);

typedef PreviewRecoveryRunner =
    Future<List<PreviewChapter>> Function(List<InspectedChapter> chapters);

/// Keep the runner's existing chapter API, but transfer only recovery fields.
/// Eight times the text budget allows entity/markup overhead, plus parser slack.
const previewRecoveryMarkupLimit =
    EpubHtmlExtractor.previewCharacterLimit * 8 + 4096;

class _PreviewRecoveryPayload extends InspectedChapter {
  /// Parse-free transfer slimming (P-#46). Built on the caller thread
  /// before compute(): drops the per-block source fields the recovery
  /// pipeline never reads and drops blocks without translations, so the
  /// isolate copy no longer grows with the total block count. No DOM
  /// parsing here — that stays inside the isolate (perf-#35); see
  /// [_finishSlimming].
  _PreviewRecoveryPayload(InspectedChapter chapter)
    : blockCount = chapter.blocks.length,
      translatedBlockCount = chapter.translatedBlockCount,
      super(
        path: chapter.path,
        title: chapter.title,
        body: chapter.body,
        originalHtml: chapter.originalHtml,
        blocks: _transferBlocks(chapter),
        category: chapter.category,
        recommendedForTranslation: chapter.recommendedForTranslation,
        includeInTranslation: chapter.includeInTranslation,
      );

  /// Parse-dependent finish, run inside the isolate: bounds the markup and
  /// derives the exact source excerpt ([_slimSourceBody],
  /// [_slimOriginalHtml], [_slimTranslations]).
  _PreviewRecoveryPayload _finishSlimming() => _PreviewRecoveryPayload._slimmed(
    this,
    body: _slimSourceBody(this),
    originalHtml: _slimOriginalHtml(this),
    blocks: _slimTranslations(this),
  );

  _PreviewRecoveryPayload._slimmed(
    _PreviewRecoveryPayload payload, {
    required super.body,
    required super.originalHtml,
    required super.blocks,
  }) : blockCount = payload.blockCount,
       translatedBlockCount = payload.translatedBlockCount,
       super(
         path: payload.path,
         title: payload.title,
         category: payload.category,
         recommendedForTranslation: payload.recommendedForTranslation,
         includeInTranslation: payload.includeInTranslation,
       );

  final int blockCount;
  @override
  final int translatedBlockCount;
}

/// Parse-free block slimming for the transfer payload (P-#46): keeps only
/// the first 12 translated blocks (translatedHtml, parsed in the
/// isolate), with id/tagName/sourceHtml dropped. When originalHtml is empty
/// the source excerpt falls back to the first 12 blocks' sourceText
/// ([_slimSourceBody]), so those blocks and their sourceText are kept —
/// the isolate then derives the identical excerpt.
List<ExtractedBlock> _transferBlocks(InspectedChapter chapter) {
  final blocks = <ExtractedBlock>[];
  var translatedCount = 0;
  for (int i = 0; i < chapter.blocks.length; i++) {
    final block = chapter.blocks[i];
    final bool excerptBlock = chapter.originalHtml.isEmpty && i < 12;
    if (block.translatedHtml == null && !excerptBlock) continue;
    blocks.add(
      block.copyWith(
        id: '',
        tagName: '',
        sourceHtml: '',
        sourceText: excerptBlock ? block.sourceText : '',
      ),
    );
    // Twelve translations necessarily span at least the first twelve source
    // blocks, so the source excerpt is complete when this cap is reached.
    if (block.translatedHtml != null && ++translatedCount == 12) break;
  }
  return blocks;
}

String _excerptMarkup(String text) {
  // Keep overflow evidence for the final ellipsis, even if fragment parsing
  // trims a trailing normalized space. Do not insert an ellipsis per block:
  // joins and surrogate boundaries must be limited only at final projection.
  const limit = EpubHtmlExtractor.previewCharacterLimit + 2;
  final prefix = text.length > limit ? text.substring(0, limit) : text;
  return '<p>${const HtmlEscape().convert(prefix)}</p>';
}

String _slimOriginalHtml(InspectedChapter chapter) {
  if (chapter.originalHtml.length <= previewRecoveryMarkupLimit) {
    return chapter.originalHtml;
  }
  // A raw prefix is not equivalent to inspection: a long head/skipped subtree
  // may precede the body, and truncation can change block selection or entities.
  // For oversized HTML the markup is dropped here and the exact bounded body
  // is derived from the full HTML via _slimSourceBody (inside the isolate);
  // ordinary markup is parsed in compute.
  return '';
}

String _slimSourceBody(InspectedChapter chapter) {
  if (chapter.originalHtml.length > previewRecoveryMarkupLimit) {
    return const EpubHtmlExtractor()
        .inspectChapterBytes(
          chapterPath: chapter.path,
          bytes: utf8.encode(chapter.originalHtml),
        )
        .body;
  }
  return EpubHtmlExtractor.limitPreviewText(
    chapter.originalHtml.isEmpty && chapter.body.isEmpty
        ? chapter.blocks.take(12).map((b) => b.sourceText).join('\n\n').trim()
        : chapter.body,
  );
}

List<ExtractedBlock> _slimTranslations(InspectedChapter chapter) {
  final blocks = <ExtractedBlock>[];
  for (final block in chapter.blocks) {
    final markup = block.translatedHtml;
    if (markup == null) continue;
    final text = (XhtmlHtmlCompatibility.parseFragment(markup).text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) continue;
    blocks.add(
      ExtractedBlock(
        id: '',
        tagName: '',
        sourceHtml: '',
        sourceText: '',
        translatedHtml: markup.length <= previewRecoveryMarkupLimit
            ? markup
            : _excerptMarkup(text),
      ),
    );
    // Defense in depth: _transferBlocks already caps translated blocks at
    // 12 before the isolate copy; keep the original output-based bound here
    // so empty translations never consume a preview slot.
    if (blocks.length == 12) break;
  }
  return blocks;
}

Future<List<PreviewChapter>> _recoverInIsolate(
  List<InspectedChapter> chapters,
) => compute(_recoverBatch, chapters);

// The parse-dependent slimming (DOM parsing for oversized source HTML and
// per-block translated markup) runs inside the isolate — building it on the
// caller (UI) thread before compute() janked on large chapters (perf-#35).
// The caller only applies the parse-free transfer slimming first
// (_PreviewRecoveryPayload), so the isolate copy no longer grows with the
// total block count (P-#46).
List<PreviewChapter> _recoverBatch(List<InspectedChapter> chapters) => chapters
    .map(
      (chapter) => previewChapterFromInspected(
        (chapter is _PreviewRecoveryPayload
                ? chapter
                : _PreviewRecoveryPayload(chapter))
            ._finishSlimming(),
      ),
    )
    .toList();

/// Test-only: the isolate entry point above, callable on the test thread to
/// assert the slim-then-project pipeline without spawning an isolate.
@visibleForTesting
List<PreviewChapter> recoverBatchForTest(List<InspectedChapter> chapters) =>
    _recoverBatch(chapters);

/// One current content version per chapter, scoped to the provider container.
/// Metadata/selection changes reuse excerpts; changed source or translations
/// invalidate them. Pending work is also reused and stale completions cannot
/// overwrite a newer load (or retain an old book).
class PreviewRecoveryCache {
  PreviewRecoveryCache({PreviewRecoveryRunner? runner})
    : _runner = runner ?? _recoverInIsolate;

  final PreviewRecoveryRunner _runner;
  final Map<String, _RecoveryEntry> _entries = {};
  int _generation = 0;

  PreviewChapter? lookup(InspectedChapter chapter) {
    final entry = _entries[chapter.path];
    return entry != null && entry.matches(chapter) ? entry.result : null;
  }

  Future<void> prepare(List<InspectedChapter> chapters) async {
    final generation = ++_generation;
    final paths = chapters.map((c) => c.path).toSet();
    _entries.removeWhere((path, _) => !paths.contains(path));
    final missing = <InspectedChapter>[];
    final newEntries = <_RecoveryEntry>[];
    final pending = <Future<void>>[];
    for (final chapter in chapters) {
      if (!needsPreviewRecovery(chapter)) {
        _entries.remove(chapter.path);
        continue;
      }
      final existing = _entries[chapter.path];
      if (existing != null && existing.matches(chapter)) {
        // Identical pending work is adopted by this generation, preserving reuse.
        existing.generation = generation;
        pending.add(existing.ready);
      } else {
        final entry = _RecoveryEntry(chapter, generation);
        _entries[chapter.path] = entry;
        missing.add(chapter);
        newEntries.add(entry);
      }
    }
    if (missing.isNotEmpty) {
      // P-#46: slim the transfer payload BEFORE compute(): shipping the full
      // chapter object graphs made the isolate copy grow with the total
      // block count (per-block sourceText/sourceHtml). This slimming is
      // parse-free (field drops only); DOM parsing stays inside the isolate
      // (perf-#35).
      final work =
          _runner(<InspectedChapter>[
                for (final chapter in missing) _PreviewRecoveryPayload(chapter),
              ])
              .then((results) {
                for (var i = 0; i < newEntries.length; i++) {
                  final entry = newEntries[i];
                  // compute cannot be cancelled. Logical cancellation drops results
                  // for switched-away content without applying them even to old entries.
                  if (entry.generation == _generation &&
                      identical(_entries[entry.chapter.path], entry)) {
                    entry.result = results[i];
                  }
                }
              })
              .catchError((Object error, StackTrace stack) {
                for (final entry in newEntries) {
                  if (identical(_entries[entry.chapter.path], entry)) {
                    _entries.remove(entry.chapter.path);
                  }
                }
                Error.throwWithStackTrace(error, stack);
              });
      for (final entry in newEntries) {
        entry.ready = work;
      }
      pending.add(work);
    }
    await Future.wait(pending);
  }
}

class _RecoveryEntry {
  _RecoveryEntry(this.chapter, this.generation);
  final InspectedChapter chapter;
  int generation;
  PreviewChapter? result;
  Future<void> ready = Future.value();

  bool matches(InspectedChapter other) {
    if (chapter.originalHtml != other.originalHtml ||
        chapter.body != other.body ||
        chapter.translatedBody != other.translatedBody ||
        chapter.blocks.length != other.blocks.length) {
      return false;
    }
    if (identical(chapter.blocks, other.blocks)) return true;
    for (var i = 0; i < chapter.blocks.length; i++) {
      final a = chapter.blocks[i];
      final b = other.blocks[i];
      if (a.translatedHtml != b.translatedHtml ||
          (other.originalHtml.isEmpty && a.sourceText != b.sourceText)) {
        return false;
      }
    }
    return true;
  }
}
