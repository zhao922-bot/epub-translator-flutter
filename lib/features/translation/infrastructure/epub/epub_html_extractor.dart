import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;

import '../../domain/models/inspected_chapter.dart';
import 'xhtml_html_compatibility.dart';

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
    'a',
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
    final dom.Document document = html_parser.parse(
      XhtmlHtmlCompatibility.normalizeForHtmlParser(decoded),
    );
    final String title =
        document.querySelector('title')?.text.trim().isNotEmpty == true
        ? document.querySelector('title')!.text.trim()
        : document
                  .querySelector('h1, h2, h3')
                  ?.text
                  .trim()
                  .replaceAll(RegExp(r'\s+'), ' ') ??
              path.basenameWithoutExtension(chapterPath);
    final ChapterCategory category = categorizeChapter(chapterPath, title);
    final List<ExtractedBlock> blocks = extractBlocks(
      document,
      chapterPath: chapterPath,
      detectAuthorSignatures: category == ChapterCategory.frontMatter,
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

    final bool recommendedForTranslation =
        blocks.isNotEmpty && category != ChapterCategory.ancillary;

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
    bool detectAuthorSignatures = false,
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
          isAuthorSignature:
              detectAuthorSignatures && _isAuthorSignatureElement(element),
        ),
      );
    }
    return blocks;
  }

  bool _isAuthorSignatureElement(dom.Element element) {
    if (element.localName != 'p' ||
        element.children.isNotEmpty ||
        !_hasSignatureClass(element) ||
        !_looksLikePersonName(elementText(element))) {
      return false;
    }
    final dom.Element? parent = element.parent;
    if (parent == null || !_isSemanticPrefaceContainer(parent)) {
      return false;
    }
    final List<dom.Element> visibleSiblings = parent.children
        .where((dom.Element sibling) => elementText(sibling).isNotEmpty)
        .toList(growable: false);
    final int candidateIndex = visibleSiblings.indexOf(element);
    if (candidateIndex <= 0) {
      return false;
    }

    final List<dom.Element> signatureRun = visibleSiblings
        .skip(candidateIndex)
        .toList(growable: false);
    final Set<String> sharedSignatureClasses = _signatureClassTokens(
      signatureRun.first,
    );
    for (final dom.Element sibling in signatureRun.skip(1)) {
      sharedSignatureClasses.retainAll(_signatureClassTokens(sibling));
    }
    if (signatureRun.length != 3 ||
        signatureRun.any(
          (dom.Element sibling) =>
              sibling.localName != 'p' || !_hasSignatureClass(sibling),
        ) ||
        sharedSignatureClasses.isEmpty ||
        !_looksLikeSignatureDate(elementText(signatureRun[1])) ||
        !_looksLikeSignatureLocation(elementText(signatureRun[2]))) {
      return false;
    }

    final dom.Element previous = visibleSiblings[candidateIndex - 1];
    return !_hasSignatureClass(previous) &&
        _looksLikeSubstantiveProse(elementText(previous));
  }

  bool _hasSignatureClass(dom.Element element) {
    return _signatureClassTokens(element).isNotEmpty;
  }

  Set<String> _signatureClassTokens(dom.Element element) {
    const Set<String> classes = <String>{
      'author-signature',
      'sig',
      'signature',
    };
    return element.classes
        .map((String token) => token.toLowerCase())
        .where(classes.contains)
        .toSet();
  }

  bool _isSemanticPrefaceContainer(dom.Element element) {
    final List<String> epubTypes = (element.attributes['epub:type'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'));
    final List<String> roles = (element.attributes['role'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'));
    return epubTypes.contains('preface') || roles.contains('doc-preface');
  }

  bool _looksLikeSignatureDate(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return RegExp(
      r'^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?[,]?\s+(?:18|19|20)\d{2}$',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  bool _looksLikeSignatureLocation(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty || normalized.length > 80) {
      return false;
    }
    if (!RegExp(
      r"^[A-Za-z][A-Za-z'’\-]*(?:\s+[A-Za-z][A-Za-z'’\-]*){0,5}$",
    ).hasMatch(normalized)) {
      return false;
    }
    const Set<String> locationParticles = <String>{
      'de',
      'del',
      'di',
      'du',
      'la',
      'of',
    };
    final List<String> words = normalized.split(' ');
    return words.length <= 4 &&
        words.every((String word) {
          if (locationParticles.contains(word.toLowerCase())) {
            return true;
          }
          final String first = word.substring(0, 1);
          return first == first.toUpperCase() && first != first.toLowerCase();
        });
  }

  bool _looksLikeSubstantiveProse(String text) {
    final int wordCount = RegExp(
      r"[A-Za-z][A-Za-z'’\-]*",
    ).allMatches(text).length;
    return wordCount >= 8 &&
        RegExp(r'[.!?][\"”’\)]?\s*$').hasMatch(text.trim());
  }

  bool _looksLikePersonName(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(
      r"^[A-Za-z][A-Za-z'’\-]*(?:\s+[A-Za-z][A-Za-z'’\-]*){1,5}$",
    ).hasMatch(normalized)) {
      return false;
    }
    if (!_isHighConfidencePersonName(normalized)) {
      return false;
    }
    final List<String> words = RegExp(r"[A-Za-z][A-Za-z'’\-]*")
        .allMatches(normalized)
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    if (words.length < 2 || words.length > 6) {
      return false;
    }
    const Set<String> particles = <String>{
      'da',
      'de',
      'del',
      'der',
      'di',
      'dos',
      'du',
      'la',
      'le',
      'van',
      'von',
    };
    return words.every((String word) {
      if (particles.contains(word.toLowerCase())) {
        return true;
      }
      final String first = word.substring(0, 1);
      return first == first.toUpperCase() && first != first.toLowerCase();
    });
  }

  bool _isHighConfidencePersonName(String text) {
    final List<String> words = RegExp(
      r"[A-Za-z][A-Za-z'’\-]*",
    ).allMatches(text).map((RegExpMatch match) => match.group(0)!).toList();
    if (words.length < 2 || words.length > 6) {
      return false;
    }

    // This list is intentionally a conservative positive gate, not a general
    // name database. Unknown signatures simply take the normal translation
    // path; false negatives cost one translated name, while false positives
    // can silently preserve an untranslated title or location.
    const Set<String> commonGivenNames = <String>{
      'alexander',
      'andrew',
      'anthony',
      'benjamin',
      'charles',
      'christopher',
      'daniel',
      'david',
      'donald',
      'edward',
      'elizabeth',
      'emily',
      'emma',
      'francis',
      'george',
      'henry',
      'isabella',
      'jack',
      'james',
      'jane',
      'jennifer',
      'john',
      'joseph',
      'katherine',
      'laura',
      'linda',
      'margaret',
      'maria',
      'mark',
      'mary',
      'matthew',
      'michael',
      'nicholas',
      'olivia',
      'paul',
      'peter',
      'philip',
      'richard',
      'robert',
      'sarah',
      'stephen',
      'susan',
      'thomas',
      'william',
    };
    return commonGivenNames.contains(words.first.toLowerCase());
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
      '_cvi_',
      '_cop_',
    ])) {
      return ChapterCategory.ancillary;
    }

    if (_matchesAny(token, const <String>[
      'index',
      'endnote',
      'notes',
      'bibliography',
      'reference',
      '_ind_',
      '_ill_',
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
      '_ata_',
      '_ack_',
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
      '_tp_',
      '_toc_',
      '_prf_',
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
