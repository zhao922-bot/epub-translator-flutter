import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/localization/app_strings.dart';
import '../../translation/application/translation_dashboard_controller.dart';
import '../../translation/domain/models/inspected_chapter.dart';
import '../../translation/infrastructure/epub/epub_html_extractor.dart';
import '../../translation/infrastructure/epub/xhtml_html_compatibility.dart';
import '../domain/models/preview_chapter.dart';

final previewSelectedIndexProvider = StateProvider<int>((ref) => 0);

final previewChaptersProvider = Provider<List<PreviewChapter>>((ref) {
  // Only the inspected chapters matter here; a plain watch of the whole
  // dashboard state would rebuild the preview on every log tick.
  final chapters = ref.watch(
    translationDashboardProvider.select((s) => s.inspectedChapters),
  );
  if (chapters.isEmpty) {
    // Currently unreachable (the preview page renders strings.noPreviewYet
    // for the empty state), but keep it localized in case the fallback is
    // ever surfaced.
    final AppStrings strings = ref.watch(appStringsProvider);
    return <PreviewChapter>[
      PreviewChapter(
        title: strings.previewFallbackTitle,
        body: strings.noPreviewYet,
        path: '',
        category: strings.previewFallbackCategory,
        recommendedForTranslation: false,
        includeInTranslation: false,
        blockCount: 0,
        translatedBlockCount: 0,
      ),
    ];
  }

  return chapters.map(previewChapterFromInspected).toList();
});

/// Older completed chapters stored the translation in body and released the
/// source block strings. Recover from the immutable source HTML in that case.
PreviewChapter previewChapterFromInspected(InspectedChapter chapter) {
  String source = chapter.body;
  String? translated = chapter.translatedBody;
  if (translated == null && chapter.translatedBlockCount > 0) {
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
  return PreviewChapter(
    title: chapter.title,
    body: source,
    translatedBody: translated,
    path: chapter.path,
    category: chapter.categoryLabel,
    recommendedForTranslation: chapter.recommendedForTranslation,
    includeInTranslation: chapter.includeInTranslation,
    blockCount: chapter.blocks.length,
    translatedBlockCount: chapter.translatedBlockCount,
  );
}
