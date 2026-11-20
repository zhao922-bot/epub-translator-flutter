import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../epub/epub_dom.dart';
import '../epub/epub_html_extractor.dart';
import 'quality_residual_detector.dart';
import 'quality_residual_models.dart';

/// HTML DOM, work-title, attribution, and named-entity residual checks.
class QualityDocumentResidual {
  const QualityDocumentResidual._();

  static TranslationResidualFinding? findSuspiciousHtmlResidual({
    required String sourceHtml,
    required String translatedHtml,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) {
    validateEpubMarkupDepth(sourceHtml);
    validateEpubMarkupDepth(translatedHtml);
    final Document sourceDocument = html_parser.parse(sourceHtml);
    final Document translatedDocument = html_parser.parse(translatedHtml);
    return _findSuspiciousDocumentResidual(
      sourceDocument: sourceDocument,
      translatedDocument: translatedDocument,
      targetLanguage: targetLanguage,
      allowRetainedAuthorSignature: allowRetainedAuthorSignature,
      allowBibliographicRetention: allowBibliographicRetention,
      lockedGlossary: lockedGlossary,
    );
  }

  /// DOM entry point for the response pipeline. Quality rules clear exempted
  /// content, so operate on clones rather than changing the source/output DOM.
  static TranslationResidualFinding? findSuspiciousFragmentResidual({
    required DocumentFragment sourceFragment,
    required DocumentFragment translatedFragment,
    required String targetLanguage,
    bool allowRetainedAuthorSignature = false,
    bool allowBibliographicRetention = false,
    String lockedGlossary = '',
  }) {
    Document qualityDocument(DocumentFragment fragment) {
      validateEpubDomDepth(fragment);
      final document = Document();
      final html = Element.tag('html');
      final body = Element.tag('body');
      document.append(html);
      html.append(body);
      for (final node in fragment.nodes) {
        body.append(node.clone(true));
      }
      return document;
    }

    return _findSuspiciousDocumentResidual(
      sourceDocument: qualityDocument(sourceFragment),
      translatedDocument: qualityDocument(translatedFragment),
      targetLanguage: targetLanguage,
      allowRetainedAuthorSignature: allowRetainedAuthorSignature,
      allowBibliographicRetention: allowBibliographicRetention,
      lockedGlossary: lockedGlossary,
    );
  }

  /// Only the diagnostic copies are canonicalized; EPUB output keeps its
  /// qualified names. An explicit foreign namespace must never gain an XHTML
  /// work-title exemption just because its local name happens to be i/cite.
  static void _normalizeDiagnosticXhtmlNames(Document document) {
    final replacements = <Element>[];
    for (final element in epubElements(document)) {
      final name = element.localName ?? '';
      final colon = name.indexOf(':');
      if (colon < 0) continue;
      if (element.namespaceUri != null &&
          element.namespaceUri != 'http://www.w3.org/1999/xhtml') {
        continue;
      }
      final prefix = name.substring(0, colon);
      String? binding;
      for (
        Element? current = element;
        current != null;
        current = current.parent
      ) {
        binding = current.attributes['xmlns:$prefix'];
        if (binding != null) break;
      }
      // Detached XHTML fragments can omit their inherited declaration.
      if (binding == null || binding == 'http://www.w3.org/1999/xhtml') {
        replacements.add(element);
      }
    }
    for (final element in replacements.reversed) {
      final replacement = Element.tag(epubLocalName(element))
        ..attributes.addAll(element.attributes);
      replacement.nodes.addAll(element.nodes.toList());
      element.replaceWith(replacement);
    }
  }

  static TranslationResidualFinding? _findSuspiciousDocumentResidual({
    required Document sourceDocument,
    required Document translatedDocument,
    required String targetLanguage,
    required bool allowRetainedAuthorSignature,
    required bool allowBibliographicRetention,
    required String lockedGlossary,
  }) {
    _normalizeDiagnosticXhtmlNames(sourceDocument);
    _normalizeDiagnosticXhtmlNames(translatedDocument);
    _unwrapReaderTextSpans(sourceDocument);
    _unwrapReaderTextSpans(translatedDocument);
    _clearMatchingPublicationMetadata(sourceDocument, translatedDocument);
    if (!_clearMatchingExplainedInlinePhrases(
      sourceDocument,
      translatedDocument,
      targetLanguage: targetLanguage,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    // Capture before any exemption clears source nodes. Previously these
    // heuristics reparsed the original source HTML each time they ran.
    final sourceAuditedCores = _sourceAuditedForeignTermCores(sourceDocument);
    // Source-owned code/formula text is intentionally retained. Exempt only
    // identical subtrees, so newly introduced code wrappers cannot hide prose.
    final sourceNonProse = epubTags(
      sourceDocument,
      EpubHtmlExtractor.nonTextAncestors,
    ).toList();
    final translatedNonProse = epubTags(
      translatedDocument,
      EpubHtmlExtractor.nonTextAncestors,
    ).toList();
    if (sourceNonProse.length == translatedNonProse.length) {
      for (var index = sourceNonProse.length - 1; index >= 0; index--) {
        if (sourceNonProse[index].outerHtml ==
            translatedNonProse[index].outerHtml) {
          sourceNonProse[index].nodes.clear();
          translatedNonProse[index].nodes.clear();
        }
      }
    }
    if (lockedGlossary.trim().isNotEmpty) {
      for (final document in [sourceDocument, translatedDocument]) {
        for (final node in _textNodes(document)) {
          node.data = QualityResidualDetector.stripLockedTerms(
            node.data,
            lockedGlossary,
          );
        }
      }
    }
    if (QualityResidualDetector.hasNonLatinSourceResidual(
      sourceDocument.body?.text ?? '',
      translatedDocument.body?.text ?? '',
      targetLanguage,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    if (!QualityResidualDetector.shouldCheckResidual(targetLanguage)) {
      return null;
    }
    // Capture source inline work titles BEFORE any clearing below empties the
    // `<i>/<em>/<cite>` nodes, so retained work titles can be recognised later
    // even when the source copy was scrubbed by term/name handling.
    final Set<String> sourceInlineWorkTitles = _sourceInlineWorkTitles(
      sourceDocument,
    );
    if (allowRetainedAuthorSignature &&
        !_prepareAuthorSignatureForResidualCheck(
          sourceDocument,
          translatedDocument,
          targetLanguage: targetLanguage,
        )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    _clearMatchingPlainAttributions(sourceDocument, translatedDocument);
    final List<Element> sourceCandidates = _outermostWorkTitleCandidates(
      sourceDocument,
    );
    final List<Element> translatedCandidates = _outermostWorkTitleCandidates(
      translatedDocument,
    );
    final Set<String> sourceWorkTitles = sourceCandidates
        .map((Element candidate) => _normalizedWorkTitleText(candidate.text))
        .where(_looksLikeEnglishWorkTitle)
        .toSet();
    final List<int> exemptedCandidateIndexes = <int>[];
    final List<String> unexemptedSourceTexts = <String>[];
    final Map<Node, WorkTitleBlockContext> workTitleContexts = Map.identity();

    if (sourceCandidates.length == translatedCandidates.length) {
      // 性能-#39: the whole translated body text is scanned once here, not
      // once per candidate. Clearing a retained title below only removes the
      // title text inside the brackets, so the bracket presence observed
      // here stays valid for every candidate.
      final bool hasChineseTitleMarker = RegExp(
        r'[《「『〈》」』〉]',
      ).hasMatch(translatedDocument.body?.text ?? '');
      for (int index = 0; index < sourceCandidates.length; index += 1) {
        final Element sourceCandidate = sourceCandidates[index];
        final Element translatedCandidate = translatedCandidates[index];
        final String sourceText = QualityScriptUtils.normalizeText(
          sourceCandidate.text,
        );
        final String translatedText = QualityScriptUtils.normalizeText(
          translatedCandidate.text,
        );
        final bool canExempt =
            sourceCandidate.localName == translatedCandidate.localName &&
            _elementStructurePath(sourceCandidate) ==
                _elementStructurePath(translatedCandidate) &&
            _normalizedWorkTitleText(sourceText) ==
                _normalizedWorkTitleText(translatedText) &&
            _looksLikeEnglishWorkTitle(sourceText) &&
            (_hasWorkTitleSemantics(
                  sourceDocument,
                  sourceCandidate,
                  sourceText,
                  contexts: workTitleContexts,
                ) ||
                hasChineseTitleMarker);
        final bool canExemptCjkGloss =
            !canExempt &&
            _clearCjkMarkedWorkTitleGloss(
              translatedDocument,
              sourceText,
              targetLanguage: targetLanguage,
            );
        if (canExempt || canExemptCjkGloss) {
          if (canExemptCjkGloss) {
            // The HTML lock may leave an empty emphasis wrapper at the end of
            // the block while the model moves the original title into plain
            // CJK book-title marks. Clear only the quality-check copy; the
            // rendered translation remains untouched.
            sourceCandidate.text = '';
            // Later candidates must see this mutation, just as they did
            // with uncached context walks.
            workTitleContexts.clear();
          }
          exemptedCandidateIndexes.add(index);
          continue;
        }
        if (_looksLikeEnglishWorkTitle(sourceText)) {
          unexemptedSourceTexts.add(sourceText);
        }
      }
    } else {
      for (final Element sourceCandidate in sourceCandidates) {
        final String sourceText = QualityScriptUtils.normalizeText(
          sourceCandidate.text,
        );
        if (!_looksLikeEnglishWorkTitle(sourceText) ||
            isAuditedForeignTermNodeText(sourceText)) {
          continue;
        }
        final Element? matchingTranslated = translatedCandidates
            .where(
              (Element candidate) =>
                  _normalizedWorkTitleText(candidate.text) ==
                      _normalizedWorkTitleText(sourceText) &&
                  _looksLikeEnglishWorkTitle(
                    _normalizedWorkTitleText(candidate.text),
                  ),
            )
            .firstOrNull;
        if (matchingTranslated != null) {
          // The model kept the original English work title and supplied a
          // translated gloss elsewhere in the block; this is the same
          // retention accepted when wrapper counts match.
          sourceCandidate.text = '';
          matchingTranslated.text = '';
          continue;
        }
        // The model may instead render the book title as a bilingual gloss in
        // a single node: 《中文书名》（English original title）. The English
        // original is retained only as a parenthetical gloss, exactly like
        // the separate-node form handled above, so treat it as matched too.
        final bool translatedGlossRetained = translatedCandidates.any(
          (Element candidate) =>
              _isWorkTitleGlossRetention(candidate.text, sourceText),
        );
        if (translatedGlossRetained) {
          sourceCandidate.text = '';
          continue;
        }
        unexemptedSourceTexts.add(_normalizedWorkTitleText(sourceText));
      }
      final String translatedVisibleText = QualityScriptUtils.normalizeText(
        _stripSourceAuditedForeignTermsFromText(
          sourceAuditedCores,
          translatedDocument.body?.text ?? translatedDocument.text ?? '',
        ),
      );
      final bool hasChineseTitleMarker =
          RegExp(r'[《「『〈]').hasMatch(translatedVisibleText) ||
          RegExp(r'[》」』〉]').hasMatch(translatedVisibleText) ||
          translatedCandidates.any(
            (Element candidate) => RegExp(
              r'[\u3400-\u9FFF\u{20000}-\u{2FA1F}]',
              unicode: true,
            ).hasMatch(candidate.text),
          );
      for (final String unexempted in unexemptedSourceTexts) {
        // An unretained source work title that is neither kept verbatim nor
        // translated into a Chinese title (marked with 《》 etc.) means the
        // model dropped it entirely instead of translating the block.
        if (!translatedVisibleText.contains(unexempted) &&
            !hasChineseTitleMarker) {
          return const TranslationResidualFinding(
            kind: TranslationResidualKind.longSourceText,
          );
        }
      }
    }

    for (final int index in exemptedCandidateIndexes) {
      sourceCandidates[index].text = '';
      translatedCandidates[index].text = '';
    }

    if (!_clearMatchingAuditedForeignTerms(
      sourceDocument,
      translatedDocument,
      targetLanguage: targetLanguage,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    _clearMatchingInvertedIndexPersonNames(sourceDocument, translatedDocument);
    _clearRetainedProperNames(sourceDocument, translatedDocument);
    _clearSourceOwnedCompanyLists(
      sourceDocument,
      translatedDocument,
      targetLanguage: targetLanguage,
    );

    final String? adjacentLowercaseWord =
        QualityResidualDetector.findCjkAdjacentLowercaseWord(
          _stripSourceAuditedForeignTermsFromText(
            sourceAuditedCores,
            translatedDocument.body?.text ?? translatedDocument.text ?? '',
          ),
          targetLanguage: targetLanguage,
          sourceText: sourceDocument.body?.text ?? sourceDocument.text ?? '',
        );
    if (adjacentLowercaseWord != null) {
      return TranslationResidualFinding(
        kind: TranslationResidualKind.cjkAdjacentLowercaseWord,
        token: adjacentLowercaseWord,
      );
    }

    if (_hasRemainingTranslatedInlineResidual(
      translatedDocument,
      sourceInlineWorkTitles: sourceInlineWorkTitles,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    if (allowBibliographicRetention &&
        isPureCitationMetadata(
          sourceDocument.body?.text ?? sourceDocument.text ?? '',
        )) {
      // Pure citation / index metadata (author names, page numbers, locators,
      // `Ibid.` / `op. cit.` cross-references) is conventionally retained
      // verbatim. The per-node short-English-prose check below would mistake
      // these retained fields for untranslated sentences even when the entry
      // is a pure metadata line with nothing to translate, so exempt it here
      // the same way the translation-time validation does.
    } else if (_hasSourceOwnedShortEnglishProse(
      sourceDocument,
      translatedDocument,
      isBibliographicEntry: allowBibliographicRetention,
    )) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final String translatedVisibleText = QualityScriptUtils.normalizeText(
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
    );
    if (!allowBibliographicRetention &&
        unexemptedSourceTexts.any(translatedVisibleText.contains)) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }

    final bool hasLongSourceText =
        QualityResidualDetector.hasSuspiciousSourceResidual(
          sourceText: sourceDocument.body?.text ?? sourceDocument.text ?? '',
          translatedText:
              translatedDocument.body?.text ?? translatedDocument.text ?? '',
          targetLanguage: targetLanguage,
          sourceWorkTitles: sourceWorkTitles,
        );
    if (hasLongSourceText) {
      return const TranslationResidualFinding(
        kind: TranslationResidualKind.longSourceText,
      );
    }
    return null;
  }

  /// Whether [text] is a pure citation-metadata endnote with no translatable
  /// natural-language sentence, e.g. `Ibid.` or `Yardeni, op. cit., p. 62.`
  ///
  /// Such entries conventionally stay verbatim in translated works, since
  /// `op. cit.` / `ibid.` / `loc. cit.` are standard scholarly abbreviations
  /// and any surrounding words are author/journal names or page numbers.
  static bool isPureCitationMetadata(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Remove the leading footnote number (`14.`) and the entry's number anchor
    // text if the extractor included it (`14`) at the start.
    var body = normalized.replaceFirst(RegExp(r'^\d+\s*\.?\s*'), '');
    // Strip any quoted/curly-quoted article or book titles — a quoted title is
    // translatable natural-language content, so its presence disqualifies the
    // entry from being treated as pure metadata.
    if (RegExp(r'[“”"«»]').hasMatch(body)) {
      return false;
    }
    // Strip trailing sentence-final punctuation then split into words.
    body = body.replaceFirst(RegExp(r'[.!?]+\s*$'), '');
    final wordPattern = RegExp(r"[A-Za-z][A-Za-z'’\-]*|\d+");
    // Numbers and citation cues cannot exempt letters the tokenizer did not
    // consume. Check before every affirmative metadata branch.
    if (RegExp(
      r'\p{L}',
      unicode: true,
    ).hasMatch(body.replaceAll(wordPattern, ''))) {
      return false;
    }
    final List<String> words = wordPattern
        .allMatches(body)
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    if (words.isEmpty) {
      return true;
    }
    const Set<String> citationTokens = <String>{
      'a',
      'al',
      'ben',
      'bin',
      'and',
      'by',
      'cit',
      'da',
      'de',
      'del',
      'der',
      'des',
      'di',
      'du',
      'ed',
      'eds',
      'el',
      'et',
      'for',
      'ibid',
      'in',
      'la',
      'le',
      'loc',
      'n',
      'no',
      'of',
      'op',
      'p',
      'pp',
      'rev',
      'sd',
      'st',
      'ten',
      'ter',
      'the',
      'trans',
      'van',
      'vol',
      'von',
      'see',
      'quoted',
    };
    for (final String word in words) {
      if (RegExp(r'^\d+$').hasMatch(word)) {
        continue;
      }
      final String lower = word.toLowerCase();
      if (citationTokens.contains(lower)) {
        continue;
      }
      final String first = word.substring(0, 1);
      // Allow title-cased author/journal words (Fiorentini, Peltzman,
      // Washington, New) but reject ordinary lowercase sentence words.
      if (first == first.toUpperCase() && first != first.toLowerCase()) {
        continue;
      }
      return false;
    }
    // P2-#19: an all-caps run of sentence length is body prose, not
    // metadata. A lone all-caps surname (YARDENI) or acronym stays allowed,
    // but several all-caps words in a row are a sentence that must not be
    // exempted as "pure citation metadata".
    int allCapsWords = 0;
    for (final String word in words) {
      // P2-#11: single-letter words count too — "THIS IS A TEST" is a
      // four-word all-caps sentence, not citation metadata.
      if (word.isNotEmpty &&
          word == word.toUpperCase() &&
          RegExp(r'[A-Z]').hasMatch(word)) {
        allCapsWords++;
      }
    }
    if (allCapsWords >= 4) {
      return false;
    }
    // Capitalization alone does not distinguish a heading from metadata.
    // Preserve the established lone-surname case and require citation shape
    // for multiword entries (cross-reference, locator, or author/year).
    return words.length == 1 ||
        RegExp(
          r'\b(?:ibid|(?:op|loc)\.\s*cit)\b',
          caseSensitive: false,
        ).hasMatch(body) ||
        RegExp(
          r'(?:[,:(]\s*\d+|\b(?:p|pp|vol|no)\.\s*\d+)',
          caseSensitive: false,
        ).hasMatch(body);
  }

  static bool _prepareAuthorSignatureForResidualCheck(
    Document sourceDocument,
    Document translatedDocument, {
    required String targetLanguage,
  }) {
    final List<Element> sourceElements =
        sourceDocument.body?.children ?? const <Element>[];
    final List<Element> translatedElements =
        translatedDocument.body?.children ?? const <Element>[];
    if (sourceElements.length != 1 || translatedElements.length != 1) {
      return false;
    }
    final Element sourceElement = sourceElements.single;
    final Element translatedElement = translatedElements.single;
    final String sourceText = QualityScriptUtils.normalizeText(
      sourceElement.text,
    );
    final String translatedText = QualityScriptUtils.normalizeText(
      translatedElement.text,
    );
    if (sourceElement.localName != 'p' ||
        translatedElement.localName != 'p' ||
        !_hasSignatureSemantics(sourceElement) ||
        !_hasSignatureSemantics(translatedElement) ||
        sourceElement.children.isNotEmpty ||
        translatedElement.children.isNotEmpty ||
        _canonicalRetainedPersonName(sourceText) == null) {
      return false;
    }

    if (sourceText == translatedText) {
      sourceElement.text = '';
      translatedElement.text = '';
      return true;
    }

    // A translated or transliterated signature is already safe. Keep it in
    // the normal residual pipeline so any unrelated English text is still
    // checked. A different all-Latin name, however, is not an acceptable
    // retained signature and must be retried.
    if (!QualityScriptUtils.hasTargetScript(
          translatedText,
          targetLanguage: targetLanguage,
        ) ||
        RegExp(r'[A-Za-z]').hasMatch(translatedText)) {
      return false;
    }
    return true;
  }

  static bool _hasSignatureSemantics(Element paragraph) {
    const Set<String> recognizedClasses = <String>{
      'author-signature',
      'sig',
      'signature',
    };
    return paragraph.classes
        .map((String token) => token.toLowerCase())
        .any(
          (token) =>
              recognizedClasses.contains(token) ||
              RegExp(r'(?:^|[-_])signature$').hasMatch(token),
        );
  }

  // Reader-generated text runs carry positions, not linguistic boundaries.
  // Normalize diagnostic clones only; rendered markup/IDs remain untouched.
  static void _unwrapReaderTextSpans(Document document) {
    final spans = document.querySelectorAll('span.koboSpan');
    if (spans.isEmpty) return;
    for (final element in spans.reversed) {
      if (element.attributes.keys.any(
            (key) => !const {
              'id',
              'class',
              'lang',
              'xml:lang',
              'xmlns',
            }.contains(key.toString()),
          ) ||
          !element.classes.contains('koboSpan') ||
          element.classes.any((c) => c != 'koboSpan') ||
          element.namespaceUri != null &&
              element.namespaceUri != 'http://www.w3.org/1999/xhtml') {
        continue;
      }
      final parent = element.parentNode;
      if (parent == null) continue;
      final at = parent.nodes.indexOf(element);
      parent.nodes.insertAll(at, element.nodes.toList());
      element.remove();
    }
    // Adjacent text nodes left by unwrapping must not remain artificial
    // sentence boundaries in the per-node source/target comparison.
    void merge(Node node) {
      for (final child in node.nodes.toList()) {
        merge(child);
      }
      for (var i = node.nodes.length - 1; i > 0; i--) {
        final left = node.nodes[i - 1], right = node.nodes[i];
        if (left is Text && right is Text) {
          left.data += right.data;
          right.remove();
        }
      }
    }

    merge(document);
  }

  static void _clearMatchingPlainAttributions(
    Document source,
    Document target,
  ) {
    final sources = source.querySelectorAll('p');
    final targets = target.querySelectorAll('p');
    if (sources.length != targets.length) return;
    for (var i = 0; i < sources.length; i++) {
      final a = sources[i], b = targets[i];
      final name = QualityScriptUtils.normalizeText(a.text);
      if (name != QualityScriptUtils.normalizeText(b.text) ||
          _canonicalRetainedPersonName(name) == null ||
          a.children.isNotEmpty ||
          b.children.isNotEmpty ||
          _elementStructurePath(a) != _elementStructurePath(b)) {
        continue;
      }
      bool attribution(Element p) {
        // Publishing-system signature classes are explicit attributions.
        // Keep the older ambiguous `sig` class behind the extractor's
        // contextual author-signature classification.
        if (p.classes.any(
          (c) => RegExp(r'^.+[-_]signature$', caseSensitive: false).hasMatch(c),
        )) {
          return true;
        }
        final parent = p.parent;
        if (parent?.localName != 'blockquote') return false;
        final paragraphs = parent!.children
            .where((e) => e.localName == 'p' && e.text.trim().isNotEmpty)
            .toList();
        return paragraphs.length >= 2 &&
            identical(paragraphs.last, p) &&
            (_hasEpigraphAttributionSemantics(p) ||
                p.classes.any(
                  (c) => RegExp(
                    r'(?:^|[-_])epigraph[-_](?:source|author)$',
                    caseSensitive: false,
                  ).hasMatch(c),
                ));
      }

      if (attribution(a) && attribution(b)) {
        a.text = '';
        b.text = '';
      }
    }
  }

  static void _clearMatchingPublicationMetadata(
    Document source,
    Document target,
  ) {
    final sources = source.querySelectorAll('p');
    final targets = target.querySelectorAll('p');
    if (sources.length != targets.length) return;
    final classification = RegExp(
      r'\b(?:LCC\s+[A-Z]{1,3}\d[\w./-]*(?:\s+[A-Z]\d[\w./-]*)?(?:\s+\d{4})?|DDC\s+\d[\d/.\-]*(?:[—-]dc\d+(?:/[a-z]{2,3}/\d{8})?)?)\b',
    );
    for (var i = 0; i < sources.length; i++) {
      final a = sources[i], b = targets[i];
      if (_elementStructurePath(a) != _elementStructurePath(b)) continue;
      final raw = QualityScriptUtils.normalizeText(a.text),
          translated = QualityScriptUtils.normalizeText(b.text);
      if (raw == translated &&
          raw.length <= 160 &&
          RegExp(
            r'^[A-Za-z][A-Za-z0-9]*_(?:[A-Za-z0-9.]+_)+[A-Za-z0-9.]+$',
          ).hasMatch(raw) &&
          RegExp(r'\d').hasMatch(raw)) {
        a.text = '';
        b.text = '';
        continue;
      }
      final metadata = a.classes.any(
        (c) => RegExp(
          r'copyright|bibliograph|metadata',
          caseSensitive: false,
        ).hasMatch(c),
      );
      if (!metadata) continue;
      final title = RegExp(
        r'^Title:\s*(.{1,300})\s*/\s*([^/]+?)\.?$',
      ).firstMatch(raw);
      if (title != null &&
          _canonicalRetainedPersonName(title[2]!.trim()) != null) {
        final colon = translated.indexOf(RegExp(r'[:：]'));
        if (colon > 0 &&
            RegExp(
              r'[\u3400-\u9fff]',
            ).hasMatch(translated.substring(0, colon)) &&
            translated.substring(colon + 1).trim() ==
                raw.substring(raw.indexOf(':') + 1).trim()) {
          a.text = '';
          b.text = '';
          continue;
        }
      }
      if (raw.startsWith('Classification:')) {
        for (final match in classification.allMatches(raw)) {
          final code = match[0]!;
          if (!translated.contains(code)) continue;
          for (final p in [a, b]) {
            void clear(Node node) {
              if (node is Text) node.data = node.data.replaceAll(code, ' ');
              for (final child in node.nodes) {
                clear(child);
              }
            }

            clear(p);
          }
        }
      }
    }
  }

  static List<Element> _outermostWorkTitleCandidates(Document document) {
    return document.querySelectorAll('i, em, cite').where((Element candidate) {
      if (candidate.localName == 'cite') {
        return !_hasAncestorWithTag(candidate, const <String>{'cite'});
      }
      return !_hasAncestorWithTag(candidate, const <String>{
            'i',
            'em',
            'cite',
          }) &&
          candidate.querySelector('cite') == null;
    }).toList();
  }

  static bool _hasAncestorWithTag(Element element, Set<String> tags) {
    Node? ancestor = element.parentNode;
    while (ancestor != null) {
      if (ancestor is Element && tags.contains(ancestor.localName)) {
        return true;
      }
      ancestor = ancestor.parentNode;
    }
    return false;
  }

  static String _elementStructurePath(Element element) {
    final List<int> indexes = <int>[];
    Node? current = element;
    while (current is Element && current.localName != 'body') {
      final Node? parent = current.parentNode;
      if (parent == null) {
        break;
      }
      indexes.add(parent.children.indexOf(current));
      current = parent;
    }
    return indexes.reversed.join('/');
  }

  static bool _looksLikeEnglishWorkTitle(String text) {
    final String normalized = QualityScriptUtils.normalizeText(text);
    if (normalized.isEmpty || normalized.length > 140) {
      return false;
    }
    // Source HTML often keeps a trailing period inside italicized titles
    // ("The Great Reckoning.") without making them ordinary sentences.
    final String titleCore = normalized.replaceFirst(RegExp(r'[.!?。！？]+$'), '');
    if (titleCore.isEmpty || titleCore.length > 140) {
      return false;
    }
    // Short abbreviations inside a title (for example `Alt. Abracadabra`)
    // are not sentence punctuation. Remove those abbreviation periods before
    // checking for punctuation that should disqualify a title candidate.
    final String withoutAbbreviationPeriods = titleCore
        .replaceAll(RegExp(r'\b(?:[A-Za-z]\.){2,}(?=\s|$)'), '')
        .replaceAll(RegExp(r'\b[A-Za-z]{1,3}\.(?=\s+[A-Z])'), '');
    if (RegExp(r'[.!?。！？]').hasMatch(withoutAbbreviationPeriods) ||
        RegExp(
          r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
        ).hasMatch(titleCore)) {
      return false;
    }
    final List<String> words = QualityScriptUtils.englishWorkTitleWords(
      titleCore,
    );
    // Two-word title-case names are common for books and newsletters
    // ("Strategic Investment", "Blade Runner").
    return words.length >= 2 &&
        words.length <= 16 &&
        QualityResidualDetector.looksLikeEnglishTitleOrName(words);
  }

  static bool _looksLikeSentenceOrInstruction(String text) {
    final List<String> words = QualityScriptUtils.englishWorkTitleWords(
      text,
    ).map((String word) => word.toLowerCase()).toList(growable: false);
    if (words.isEmpty) {
      return false;
    }
    const Set<String> commandOpeners = <String>{
      'click',
      'close',
      'continue',
      'do',
      "don't",
      'enter',
      'follow',
      'never',
      'open',
      'please',
      'press',
      'read',
      'restart',
      'select',
      'sign',
      'start',
      'stop',
      'tap',
      'turn',
      'wait',
    };
    if (commandOpeners.contains(words.first)) {
      return true;
    }
    const Set<String> sentenceSubjects = <String>{
      'he',
      'i',
      'it',
      'she',
      'that',
      'these',
      'they',
      'this',
      'those',
      'we',
      'you',
    };
    if (sentenceSubjects.contains(words.first)) {
      return true;
    }
    const Set<String> auxiliariesAndModals = <String>{
      'am',
      'are',
      'can',
      'could',
      'did',
      'do',
      'does',
      'had',
      'has',
      'have',
      'is',
      'may',
      'might',
      'must',
      'shall',
      'should',
      'was',
      'were',
      'will',
      'would',
    };
    if (words.any(auxiliariesAndModals.contains)) {
      return true;
    }
    return words.length >= 2 &&
        words[0] == 'important' &&
        const <String>{
          'information',
          'notice',
          'safety',
          'warning',
        }.contains(words[1]);
  }

  static bool _looksLikeImperativeOrNotice(String text) {
    final List<String> words = QualityScriptUtils.englishWorkTitleWords(
      text,
    ).map((String word) => word.toLowerCase()).toList(growable: false);
    if (words.isEmpty) {
      return false;
    }
    const Set<String> imperativeOpeners = <String>{
      'click',
      'close',
      'continue',
      'do',
      "don't",
      'enter',
      'follow',
      'never',
      'open',
      'please',
      'press',
      'read',
      'restart',
      'select',
      'sign',
      'start',
      'stop',
      'tap',
      'turn',
      'wait',
    };
    return imperativeOpeners.contains(words.first) ||
        (words.length >= 2 &&
            words.first == 'important' &&
            const <String>{
              'information',
              'notice',
              'safety',
              'warning',
            }.contains(words[1]));
  }

  static String _sourceTextBeforeNode(
    Document document,
    Node target, {
    int? maxLength = 120,
  }) {
    final StringBuffer precedingText = StringBuffer();

    bool collectUntilTarget(Node node) {
      if (identical(node, target)) {
        return true;
      }
      if (node.nodeType == Node.TEXT_NODE) {
        precedingText.write(' ${node.text ?? ''}');
        return false;
      }
      for (final Node child in node.nodes) {
        if (collectUntilTarget(child)) {
          return true;
        }
      }
      return false;
    }

    collectUntilTarget(
      _nearestSemanticBlock(target) ?? document.body ?? document,
    );
    final String normalized = QualityScriptUtils.normalizeText(
      precedingText.toString(),
    );
    return maxLength == null || normalized.length <= maxLength
        ? normalized
        : normalized.substring(normalized.length - maxLength);
  }

  static Element? _nearestSemanticBlock(Node target) {
    const Set<String> semanticBlockTags = <String>{
      'p',
      'li',
      'blockquote',
      'dd',
      'dt',
      'figcaption',
      'caption',
      'summary',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'td',
      'th',
    };
    Node? ancestor = target.parentNode;
    while (ancestor != null) {
      if (ancestor is Element &&
          semanticBlockTags.contains(ancestor.localName)) {
        return ancestor;
      }
      ancestor = ancestor.parentNode;
    }
    return null;
  }

  static bool _hasWorkTitleSemantics(
    Document document,
    Element element,
    String title, {
    required Map<Node, WorkTitleBlockContext> contexts,
  }) {
    final Element? semanticBlock = _nearestSemanticBlock(element);
    if (semanticBlock != null && _hasSignatureSemantics(semanticBlock)) {
      return false;
    }
    if (element.localName == 'cite' || element.querySelector('cite') != null) {
      return true;
    }
    if (_looksLikeImperativeOrNotice(title)) {
      return false;
    }
    // 性能-#39: the text around the candidate is traversed once here and
    // shared by every context check below, instead of re-traversed per
    // check (O(checks × text)). The 120-char window is a suffix of the
    // full preceding text, so one traversal serves both.
    final root = semanticBlock ?? document.body ?? document;
    final context = contexts.putIfAbsent(
      root,
      () => WorkTitleBlockContext(root),
    );
    final span = context.spans[element]!;
    final String precedingFull = QualityScriptUtils.normalizeText(
      context.text.substring(0, span.$1),
    );
    final String precedingText = precedingFull.length <= 120
        ? precedingFull
        : precedingFull.substring(precedingFull.length - 120);
    final String followingText = QualityScriptUtils.normalizeText(
      context.text.substring(span.$2),
    );
    return _hasExplicitWorkReferenceContext(precedingText) ||
        _hasAttributedWorkContext(precedingText, followingText) ||
        _hasDescriptiveWorkContext(precedingText) ||
        _hasBibliographicContext(
          precedingFull,
          followingText,
          semanticBlock,
          title,
        ) ||
        _hasSubjectWorkContext(followingText) ||
        _hasNamedPublicationContext(precedingText) ||
        _hasSerialWorkTitleContext(
          element,
          precedingText,
          semanticBlock,
          title,
        ) ||
        _isOnlyTitleInSemanticBlock(semanticBlock, title);
  }

  static bool _hasExplicitWorkReferenceContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r'(?:\bauthors?\s+of|\bwriters?\s+of|\b(?:book|novel|work|essay|article|report|study|volume|memoir|guide|paper|newsletter|magazine|journal)(?:\s+(?:called|named|titled))?|\b(?:read|reading)|\bwent\s+into)\s*(?:[:\-–—]\s*)?$',
    ).hasMatch(lower);
  }

  static bool _hasAttributedWorkContext(
    String precedingText,
    String followingText,
  ) {
    final String lower = precedingText.toLowerCase();
    if (!RegExp(r'(?:^|\s)(?:in|within)\s*$').hasMatch(lower)) {
      return false;
    }
    return RegExp(
      r"^[,;:]?\s*[A-Z][A-Za-z'’\-]*(?:\s+[A-Z][A-Za-z'’\-]*){0,3}\s+(?:argues?|contends?|describes?|explains?|maintains?|notes?|observes?|proposes?|writes?)\b",
    ).hasMatch(followingText);
  }

  static bool _hasDescriptiveWorkContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r"(?:\b(?:his|her|their|the)\s+)?(?:acclaimed|award-winning|best-selling|celebrated|classic|famous|influential|landmark|seminal)(?:\s+(?:book|essay|memoir|novel|report|study|work))?\s*$",
    ).hasMatch(lower);
  }

  static bool _hasSubjectWorkContext(String followingText) {
    return RegExp(
      r'^(?:[,;:]?\s*)?(?:'
      r'builds?\s+upon|draws?\s+(?:on|from)|is\s+based\s+on|'
      r'explores?|examines?|argues?|contends?|describes?|chronicles?|'
      r'recounts?|presents?|offers?|provides?|remains?|became|becomes|'
      r'changed|continues?|develops?|extends?|follows?|'
      r'is\s+a|was\s+a|were|are\s+a'
      r')\b',
      caseSensitive: false,
    ).hasMatch(followingText);
  }

  static bool _hasNamedPublicationContext(String precedingText) {
    final String lower = precedingText.toLowerCase();
    return RegExp(
      r'(?:\b(?:our|the|his|her|their)\s+)?(?:newsletter|magazine|journal|newspaper|column|periodical|publication|bulletin|digest)\b[,:\s]*$',
    ).hasMatch(lower);
  }

  /// A retained short quotation with an adjacent translated gloss is already
  /// bilingual. Clear only its matching inline node in the audit copies, never
  /// unrelated prose or another occurrence of the same words.
  static bool _clearMatchingExplainedInlinePhrases(
    Document source,
    Document translated, {
    required String targetLanguage,
  }) {
    if (!QualityScriptUtils.isChineseTargetLanguage(
      targetLanguage.trim().toLowerCase(),
    )) {
      return true;
    }
    final originals = source.querySelectorAll('em, i');
    final outputs = translated.querySelectorAll('em, i');
    if (originals.length != outputs.length) return true;
    for (var index = 0; index < originals.length; index++) {
      final a = originals[index], b = outputs[index];
      final phrase = _normalizedWorkTitleText(
        _normalizedExplainedPhrase(a.text),
      );
      final translatedPhrase = _normalizedExplainedPhrase(b.text);
      if (a.children.isNotEmpty ||
          b.children.isNotEmpty ||
          phrase.length > 100 ||
          QualityScriptUtils.englishWordCount(phrase) < 2 ||
          QualityScriptUtils.englishWordCount(phrase) > 8 ||
          !RegExp(r"^[A-Za-zÀ-ɏ ,.'’\-]+$").hasMatch(phrase) ||
          !RegExp(r"^[A-Za-zÀ-ɏ ,.'’\-]+$").hasMatch(translatedPhrase) ||
          a.localName != b.localName ||
          _taggedElementStructurePath(a) != _taggedElementStructurePath(b)) {
        continue;
      }
      String following(Element node) {
        final siblings = node.parentNode!.nodes;
        final next = siblings.indexOf(node) + 1;
        return next < siblings.length && siblings[next] is Text
            ? (siblings[next] as Text).data
            : '';
      }

      final after = following(b);
      // Explicit "(Chinese explanation)" or "—Chinese explanation)".
      final marked = RegExp(
        r'^\s*(?:[（(]\s*|[—–:：]+\s*)([^（）()\r\n]{2,160})[）)]',
      ).firstMatch(after);
      var gloss = marked?.group(1);
      if (gloss == null) {
        // A complete, standalone phrase + explanatory sentence. The source
        // must have the same paired layout, not an emphasized word buried in
        // an ordinary paragraph followed by unrelated translated prose.
        final ap = a.parentNode, bp = b.parentNode;
        if (ap is! Element ||
            bp is! Element ||
            ap.localName != 'p' ||
            bp.localName != 'p' ||
            ap.children.length != 1 ||
            bp.children.length != 1 ||
            ap.nodes
                .takeWhile((n) => !identical(n, a))
                .any((n) => (n.text ?? '').trim().isNotEmpty) ||
            bp.nodes
                .takeWhile((n) => !identical(n, b))
                .any((n) => (n.text ?? '').trim().isNotEmpty) ||
            !RegExp(r'^\s*[.。]\s*[A-Z]').hasMatch(following(a)) ||
            QualityScriptUtils.englishWordCount(following(a)) < 3) {
          continue;
        }
        gloss = RegExp(
          r'^\s*[.。]\s*([^。！？\r\n]{2,160})[。！？]\s*$',
        ).firstMatch(after)?.group(1);
      }
      if (gloss == null ||
          RegExp(r'[A-Za-z]').hasMatch(gloss) ||
          RegExp(r'[\u3400-\u9FFF]').allMatches(gloss).length < 2) {
        continue;
      }
      if (phrase != _normalizedWorkTitleText(translatedPhrase)) {
        return false;
      }
      a.text = '';
      b.text = '';
    }
    return true;
  }

  // Chinese typesetting may localize punctuation while retaining the exact
  // words of an explained quotation. This normalization is audit-only.
  static String _normalizedExplainedPhrase(String text) =>
      QualityScriptUtils.normalizeText(
        text,
      ).replaceAll('。', '.').replaceAll('．', '.').replaceAll('，', ',');

  static bool _clearMatchingAuditedForeignTerms(
    Document sourceDocument,
    Document translatedDocument, {
    required String targetLanguage,
  }) {
    const Map<String, Set<String>> auditedNodeTexts = auditedForeignTermNodes;
    final List<Element> sourceInline = sourceDocument.querySelectorAll('i, em');
    final List<Element> translatedInline = translatedDocument.querySelectorAll(
      'i, em',
    );
    if (sourceInline.length != translatedInline.length) {
      // A model may fully translate an audited foreign term into the target
      // language and drop the italic wrapper entirely (for example
      // <i>—de facto</i> -> “实际上”), or it may keep the audited term as
      // plain text without the italic wrapper (for example
      // <i>politique,</i> -> “politique”). Both are acceptable: the term
      // itself is approved for retention; the wrapper is presentation only.
      final String translatedVisibleText = QualityScriptUtils.normalizeText(
        translatedDocument.body?.text ?? translatedDocument.text ?? '',
      );
      for (final Element element in sourceInline) {
        if (element.children.isNotEmpty ||
            !auditedNodeTexts.containsKey(element.text)) {
          continue;
        }
        final String core = _auditedCoreText(element.text);
        if (core.isNotEmpty) {
          // Whether the term is translated away or retained verbatim, the
          // source node is no longer a residual to complain about.
          element.text = '';
          if (translatedVisibleText.contains(core)) {
            final List<Element> translatedMatching = translatedDocument
                .querySelectorAll('*')
                .where(
                  (Element candidate) =>
                      candidate.children.isEmpty &&
                      QualityScriptUtils.normalizeText(candidate.text) == core,
                )
                .toList(growable: false);
            for (final Element candidate in translatedMatching) {
              candidate.text = '';
            }
          }
        }
      }
      return true;
    }

    for (int index = 0; index < sourceInline.length; index += 1) {
      final Element sourceElement = sourceInline[index];
      final Element translatedElement = translatedInline[index];
      final Set<String>? allowedTranslations =
          auditedNodeTexts[sourceElement.text];
      if (sourceElement.children.isNotEmpty || allowedTranslations == null) {
        continue;
      }
      if (sourceElement.localName != translatedElement.localName ||
          _taggedElementStructurePath(sourceElement) !=
              _taggedElementStructurePath(translatedElement) ||
          !_sameElementAttributes(sourceElement, translatedElement) ||
          translatedElement.children.isNotEmpty) {
        return false;
      }
      final String normalizedTranslated = _normalizeAuditedTerm(
        translatedElement.text,
      );
      final bool normalizedAllowed = allowedTranslations.any(
        (String candidate) =>
            _normalizeAuditedTerm(candidate) == normalizedTranslated,
      );
      if (!normalizedAllowed) {
        if (translatedElement.text.runes.any(
              QualityScriptUtils.isLatinLetterRune,
            ) ||
            !QualityScriptUtils.hasTargetScript(
              translatedElement.text,
              targetLanguage: targetLanguage,
            )) {
          return false;
        }
        continue;
      }
      sourceElement.text = '';
      translatedElement.text = '';
    }
    return true;
  }

  /// Normalizes only quote variants (curly to straight/absent) and a single
  /// trailing comma or period so audited foreign terms still match when the
  /// model normalizes quotes or drops the audited boundary comma (for example
  /// `“sistema del potere,”` -> `"sistema del potere"`). Any other change --
  /// leading whitespace, a semicolon, an internal edit -- must stay a
  /// rejection, because those unreviewed forms are exactly what the strict
  /// tests require to fail.
  static String _normalizeAuditedTerm(String value) {
    final String withoutQuotes = value.replaceAll(RegExp(r'[“”"„‟«»]'), '');
    return withoutQuotes.replaceFirst(RegExp(r'[,，。.]$'), '');
  }

  /// Normalizes a work-title candidate so trailing punctuation (for example
  /// `The General Crisis of the Seventeenth Century,`) does not prevent
  /// matching the same title retained without that punctuation in the
  /// translation.
  static String _normalizedWorkTitleText(String text) {
    return QualityScriptUtils.normalizeText(
      text,
    ).replaceFirst(RegExp(r'[,;:。，；：.!?！？]+$'), '');
  }

  /// Whether [translatedText] holds [sourceTitle] as an original-title gloss
  /// inside a Chinese book-title wrapper, for example
  /// `《道德与立法原理导论》（An Introduction to the Principles of Morals and
  /// Legislation）`.
  static bool _isWorkTitleGlossRetention(
    String translatedText,
    String sourceTitle,
  ) {
    final String normalizedTranslated = QualityScriptUtils.normalizeText(
      translatedText,
    );
    if (!RegExp(r'[《「『〈（]').hasMatch(normalizedTranslated)) {
      return false;
    }
    final String normalizedSource = _normalizedWorkTitleText(sourceTitle);
    if (normalizedSource.isEmpty) {
      return false;
    }
    return normalizedTranslated.contains(normalizedSource);
  }

  /// Clears one retained source work title when the model moved it out of its
  /// original inline wrapper and placed it inside CJK book-title/parenthesis
  /// marks (for example `《The Sovereign Individual》`). This only mutates the
  /// parsed quality-check document, never the final HTML returned to callers.
  static bool _clearCjkMarkedWorkTitleGloss(
    Document translatedDocument,
    String sourceTitle, {
    required String targetLanguage,
  }) {
    final String normalizedSource = _normalizedWorkTitleText(sourceTitle);
    if (normalizedSource.isEmpty ||
        _looksLikeSentenceOrInstruction(normalizedSource)) {
      return false;
    }
    final String translatedBody =
        translatedDocument.body?.text ?? translatedDocument.text ?? '';
    if (!QualityScriptUtils.hasTargetScript(
      translatedBody,
      targetLanguage: targetLanguage,
    )) {
      return false;
    }
    final RegExp retainedTitle = RegExp(
      r'[《「『〈（]\s*' +
          RegExp.escape(normalizedSource) +
          r'\s*[,.;:，。；：]?\s*[》」』〉）]',
      caseSensitive: false,
    );
    for (final Text node in _textNodes(translatedDocument)) {
      final String data = node.data;
      final RegExpMatch? match = retainedTitle.firstMatch(data);
      if (match == null) {
        continue;
      }
      final String matchedTitle = match.group(0)!;
      final int titleStart = matchedTitle.toLowerCase().indexOf(
        normalizedSource.toLowerCase(),
      );
      if (titleStart < 0) {
        continue;
      }
      final int absoluteStart = match.start + titleStart;
      node.data = data.replaceRange(
        absoluteStart,
        absoluteStart + normalizedSource.length,
        '',
      );
      return true;
    }
    return false;
  }

  /// Audited source-language foreign terms that may legitimately stay in the
  /// translated text (typically historical Latin/Italian expressions).
  static const Map<String, Set<String>> auditedForeignTermNodes =
      <String, Set<String>>{
        'Homo economicus': <String>{'Homo economicus'},
        'agri deserti,': <String>{
          'agri deserti,',
          'agri deserti',
          'agri deserti，',
        },
        'civitas,': <String>{'civitas,', 'civitas', 'civitas，'},
        'cullagium,"': <String>{
          'cullagium,"',
          'cullagium',
          'cullagium,',
          'cullagium，',
          'cullagium,”',
          'cullagium，”',
        },
        'militum perpetuum,': <String>{
          'militum perpetuum,',
          'militum perpetuum',
          'militum perpetuum，',
        },
        'op. cit.,': <String>{
          'op. cit.,',
          'op. cit.',
          'op. cit.，',
          'op. cit',
          '同上引文',
          '前引书',
        },
        'pagus': <String>{'pagus'},
        'patria,': <String>{'patria,', 'patria', 'patria，'},
        'patria': <String>{'patria'},
        'patricius': <String>{'patricius'},
        'politique,': <String>{'politique,', 'politique', 'politique，'},
        'plentitude potestatis': <String>{'plentitude potestatis'},
        '“sistema del potere,”': <String>{
          '“sistema del potere,”',
          'sistema del potere',
          'sistema del potere,',
          '“sistema del potere”',
          'sistema del potere，',
          '“sistema del potere，”',
        },
        'prophetae': <String>{'prophetae'},
        'ultimum refugium,': <String>{
          'ultimum refugium,',
          'ultimum refugium',
          'ultimum refugium，',
        },
        '—de facto': <String>{
          '—de facto',
          '——de facto',
          '–de facto',
          '-de facto',
          '--de facto',
          'de facto',
        },
      };

  /// Whether [nodeText] is an exact audited foreign term source node.
  static bool isAuditedForeignTermNodeText(String nodeText) {
    return auditedForeignTermNodes.containsKey(nodeText);
  }

  /// Removes audited foreign terms that the *source* actually contains from
  /// [text] before heuristic counts (for example work-title word counting and
  /// CJK-adjacent checks) so retained terms such as `patria` or `de facto`
  /// are not mistaken for untranslated English prose. Unreviewed source forms
  /// (for example `agri deserti` without its audited comma form) stay intact
  /// and continue to be flagged.
  static String _stripSourceAuditedForeignTermsFromText(
    Set<String> sourceCores,
    String text,
  ) {
    String stripped = text;
    for (final String core in sourceCores) {
      stripped = stripped.replaceAll(
        RegExp(RegExp.escape(core), caseSensitive: false),
        ' ',
      );
    }
    return stripped;
  }

  static Set<String> _sourceAuditedForeignTermCores(Document sourceDocument) {
    final Set<String> sourceCores = <String>{};
    for (final Element element in sourceDocument.querySelectorAll('i, em')) {
      if (element.children.isNotEmpty ||
          !auditedForeignTermNodes.containsKey(element.text)) {
        continue;
      }
      final String core = _auditedCoreText(element.text);
      if (core.isNotEmpty) {
        sourceCores.add(core);
      }
    }
    return sourceCores;
  }

  /// Strips surrounding punctuation/quotes/whitespace from an audited source
  /// node so we can detect whether the source-language term still appears in
  /// the translated text (for example `—de facto` -> `de facto`).
  static String _auditedCoreText(String value) {
    return value.replaceAll(
      RegExp(r'^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$', unicode: true),
      '',
    );
  }

  static String _taggedElementStructurePath(Element element) {
    final List<String> segments = <String>[];
    Node? current = element;
    while (current is Element && current.localName != 'body') {
      final Node? parent = current.parentNode;
      if (parent == null) {
        break;
      }
      segments.add('${current.localName}:${parent.children.indexOf(current)}');
      current = parent;
    }
    return segments.reversed.join('/');
  }

  static void _clearMatchingInvertedIndexPersonNames(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    final List<Element> sourceTerms = sourceDocument
        .querySelectorAll('span')
        .where(_isLeafIndexTerm)
        .toList(growable: false);
    final List<Element> translatedTerms = translatedDocument
        .querySelectorAll('span')
        .where(_isLeafIndexTerm)
        .toList(growable: false);
    if (sourceTerms.length != translatedTerms.length) {
      return;
    }

    for (int index = 0; index < sourceTerms.length; index += 1) {
      final Element sourceElement = sourceTerms[index];
      final Element translatedElement = translatedTerms[index];
      final String? sourceName = _canonicalInvertedIndexPersonName(
        sourceElement.text,
      );
      final String? translatedName =
          _canonicalInvertedIndexPersonName(translatedElement.text) ??
          _canonicalRetainedPersonName(
            QualityScriptUtils.normalizeText(translatedElement.text),
          );
      if (sourceName == null ||
          translatedName == null ||
          sourceName != translatedName ||
          !_sameElementAttributes(sourceElement, translatedElement) ||
          _taggedElementStructurePath(sourceElement) !=
              _taggedElementStructurePath(translatedElement)) {
        continue;
      }
      sourceElement.text = '';
      translatedElement.text = '';
    }
  }

  static bool _sameElementAttributes(Element source, Element translated) {
    if (source.attributes.length != translated.attributes.length) {
      return false;
    }
    for (final MapEntry<Object, String> attribute
        in source.attributes.entries) {
      if (translated.attributes[attribute.key] != attribute.value) {
        return false;
      }
    }
    return true;
  }

  static bool _isLeafIndexTerm(Element element) {
    if (element.children.isNotEmpty || element.parent?.localName != 'li') {
      return false;
    }
    return (element.attributes['epub:type'] ?? '')
        .split(RegExp(r'\s+'))
        .map((String token) => token.toLowerCase())
        .contains('index-term');
  }

  static String? _canonicalInvertedIndexPersonName(String text) {
    final String normalized = QualityScriptUtils.normalizeText(text);
    final List<String> commaParts = normalized
        .split(',')
        .map((String part) => part.trim())
        .toList(growable: true);
    if (commaParts.length == 3 && commaParts.last.isEmpty) {
      commaParts.removeLast();
    }
    if (commaParts.length != 2 ||
        commaParts.first.isEmpty ||
        commaParts.last.isEmpty) {
      return null;
    }

    final String surname = commaParts.first;
    final String givenNames = commaParts.last;
    final List<String> surnameWords = QualityScriptUtils.englishWorkTitleWords(
      surname,
    );
    const Set<String> lowercaseSurnameParticles = <String>{
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
    if (surnameWords.length < 2 ||
        !lowercaseSurnameParticles.contains(surnameWords.first.toLowerCase())) {
      return null;
    }

    final List<String> normalizedSurnameWords = surnameWords
        .map(
          (String word) =>
              lowercaseSurnameParticles.contains(word.toLowerCase())
              ? word.toLowerCase()
              : word,
        )
        .toList(growable: false);

    final String naturalOrder =
        '$givenNames ${normalizedSurnameWords.join(' ')}';
    final List<String> naturalWords = QualityScriptUtils.englishWorkTitleWords(
      naturalOrder,
    );
    if (naturalWords.length < 3 || naturalWords.length > 6) {
      return null;
    }
    return _canonicalRetainedPersonName(naturalOrder);
  }

  static bool _hasSerialWorkTitleContext(
    Element element,
    String precedingText,
    Element? semanticBlock,
    String title,
  ) {
    final String lower = precedingText.toLowerCase();
    if (!RegExp(r'\b(?:and|or)\s*$').hasMatch(lower)) {
      return false;
    }
    final Element? block = semanticBlock;
    if (block == null) {
      return false;
    }
    for (final Element candidate in block.querySelectorAll('i, em, cite')) {
      if (identical(candidate, element)) {
        continue;
      }
      final String other = QualityScriptUtils.normalizeText(candidate.text);
      if (other != title && _looksLikeEnglishWorkTitle(other)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasBibliographicContext(
    String precedingFull,
    String followingText,
    Element? semanticBlock,
    String title,
  ) {
    final Element? block = semanticBlock;
    if (block == null) {
      return false;
    }
    final String blockText = QualityScriptUtils.normalizeText(block.text);
    if (blockText == title) {
      return false;
    }
    final String before = precedingFull;
    final String after = followingText;
    final bool hasYearOrIdentifier = RegExp(
      r'\b(?:18|19|20)\d{2}\b|\bISBN\b|(?:(?:https?|ftp)://|www\.)',
      caseSensitive: false,
    ).hasMatch('$before $after');
    final bool hasAuthorLikePrefix = RegExp(
      r"(?:^|[.;])\s*[A-Z][A-Za-z'’\-]+,\s*(?:[A-Z][A-Za-z'’\-]*\s*){1,4}[.:]?\s*$",
    ).hasMatch(before);
    return hasYearOrIdentifier && hasAuthorLikePrefix;
  }

  static bool _isOnlyTitleInSemanticBlock(
    Element? semanticBlock,
    String title,
  ) {
    final Element? block = semanticBlock;
    if (block == null ||
        QualityScriptUtils.normalizeText(block.text) != title) {
      return false;
    }
    final int wordCount = QualityScriptUtils.englishWorkTitleWords(
      title,
    ).length;
    return wordCount <= 4 || !_looksLikeSentenceOrInstruction(title);
  }

  /// Recognize bounded, source-owned company/brand enumerations. A lowercase
  /// brand between named companies is not a prose sentence. Require explicit
  /// source context, at least three single-token names and two capitalized or
  /// mixed-case anchors; exempt only the same ordered list in translated text.
  static void _clearSourceOwnedCompanyLists(
    Document source,
    Document translated, {
    required String targetLanguage,
  }) {
    final targets = _textNodes(translated);
    if (!QualityScriptUtils.hasTargetScript(
      translated.body?.text ?? '',
      targetLanguage: targetLanguage,
    )) {
      return;
    }
    const name = r"[A-Za-z][A-Za-z0-9'’\-]{1,39}";
    final lists = RegExp(
      r'\b(?:invested\s+in|(?:companies|brands|platforms|firms)'
      r'(?:\s+(?:include|including|such\s+as|like|called|named))?)\s+'
      '($name(?:\\s*,\\s*(?:and\\s+)?$name){2,7})'
      r'(?=\s*(?:[,;.)]|$))',
      caseSensitive: false,
    );
    for (final original in _textNodes(source)) {
      for (final match in lists.allMatches(original.data).toList()) {
        final list = match
            .group(1)!
            .replaceFirst(
              RegExp(
                r',\s*(?:and\s+)?(?:others|more|etc)$',
                caseSensitive: false,
              ),
              '',
            );
        final names = list
            .split(',')
            .map(
              (item) => item.trim().replaceFirst(
                RegExp(r'^and\s+', caseSensitive: false),
                '',
              ),
            )
            .toList();
        if (names.length < 3 ||
            names.where((item) => RegExp(r'[A-Z]').hasMatch(item)).length < 2 ||
            _looksLikeSentenceOrInstruction(names.join(' '))) {
          continue;
        }
        final retained = RegExp(
          r"(?<![A-Za-z0-9'’\-])" +
              names.map(RegExp.escape).join(r'\s*[,，、]\s*(?:and\s+)?') +
              r"(?![A-Za-z0-9'’\-]|\s+[A-Za-z])",
        );
        for (final target in targets) {
          if (!retained.hasMatch(target.data)) continue;
          target.data = target.data.replaceFirst(retained, ' ');
          original.data = original.data.replaceFirst(list, ' ');
          break;
        }
      }
    }
  }

  static void _clearRetainedProperNames(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    final List<Element> sourceInline = sourceDocument.querySelectorAll(
      'i, em, cite',
    );
    final List<Element> translatedInline = translatedDocument.querySelectorAll(
      'i, em, cite',
    );
    if (sourceInline.length != translatedInline.length) {
      return;
    }
    final List<int> retainedNameIndexes = <int>[];
    final Map<Node, List<String>> retainedNamesByBlock = <Node, List<String>>{};
    for (int index = 0; index < sourceInline.length; index += 1) {
      final Element sourceElement = sourceInline[index];
      final Element translatedElement = translatedInline[index];
      final String sourceText = QualityScriptUtils.normalizeText(
        sourceElement.text,
      );
      final Node contextRoot =
          _nearestSemanticBlock(sourceElement) ??
          sourceDocument.body ??
          sourceDocument;
      final List<String> precedingRetainedNames = retainedNamesByBlock
          .putIfAbsent(contextRoot, () => <String>[]);
      final bool matchingCreditName =
          sourceText ==
              QualityScriptUtils.normalizeText(translatedElement.text) &&
          _hasRetainedProperNameContext(
            sourceDocument,
            sourceElement,
            precedingRetainedNames,
          );
      final bool matchingEpigraphAttribution = _isMatchingEpigraphAttribution(
        sourceElement,
        translatedElement,
      );
      if (sourceElement.localName == translatedElement.localName &&
          _elementStructurePath(sourceElement) ==
              _elementStructurePath(translatedElement) &&
          sourceElement.children.isEmpty &&
          translatedElement.children.isEmpty &&
          _looksLikeRetainedProperName(sourceText) &&
          (matchingCreditName || matchingEpigraphAttribution)) {
        retainedNameIndexes.add(index);
        precedingRetainedNames.add(sourceText);
      }
    }
    for (final int index in retainedNameIndexes) {
      sourceInline[index].text = '';
      translatedInline[index].text = '';
    }
  }

  static bool _isMatchingEpigraphAttribution(
    Element sourceElement,
    Element translatedElement,
  ) {
    if (!_isEpigraphAttributionLocation(sourceElement) ||
        !_isEpigraphAttributionLocation(translatedElement)) {
      return false;
    }
    final String? sourceName = _epigraphAttributionName(sourceElement.text);
    final String? translatedName = _epigraphAttributionName(
      translatedElement.text,
    );
    return sourceName != null &&
        translatedName != null &&
        sourceName == translatedName;
  }

  static bool _isEpigraphAttributionLocation(Element element) {
    final Node? paragraphNode = element.parentNode;
    if (paragraphNode is! Element || paragraphNode.localName != 'p') {
      return false;
    }
    if (!_hasEpigraphAttributionSemantics(paragraphNode)) {
      return false;
    }
    final Node? blockquoteNode = paragraphNode.parentNode;
    if (blockquoteNode is! Element ||
        blockquoteNode.localName != 'blockquote') {
      return false;
    }
    final List<Element> inlineCandidates = paragraphNode.querySelectorAll(
      'i, em, cite',
    );
    if (inlineCandidates.length != 1 ||
        !identical(inlineCandidates.single, element) ||
        _hasVisibleTextBeforeChild(paragraphNode, element) ||
        !_hasVisibleTextAfterChild(paragraphNode, element)) {
      return false;
    }
    final List<Element> visibleParagraphs = blockquoteNode.children
        .where(
          (Element child) =>
              child.localName == 'p' &&
              QualityScriptUtils.normalizeText(child.text).isNotEmpty,
        )
        .toList(growable: false);
    return visibleParagraphs.length >= 2 &&
        identical(visibleParagraphs.last, paragraphNode);
  }

  static bool _hasEpigraphAttributionSemantics(Element paragraph) {
    final Set<String> classTokens = paragraph.classes
        .map((String token) => token.toLowerCase())
        .toSet();
    const Set<String> recognizedClasses = <String>{
      'attribution',
      'epi-att',
      'epigraph-attribution',
      'epigraph-author',
      'quote-attribution',
      'quote-author',
    };
    return classTokens.any(recognizedClasses.contains);
  }

  static bool _hasVisibleTextBeforeChild(Element parent, Node target) {
    for (final Node child in parent.nodes) {
      if (identical(child, target)) {
        return false;
      }
      if (QualityScriptUtils.normalizeText(child.text ?? '').isNotEmpty) {
        return true;
      }
    }
    return true;
  }

  static bool _hasVisibleTextAfterChild(Element parent, Node target) {
    bool foundTarget = false;
    for (final Node child in parent.nodes) {
      if (identical(child, target)) {
        foundTarget = true;
        continue;
      }
      if (foundTarget &&
          QualityScriptUtils.normalizeText(child.text ?? '').isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static String? _epigraphAttributionName(String text) {
    final String normalized = QualityScriptUtils.normalizeText(text);
    final RegExpMatch? match = RegExp(
      r'^(?:[-\u2012\u2013\u2014\u2015]\s*)+(.+?)[,，;；:：]\s*$',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final String name = QualityScriptUtils.normalizeText(match.group(1) ?? '');
    return _canonicalRetainedPersonName(name);
  }

  static String? _canonicalRetainedPersonName(String name) {
    if (name.isEmpty || _looksLikeSentenceOrInstruction(name)) {
      return null;
    }
    for (final int rune in name.runes) {
      final bool allowedSeparator =
          rune == 0x20 ||
          rune == 0x27 ||
          rune == 0x2D ||
          rune == 0x2E ||
          rune == 0x2018 ||
          rune == 0x2019;
      if (!QualityScriptUtils.isLatinLetterRune(rune) &&
          !QualityScriptUtils.isCombiningDiacriticalMark(rune) &&
          !allowedSeparator) {
        return null;
      }
    }
    final List<String> words = QualityScriptUtils.englishWorkTitleWords(name);
    if (words.length < 2 || words.length > 6) {
      return null;
    }
    if (const <String>{
      'a',
      'an',
      'the',
      'this',
      'these',
      'those',
    }.contains(words.first.toLowerCase())) {
      return null;
    }
    const Set<String> nameParticles = <String>{
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
    for (final String word in words) {
      if (nameParticles.contains(word.toLowerCase())) {
        continue;
      }
      final String first = String.fromCharCode(word.runes.first);
      if (first != first.toUpperCase() || first == first.toLowerCase()) {
        return null;
      }
    }
    return words.join(' ');
  }

  static bool _looksLikeRetainedProperName(String text) {
    final List<String> words = QualityScriptUtils.englishWorkTitleWords(text);
    if (words.length < 2 || words.length > 6) {
      return false;
    }
    const Set<String> nameParticles = <String>{
      'and',
      'da',
      'de',
      'del',
      'der',
      'di',
      'dos',
      'du',
      'la',
      'le',
      'of',
      'the',
      'van',
      'von',
    };
    final List<String> significantWords = words
        .where((String word) => !nameParticles.contains(word.toLowerCase()))
        .toList();
    if (significantWords.isEmpty) {
      return false;
    }
    final int titleCaseOrInitialWords = significantWords.where((String word) {
      final String first = String.fromCharCode(word.runes.first);
      return first == first.toUpperCase() && first != first.toLowerCase();
    }).length;
    return titleCaseOrInitialWords / significantWords.length > 0.5;
  }

  static bool _hasRetainedProperNameContext(
    Document sourceDocument,
    Element sourceElement,
    List<String> precedingRetainedNames,
  ) {
    final String precedingText = _sourceTextBeforeNode(
      sourceDocument,
      sourceElement,
      maxLength: null,
    ).toLowerCase();
    final List<RegExpMatch> creditCues = RegExp(
      r'\b(?:(?:written|edited|designed|illustrated|translated|photographed|compiled|created)\s+by|(?:book|cover|jacket)\s+design\s+by|(?:graphics|illustrations|art)\s+by)\s*(?:[:\-–—]\s*)?',
    ).allMatches(precedingText).toList();
    if (creditCues.isEmpty) {
      return false;
    }
    String remaining = precedingText.substring(creditCues.last.end).trim();
    if (remaining.isEmpty) {
      return true;
    }
    bool consumedRetainedName = false;
    for (final String retainedName in precedingRetainedNames) {
      final String normalizedName = retainedName.toLowerCase();
      if (!_startsWithWholeCreditName(remaining, normalizedName)) {
        continue;
      }
      remaining = remaining.substring(normalizedName.length).trimLeft();
      remaining = remaining.replaceFirst(
        RegExp(r'^(?:(?:and\b|&|[,;])\s*)+'),
        '',
      );
      consumedRetainedName = true;
    }
    return consumedRetainedName && remaining.trim().isEmpty;
  }

  static bool _startsWithWholeCreditName(String text, String name) {
    if (!text.startsWith(name)) {
      return false;
    }
    if (text.length == name.length) {
      return true;
    }
    final String next = text.substring(name.length, name.length + 1);
    return RegExp(r'[\s,&;]').hasMatch(next);
  }

  /// Work titles appearing inside source-language `<i>/<em>/<cite>` nodes.
  /// Computed before any clearing logic, so retained titles can be verified
  /// even after the source copies are scrubbed from the parsed document.
  static Set<String> _sourceInlineWorkTitles(Document document) {
    return document
        .querySelectorAll('i, em, cite')
        .map(
          (Element element) => _normalizedWorkTitleText(
            QualityScriptUtils.normalizeText(element.text),
          ),
        )
        .where(
          (String title) =>
              title.isNotEmpty && _looksLikeEnglishWorkTitle(title),
        )
        .toSet();
  }

  static bool _hasRemainingTranslatedInlineResidual(
    Document translatedDocument, {
    required Set<String> sourceInlineWorkTitles,
  }) {
    return translatedDocument
        .querySelectorAll('i, em, cite')
        .any(
          (Element element) =>
              _looksLikeEnglishWorkTitle(
                QualityScriptUtils.normalizeText(element.text),
              ) &&
              !sourceInlineWorkTitles.contains(
                _normalizedWorkTitleText(
                  QualityScriptUtils.normalizeText(element.text),
                ),
              ),
        );
  }

  /// Clears matching retained work-title nodes from `<i>/<em>/<cite>` in both
  /// the source and translated documents, so a title kept verbatim in its own
  /// emphasis node is not later misread as untranslated source prose. A
  /// title-like node in the translation is only cleared when an equivalent
  /// source node exists, keeping genuinely untranslated emphasis prose intact.
  static void _clearInlineEmphasisTitleNodes(
    Document sourceDocument,
    Document translatedDocument,
  ) {
    // Only clear retained title nodes when the surrounding block was actually
    // translated (has target-script context). A block that is still entirely
    // English — for example an untranslated emphasized instruction like
    // `Important Safety Information For All New Device Owners Today` — must
    // not be exempted just because its emphasis text is title-cased.
    final String translatedBody =
        translatedDocument.body?.text ?? translatedDocument.text ?? '';
    final bool hasTargetScriptContext = RegExp(
      r'[\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).hasMatch(translatedBody);
    if (!hasTargetScriptContext) {
      return;
    }
    final List<Element> sourceTitles = sourceDocument
        .querySelectorAll('i, em, cite')
        .where(
          (Element element) =>
              _looksLikeEnglishWorkTitle(
                QualityScriptUtils.normalizeText(element.text),
              ) &&
              !_looksLikeSentenceOrInstruction(
                QualityScriptUtils.normalizeText(element.text),
              ),
        )
        .toList(growable: false);
    // Imperative / instruction-like emphasis (for example
    // `Please Read All Instructions Before Continuing`) is never a work title
    // even when it is title-cased, so leave it in place to be caught by the
    // residual checks.
    final List<Element> translatedTitles = translatedDocument
        .querySelectorAll('i, em, cite')
        .where(
          (Element element) =>
              _looksLikeEnglishWorkTitle(
                QualityScriptUtils.normalizeText(element.text),
              ) &&
              !_looksLikeSentenceOrInstruction(
                QualityScriptUtils.normalizeText(element.text),
              ),
        )
        .toList(growable: false);
    for (final Element translatedTitle in translatedTitles) {
      final String normalized = _normalizedWorkTitleText(
        QualityScriptUtils.normalizeText(translatedTitle.text),
      );
      if (normalized.isEmpty) {
        continue;
      }
      for (final Element sourceTitle in sourceTitles) {
        if (_normalizedWorkTitleText(
              QualityScriptUtils.normalizeText(sourceTitle.text),
            ) ==
            normalized) {
          translatedTitle.text = '';
          sourceTitle.text = '';
          break;
        }
      }
    }
  }

  static bool _hasSourceOwnedShortEnglishProse(
    Document sourceDocument,
    Document translatedDocument, {
    bool isBibliographicEntry = false,
  }) {
    if (isBibliographicEntry) {
      // A bibliography / endnote entry conventionally keeps several fields in
      // the original language: author names, journal names, volume/issue/year
      // and page numbers, publisher and city. These retained fields appear as
      // `allSourceEnglishRetained` text nodes that are exactly the same in the
      // source and the translation, so the per-node prose check below would
      // mistake them for untranslated sentences. When the surrounding entry was
      // actually translated (it contains target-script text), skip the per-node
      // check; a completely untranslated entry is still rejected because no
      // target-script context exists to gate this exemption.
      final String translatedBody =
          translatedDocument.body?.text ?? translatedDocument.text ?? '';
      final bool hasTargetScriptContext = RegExp(
        r'[\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
      ).hasMatch(translatedBody);
      if (hasTargetScriptContext) {
        return false;
      }
    }
    // Retained work titles inside their own `<i>/<em>/<cite>` nodes are
    // deliberate (for example the newsletter title <i>Strategic Investment</i>
    // kept verbatim inside otherwise-translated prose). Clear the matching
    // source/translation title nodes before the pairwise text-node comparison
    // so they are not mistaken for untranslated source prose.
    _clearInlineEmphasisTitleNodes(sourceDocument, translatedDocument);
    final List<Text> sourceTextNodes = _textNodes(sourceDocument);
    final List<Text> translatedTextNodes = _textNodes(translatedDocument);
    if (sourceTextNodes.length == translatedTextNodes.length) {
      for (int index = 0; index < sourceTextNodes.length; index += 1) {
        if (_hasSuspiciousSourceOwnedEnglishText(
          sourceTextNodes[index].data,
          translatedTextNodes[index].data,
        )) {
          return true;
        }
      }
      return false;
    }
    return _hasSuspiciousSourceOwnedEnglishText(
      sourceDocument.body?.text ?? sourceDocument.text ?? '',
      translatedDocument.body?.text ?? translatedDocument.text ?? '',
    );
  }

  static List<Text> _textNodes(Document document) {
    final List<Text> result = <Text>[];

    void collect(Node node) {
      if (node is Text) {
        result.add(node);
        return;
      }
      if (node is Element &&
          const <String>{'script', 'style'}.contains(node.localName)) {
        return;
      }
      for (final Node child in node.nodes) {
        collect(child);
      }
    }

    collect(document.body ?? document);
    return result;
  }

  static bool _hasSuspiciousSourceOwnedEnglishText(
    String sourceText,
    String translatedText,
  ) {
    final String strippedSource = QualityScriptUtils.stripNonLinguisticTokens(
      sourceText,
    );
    final String strippedTranslated =
        QualityScriptUtils.stripNonLinguisticTokens(translatedText);
    final List<String> sourceWords = QualityScriptUtils.englishWorkTitleWords(
      strippedSource,
    );
    final List<String> translatedWords =
        QualityScriptUtils.englishWorkTitleWords(strippedTranslated);
    if (sourceWords.length < 2 || translatedWords.length < 2) {
      return false;
    }

    final bool hasTargetLanguageContext = RegExp(
      r'[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
    ).hasMatch(strippedTranslated);
    final bool allSourceEnglishRetained =
        sourceWords.length == translatedWords.length &&
        _sameWordsIgnoreCase(sourceWords, translatedWords);
    if (allSourceEnglishRetained) {
      if (!hasTargetLanguageContext) {
        // A lone retained epigraph attribution (`—CHARLES TILLY`) is a
        // deliberate retention, not an untranslated sentence. Requiring the
        // leading dash keeps ordinary unmodified `sig` text (for example
        // `Peter Thiel` or `Los Angeles`) out of this exemption.
        if (RegExp(r'^[-–—]').hasMatch(strippedSource.trim())) {
          final String name = QualityScriptUtils.normalizeText(
            strippedSource,
          ).replaceFirst(RegExp(r'^[-–—]\s*'), '');
          if (_canonicalRetainedPersonName(name) != null) {
            return false;
          }
        }
        // A short all-lowercase transliteration/term retained verbatim in
        // both source and translated inline node (for example the pinyin
        // gloss `chum yum`) is a deliberate term retention, not an
        // untranslated sentence. Only very short lowercase runs qualify so
        // title-case proper names such as `Peter Thiel` or `Los Angeles`
        // and full English sentences still fail.
        if (_looksLikeSentenceOrInstruction(strippedTranslated) ||
            isCommonInstructionPhrase(strippedTranslated) ||
            RegExp(r'[.!?。！？]').hasMatch(strippedTranslated)) {
          return true;
        }
        final bool isShortLowercaseTransliteration =
            translatedWords.isNotEmpty &&
            translatedWords.length <= 4 &&
            translatedWords.every(
              (String word) => word == word.toLowerCase(),
            ) &&
            !RegExp(r'[.!?]').hasMatch(strippedTranslated) &&
            // P2-#20: common instruction/signal phrases ("do not enter")
            // are ordinary untranslated prose, not transliterated terms.
            !isCommonInstructionPhrase(strippedTranslated);
        if (isShortLowercaseTransliteration) {
          return false;
        }
        return true;
      }
      // A retained English work title inside an otherwise-translated inline
      // node (for example 《道德与立法原理导论》（An Introduction to the
      // Principles of Morals and Legislation）) is a deliberate original-title
      // gloss marked with CJK book-title brackets. Exempt it before the
      // sentence-ending heuristic so a book title whose source ends with a
      // period is not mistaken for a lone untranslated sentence.
      final bool isCjkMarkedTitle =
          QualityResidualDetector.looksLikeEnglishTitleOrName(
            translatedWords,
          ) &&
          RegExp(r'[《「『〈》」』〉]').hasMatch(strippedTranslated);
      if (isCjkMarkedTitle) {
        return false;
      }
      final bool hasSentenceEnding = RegExp(
        r'''[.!?]["'\u2019\u201D)\]]*\s*$''',
      ).hasMatch(strippedSource.trim());
      if (translatedWords.length >= 3 && hasSentenceEnding) {
        return true;
      }
      if (_looksLikeSentenceOrInstruction(strippedSource)) {
        return true;
      }
      if (QualityResidualDetector.looksLikeEnglishTitleOrName(
        translatedWords,
      )) {
        return false;
      }
      final bool isStandaloneLowercaseTerm =
          translatedWords.every((String word) => word == word.toLowerCase()) &&
          !RegExp(r'[.!?]').hasMatch(strippedSource);
      return !isStandaloneLowercaseTerm;
    }

    late final glosses = ParenthesizedTermGlossIndex(strippedTranslated);
    for (final List<String> run in _englishRunsSeparatedByTargetScript(
      strippedTranslated,
    )) {
      if (run.length < 2 ||
          !_containsWordSequenceIgnoreCase(sourceWords, run)) {
        continue;
      }
      if (_canonicalRetainedPersonName(run.join(' ')) != null) {
        continue;
      }
      if (QualityResidualDetector.looksLikeEnglishTitleOrName(run) &&
          !_looksLikeSentenceOrInstruction(run.join(' ')) &&
          !isCommonInstructionPhrase(run.join(' '))) {
        continue;
      }
      // Legal case names such as `Roe v. Wade` (or the embedded form
      // `Roe v. Wade案`) are conventionally retained verbatim in translated
      // legal/commentary prose. Recognize the `X v. Y` shape so these
      // retentions are not treated as untranslated sentences.
      if (QualityResidualDetector.looksLikeLegalCaseName(run)) {
        continue;
      }
      // An original-term gloss in parentheses after a Chinese translation
      // (for example 南方黑手党（Dixie mafia）) is a deliberate first-use
      // retention. The run may contain a lowercase ordinary word (`mafia`),
      // so it is not title-like, but it still sits inside the parenthesized
      // gloss and must not be treated as untranslated prose.
      final String runText = run.join(' ');
      if (glosses.contains(runText)) {
        continue;
      }
      final bool allLowercase = run.every(
        (String word) => word == word.toLowerCase(),
      );
      final double sourceCoverage = run.length / sourceWords.length;
      if (hasTargetLanguageContext &&
          allLowercase &&
          run.length <= 4 &&
          sourceCoverage < 0.75) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// P2-#20: short lowercase signage/instruction phrases that must never be
  /// mistaken for transliterated terms (e.g. `<p>do not enter</p>` left
  /// untranslated). Compared against the stripped text node.
  /// Test hook for P2-#12: boundary-punctuation stripping before the
  /// common-instruction-phrase denylist lookup.
  static bool isCommonInstructionPhraseForTest(String text) =>
      isCommonInstructionPhrase(text);

  static bool isCommonInstructionPhrase(String text) {
    // P2-#12: strip boundary punctuation before matching, so "no smoking:"
    // and "keep out;" are still recognized instead of being exempted.
    final String normalized = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'^[\p{P}]+|[\p{P}]+$', unicode: true), '');
    return _commonInstructionPhrases.contains(normalized);
  }

  static const Set<String> _commonInstructionPhrases = <String>{
    'do not enter',
    'no entry',
    'no admittance',
    'keep out',
    'do not disturb',
    'no smoking',
    'no trespassing',
    'do not touch',
    'no parking',
    'no photographs',
    'no photos',
    'do not feed',
    'mind the gap',
    'no littering',
    'do not litter',
    'keep off the grass',
    'staff only',
    'no exit',
    'do not cross',
    'do not lean',
    'no loitering',
    'do not block',
    'keep clear',
    'do not use',
    'beware of dog',
    'do not spit',
    'no spitting',
    'keep right',
    'keep left',
    'slow down',
    'give way',
  };

  static bool _sameWordsIgnoreCase(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (int index = 0; index < left.length; index += 1) {
      if (left[index].toLowerCase() != right[index].toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  static List<List<String>> _englishRunsSeparatedByTargetScript(String text) {
    final List<List<String>> runs = <List<String>>[];
    List<String> current = <String>[];

    void finishRun() {
      if (current.isNotEmpty) {
        runs.add(current);
        current = <String>[];
      }
    }

    for (final RegExpMatch match in RegExp(
      r"[A-Za-z][A-Za-z'’\-]*|[\u0400-\u04FF\u0600-\u06FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]",
    ).allMatches(text)) {
      final String token = match.group(0) ?? '';
      if (RegExp(r'^[A-Za-z]').hasMatch(token)) {
        current.add(token.replaceAll('’', "'"));
      } else {
        finishRun();
      }
    }
    finishRun();
    return runs;
  }

  static bool _containsWordSequenceIgnoreCase(
    List<String> words,
    List<String> candidate,
  ) {
    if (candidate.length > words.length) {
      return false;
    }
    for (int start = 0; start <= words.length - candidate.length; start += 1) {
      bool matches = true;
      for (int index = 0; index < candidate.length; index += 1) {
        if (words[start + index].toLowerCase() !=
            candidate[index].toLowerCase()) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }
}
