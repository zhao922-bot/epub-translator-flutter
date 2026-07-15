import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;

import '../../domain/models/inspected_chapter.dart';

/// Shared HTML extraction / chapter categorization for inspect + repack.
class EpubHtmlExtractor {
  const EpubHtmlExtractor();

  static const Set<String> translatableTags = <String>{
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'td',
    'th',
    'blockquote',
    'dt',
    'dd',
    'figcaption',
    'caption',
    'summary',
    'span',
  };

  static const Set<String> nonTextAncestors = <String>{
    'script',
    'style',
    'img',
    'svg',
    'math',
    'head',
    'link',
    'meta',
    'pre',
    'code',
    'var',
    'kbd',
    'samp',
  };

  InspectedChapter inspectChapterBytes({
    required String chapterPath,
    required List<int> bytes,
  }) {
    final String decoded = utf8.decode(bytes, allowMalformed: true);
    final dom.Document document = html_parser.parse(decoded);
    final String title =
        document.querySelector('title')?.text.trim().isNotEmpty == true
        ? document.querySelector('title')!.text.trim()
        : document
                  .querySelector('h1, h2, h3')
                  ?.text
                  .trim()
                  .replaceAll(RegExp(r'\s+'), ' ') ??
              path.basenameWithoutExtension(chapterPath);
    final List<ExtractedBlock> blocks = extractBlocks(
      document,
      chapterPath: chapterPath,
    );
    final String bodyText = blocks.isNotEmpty
        ? blocks
              .take(12)
              .map((ExtractedBlock block) => block.sourceText)
              .join('\n\n')
              .trim()
        : (document.body?.text ?? document.documentElement?.text ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

    final ChapterCategory category = categorizeChapter(chapterPath, title);
    final bool recommendedForTranslation =
        category != ChapterCategory.ancillary;

    return InspectedChapter(
      path: chapterPath,
      title: title.isEmpty ? path.basenameWithoutExtension(chapterPath) : title,
      body: bodyText.isEmpty
          ? '(No readable text extracted from this chapter.)'
          : bodyText,
      originalHtml: decoded,
      blocks: blocks,
      category: category,
      recommendedForTranslation: recommendedForTranslation,
      includeInTranslation: recommendedForTranslation,
    );
  }

  List<ExtractedBlock> extractBlocks(
    dom.Document document, {
    required String chapterPath,
  }) {
    final List<ExtractedBlock> blocks = <ExtractedBlock>[];
    int index = 0;
    for (final dom.Element element in extractTranslatableTextElements(
      document,
    )) {
      final String sourceText = elementText(element);
      index += 1;
      blocks.add(
        ExtractedBlock(
          id: '${element.localName ?? 'node'}-$index',
          tagName: element.localName ?? 'node',
          sourceHtml: element.outerHtml,
          sourceText: sourceText,
        ),
      );
    }
    return blocks;
  }

  List<dom.Element> extractTranslatableElements(dom.Document document) {
    return document
        .querySelectorAll(translatableTags.join(', '))
        .where(
          (dom.Element element) =>
              !hasTranslatableAncestor(element) &&
              !isInsideSkippedAncestor(element) &&
              !isStandaloneProtectedMarkerElement(element),
        )
        .toList();
  }

  List<dom.Element> extractTranslatableTextElements(dom.Document document) {
    return extractTranslatableElements(
      document,
    ).where((dom.Element element) => elementText(element).isNotEmpty).toList();
  }

  String elementText(dom.Element element) {
    return element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool hasTranslatableAncestor(dom.Element element) {
    dom.Node? current = element.parent;
    while (current is dom.Element) {
      if (translatableTags.contains(current.localName)) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  bool isInsideSkippedAncestor(dom.Element element) {
    dom.Node? current = element.parent;
    while (current is dom.Element) {
      if (nonTextAncestors.contains(current.localName)) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  bool isStandaloneProtectedMarkerElement(dom.Element element) {
    final String tag = element.localName ?? '';
    if (tag != 'span' && tag != 'a') {
      return false;
    }

    final String role = element.attributes['role']?.toLowerCase() ?? '';
    final Set<String> epubTypes = epubTypesOf(element);
    if (role == 'doc-noteref' || epubTypes.contains('noteref')) {
      return true;
    }
    if (role == 'doc-pagebreak' || epubTypes.contains('pagebreak')) {
      return isProtectedPagebreakText(element.text);
    }

    final String href = element.attributes['href'] ?? '';
    return tag == 'a' &&
        href.startsWith('#') &&
        isProtectedMarkerText(element.text);
  }

  ChapterCategory categorizeChapter(String chapterPath, String title) {
    final String token = '${chapterPath.toLowerCase()} ${title.toLowerCase()}';

    if (_matchesAny(token, const <String>[
      'cover',
      'copyright',
      'credit',
      'signup',
      'advert',
      'ad_',
      'promo',
      'z-lib',
      '1lib',
    ])) {
      return ChapterCategory.ancillary;
    }

    if (_matchesAny(token, const <String>[
      'index',
      'endnote',
      'notes',
      'bibliography',
      'reference',
    ])) {
      return ChapterCategory.reference;
    }

    if (_matchesAny(token, const <String>[
      'ack',
      'acknowledg',
      'authorbio',
      'about the author',
      'epilogue',
      'appendix',
    ])) {
      return ChapterCategory.backMatter;
    }

    if (_matchesAny(token, const <String>[
      'dedication',
      'prologue',
      'foreword',
      'preface',
      'title',
      'contents',
      'introduction',
      'fm0',
      'front',
    ])) {
      return ChapterCategory.frontMatter;
    }

    return ChapterCategory.content;
  }

  Set<String> epubTypesOf(dom.Element element) {
    final String raw =
        element.attributes['epub:type'] ?? element.attributes['type'] ?? '';
    return raw
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String part) => part.isNotEmpty)
        .toSet();
  }

  bool isProtectedPagebreakText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '').trim();
    if (compact.isEmpty || compact.length > 12) {
      return false;
    }
    return RegExp(r'^\d{1,4}[a-zA-Z]?$').hasMatch(compact) ||
        RegExp(r'^[ivxlcdm]+$', caseSensitive: false).hasMatch(compact);
  }

  bool isProtectedMarkerText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '').trim();
    if (compact.isEmpty || compact.length > 10) {
      return false;
    }
    return RegExp(r'^[\[\(（【].+[\]\)）】]$').hasMatch(compact) ||
        RegExp(r'^\d{1,3}$').hasMatch(compact) ||
        RegExp(r'^[a-zA-Z]$').hasMatch(compact);
  }

  bool _matchesAny(String source, List<String> needles) {
    return needles.any(source.contains);
  }
}
