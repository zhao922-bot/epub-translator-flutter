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
        : chapter.blocks.take(12).map((b) => b.sourceText).join('\n\n').trim();
    translated = chapter.blocks
        .map((b) => b.translatedHtml)
        .whereType<String>()
        .map(
          (html) => (XhtmlHtmlCompatibility.parseFragment(html).text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        )
        .where((text) => text.isNotEmpty)
        .take(12)
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
  blockCount: chapter.blocks.length,
  translatedBlockCount: chapter.translatedBlockCount,
);

typedef PreviewRecoveryRunner =
    Future<List<PreviewChapter>> Function(List<InspectedChapter> chapters);

Future<List<PreviewChapter>> _recoverInIsolate(
  List<InspectedChapter> chapters,
) => compute(_recoverBatch, chapters);

List<PreviewChapter> _recoverBatch(List<InspectedChapter> chapters) =>
    chapters.map(previewChapterFromInspected).toList();

/// One current content version per chapter, scoped to the provider container.
/// Metadata/selection changes reuse excerpts; changed source or translations
/// invalidate them. Pending work is also reused and stale completions cannot
/// overwrite a newer load (or retain an old book).
class PreviewRecoveryCache {
  PreviewRecoveryCache({PreviewRecoveryRunner? runner})
    : _runner = runner ?? _recoverInIsolate;

  final PreviewRecoveryRunner _runner;
  final Map<String, _RecoveryEntry> _entries = {};

  /// The error thrown by the most recent failed [prepare], if any. Cleared
  /// when a later [prepare] starts. The UI surfaces it with a retry entry
  /// instead of silently projecting an empty preview.
  Object? get lastError => _lastError;
  Object? _lastError;

  PreviewChapter? lookup(InspectedChapter chapter) {
    final entry = _entries[chapter.path];
    return entry != null && entry.matches(chapter) ? entry.result : null;
  }

  Future<void> prepare(List<InspectedChapter> chapters) async {
    _lastError = null;
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
        pending.add(existing.ready);
      } else {
        final entry = _RecoveryEntry(chapter);
        _entries[chapter.path] = entry;
        missing.add(chapter);
        newEntries.add(entry);
      }
    }
    if (missing.isNotEmpty) {
      final work = _runner(missing)
          .then((results) {
            for (var i = 0; i < newEntries.length; i++) {
              newEntries[i].result = results[i];
            }
          })
          .catchError((Object error, StackTrace stack) {
            for (final entry in newEntries) {
              if (identical(_entries[entry.chapter.path], entry)) {
                _entries.remove(entry.chapter.path);
              }
            }
            // Record before rethrowing: the provider surfaces the failure
            // through its AsyncValue, and the UI shows this error with a
            // retry entry instead of an empty preview.
            _lastError = error;
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
  _RecoveryEntry(this.chapter);
  final InspectedChapter chapter;
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
