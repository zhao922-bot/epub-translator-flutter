import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../domain/models/inspected_chapter.dart';
import 'translation_batch_planner.dart';

/// Plans compact API batches for standalone EPUB footnote and endnote files.
///
/// A reference keeps its original [InspectedChapter] and [ExtractedBlock], so
/// callers can write translated HTML back to the correct XHTML file and use
/// the normal chapter-scoped cache key.
class FootnoteBatchPlanner {
  const FootnoteBatchPlanner({
    this.maxReferencesPerBatch = 12,
    this.batchPlanner = const TranslationBatchPlanner(),
  });

  final int maxReferencesPerBatch;
  final TranslationBatchPlanner batchPlanner;

  List<FootnoteTranslationBatch> plan({
    required List<InspectedChapter> chapters,
    required Map<int, List<ExtractedBlock>> pendingBlocksByChapter,
    required int chunkSize,
    Map<String, Object?>? bookMemory,
  }) {
    final int safeChunkSize = max(1, chunkSize);
    final int safeMaxReferences = max(1, maxReferencesPerBatch);
    final List<FootnoteTranslationBatch> batches = <FootnoteTranslationBatch>[];
    List<FootnoteBlockReference> current = <FootnoteBlockReference>[];
    int currentBudget = 0;

    for (
      int chapterIndex = 0;
      chapterIndex < chapters.length;
      chapterIndex += 1
    ) {
      final InspectedChapter chapter = chapters[chapterIndex];
      if (!isStandaloneFootnoteChapter(chapter)) {
        if (current.isNotEmpty) {
          batches.add(_createBatch(current, bookMemory: bookMemory));
          current = <FootnoteBlockReference>[];
          currentBudget = 0;
        }
        continue;
      }

      for (final ExtractedBlock block
          in pendingBlocksByChapter[chapterIndex] ?? const <ExtractedBlock>[]) {
        final int blockBudget = batchPlanner.blockBudgetFor(block);
        final bool exceedsBudget =
            current.isNotEmpty && currentBudget + blockBudget > safeChunkSize;
        final bool reachedReferenceLimit =
            current.isNotEmpty && current.length >= safeMaxReferences;
        if (exceedsBudget || reachedReferenceLimit) {
          batches.add(_createBatch(current, bookMemory: bookMemory));
          current = <FootnoteBlockReference>[];
          currentBudget = 0;
        }

        current.add(
          FootnoteBlockReference(
            chapterIndex: chapterIndex,
            chapter: chapter,
            block: block,
          ),
        );
        currentBudget += blockBudget;
      }
    }

    if (current.isNotEmpty) {
      batches.add(_createBatch(current, bookMemory: bookMemory));
    }
    return List<FootnoteTranslationBatch>.unmodifiable(batches);
  }

  /// Returns whether a chapter is a separate footnote/endnote document.
  static bool isStandaloneFootnoteChapter(InspectedChapter chapter) {
    final String path = chapter.path.toLowerCase();
    final String title = chapter.title.toLowerCase();
    final String filename = path.split('/').last.split('\\').last;
    final bool hasFootnoteFileSuffix = filename.endsWith('-fn.xhtml');
    final bool hasFootnoteFileMarker = RegExp(
      r'(^|[-_.])fn(?:[-_.]|$)',
    ).hasMatch(filename);
    final bool hasFootnotePath = _hasFootnoteWord(path);
    if (hasFootnoteFileSuffix || hasFootnoteFileMarker || hasFootnotePath) {
      return true;
    }
    return _hasFootnoteTitleWord(title) &&
        _hasExplicitFootnoteSemantics(chapter.originalHtml);
  }

  static bool _hasFootnoteWord(String value) {
    const String separators = r'[-_./\\]';
    return RegExp(
      '(^|$separators)(?:footnotes?|endnotes?|notes?)(?=\$|$separators)',
    ).hasMatch(value);
  }

  static bool _hasFootnoteTitleWord(String value) {
    return RegExp(
      r'(^|[^a-z])(?:footnotes?|endnotes?|notes?)(?=$|[^a-z])',
    ).hasMatch(value);
  }

  static bool _hasExplicitFootnoteSemantics(String originalHtml) {
    final dom.Document document = html_parser.parse(originalHtml);
    for (final dom.Element element in document.querySelectorAll('*')) {
      final Set<String> epubTypes = (element.attributes['epub:type'] ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((String value) => value.isNotEmpty)
          .toSet();
      if (epubTypes.contains('footnote') || epubTypes.contains('endnote')) {
        return true;
      }
      final String role = element.attributes['role']?.toLowerCase() ?? '';
      if (role == 'doc-footnote' || role == 'doc-endnote') {
        return true;
      }
    }
    return false;
  }

  FootnoteTranslationBatch _createBatch(
    List<FootnoteBlockReference> references, {
    Map<String, Object?>? bookMemory,
  }) {
    return FootnoteTranslationBatch(
      List<FootnoteBlockReference>.unmodifiable(references),
      context: TranslationBatchContext(
        chapterTitle: '跨文件脚注',
        bookMemory: bookMemory,
      ),
    );
  }
}

/// A uniquely-addressable source block inside a standalone footnote file.
class FootnoteBlockReference {
  const FootnoteBlockReference({
    required this.chapterIndex,
    required this.chapter,
    required this.block,
  });

  final int chapterIndex;
  final InspectedChapter chapter;
  final ExtractedBlock block;

  /// Unique across the EPUB even when multiple XHTML files use `p-1`.
  String get requestId => 'f$chapterIndex:${block.id}';
}

/// A cross-file batch plus stable read-only request context.
class FootnoteTranslationBatch {
  const FootnoteTranslationBatch(this.references, {required this.context});

  final List<FootnoteBlockReference> references;
  final TranslationBatchContext context;
}
