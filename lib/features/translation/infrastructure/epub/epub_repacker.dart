import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub_isolate_worker.dart';
import 'epub_html_extractor.dart';

/// Renders translated chapters and writes a new EPUB via isolate ZIP work.
class EpubRepacker {
  EpubRepacker({EpubHtmlExtractor? extractor})
    : _extractor = extractor ?? const EpubHtmlExtractor();

  final EpubHtmlExtractor _extractor;

  Future<void> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
  }) async {
    void throwIfCancelled() {
      if (cancelToken?.isCancelled == true || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
    }

    throwIfCancelled();
    final Map<String, String> translatedHtmlByPath = <String, String>{
      for (final InspectedChapter chapter in chapters)
        if (chapter.includeInTranslation)
          chapter.path: renderTranslatedChapter(
            chapter: chapter,
            bilingual: config.bilingual,
          ),
    };
    throwIfCancelled();
    final bool committed = await EpubIsolateWorker.writeTranslatedEpub(
      inputPath: inputPath,
      outputFilePath: outputFilePath,
      translatedHtmlByPath: translatedHtmlByPath,
      // Isolate cannot be hard-interrupted; refuse final commit on cancel.
      shouldCommit: () =>
          !(cancelToken?.isCancelled == true || (isCancelled?.call() ?? false)),
    );
    if (!committed) {
      throw const TranslationCancelledException();
    }
    throwIfCancelled();
  }

  String renderTranslatedChapter({
    required InspectedChapter chapter,
    required bool bilingual,
  }) {
    final dom.Document document = html_parser.parse(chapter.originalHtml);
    final List<dom.Element> targets = _extractor
        .extractTranslatableTextElements(document);
    final int count = min(targets.length, chapter.blocks.length);
    for (int index = 0; index < count; index += 1) {
      final dom.Element target = targets[index];
      final ExtractedBlock block = chapter.blocks[index];
      final String translatedHtml = block.translatedHtml?.trim() ?? '';
      if (translatedHtml.isEmpty) {
        continue;
      }
      final String replacement = bilingual
          ? '${target.outerHtml}\n${_sanitizeForBilingual(translatedHtml)}'
          : translatedHtml;
      _replaceNodeWithHtml(target, replacement);
    }
    return document.outerHtml;
  }

  void _replaceNodeWithHtml(dom.Element target, String replacementHtml) {
    final dom.Node? parentNode = target.parentNode;
    if (parentNode == null) {
      return;
    }
    final int index = parentNode.nodes.indexOf(target);
    if (index < 0) {
      return;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      replacementHtml,
      container: target.parent?.localName ?? 'body',
    );
    final List<dom.Node> replacementNodes = fragment.nodes.toList();
    if (replacementNodes.isEmpty) {
      return;
    }
    parentNode.nodes[index] = replacementNodes.first;
    for (int i = 1; i < replacementNodes.length; i += 1) {
      parentNode.nodes.insert(index + i, replacementNodes[i]);
    }
  }

  String _sanitizeForBilingual(String translatedHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      translatedHtml,
    );
    for (final dom.Element element in fragment.querySelectorAll('[id]')) {
      element.attributes.remove('id');
      element.attributes['data-translation'] = 'true';
    }
    return fragment.outerHtml;
  }
}
