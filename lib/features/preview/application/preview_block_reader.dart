import 'package:flutter/foundation.dart';

import '../../translation/domain/models/inspected_chapter.dart';
import '../../translation/infrastructure/epub/chapter_source_restorer.dart';
import '../../translation/infrastructure/epub/xhtml_html_compatibility.dart';

typedef PreviewBlockText = ({String source, String translation});

class PreviewBlockReader {
  PreviewBlockReader(this.chapter, this._isCancelled);

  final InspectedChapter chapter;
  final bool Function() _isCancelled;
  Future<InspectedChapter?>? _restoredSource;

  Future<PreviewBlockText> read(int index) async {
    final block = chapter.blocks[index];
    final markup = block.translatedHtml ?? '';
    final results = await Future.wait([
      _sourceText(index, block.sourceText),
      _translationText(markup),
    ]);
    return (source: results[0], translation: results[1]);
  }

  Future<String> _translationText(String markup) async =>
      markup.length > 32 * 1024
      ? compute(_plainText, markup)
      : _plainText(markup);

  Future<String> _sourceText(int index, String source) async {
    if (source.isNotEmpty ||
        (chapter.originalHtml.isEmpty && chapter.sourceIdentity == null)) {
      return source;
    }
    final restored = await (_restoredSource ??= _restoreSource());
    return restored?.blocks[index].sourceText ?? '';
  }

  Future<InspectedChapter?> _restoreSource() async {
    try {
      return await ChapterSourceRestorer.restoreChapter(
        chapter: chapter.copyWith(includeInTranslation: true),
        isCancelled: _isCancelled,
      );
    } on Exception {
      // The input archive may have been moved or changed after translation.
      // Keep the translated block available independently of its source.
      return null;
    }
  }
}

String _plainText(String markup) {
  if (markup.isEmpty) return '';
  return (XhtmlHtmlCompatibility.parseFragment(markup).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
