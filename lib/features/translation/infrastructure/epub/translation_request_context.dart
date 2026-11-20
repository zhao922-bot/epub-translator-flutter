part of 'translation_batch_planner.dart';

TranslationBatchContext _selectTranslationRequestContext({
  required TranslationBatchPlanner planner,
  required TranslationBatchContext source,
  required List<ExtractedBlock> batchBlocks,
  required String lockedGlossary,
  required List<ExtractedBlock> chapterBlocks,
  required Map<String, int>? indexById,
  required bool compact,
}) {
  final texts = batchBlocks.map(_requestSourceText).toList(growable: false);
  final nearby = _requestNeighbours(
    planner,
    source,
    batchBlocks,
    chapterBlocks,
    indexById,
  );
  final needsContinuity =
      batchBlocks.any(_hasComplexMarkup) ||
      texts.any(_hasContinuityCue) ||
      (nearby.externalContext &&
          (nearby.before.isNotEmpty || nearby.after.isNotEmpty));
  final searchText = [
    ...texts,
    ...nearby.before.map((snippet) => snippet.text),
    ...nearby.after.map((snippet) => snippet.text),
  ].map(_termKey).join('\n');
  final glossary = _selectGlossary(
    lockedGlossary,
    source.bookMemory,
    searchText,
  );
  final textLimit = compact
      ? min(96, planner.contextTextLimit)
      : planner.contextTextLimit;
  return TranslationBatchContext._selected(
    lockedGlossary,
    chapterTitle: source.chapterTitle,
    before: needsContinuity
        ? _clipNeighbours(nearby.before, textLimit, fromEnd: true)
        : const [],
    after: needsContinuity
        ? _clipNeighbours(nearby.after, textLimit)
        : const [],
    bookMemory: _selectMemory(
      source.bookMemory,
      glossary.automatic,
      keepContinuity: needsContinuity && !compact,
    ),
    lockedGlossary: glossary.locked,
    lockedGlossaryNotes: glossary.notes,
    needsContinuity: needsContinuity,
    source: source,
  );
}

String _requestSourceText(ExtractedBlock block) {
  if (block.sourceText.trim().isNotEmpty) return block.sourceText;
  return html_parser.parseFragment(block.sourceHtml).text ?? '';
}

final _openingTag = RegExp(r'<\s*[A-Za-z][\w:.-]*(?=[\s/>])');
final _complexBlockTag = RegExp(
  r'^(?:blockquote|table|t[dh]|dl|d[dt]|ruby|figure|figcaption|pre|aside)$',
  caseSensitive: false,
);
bool _hasComplexMarkup(ExtractedBlock block) =>
    _complexBlockTag.hasMatch(block.tagName.split(':').last) ||
    _openingTag.allMatches(block.sourceHtml).skip(1).isNotEmpty;

final _dialogue = RegExp(r'''["“”„‘«»「」『』]|(?:^|\n)\s*(?:['—–]\s*|-\s+)\S''');
final _referenceCue = RegExp(
  r'(?:^|[.!?…]\s+)(?:(?:and|but|then|however),?\s+)?'
  r'(?:he|she|it|they|we|you|i|him|her|them|his|their|its|hers|'
  r'this|these|that|those|such|there|'
  r'il|elle|ils|elles|cela|ceci|er|sie|ihm|ihnen|dies|'
  r'él|ella|ellos|ellas|esto|eso|aquello|ele|ela|eles|elas)\b'
  r'|\b(?:the former|the latter|as above|as before)\b'
  r'|(?:^|[。！？])(?:他们|她们|它们|他|她|它|你|您|这|那|此前|于是|その|それ|これ|彼|그녀|그는|이것|그것)',
  caseSensitive: false,
  unicode: true,
);
bool _hasContinuityCue(String text) {
  final trimmed = text.trim();
  return trimmed.length > 360 ||
      _dialogue.hasMatch(trimmed) ||
      _referenceCue.hasMatch(trimmed) ||
      trimmed.endsWith('…');
}

({
  List<TranslationContextSnippet> before,
  List<TranslationContextSnippet> after,
  bool externalContext,
})
_requestNeighbours(
  TranslationBatchPlanner planner,
  TranslationBatchContext source,
  List<ExtractedBlock> batchBlocks,
  List<ExtractedBlock> chapterBlocks,
  Map<String, int>? indexById,
) {
  final chapterIndex =
      indexById ??
      {for (var i = 0; i < chapterBlocks.length; i++) chapterBlocks[i].id: i};
  final requested = batchBlocks.map((block) => block.id).toSet();
  final positions = requested
      .map((id) => chapterIndex[id])
      .whereType<int>()
      .where((position) => position >= 0 && position < chapterBlocks.length)
      .toSet();
  final before = <int>{};
  final after = <int>{};
  for (final position in positions) {
    if (!positions.contains(position - 1)) {
      for (
        var i = max(0, position - planner.contextBeforeBlockCount);
        i < position;
        i++
      ) {
        if (!positions.contains(i)) before.add(i);
      }
    }
    if (!positions.contains(position + 1)) {
      final end = min(
        chapterBlocks.length,
        position + 1 + planner.contextAfterBlockCount,
      );
      for (var i = position + 1; i < end; i++) {
        if (!positions.contains(i)) after.add(i);
      }
    }
  }
  final included = {...requested};
  final beforeSnippets = <TranslationContextSnippet>[];
  final afterSnippets = <TranslationContextSnippet>[];
  bool append(List<TranslationContextSnippet> target, String id, String text) {
    if (text.trim().isEmpty || !included.add(id)) return false;
    target.add(TranslationContextSnippet(id: id, text: text));
    return true;
  }

  for (final i in before.toList()..sort()) {
    final block = chapterBlocks[i];
    append(beforeSnippets, block.id, _requestSourceText(block));
  }
  for (final i in after.toList()..sort()) {
    final block = chapterBlocks[i];
    append(afterSnippets, block.id, _requestSourceText(block));
  }
  var externalContext = false;
  // Explicit snippets can carry a main-text reference for an attached note
  // or context from another file. Regenerate chapter snippets around sparse
  // requests when source order is available.
  for (final (original, target) in [
    (source.before, beforeSnippets),
    (source.after, afterSnippets),
  ]) {
    for (final snippet in original) {
      if (positions.isNotEmpty && chapterIndex.containsKey(snippet.id)) {
        continue;
      }
      if (append(target, snippet.id, snippet.text)) externalContext = true;
    }
  }
  return (
    before: beforeSnippets,
    after: afterSnippets,
    externalContext: externalContext,
  );
}

final _contextWhitespace = RegExp(r'[\s\u0085]+');

List<TranslationContextSnippet> _clipNeighbours(
  List<TranslationContextSnippet> snippets,
  int limit, {
  bool fromEnd = false,
}) => List.unmodifiable([
  for (final snippet in snippets)
    TranslationContextSnippet(
      id: snippet.id,
      text: _clipContextText(snippet.text, limit, fromEnd: fromEnd),
    ),
]);

String _clipContextText(String text, int limit, {bool fromEnd = false}) {
  final clean = text.replaceAll(_contextWhitespace, ' ').trim();
  if (clean.length <= limit) return clean;
  if (!fromEnd) return '${unicodeSafePrefix(clean, limit - 1)}…';
  final preceding = unicodeSafePrefix(clean, clean.length - limit + 1);
  // When the prefix stopped at the start of a scalar, skip that scalar if
  // taking it would exceed the limit.
  final start = preceding.length == clean.length - limit + 1
      ? preceding.length
      : preceding.length + 2;
  return '…${clean.substring(start)}';
}

Map<String, Object?>? _selectMemory(
  Map<String, Object?>? memory,
  List<Map<String, String>> automatic, {
  required bool keepContinuity,
}) {
  final style = memory?['styleProfile'];
  final confirmed = memory?['styleProfileConfirmed'] == true;
  final renderedRules = <String>{};
  if (style is Map<String, Object?>) {
    final profile = TranslationStyleProfile.fromJson(style);
    if (confirmed || profile.shouldInject) {
      renderedRules.addAll(
        [
          profile.tone,
          profile.sentenceStyle,
          ...profile.translationConstraints,
          ...profile.avoid,
        ].map(_styleRuleKey),
      );
    }
  }
  final guide = _contextStrings(memory?['styleGuide'])
      .where((rule) => renderedRules.add(_styleRuleKey(rule)))
      .toList(growable: false);
  final summary = _contextString(memory?['bookSummary']);
  final recent = <Map<String, Object?>>[];
  if (keepContinuity) {
    for (final entry in _contextMaps(memory?['recentChapters'])) {
      final title = _contextString(entry['title']);
      final chapterSummary = _contextString(entry['summary']);
      final notes = _contextStrings(entry['continuityNotes'])
          .where((note) => renderedRules.add(_styleRuleKey(note)))
          .toList(growable: false);
      if (chapterSummary.isEmpty && notes.isEmpty) continue;
      recent.add({
        if (title.isNotEmpty) 'title': title,
        if (chapterSummary.isNotEmpty)
          'summary': _clipContextText(chapterSummary, 240),
        if (notes.isNotEmpty) 'continuityNotes': notes,
      });
    }
  }
  final result = <String, Object?>{
    'styleProfile': ?style,
    if (confirmed) 'styleProfileConfirmed': true,
    if (guide.isNotEmpty) 'styleGuide': guide,
    if (automatic.isNotEmpty) 'glossary': automatic,
    if (keepContinuity && summary.isNotEmpty)
      'bookSummary': _clipContextText(summary, 280),
    if (recent.isNotEmpty) 'recentChapters': recent,
  };
  return result.isEmpty ? null : Map.unmodifiable(result);
}

String _contextString(Object? value) => value is String ? value.trim() : '';
Iterable<String> _contextStrings(Object? value) sync* {
  if (value is! List) return;
  for (final text in value.whereType<String>()) {
    if (text.trim().isNotEmpty) yield text.trim();
  }
}

Iterable<Map> _contextMaps(Object? value) =>
    value is List ? value.whereType<Map>() : const [];
String _styleRuleKey(String text) =>
    _termKey(text).replaceFirst(RegExp(r'[.!。]+$'), '');

({
  List<Map<String, String>> locked,
  List<Map<String, String>> automatic,
  List<String> notes,
})
_selectGlossary(
  String userText,
  Map<String, Object?>? memory,
  String searchText,
) {
  final memoryEntries = [
    ..._contextMaps(memory?['glossary']),
    for (final chapter in _contextMaps(memory?['recentChapters']))
      ..._contextMaps(chapter['glossary']),
  ];
  final locks = <String, ({String source, String target, Object group})>{};
  void lock(String source, String target, {required bool userProvided}) {
    final group = Object();
    for (final variant in _lockedVariants(source)) {
      final key = _termKey(variant).replaceAll(_termSpaceOrHyphen, ' ');
      final entry = (source: variant, target: target, group: group);
      if (userProvided) {
        locks[key] = entry;
      } else {
        locks.putIfAbsent(key, () => entry);
      }
    }
  }

  // Checkpoints may contain locks derived by older glossary parsers. The
  // current user input owns the whole set when supplied, including its term
  // boundaries and separator precedence.
  if (userText.trim().isEmpty) {
    for (final entry in memoryEntries) {
      if (entry['locked'] != true && entry['locked'] != 'true') continue;
      final source = _contextString(entry['source']);
      final target = _contextString(entry['target']);
      if (source.isNotEmpty && target.isNotEmpty) {
        lock(source, target, userProvided: false);
      }
    }
  }
  final notes = <String>{};
  for (final raw in const LineSplitter().convert(userText)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final separator =
        _lockArrow.firstMatch(line) ?? _lockSeparator.firstMatch(line);
    if (separator == null) {
      notes.add(line);
      continue;
    }
    final source = line.substring(0, separator.start).trim();
    final target = line.substring(separator.end).trim();
    if (source.isNotEmpty && target.isNotEmpty) {
      lock(source, target, userProvided: true);
    }
  }

  final locked = <Object, ({List<String> sources, String target})>{};
  final selectedMatchers = <RegExp>[];
  for (final entry in locks.values) {
    final matcher = _termMatcher(entry.source, inflect: true);
    if (!matcher.hasMatch(searchText)) continue;
    final group = locked.putIfAbsent(
      entry.group,
      () => (sources: [], target: entry.target),
    );
    group.sources.add(entry.source);
    selectedMatchers.add(matcher);
  }
  final automatic = <String, Map<String, String>>{};
  for (final entry in memoryEntries) {
    if (entry['locked'] == true || entry['locked'] == 'true') continue;
    final source = _contextString(entry['source']);
    final target = _contextString(entry['target']);
    if (source.isEmpty || target.isEmpty) continue;
    final key = _termKey(source);
    final dedupKey = key.replaceAll(_termSpaceOrHyphen, ' ');
    if (automatic.containsKey(dedupKey) || locks.containsKey(dedupKey)) {
      continue;
    }
    if (!_termMatcher(source).hasMatch(searchText)) continue;
    // A memory term for an inflected form may contradict a user lock. The
    // same matcher must cover the entire memory term; longer phrases may
    // have independent translations.
    if (selectedMatchers.any(
      (matcher) => matcher.matchAsPrefix(key)?.end == key.length,
    )) {
      continue;
    }
    automatic[dedupKey] = Map.unmodifiable({
      'source': source,
      'target': target,
    });
  }
  return (
    locked: List.unmodifiable([
      for (final entry in locked.values)
        Map<String, String>.unmodifiable({
          'source': entry.sources.join(' / '),
          'target': entry.target,
        }),
    ]),
    automatic: List.unmodifiable(automatic.values),
    notes: List.unmodifiable(notes),
  );
}

final _lockArrow = RegExp(r'=>|→');
final _lockSeparator = RegExp(r'=|：|:(?!/)');
final _aliasSeparator = RegExp(r'\s*\|\s*|\s+/\s+');
final _compactAliases = RegExp(r'^\p{L}{3,}(?:/\p{L}{3,})+$', unicode: true);
List<String> _lockedVariants(String source) {
  final parts = source.split(_aliasSeparator);
  if (parts.length > 1 && parts.every((part) => part.isNotEmpty)) return parts;
  if (_compactAliases.hasMatch(source)) return source.split('/');
  return [source];
}

final _apostrophe = RegExp(r'[‘’ʼ＇]');
final _hyphen = RegExp(r'[‐‑‒–—−]');
String _termKey(String value) => value
    .replaceAll('\u00ad', '')
    .replaceAll(_apostrophe, "'")
    .replaceAll(_hyphen, '-')
    .replaceAll(_contextWhitespace, ' ')
    .trim()
    .toLowerCase();

const _unspacedScript =
    r'\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}'
    r'\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}';
const _termWord = r'[\p{L}\p{M}\p{N}_]';
final _wholeWord = RegExp(_termWord, unicode: true);
final _runsTogether = RegExp('[$_unspacedScript]', unicode: true);
final _asciiEnding = RegExp(r'[a-z]{3,}$');
final _termSpaceOrHyphen = RegExp(
  r'(?<=[\p{L}\p{M}\p{N}])[- ]+(?=[\p{L}\p{N}])',
  unicode: true,
);

RegExp _termMatcher(String source, {bool inflect = false}) {
  final key = _termKey(source);
  if (key.isEmpty) return RegExp(r'(?!)');
  String edge(int scalar, {required bool before}) {
    final char = String.fromCharCode(scalar);
    if (!_wholeWord.hasMatch(char) || _runsTogether.hasMatch(char)) return '';
    return before
        ? '(?:(?<!$_termWord)|(?<=[$_unspacedScript]))'
        : '(?:(?!$_termWord)|(?=[$_unspacedScript]))';
  }

  String expression(String value) =>
      value.split(_termSpaceOrHyphen).map(RegExp.escape).join(r'[- ]+');
  final ending = inflect ? _asciiEnding.firstMatch(key) : null;
  final literal = expression(key);
  final forms = ending == null
      ? literal
      : '(?:$literal|'
            '${expression(key.substring(0, ending.start))}${_inflectedEnding(ending[0]!)})';
  return RegExp(
    '${edge(key.runes.first, before: true)}$forms${edge(key.runes.last, before: false)}',
    unicode: true,
  );
}

String _inflectedEnding(String base) {
  final stem = base.substring(0, base.length - 1);
  final tail = base[base.length - 1];
  final forms = <String>{'${base}s', '${base}es', '${base}ed', '${base}ing'};
  if (tail == 'y' && RegExp(r'[^aeiou]y$').hasMatch(base)) {
    forms.addAll(['${stem}ies', '${stem}ied']);
  }
  if (tail == 'e') forms.addAll(['${base}d', '${stem}ing']);
  if (RegExp(r'[^aeiou][aeiou][bdgmnprt]$').hasMatch(base)) {
    forms.addAll(['$base${tail}ed', '$base${tail}ing']);
  }
  final irregular = const {
    'child': 'children',
    'person': 'people',
    'man': 'men',
    'woman': 'women',
    'mouse': 'mice',
    'foot': 'feet',
    'goose': 'geese',
    'tooth': 'teeth',
  }[base];
  if (irregular != null) forms.add(irregular);
  return '(?:${forms.join('|')})';
}
