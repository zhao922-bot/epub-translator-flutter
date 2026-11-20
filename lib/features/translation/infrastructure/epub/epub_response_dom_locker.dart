part of 'epub_chapter_translator.dart';

/// Locks translated XHTML structure against source DOM slots and normalizes
/// protected inline/anchor markers and CJK target markup.
class _EpubResponseDomLocker {
  const _EpubResponseDomLocker._();

  static String _lockAndValidateTranslatedBlock({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String translatedHtml,
    Map<String, int>? instrumentation,
    bool rejectEmptyResponse = false,
    void Function(String html, String text)? onLocked,
  }) {
    final replyDom = _cleanResponseDom(
      translatedHtml,
      sourceText: block.sourceText,
      instrumentation: instrumentation,
      rejectEmptyResponse: rejectEmptyResponse,
    );
    return _lockAndValidateTranslatedBlockDom(
      config: config,
      block: block,
      replyDom: replyDom,
      instrumentation: instrumentation,
      onLocked: onLocked,
    );
  }

  /// Single-parse entry: [replyDom] is the already-parsed model reply (see
  /// _cleanResponseDom), so the reply is never parsed twice for one block.
  static String _lockAndValidateTranslatedBlockDom({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml replyDom,
    Map<String, int>? instrumentation,
    void Function(String html, String text)? onLocked,
  }) {
    final sourceDom = _ResponseHtml.parse(block.sourceHtml, instrumentation);
    final locked = _lockResponseDom(sourceDom, replyDom);
    final html = locked.html;
    // Single-block quality retries/degrades must retain the usable locked
    // response even when validation below rejects residual source text.
    onLocked?.call(html, locked.plainText);
    _validateTranslatedBlockQuality(
      config: config,
      block: block,
      sourceDom: sourceDom,
      translatedDom: locked,
    );
    return html;
  }

  static String _lockHtmlStructure({
    required String sourceHtml,
    required String translatedHtml,
    Map<String, int>? instrumentation,
  }) {
    final sourceDom = _ResponseHtml.parse(sourceHtml, instrumentation);
    final replyDom = _cleanResponseDom(
      translatedHtml,
      sourceText: sourceDom.plainText,
      instrumentation: instrumentation,
    );
    return _lockResponseDom(sourceDom, replyDom).html;
  }

  static _ResponseHtml _lockResponseDom(
    _ResponseHtml sourceDom,
    _ResponseHtml replyDom,
  ) {
    _validateNonemptyDoms(sourceDom, replyDom);
    // Anchor normalization and protected restoration mutate the working reply.
    // Keep the model's original DOM for language alignment, without reparsing.
    final modelDom = _ResponseHtml(
      replyDom.fragment.clone(true),
      replyDom.instrumentation,
    );
    final locked = _lockHtmlStructureCore(
      sourceDom: sourceDom,
      translatedDom: replyDom,
    );
    final source = sourceDom.root;
    final model = modelDom.root;
    final result = locked.root;
    if (source == null || model == null || result == null) return locked;
    late final textAlignment = _ResponseTextAlignment(
      modelDom.facts,
      locked.facts,
    );
    void preserve(dom.Element original, dom.Element reply, dom.Element output) {
      if (original.localName != reply.localName ||
          original.localName != output.localName ||
          EpubHtmlExtractor.nonTextAncestors.contains(
            EpubHtmlExtractor.tagLocalName(original),
          )) {
        return;
      }
      // Only carry language metadata on an unambiguously aligned subtree.
      // Source IDs, links and all other attributes remain source-owned.
      if (!original.attributes.containsKey('lang') &&
          !original.attributes.containsKey('xml:lang') &&
          (reply.attributes.containsKey('lang') ||
              reply.attributes.containsKey('xml:lang')) &&
          textAlignment.matches(reply, output)) {
        final language =
            reply.attributes['lang'] ?? reply.attributes['xml:lang'];
        final xmlLanguage = reply.attributes['xml:lang'];
        if (language != null &&
            RegExp(
              r'^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$',
            ).hasMatch(language) &&
            (xmlLanguage == null || xmlLanguage == language)) {
          output.attributes['lang'] = language;
          output.attributes['xml:lang'] = language;
        }
      }
      if (original.children.length != reply.children.length ||
          original.children.length != output.children.length) {
        return;
      }
      for (var i = 0; i < original.children.length; i++) {
        preserve(original.children[i], reply.children[i], output.children[i]);
      }
    }

    preserve(source, model, result);
    return locked;
  }

  /// Apply the strategy's wrapper rules using the same DOM that structure
  /// handling will consume. Its string cleaner parses both markup and plain
  /// text separately, so calling it here would hide two additional parses.
  static _ResponseHtml _cleanResponseDom(
    String response, {
    required String sourceText,
    Map<String, int>? instrumentation,
    bool rejectEmptyResponse = false,
  }) {
    String value = response.trim();
    final fence = RegExp(
      r'^```(?:html|xhtml)?\s*\n([\s\S]*?)\n```$',
      caseSensitive: false,
    ).firstMatch(value);
    if (fence != null) value = fence.group(1)!.trim();
    if (rejectEmptyResponse && value.isEmpty) {
      throw const FormatException(
        'The translation API returned an empty block.',
      );
    }
    _responseCount(instrumentation, 'replyParses');
    final _ResponseHtml reply;
    try {
      reply = _ResponseHtml.parse(value, instrumentation);
    } on InvalidEpubXmlCharacterException catch (error) {
      // A malformed model reply follows the existing per-block retry/source
      // fallback policy. Invalid source/cache files retain their format error.
      throw TranslationParseException(error.message);
    }
    final hasMarkup = reply.fragment.nodes.any((node) => node is dom.Element);
    if (TranslationResponseGuard.isNonTranslationReply(
      sourceText: sourceText,
      translatedText: reply.plainText,
    )) {
      throw const NonTranslationReplyException();
    }
    final hasOutsideText = reply.fragment.nodes.any(
      (node) => node is dom.Text && node.data.trim().isNotEmpty,
    );
    if (value.contains('```') ||
        _EpubTranslationStrategy._hasTranslationExplanationPrefix(value) ||
        (hasMarkup && hasOutsideText) ||
        _EpubTranslationStrategy._hasTranslationExplanationPrefix(
          reply.plainText,
        ) ||
        _EpubTranslationStrategy._hasMarkdownWrapper(value) ||
        _EpubTranslationStrategy._hasUnexpectedJsonWrapper(
          sourceText: sourceText,
          translatedText: value,
        )) {
      throw const TranslationParseException(
        'HTML translation contains wrapper content.',
      );
    }
    return reply;
  }

  static _ResponseHtml _lockHtmlStructureCore({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final _NormalizedAnchorHtml normalizedTranslation =
        _normalizeProtectedAnchorMarkers(
          sourceDom: sourceDom,
          translatedDom: translatedDom,
        );
    if (normalizedTranslation.hasOverflow &&
        normalizedTranslation.root != null &&
        _elementSkeletonMatches(sourceDom.root!, normalizedTranslation.root!) &&
        _overflowTextFitsSourceSlots(
          sourceDom: sourceDom,
          translatedDom: translatedDom,
          trustedOverflowTexts: normalizedTranslation.trustedOverflowTexts,
        )) {
      translatedDom.invalidate();
      return translatedDom;
    }
    if (_domStructureMatches(sourceDom, translatedDom)) {
      final _ResponseHtml? restored = _restoreProtectedTexts(
        sourceDom: sourceDom,
        translatedDom: translatedDom,
      );
      if (restored != null) {
        return restored;
      }
    }
    // Models sometimes fold small-caps authored spans (e.g.
    // <span class="smallcaps">EES</span>) into plain text
    // ("REES DAVIES"). That changes the element skeleton, so the normal
    // structure-matching path above fails and the rebuild path misplaces
    // text. Flatten those spans on the source side; if the flattened source
    // skeleton now matches the translation, restore text into it and return.
    if (sourceDom.html.contains('smallcaps')) {
      final _ResponseHtml? flattenedRestored = _restoreWithFlattenedSmallcaps(
        sourceDom: sourceDom,
        translatedDom: translatedDom,
      );
      if (flattenedRestored != null) {
        return flattenedRestored;
      }
    }
    final dom.Element? sourceRoot = sourceDom.root;
    if (sourceRoot == null) {
      return translatedDom;
    }
    final dom.Element rebuiltRoot = sourceRoot.clone(true);
    final rebuilt = _ResponseHtml.fromRoot(
      rebuiltRoot,
      sourceDom.instrumentation,
    );
    final List<_HtmlTextSlot> sourceSlots = rebuilt.slots;
    if (sourceSlots.isEmpty) {
      return rebuilt;
    }

    final List<_HtmlTextSlot> translatedSlots = translatedDom.slots;
    // P2-#7: effective protection is positional, not tag-based. A response
    // protected slot keeps its protected status only when the source has a
    // protected slot with the same (protecting tag, ordinal within that
    // tag); a protected-kind element the model introduced (an extra <code>,
    // a moved marker, ...) holds real translation text and must not be
    // dropped as protected content. 性能-#42: decided once per slot in a
    // single pass and cached — the old code walked up the ancestor chain
    // once per filter pass.
    final Map<String, int> sourceProtectedCounts = _protectedSlotCountsByTag(
      rebuilt,
      sourceSlots,
    );
    final Map<dom.Text, bool> effectiveProtectedByNode =
        Map<dom.Text, bool>.identity();
    final Map<dom.Element, bool> effectiveProtectedByElement =
        Map<dom.Element, bool>.identity();
    final Map<dom.Text, int> writableIndexByNode =
        Map<dom.Text, int>.identity();
    final List<String> writableTranslatedTexts = <String>[];
    int protectedTranslatedCount = 0;
    final Map<String, int> seenProtectedByTag = <String, int>{};
    for (final _HtmlTextSlot slot in translatedSlots) {
      if (!slot.protected) {
        if (slot.text.isNotEmpty) {
          writableIndexByNode[slot.node] = writableTranslatedTexts.length;
          writableTranslatedTexts.add(slot.text);
        }
        continue;
      }
      final String tag = _nearestProtectingTag(translatedDom, slot.node) ?? '';
      final int ordinal = seenProtectedByTag[tag] ?? 0;
      seenProtectedByTag[tag] = ordinal + 1;
      final bool effective =
          tag == 'script' ||
          tag == 'style' ||
          ordinal < (sourceProtectedCounts[tag] ?? 0);
      effectiveProtectedByNode[slot.node] = effective;
      dom.Node? ancestor = slot.node.parentNode;
      while (ancestor is dom.Element) {
        if (translatedDom.isProtected(ancestor)) {
          effectiveProtectedByElement[ancestor] = effective;
          break;
        }
        ancestor = ancestor.parentNode;
      }
      if (slot.text.isEmpty) {
        continue;
      }
      if (effective) {
        protectedTranslatedCount++;
      } else {
        writableIndexByNode[slot.node] = writableTranslatedTexts.length;
        writableTranslatedTexts.add(slot.text);
      }
    }
    // Whitespace-only protected-kind wrappers have no slots. Resolve them
    // using the same source-counterpart fallback before collecting gaps.
    for (final element in translatedDom.fragment.querySelectorAll('*')) {
      if (translatedDom.isProtected(element)) {
        effectiveProtectedByElement.putIfAbsent(element, () {
          final String tag = EpubHtmlExtractor.tagLocalName(element);
          return tag == 'script' ||
              tag == 'style' ||
              (sourceProtectedCounts[tag] ?? 0) > 0;
        });
      }
    }
    // Positional mapping must pair unprotected slots with unprotected
    // slots: protected slots (footnote markers, page breaks, code) keep
    // their source text, so consuming translation texts across the
    // protected boundary would silently drop real translation text and
    // duplicate marker text whenever the model moves a marker to another
    // position. Fall back to the plain-text path when the protected counts
    // do not line up either.
    final List<_HtmlTextSlot> writableSourceSlots = sourceSlots
        .where((_HtmlTextSlot slot) => !slot.protected)
        .toList(growable: false);
    final int protectedSourceCount =
        sourceSlots.length - writableSourceSlots.length;

    if (writableTranslatedTexts.length == writableSourceSlots.length &&
        protectedTranslatedCount == protectedSourceCount) {
      // P2-#6: standalone whitespace-only text nodes never become slots, so
      // writing slot texts alone would drop them and glue words the model
      // separated with standalone whitespace. Fold each into the adjacent
      // slot text so the written text sequence keeps the response's word
      // separation.
      final Map<dom.Text, int> writableSourceIndexByNode =
          Map<dom.Text, int>.identity();
      for (int index = 0; index < writableSourceSlots.length; index += 1) {
        writableSourceIndexByNode[writableSourceSlots[index].node] = index;
      }
      final List<String> finalTexts = _withStandaloneWhitespace(
        translatedDom,
        writableTranslatedTexts,
        writableIndexByNode,
        rebuilt,
        writableSourceIndexByNode,
        effectiveProtectedByElement,
      );
      for (int index = 0; index < writableSourceSlots.length; index += 1) {
        writableSourceSlots[index].text = finalTexts[index];
      }
      rebuilt.invalidate();
      return rebuilt;
    }

    // P2-#13: rebuild the plain text from every non-protected text node,
    // including whitespace-only ones that never become slots, so words the
    // model separated with standalone whitespace do not glue together.
    // Protected source slots retain their text; including genuinely
    // protected response text here would duplicate it in the first writable
    // source slot.
    final String translatedPlainText = _unprotectedResponseText(
      translatedDom,
      effectiveProtectedByNode,
      effectiveProtectedByElement,
    );
    bool wroteMainText = false;
    final List<({_HtmlTextSlot slot, String sourceText})> emptiedSlots =
        <({_HtmlTextSlot slot, String sourceText})>[];
    for (final _HtmlTextSlot slot in sourceSlots) {
      if (slot.protected) {
        continue;
      }
      if (!wroteMainText) {
        slot.text = translatedPlainText;
        wroteMainText = true;
      } else {
        final String sourceText = slot.text;
        slot.text = '';
        emptiedSlots.add((slot: slot, sourceText: sourceText));
      }
    }
    _removeEmptiedInlineEmphasis(emptiedSlots);
    rebuilt.invalidate();
    return rebuilt;
  }

  /// If [sourceDom] contains `<span class="smallcaps">` nodes that the
  /// translation folded into a single plain text run, return a version of the
  /// source with those spans flattened so the skeletons match and the
  /// translation text can be restored positionally. Returns null when the
  /// flattened source still does not align with the translation.
  static _ResponseHtml? _restoreWithFlattenedSmallcaps({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return null;
    }
    // Flatten smallcaps spans in a clone of the source root.
    final dom.Element flattened = sourceRoot.clone(true);
    bool changed = false;
    bool retainedSemanticSpan = false;
    for (final dom.Element span
        in flattened.querySelectorAll('span').toList(growable: false)) {
      final String cls = span.className.toLowerCase();
      if (!cls.split(RegExp(r'\s+')).contains('smallcaps')) {
        continue;
      }
      if (_spanHasSemanticAttributes(span)) {
        span.classes.removeWhere(_isSmallCapsClass);
        changed = true;
        retainedSemanticSpan = true;
        continue;
      }
      final List<dom.Node> children = span.nodes.toList(growable: false);
      for (final dom.Node child in children) {
        span.parentNode?.insertBefore(child.clone(true), span);
      }
      span.remove();
      changed = true;
    }
    if (!changed) {
      return null;
    }
    // Unwrapping spans leaves adjacent Text nodes. The former serialize/parse
    // round-trip merged these; do that directly so positional matching retains
    // the same text-slot boundaries without another parse.
    _mergeAdjacentTextNodes(flattened);
    final flattenedDom = _ResponseHtml.fromRoot(
      flattened,
      sourceDom.instrumentation,
    );
    if (!_domStructureMatches(flattenedDom, translatedDom)) {
      if (!retainedSemanticSpan) return null;
      return _lockHtmlStructureCore(
        sourceDom: flattenedDom,
        translatedDom: translatedDom,
      );
    }
    final _ResponseHtml? restored = _restoreProtectedTexts(
      sourceDom: flattenedDom,
      translatedDom: translatedDom,
    );
    if (restored == null) {
      return null;
    }
    // The translation folded the small-caps spans into plain uppercase text.
    // Return the restored translation inside the flattened source skeleton.
    // (The authored small-caps spans are not re-introduced here; the content
    // and structure are correct, which is what downstream validation needs.)
    return restored;
  }

  static void _mergeAdjacentTextNodes(dom.Node parent) {
    dom.Text? previous;
    for (final node in parent.nodes.toList(growable: false)) {
      if (node is dom.Text) {
        if (previous == null) {
          previous = node;
        } else {
          previous.data += node.data;
          node.remove();
        }
      } else {
        previous = null;
        _mergeAdjacentTextNodes(node);
      }
    }
  }

  /// After rebuilding the source skeleton, inline emphasis wrappers whose
  /// source text is an audited foreign term and that were emptied (for example
  /// `<i class="calibre3">agri deserti,</i>` when the model folded the whole
  /// translation into the first text slot) are removed. Keeping them would
  /// make the residual checker treat the emptied node as an untranslated
  /// audited term and reject a perfectly valid translation. Ordinary empty
  /// emphasis wrappers are preserved so source skeletons stay stable.
  static void _removeEmptiedInlineEmphasis(
    List<({_HtmlTextSlot slot, String sourceText})> emptiedSlots,
  ) {
    final Set<dom.Element> candidates = <dom.Element>{};
    for (final ({_HtmlTextSlot slot, String sourceText}) entry
        in emptiedSlots) {
      if (!TranslationQuality.isAuditedForeignTermNodeText(
        entry.sourceText.trim(),
      )) {
        continue;
      }
      final dom.Node? parent = entry.slot.node.parentNode;
      if (parent is dom.Element &&
          (parent.localName == 'i' || parent.localName == 'em')) {
        candidates.add(parent);
      }
    }
    for (final dom.Element element in candidates) {
      if (element.children.isNotEmpty || element.text.trim().isNotEmpty) {
        continue;
      }
      element.remove();
    }
  }

  static bool _overflowTextFitsSourceSlots({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
    required List<dom.Text> trustedOverflowTexts,
  }) {
    final int sourceTextSlots = sourceDom.slots
        .where((_HtmlTextSlot slot) => !slot.protected)
        .length;
    final List<_HtmlTextSlot> untrustedTranslatedSlots = translatedDom.slots
        .where(
          (_HtmlTextSlot slot) =>
              !slot.protected && !trustedOverflowTexts.contains(slot.node),
        )
        .toList(growable: false);
    if (untrustedTranslatedSlots.length <= sourceTextSlots) {
      return true;
    }
    if (sourceTextSlots != 0) {
      return false;
    }
    for (final _HtmlTextSlot slot in untrustedTranslatedSlots) {
      slot.text = '';
    }
    return true;
  }

  static _ResponseHtml? _restoreProtectedTexts({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return translatedDom;
    }

    final List<_HtmlTextSlot> sourceSlots = sourceDom.slots;
    final List<_HtmlTextSlot> translatedSlots = translatedDom.slots;
    if (sourceSlots.length != translatedSlots.length) {
      return null;
    }

    for (int index = 0; index < sourceSlots.length; index += 1) {
      if (sourceSlots[index].protected) {
        translatedSlots[index].text = sourceSlots[index].text;
      }
    }
    translatedDom.invalidate();
    return translatedDom;
  }

  static bool _elementSkeletonMatches(
    dom.Element source,
    dom.Element translated, {
    Iterable<dom.Node> ignoredTranslatedNodes = const <dom.Node>[],
  }) {
    if (source.localName != translated.localName ||
        !_attributesMatch(source, translated)) {
      return false;
    }
    final List<dom.Element> sourceChildren = source.children.toList(
      growable: false,
    );
    final List<dom.Element> translatedChildren = translated.children.toList(
      growable: true,
    )..removeWhere(ignoredTranslatedNodes.contains);
    if (sourceChildren.length != translatedChildren.length) {
      return false;
    }
    for (int index = 0; index < sourceChildren.length; index += 1) {
      if (!_elementSkeletonMatches(
        sourceChildren[index],
        translatedChildren[index],
        ignoredTranslatedNodes: ignoredTranslatedNodes,
      )) {
        return false;
      }
    }
    return true;
  }

  static _NormalizedAnchorHtml _normalizeProtectedAnchorMarkers({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return const _NormalizedAnchorHtml();
    }
    final List<String> overflowTexts = <String>[];
    final List<dom.Text> trustedOverflowTexts = <dom.Text>[];
    _normalizePairedProtectedAnchors(
      sourceRoot,
      translatedRoot,
      overflowTexts,
      trustedOverflowTexts,
      sourceDom,
    );
    translatedDom.invalidate();
    return _NormalizedAnchorHtml(
      root: translatedRoot,
      hasOverflow: overflowTexts.isNotEmpty,
      trustedOverflowTexts: trustedOverflowTexts,
    );
  }

  static void _normalizePairedProtectedAnchors(
    dom.Element source,
    dom.Element translated,
    List<String> overflowTexts,
    List<dom.Text> trustedOverflowTexts,
    _ResponseHtml sourceDom,
  ) {
    if (source.localName != translated.localName ||
        !_attributesMatch(source, translated)) {
      return;
    }

    if (!EpubHtmlExtractor.nonTextAncestors.contains(
          EpubHtmlExtractor.tagLocalName(source),
        ) &&
        sourceDom.isProtected(source) &&
        _isProtectedMarkerText(sourceDom.textOf(source))) {
      _normalizeProtectedAnchor(
        source: source,
        translated: translated,
        sourceMarker: sourceDom.textOf(source).trim(),
        overflowTexts: overflowTexts,
        trustedOverflowTexts: trustedOverflowTexts,
      );
      return;
    }

    final List<dom.Element> sourceChildren = source.children.toList(
      growable: false,
    );
    final List<dom.Element> translatedChildren = translated.children.toList(
      growable: false,
    );
    if (sourceChildren.length != translatedChildren.length) {
      return;
    }
    for (int index = 0; index < sourceChildren.length; index += 1) {
      _normalizePairedProtectedAnchors(
        sourceChildren[index],
        translatedChildren[index],
        overflowTexts,
        trustedOverflowTexts,
        sourceDom,
      );
    }
  }

  static void _normalizeProtectedAnchor({
    required dom.Element source,
    required dom.Element translated,
    required String sourceMarker,
    required List<String> overflowTexts,
    required List<dom.Text> trustedOverflowTexts,
  }) {
    final dom.Text? markerText = _firstNonWhitespaceTextDescendant(translated);
    if (markerText == null) {
      _removeAdjacentMarker(
        source: source,
        translated: translated,
        marker: sourceMarker,
      );
      return;
    }

    final List<int>? markerRange = _markerRangeAtTextStart(
      markerText.data,
      sourceMarker,
    );
    if (markerRange == null) {
      return;
    }
    final String overflowText = _overflowTextAfterMarker(
      anchor: translated,
      markerText: markerText,
      markerEnd: markerRange[1],
    );
    final dom.Node? parent = translated.parentNode;
    if (parent == null) {
      return;
    }
    final int anchorIndex = parent.nodes.indexOf(translated);
    if (anchorIndex < 0) {
      return;
    }
    final dom.Element restoredAnchor = source.clone(true);
    parent.nodes.removeAt(anchorIndex);
    parent.nodes.insert(anchorIndex, restoredAnchor);
    if (overflowText.isNotEmpty) {
      final dom.Text? insertedOverflow = _placeOverflowTextAfter(
        parent: parent,
        anchorIndex: anchorIndex,
        overflowText: overflowText,
      );
      overflowTexts.add(overflowText);
      if (insertedOverflow != null) {
        trustedOverflowTexts.add(insertedOverflow);
      }
    }
  }

  static String _overflowTextAfterMarker({
    required dom.Element anchor,
    required dom.Text markerText,
    required int markerEnd,
  }) {
    String overflow = markerText.data.substring(markerEnd).trimLeft();

    dom.Node branch = markerText;
    while (true) {
      final dom.Node? parent = branch.parentNode;
      if (parent == null) {
        return overflow;
      }
      final int index = parent.nodes.indexOf(branch);
      for (
        int siblingIndex = index + 1;
        siblingIndex < parent.nodes.length;
        siblingIndex += 1
      ) {
        overflow += _safeOverflowText(parent.nodes[siblingIndex]);
      }
      if (parent == anchor) {
        return overflow;
      }
      branch = parent;
    }
  }

  static String _safeOverflowText(dom.Node node) {
    if (node is dom.Text) {
      return node.data;
    }
    if (node is! dom.Element) {
      return '';
    }
    const Set<String> unsafeTags = <String>{
      'script',
      'style',
      'iframe',
      'object',
      'embed',
      'img',
    };
    if (unsafeTags.contains(EpubHtmlExtractor.tagLocalName(node))) {
      return '';
    }
    return node.nodes.map(_safeOverflowText).join();
  }

  static dom.Text? _placeOverflowTextAfter({
    required dom.Node parent,
    required int anchorIndex,
    required String overflowText,
  }) {
    final int nextIndex = anchorIndex + 1;
    if (nextIndex < parent.nodes.length &&
        parent.nodes[nextIndex] is dom.Text) {
      final dom.Text nextText = parent.nodes[nextIndex] as dom.Text;
      nextText.data = _joinOverflowText(overflowText, nextText.data);
      return null;
    }
    final dom.Text inserted = dom.Text(overflowText);
    parent.nodes.insert(nextIndex, inserted);
    return inserted;
  }

  static String _joinOverflowText(String overflow, String followingText) {
    if (overflow.isEmpty || followingText.isEmpty) {
      return '$overflow$followingText';
    }
    final bool needsSeparator =
        RegExp(r'[A-Za-z0-9]$').hasMatch(overflow) &&
        RegExp(r'^[A-Za-z0-9]').hasMatch(followingText);
    return needsSeparator
        ? '$overflow $followingText'
        : '$overflow$followingText';
  }

  static dom.Text? _firstNonWhitespaceTextDescendant(dom.Node node) {
    if (node is dom.Text) {
      return node.data.trim().isEmpty ? null : node;
    }
    for (final dom.Node child in node.nodes) {
      final dom.Text? text = _firstNonWhitespaceTextDescendant(child);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  static void _removeAdjacentMarker({
    required dom.Element source,
    required dom.Element translated,
    required String marker,
  }) {
    final dom.Text? translatedPrevious = _adjacentText(
      translated,
      before: true,
    );
    final dom.Text? sourcePrevious = _adjacentText(source, before: true);
    if (translatedPrevious != null &&
        !_textEndsWithMarker(sourcePrevious?.data ?? '', marker) &&
        _textEndsWithMarker(translatedPrevious.data, marker) &&
        _removeMarkerAtTextEnd(translatedPrevious, marker)) {
      return;
    }

    final dom.Text? translatedNext = _adjacentText(translated, before: false);
    final dom.Text? sourceNext = _adjacentText(source, before: false);
    if (translatedNext != null &&
        !_textStartsWithMarker(sourceNext?.data ?? '', marker) &&
        _textStartsWithMarker(translatedNext.data, marker)) {
      _removeMarkerAtTextStart(translatedNext, marker);
    }
  }

  static dom.Text? _adjacentText(dom.Element element, {required bool before}) {
    final dom.Node? parent = element.parentNode;
    if (parent == null) {
      return null;
    }
    final int index = parent.nodes.indexOf(element);
    final int adjacentIndex = before ? index - 1 : index + 1;
    if (index < 0 ||
        adjacentIndex < 0 ||
        adjacentIndex >= parent.nodes.length) {
      return null;
    }
    final dom.Node adjacent = parent.nodes[adjacentIndex];
    return adjacent is dom.Text ? adjacent : null;
  }

  static bool _textEndsWithMarker(String value, String marker) {
    int end = value.length;
    while (end > 0 && value[end - 1].trim().isEmpty) {
      end -= 1;
    }
    final int start = end - marker.length;
    return start >= 0 && value.substring(start, end) == marker;
  }

  static bool _textStartsWithMarker(String value, String marker) {
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    return end <= value.length && value.substring(start, end) == marker;
  }

  static bool _removeMarkerAtTextEnd(dom.Text textNode, String marker) {
    final String value = textNode.data;
    int end = value.length;
    while (end > 0 && value[end - 1].trim().isEmpty) {
      end -= 1;
    }
    final int start = end - marker.length;
    if (start >= 0 && value.substring(start, end) == marker) {
      textNode.data = value.substring(0, start) + value.substring(end);
      return true;
    }
    return false;
  }

  static bool _removeMarkerAtTextStart(dom.Text textNode, String marker) {
    final String value = textNode.data;
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    if (end <= value.length && value.substring(start, end) == marker) {
      textNode.data = value.substring(0, start) + value.substring(end);
      return true;
    }
    return false;
  }

  static List<int>? _markerRangeAtTextStart(String value, String marker) {
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    if (end <= value.length && value.substring(start, end) == marker) {
      return <int>[start, end];
    }
    return null;
  }

  static bool _htmlStructureMatches(String sourceHtml, String translatedHtml) {
    return _domStructureMatches(
      _ResponseHtml.parse(sourceHtml),
      _ResponseHtml.parse(translatedHtml),
    );
  }

  static bool _domStructureMatches(
    _ResponseHtml sourceDom,
    _ResponseHtml translatedDom,
  ) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return false;
    }
    return _elementStructureMatches(sourceRoot, translatedRoot);
  }

  static dom.Element? _fragmentRoot(dom.DocumentFragment fragment) {
    final List<dom.Node> nodes = fragment.nodes
        .where((dom.Node node) => !_isIgnorableStructureNode(node))
        .toList(growable: false);
    if (nodes.length != 1 || nodes.single is! dom.Element) {
      return null;
    }
    return nodes.single as dom.Element;
  }

  static bool _elementStructureMatches(
    dom.Element source,
    dom.Element translated,
  ) {
    if (source.localName != translated.localName) {
      return false;
    }
    if (!_attributesMatch(source, translated)) {
      return false;
    }

    final List<dom.Node> sourceNodes = _meaningfulStructureNodes(source);
    final List<dom.Node> translatedNodes = _meaningfulStructureNodes(
      translated,
    );
    if (sourceNodes.length != translatedNodes.length) {
      return false;
    }
    for (int index = 0; index < sourceNodes.length; index += 1) {
      final dom.Node sourceNode = sourceNodes[index];
      final dom.Node translatedNode = translatedNodes[index];
      if (sourceNode is dom.Text && translatedNode is dom.Text) {
        continue;
      }
      if (sourceNode is dom.Element && translatedNode is dom.Element) {
        if (!_elementStructureMatches(sourceNode, translatedNode)) {
          return false;
        }
        continue;
      }
      return false;
    }
    return true;
  }

  static bool _attributesMatch(dom.Element source, dom.Element translated) {
    if (source.attributes.length != translated.attributes.length) {
      return false;
    }
    for (final MapEntry<Object, String> entry in source.attributes.entries) {
      if (translated.attributes[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  static List<dom.Node> _meaningfulStructureNodes(dom.Element element) {
    return element.nodes
        .where((dom.Node node) => !_isIgnorableStructureNode(node))
        .toList(growable: false);
  }

  static bool _isIgnorableStructureNode(dom.Node node) {
    return node is dom.Text && node.data.trim().isEmpty;
  }

  static void _collectTextSlots(
    dom.Node node,
    List<_HtmlTextSlot> slots, {
    required bool protected,
    required _ResponseNodeFacts facts,
  }) {
    if (node is dom.Text) {
      if (node.data.trim().isNotEmpty) {
        slots.add(_HtmlTextSlot(node: node, protected: protected));
      }
      return;
    }
    if (node is! dom.Element) {
      return;
    }
    final bool childProtected = protected || facts.isProtected(node);
    for (final dom.Node child in node.nodes) {
      _collectTextSlots(child, slots, protected: childProtected, facts: facts);
    }
  }

  /// P2-#7: per-tag counts of protected source slots. A response protected
  /// slot is effectively protected only when the source has a protected
  /// slot with the same (protecting tag, ordinal within that tag): the
  /// identity of protected content is positional, not a tag-name set.
  static Map<String, int> _protectedSlotCountsByTag(
    _ResponseHtml dom,
    List<_HtmlTextSlot> slots,
  ) {
    final Map<String, int> counts = <String, int>{};
    for (final _HtmlTextSlot slot in slots) {
      if (!slot.protected) {
        continue;
      }
      final String tag = _nearestProtectingTag(dom, slot.node) ?? '';
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
    return counts;
  }

  /// Tag of the nearest ancestor that protects [slotNode]'s text, or null
  /// when none does. Callers only ask for protected slots, which always
  /// have a protecting ancestor by construction.
  static String? _nearestProtectingTag(
    _ResponseHtml document,
    dom.Text slotNode,
  ) {
    dom.Node? ancestor = slotNode.parentNode;
    while (ancestor is dom.Element) {
      if (document.isProtected(ancestor)) {
        return EpubHtmlExtractor.tagLocalName(ancestor);
      }
      ancestor = ancestor.parentNode;
    }
    return null;
  }

  /// Walks [document] in document order and reports each standalone
  /// whitespace-only text node (which never becomes a slot) via [onGap],
  /// keyed by the index of the preceding writable slot ([writableIndexByNode]
  /// maps each writable slot's text node to its index; -1 when the
  /// whitespace leads). Whitespace inside protected subtrees is skipped,
  /// mirroring the slot walk.
  static void _collectStandaloneWhitespaceGaps(
    _ResponseHtml document,
    Map<dom.Text, int> writableIndexByNode,
    void Function(int precedingSlot, String data) onGap, [
    Map<dom.Element, bool>? effectiveProtection,
  ]) {
    int lastWritable = -1;
    void visit(dom.Node node, bool protected) {
      if (node is dom.Text) {
        if (node.data.trim().isEmpty) {
          if (!protected) {
            onGap(lastWritable, node.data);
          }
          return;
        }
        final int? writableIndex = writableIndexByNode[node];
        if (writableIndex != null) {
          lastWritable = writableIndex;
        }
        return;
      }
      if (node is! dom.Element) {
        return;
      }
      final String tag = EpubHtmlExtractor.tagLocalName(node);
      if (tag == 'script' || tag == 'style') return;
      final bool childProtected =
          protected ||
          (effectiveProtection?[node] ?? document.isProtected(node));
      for (final dom.Node child in node.nodes) {
        visit(child, childProtected);
      }
    }

    for (final dom.Node node in document.fragment.nodes) {
      visit(node, false);
    }
  }

  /// P2-#6: folds standalone whitespace-only text nodes (which never become
  /// slots) into the adjacent writable slot texts, in document order. Each
  /// whitespace node is appended to the preceding writable slot's text (or
  /// prepended to the first slot's text when it leads), so the written text
  /// sequence keeps the response's word separation instead of gluing words.
  /// [writableIndexByNode] maps each writable slot's text node to its index
  /// in [writableTexts].
  ///
  /// P2-#6 regression: [sourceDom] is the rebuilt (source-clone) DOM whose
  /// own standalone whitespace nodes survive the write (they never become
  /// slots), and [writableSourceIndexByNode] maps its writable slots to
  /// their indices. The writable slot sequences are positionally aligned
  /// (the branch precondition), so a response gap is skipped when the
  /// source already has whitespace at the same gap position — folding it
  /// as well would double the whitespace in the output.
  static List<String> _withStandaloneWhitespace(
    _ResponseHtml translatedDom,
    List<String> writableTexts,
    Map<dom.Text, int> writableIndexByNode,
    _ResponseHtml sourceDom,
    Map<dom.Text, int> writableSourceIndexByNode,
    Map<dom.Element, bool> effectiveProtection,
  ) {
    final List<({int precedingSlot, String data})> gaps =
        <({int precedingSlot, String data})>[];
    _collectStandaloneWhitespaceGaps(
      translatedDom,
      writableIndexByNode,
      (int precedingSlot, String data) =>
          gaps.add((precedingSlot: precedingSlot, data: data)),
      effectiveProtection,
    );
    if (gaps.isEmpty) {
      return writableTexts;
    }
    final Set<int> sourceWhitespaceSlots = <int>{};
    _collectStandaloneWhitespaceGaps(
      sourceDom,
      writableSourceIndexByNode,
      (int precedingSlot, String _) => sourceWhitespaceSlots.add(precedingSlot),
    );
    final List<String> result = List<String>.from(writableTexts);
    for (final gap in gaps) {
      if (result.isEmpty) {
        break;
      }
      if (sourceWhitespaceSlots.contains(gap.precedingSlot)) {
        continue;
      }
      if (gap.precedingSlot >= 0 && gap.precedingSlot < result.length) {
        result[gap.precedingSlot] = result[gap.precedingSlot] + gap.data;
      } else {
        result[0] = gap.data + result[0];
      }
    }
    return result;
  }

  /// Plain text of the translated DOM for the merge fallback: the data of
  /// every text node except effectively-protected ones, including
  /// whitespace-only nodes that never become slots, so words the model
  /// separated with standalone whitespace do not glue together (P2-#13).
  /// P2-#7: [effectiveProtectedByNode] carries the per-slot identity
  /// decision — a protected-kind element the model introduced has no
  /// source counterpart, so its text is real translation content and is
  /// kept; only genuinely-protected text is excluded (protected source
  /// slots retain their text, and including it here would duplicate it in
  /// the first writable source slot).
  static String _unprotectedResponseText(
    _ResponseHtml translatedDom,
    Map<dom.Text, bool> effectiveProtectedByNode,
    Map<dom.Element, bool> effectiveProtection,
  ) {
    final StringBuffer buffer = StringBuffer();
    void visit(dom.Node node, bool protected) {
      if (node is dom.Text) {
        if (!(effectiveProtectedByNode[node] ?? protected)) {
          buffer.write(node.data);
        }
        return;
      }
      if (node is! dom.Element) {
        return;
      }
      final String tag = EpubHtmlExtractor.tagLocalName(node);
      if (tag == 'script' || tag == 'style') return;
      final bool childProtected =
          protected ||
          (effectiveProtection[node] ?? translatedDom.isProtected(node));
      for (final dom.Node child in node.nodes) {
        visit(child, childProtected);
      }
    }

    for (final dom.Node node in translatedDom.fragment.nodes) {
      visit(node, false);
    }
    return buffer.toString();
  }

  static bool _isProtectedTextElement(dom.Element element, {String? text}) {
    final String tag = EpubHtmlExtractor.tagLocalName(element);
    if (EpubHtmlExtractor.nonTextAncestors.contains(tag)) return true;
    final Set<String> roles = _roleTokens(element);
    final Set<String> epubTypes = _epubTypes(element);
    // Ordinary wrappers cannot protect text; do not read their descendants.
    if (tag != 'a' &&
        !roles.contains('doc-noteref') &&
        !epubTypes.contains('noteref') &&
        !roles.contains('doc-pagebreak') &&
        !epubTypes.contains('pagebreak')) {
      return false;
    }
    final String value = text ?? element.text;
    final bool protectedMarkerText = _isProtectedMarkerText(value);

    if ((roles.contains('doc-noteref') || epubTypes.contains('noteref')) &&
        protectedMarkerText) {
      return true;
    }
    if (roles.contains('doc-pagebreak') || epubTypes.contains('pagebreak')) {
      return _isProtectedPagebreakText(value);
    }
    final String href = element.attributes['href'] ?? '';
    if (tag != 'a') {
      return false;
    }
    final String id = element.attributes['id']?.toLowerCase() ?? '';
    if (protectedMarkerText &&
        (roles.contains('doc-backlink') || id.startsWith('footnote_ref_'))) {
      return true;
    }
    if (protectedMarkerText &&
        _isCrossFileHref(href) &&
        _containsFootnoteMarkerClass(element)) {
      return true;
    }
    return href.startsWith('#') && protectedMarkerText;
  }

  static bool _isCrossFileHref(String href) {
    final int fragmentIndex = href.indexOf('#');
    return fragmentIndex > 0 && fragmentIndex < href.length - 1;
  }

  static bool _containsFootnoteMarkerClass(dom.Element element) {
    return ProtectedAnchorTextSlots.hasFootnoteMarkerClass(element);
  }

  static Set<String> _epubTypes(dom.Element element) {
    return EpubSemantics.typesOf(element);
  }

  static Set<String> _roleTokens(dom.Element element) {
    return (element.attributes['role']?.toLowerCase() ?? '')
        .split(RegExp(r'\s+'))
        .where((String role) => role.isNotEmpty)
        .toSet();
  }

  static bool _isProtectedPagebreakText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length > 12) {
      return false;
    }
    return _isProtectedMarkerText(value) ||
        RegExp(r'^[0-9]+$').hasMatch(compact) ||
        RegExp(r'^[ivxlcdmIVXLCDM]+$').hasMatch(compact);
  }

  static bool _isProtectedMarkerText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length > 10) {
      return false;
    }
    if (compact == '＊' || _chineseNumberMarkerToAscii.containsKey(compact)) {
      return true;
    }
    return RegExp(r'^[\[\(（【].+[\]\)）】]$').hasMatch(compact) ||
        RegExp(r'^[0-9]+[.)]?$').hasMatch(compact) ||
        RegExp(r'^[*†‡§¶]+$').hasMatch(compact) ||
        compact == '↩';
  }

  static const Map<String, String> _chineseNumberMarkerToAscii =
      <String, String>{
        '零': '0',
        '一': '1',
        '二': '2',
        '三': '3',
        '四': '4',
        '五': '5',
        '六': '6',
        '七': '7',
        '八': '8',
        '九': '9',
        '十': '10',
        '十一': '11',
      };

  static void _validateTranslatedBlockQuality({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    _validateNonemptyDoms(sourceDom, translatedDom);
    if (!config.residualQualityCheck) {
      return;
    }
    // A bibliography / endnote / index entry conventionally keeps reference
    // fields (author, journal, volume/issue/year, publisher, page numbers,
    // index terms) in the original language. Detect such entries by their
    // source markup class (for example `endnotes1`, `indexmain`) or epub:type
    // (for example `index-term`, `index-locator`) rather than the block root
    // tag, because the extractor may split a `<li>` into its inner `<a>` /
    // `<i>` / `<span>` nodes while still exposing the surrounding class in
    // `sourceHtml`.
    final bool isBibliographicEntry = RegExp(
      r'class="[^"]*(?:endnote|bibliograph|reference|index)[^"]*"'
      r'|epub:type="[^"]*index[^"]*"',
      caseSensitive: false,
    ).hasMatch(block.sourceHtml);
    // A pure cross-reference / citation-metadata endnote (for example
    // `Ibid.` or `Fiorentini and Peltzman, op. cit., p. 15.`) has no
    // natural-language sentence to translate; keeping it verbatim is the
    // correct behaviour. Skip the residual check for these so they are not
    // mistaken for untranslated prose.
    if (isBibliographicEntry &&
        TranslationQuality.isPureCitationMetadata(block.sourceText)) {
      return;
    }
    final TranslationResidualFinding? finding =
        TranslationQuality.findSuspiciousFragmentResidual(
          sourceFragment: sourceDom.fragment,
          translatedFragment: translatedDom.fragment,
          targetLanguage: config.targetLanguage,
          allowRetainedAuthorSignature: block.isAuthorSignature,
          allowBibliographicRetention: isBibliographicEntry,
          lockedGlossary: config.lockedGlossary,
        );
    _responseCount(translatedDom.instrumentation, 'qualityDomChecks');
    if (finding == null) {
      return;
    }

    throw FormatException(finding.messageForBlock(block.id));
  }

  static InspectedChapter _prepareChapterForTarget(
    InspectedChapter chapter, {
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage)) {
      return chapter;
    }
    return chapter.copyWith(
      blocks: chapter.blocks
          .map(
            (ExtractedBlock block) => block.copyWith(
              sourceHtml: _prepareBlockHtmlForTarget(
                sourceHtml: block.sourceHtml,
                targetLanguage: targetLanguage,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  static String _prepareBlockHtmlForTarget({
    required String sourceHtml,
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage) ||
        (!sourceHtml.toLowerCase().contains('dropcap') &&
            !sourceHtml.toLowerCase().contains('small'))) {
      return sourceHtml;
    }
    final dom.DocumentFragment fragment = XhtmlHtmlCompatibility.parseFragment(
      sourceHtml,
    );
    bool changed = false;
    final List<dom.Element> spans = fragment
        .querySelectorAll('span[class]')
        .toList(growable: false);
    for (final dom.Element span in spans) {
      if (_isInsideFootnoteMarkerAnchor(span) ||
          const EpubHtmlExtractor().isInsideSkippedAncestor(span)) {
        continue;
      }
      final bool isDropCap = span.classes.any(
        (String className) => className.toLowerCase().startsWith('dropcap'),
      );
      final bool isUppercaseSmallCaps =
          span.classes.any(_isSmallCapsClass) &&
          _isUppercaseLatinRun(span.text);
      if (!isDropCap && !isUppercaseSmallCaps) {
        continue;
      }
      if (_spanHasSemanticAttributes(span)) {
        span.classes.removeWhere(
          (token) =>
              token.toLowerCase().startsWith('dropcap') ||
              _isSmallCapsClass(token),
        );
      } else {
        _unwrapElement(span);
      }
      changed = true;
    }
    return changed ? fragment.outerHtml : sourceHtml;
  }

  static bool _isInsideFootnoteMarkerAnchor(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      if (EpubHtmlExtractor.tagLocalName(current) == 'a' &&
          _containsFootnoteMarkerClass(current)) {
        return true;
      }
      current = current.parentNode;
    }
    return false;
  }

  static bool _isCjkTargetLanguage(String targetLanguage) {
    return const {
      'zh',
      'ja',
      'ko',
    }.contains(normalizeTargetLanguage(targetLanguage));
  }

  static void _validateNonemptyDoms(
    _ResponseHtml sourceDom,
    _ResponseHtml translatedDom,
  ) {
    try {
      validateEpubDomXmlCharacters(translatedDom.fragment);
    } on InvalidEpubXmlCharacterException catch (error) {
      throw TranslationParseException(error.message);
    }
    bool hasBody(_ResponseHtml html) => html.slots.any(
      (slot) => !slot.protected && slot.text.trim().isNotEmpty,
    );
    if (hasBody(sourceDom) && !hasBody(translatedDom)) {
      throw const TranslationParseException(
        'Translated block has empty body text for a nonempty source.',
      );
    }

    // A-P1-1: reject a translation that carries no linguistic content for a
    // long source (e.g. the API returned only punctuation for a full
    // paragraph). Only obvious body loss is rejected: any translated word
    // passes, so legitimate short translations (titles) and tiny
    // translations in existing tests are unaffected.
    if (_linguisticBodyLength(sourceDom) >= 200 &&
        _linguisticBodyLength(translatedDom) == 0) {
      throw const TranslationParseException(
        'Translated block has no linguistic content for a long source.',
      );
    }
  }

  /// Matches every rune that is not a letter or number, used to measure how
  /// much linguistic content a translated body actually carries.
  static final RegExp _nonLinguisticChars = RegExp(
    r'[^\p{L}\p{N}]',
    unicode: true,
  );

  /// Counts letters/digits across scripts in the non-protected slots,
  /// ignoring whitespace and punctuation.
  static int _linguisticBodyLength(_ResponseHtml html) {
    var length = 0;
    for (final slot in html.slots) {
      if (slot.protected) continue;
      length += slot.text.replaceAll(_nonLinguisticChars, '').runes.length;
    }
    return length;
  }

  /// Canonical language identity for local script and prompt rules.
  static String normalizeTargetLanguage(String language) {
    final String value = language.trim().toLowerCase();
    final String base = value.split(RegExp('[-_]')).first;
    if (base == 'zh' ||
        value.contains('chinese') ||
        RegExp('中文|汉语|漢語').hasMatch(value)) {
      return 'zh';
    }
    if (base == 'ja' ||
        value.contains('japanese') ||
        RegExp('日语|日語|日本語').hasMatch(value)) {
      return 'ja';
    }
    if (base == 'ko' ||
        value.contains('korean') ||
        RegExp('韩语|韓語|한국어').hasMatch(value)) {
      return 'ko';
    }
    return base;
  }

  static bool _spanHasSemanticAttributes(dom.Element span) =>
      span.attributes.keys.any((key) => key != 'class' && key != 'style');

  static bool _isSmallCapsClass(String className) {
    final String normalized = className.toLowerCase();
    return normalized == 'small' ||
        normalized == 'small-caps' ||
        normalized == 'smallcaps';
  }

  static bool _isUppercaseLatinRun(String value) {
    final String letters = value.replaceAll(RegExp('[^A-Za-z]'), '');
    return letters.isNotEmpty && letters == letters.toUpperCase();
  }

  static void _unwrapElement(dom.Element element) {
    final dom.Node? parent = element.parentNode;
    if (parent == null) {
      return;
    }
    final int index = parent.nodes.indexOf(element);
    if (index < 0) {
      return;
    }
    final List<dom.Node> children = element.nodes.toList(growable: false);
    for (final dom.Node child in children) {
      child.remove();
    }
    element.remove();
    parent.nodes.insertAll(index, children);
  }
}

/// A response-local DOM. Clones and rebuilt skeletons stay in DOM form;
/// serialization is deferred until the response leaves structure handling.
class _ResponseHtml {
  _ResponseHtml(this.fragment, [this.instrumentation]);

  factory _ResponseHtml.parse(
    String html, [
    Map<String, int>? instrumentation,
  ]) {
    _responseCount(instrumentation, 'parses');
    return _ResponseHtml(
      XhtmlHtmlCompatibility.parseFragment(html),
      instrumentation,
    );
  }

  factory _ResponseHtml.fromRoot(
    dom.Element root,
    Map<String, int>? instrumentation,
  ) => _ResponseHtml(dom.DocumentFragment()..append(root), instrumentation);

  final dom.DocumentFragment fragment;
  final Map<String, int>? instrumentation;
  _ResponseNodeFacts? _facts;
  List<_HtmlTextSlot>? _slots;

  dom.Element? get root => _EpubResponseDomLocker._fragmentRoot(fragment);
  String get html => root?.outerHtml ?? fragment.outerHtml.trim();
  _ResponseNodeFacts get facts =>
      _facts ??= _ResponseNodeFacts(fragment, instrumentation);
  String get plainText => facts.fullText;
  String textOf(dom.Element node) => facts.textOf(node);
  bool isProtected(dom.Element node) => facts.isProtected(node);

  List<_HtmlTextSlot> get slots => _slots ??= () {
    final slots = <_HtmlTextSlot>[];
    for (final node in fragment.nodes) {
      _EpubResponseDomLocker._collectTextSlots(
        node,
        slots,
        protected: false,
        facts: facts,
      );
    }
    return slots;
  }();

  // All text/structure mutations must invalidate before the next read.
  void invalidate() {
    _facts = null;
    _slots = null;
  }
}

void _responseCount(Map<String, int>? counts, String key) {
  if (counts != null) counts[key] = (counts[key] ?? 0) + 1;
}

/// One linear text index per immutable DOM phase. Marker classification needs
/// at most 12 non-whitespace characters, so summaries are capped at 13. This
/// avoids concatenating every ancestor's entire descendant text in deep trees.
class _ResponseNodeFacts {
  _ResponseNodeFacts(dom.Node root, [this.instrumentation]) {
    _index(root);
    fullText = _buffer.toString();
  }

  final Map<String, int>? instrumentation;
  final _buffer = StringBuffer();
  final _ranges = Map<dom.Node, (int, int)>.identity();
  final _compact = Map<dom.Node, String>.identity();
  final _protected = Map<dom.Element, bool>.identity();
  final _texts = <(int, int), String>{};
  late final String fullText;

  void _index(dom.Node node) {
    _responseCount(instrumentation, 'indexedNodes');
    final start = _buffer.length;
    String compact = '';
    if (node is dom.Text) {
      _buffer.write(node.data);
      compact = node.data.replaceAll(RegExp(r'\s+'), '');
      if (compact.length > 13) compact = compact.substring(0, 13);
    } else {
      for (final child in node.nodes) {
        _index(child);
        if (compact.length < 13) {
          compact += _compact[child]!;
          if (compact.length > 13) compact = compact.substring(0, 13);
        }
      }
    }
    _ranges[node] = (start, _buffer.length);
    _compact[node] = compact;
  }

  String textOf(dom.Node node) {
    final range = _ranges[node]!;
    return _texts.putIfAbsent(range, () {
      _responseCount(instrumentation, 'textMaterializations');
      return fullText.substring(range.$1, range.$2);
    });
  }

  bool isProtected(dom.Element node) => _protected.putIfAbsent(node, () {
    _responseCount(instrumentation, 'protectionChecks');
    return _EpubResponseDomLocker._isProtectedTextElement(
      node,
      text: _compact[node]!,
    );
  });
}

/// Compare aligned subtree ranges in O(1) after one linear mismatch index.
/// This also covers a lang attribute on every level of a nested reply. When
/// rebuilding shifts text boundaries, fall back to cached exact text rather
/// than using a probabilistic hash for a semantic alignment decision.
class _ResponseTextAlignment {
  _ResponseTextAlignment(this.reply, this.output) {
    final length = min(reply.fullText.length, output.fullText.length);
    var lastMismatch = -1;
    _lastMismatch = List<int>.generate(length, (index) {
      _responseCount(reply.instrumentation, 'alignmentCharacters');
      if (reply.fullText.codeUnitAt(index) !=
          output.fullText.codeUnitAt(index)) {
        lastMismatch = index;
      }
      return lastMismatch;
    });
  }

  final _ResponseNodeFacts reply;
  final _ResponseNodeFacts output;
  late final List<int> _lastMismatch;

  bool matches(dom.Element replyNode, dom.Element outputNode) {
    final a = reply._ranges[replyNode]!;
    final b = output._ranges[outputNode]!;
    if (a == b) {
      return a.$1 == a.$2 || _lastMismatch[a.$2 - 1] < a.$1;
    }
    if (a.$2 - a.$1 != b.$2 - b.$1) return false;
    return reply.textOf(replyNode) == output.textOf(outputNode);
  }
}

class _NormalizedAnchorHtml {
  const _NormalizedAnchorHtml({
    this.root,
    this.hasOverflow = false,
    this.trustedOverflowTexts = const <dom.Text>[],
  });

  final dom.Element? root;
  final bool hasOverflow;
  final List<dom.Text> trustedOverflowTexts;
}

class _HtmlTextSlot {
  const _HtmlTextSlot({required this.node, required this.protected});

  final dom.Text node;
  final bool protected;

  String get text => node.data;

  set text(String value) {
    node.data = value;
  }
}
