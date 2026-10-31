import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/translation_config.dart';
import 'review_text_patch.dart';
import 'translation_consistency_checker.dart';

/// Canonicalizes titles and explicit kinship mentions that span blocks.
///
/// These checks operate on the complete selected book after chapter
/// translation. They use source evidence and never invent a person or
/// relationship.
class BookTitleConsistency {
  const BookTitleConsistency._();

  /// Returns the translated body heading only when the source OPF title and
  /// source heading are equivalent. Distinct titles may intentionally differ.
  static String? translatedBodyTitle({
    required String metadataTitle,
    required List<InspectedChapter> chapters,
    Map<String, Object> sourceHints = const {},
  }) {
    final String normalizedMetadata = normalizeSourceTitle(metadataTitle);
    if (normalizedMetadata.isEmpty) return null;
    final headingSources = <String, String>{};
    final indexedHeadings = sourceHints['headingSources'];
    if (indexedHeadings is List) {
      for (final raw in indexedHeadings.whereType<Map>()) {
        final chapterPath = raw['chapter'];
        final blockId = raw['id'];
        final source = raw['source'];
        if (chapterPath is String &&
            blockId is String &&
            source is String &&
            source.trim().isNotEmpty) {
          headingSources[_blockKey(chapterPath, blockId)] = source;
        }
      }
    }
    for (final chapter in chapters.where((c) => c.includeInTranslation)) {
      for (final block in chapter.blocks) {
        if (!const {'h1', 'h2', 'h3'}.contains(block.tagName.toLowerCase())) {
          continue;
        }
        final String blockSource = block.sourceText.trim().isNotEmpty
            ? block.sourceText
            : headingSources[_blockKey(chapter.path, block.id)] ??
                  chapter.title;
        if (normalizeSourceTitle(blockSource) != normalizedMetadata) {
          continue;
        }
        final String? translated = block.translatedHtml;
        if (translated == null) continue;
        final String title = TranslationConsistencyChecker.text(translated)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim()
            .replaceFirst(RegExp(r'^[《“"「『]+'), '')
            .replaceFirst(RegExp(r'[》”"」』]+$'), '')
            .trim();
        if (title.isNotEmpty) return title;
      }
    }
    return null;
  }

  static bool sourceTitlesEquivalent(String left, String right) =>
      normalizeSourceTitle(left).isNotEmpty &&
      normalizeSourceTitle(left) == normalizeSourceTitle(right);

  static String normalizeSourceTitle(String value) => value
      .toLowerCase()
      .replaceFirst(RegExp(r'^(?:the|a|an)\s+'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static String _blockKey(String chapterPath, String blockId) =>
      '$chapterPath\u0000$blockId';
}

class BookRelationshipCorrection {
  const BookRelationshipCorrection({
    required this.chapterPath,
    required this.blockId,
    required this.sourceName,
    required this.before,
    required this.after,
  });

  final String chapterPath;
  final String blockId;
  final String sourceName;
  final String before;
  final String after;

  Map<String, Object?> toJson() => {
    'chapter': chapterPath,
    'id': blockId,
    'sourceName': sourceName,
    'before': before,
    'after': after,
    'category': 'name',
    'reason': 'unqualifiedCousinCanonicalized',
    'accepted': true,
    'automatic': true,
  };
}

class BookRelationshipRepairResult {
  const BookRelationshipRepairResult({
    required this.chapters,
    required this.corrections,
  });

  final List<InspectedChapter> chapters;
  final List<BookRelationshipCorrection> corrections;
}

/// Normalizes explicitly unqualified `Cousin Name` mentions in Chinese.
///
/// English `cousin` does not establish paternal/maternal side or age order.
/// The neutral canonical form prevents later blocks from drifting to
/// unsupported forms such as 堂兄、表哥 or 表姐.
class BookRelationshipConsistency {
  const BookRelationshipConsistency._();

  static final RegExp _namePattern = RegExp(
    r"[A-Z][\p{L}\p{M}'’\-]+",
    unicode: true,
  );
  static final RegExp _cousinMention = RegExp(
    r"\b[Cc]ousin\s+([A-Z][\p{L}\p{M}'’\-]+)"
    r"(?:\s*(?:,|and|&)\s*(?:Cousin\s+)?"
    r"([A-Z][\p{L}\p{M}'’\-]+))?",
    caseSensitive: true,
    unicode: true,
  );
  static final RegExp _explicitAge = RegExp(
    r'\b(?:older|elder|eldest|younger|senior|junior)\b',
    caseSensitive: false,
  );
  static const String _relationPattern =
      r'(?:堂兄|堂弟|堂姐|堂妹|堂哥|表兄|表弟|表姐|表妹|表哥|表亲|亲戚|堂亲)';
  static final RegExp _badRelation = RegExp(
    r'(?:堂兄|堂弟|堂姐|堂妹|堂哥|表兄|表弟|表姐|表妹|表哥|堂亲)',
  );
  static final RegExp _anyRelation = RegExp(_relationPattern);
  static final RegExp _cjkCandidate = RegExp(r'^[\u3400-\u9fff]{2,4}$');
  static final RegExp _candidateBoundary = RegExp(r'[和与及或跟同、，。！？；：,.!?;:]');
  static const Set<String> _commonTargetWords = {
    '他们',
    '她们',
    '我们',
    '你们',
    '自己',
    '这里',
    '那里',
    '当时',
    '已经',
    '因为',
    '所以',
    '但是',
    '可是',
    '然后',
    '最后',
    '现在',
    '过去',
    '以后',
    '之前',
    '之后',
    '起来',
    '出来',
    '回来',
    '一直',
    '只是',
    '还是',
    '就是',
  };

  static BookRelationshipRepairResult repairUnqualifiedCousins({
    required List<InspectedChapter> chapters,
    required TranslationConfig config,
    required List<Map<String, String>> glossary,
    Map<String, Object> sourceHints = const {},
  }) {
    if (!_isChinese(config.targetLanguage)) {
      return BookRelationshipRepairResult(
        chapters: chapters,
        corrections: const [],
      );
    }

    final mentionsByBlock = <String, _CousinMentions>{};
    final targets = <String, String>{};
    final sourceNamesInOrder = <String>[];
    final translatedBlocks = <_TranslatedCousinBlock>[];
    final indexedMentions = sourceHints['cousinMentions'];
    if (indexedMentions is List) {
      for (final raw in indexedMentions.whereType<Map>()) {
        final chapterPath = raw['chapter'];
        final blockId = raw['id'];
        final rawNames = raw['names'];
        if (chapterPath is! String || blockId is! String || rawNames is! List) {
          continue;
        }
        final names = rawNames
            .whereType<String>()
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toList();
        if (names.isEmpty) continue;
        mentionsByBlock[_blockKey(chapterPath, blockId)] = _CousinMentions(
          chapterPath: chapterPath,
          blockId: blockId,
          names: names,
          explicitAge: raw['explicitAge'] == true,
        );
      }
    }
    for (final term in glossary) {
      final source = term['source']?.trim() ?? '';
      final target = term['target']?.trim() ?? '';
      if (_namePattern.hasMatch(source) && target.isNotEmpty) {
        targets[source.toLowerCase()] = target;
      }
    }

    for (final chapter in chapters) {
      for (final block in chapter.blocks) {
        final key = _blockKey(chapter.path, block.id);
        final indexed = mentionsByBlock[key];
        final sourceText = block.sourceText;
        final names = sourceText.trim().isNotEmpty
            ? _sourceCousinNames(sourceText)
            : indexed?.names ?? const <String>[];
        if (names.isEmpty) continue;
        mentionsByBlock[key] = _CousinMentions(
          chapterPath: chapter.path,
          blockId: block.id,
          names: names,
          explicitAge: sourceText.trim().isNotEmpty
              ? _explicitAge.hasMatch(sourceText)
              : indexed?.explicitAge ?? false,
        );
        for (final name in names) {
          if (!sourceNamesInOrder.any(
            (value) => value.toLowerCase() == name.toLowerCase(),
          )) {
            sourceNamesInOrder.add(name);
          }
        }
        final translated = block.translatedHtml;
        if (translated == null) continue;
        translatedBlocks.add(
          _TranslatedCousinBlock(
            TranslationConsistencyChecker.text(translated),
          ),
        );
      }
    }
    _inferStableTargets(
      blocks: translatedBlocks,
      sourceNames: sourceNamesInOrder,
      targets: targets,
    );

    final corrections = <BookRelationshipCorrection>[];
    final repaired = <InspectedChapter>[];
    for (final chapter in chapters) {
      var changed = false;
      final blocks = <ExtractedBlock>[];
      for (final block in chapter.blocks) {
        final key = _blockKey(chapter.path, block.id);
        final mention = mentionsByBlock[key];
        final translated = block.translatedHtml;
        if (mention == null || translated == null || mention.explicitAge) {
          blocks.add(block);
          continue;
        }
        final result = _repairBlock(
          chapterPath: chapter.path,
          block: block,
          sourceNames: mention.names,
          targets: targets,
        );
        if (result == null) {
          blocks.add(block);
          continue;
        }
        blocks.add(block.copyWith(translatedHtml: result.html));
        corrections.add(result.correction);
        changed = true;
      }
      repaired.add(changed ? chapter.copyWith(blocks: blocks) : chapter);
    }
    return BookRelationshipRepairResult(
      chapters: repaired,
      corrections: corrections,
    );
  }

  static List<String> _sourceCousinNames(String source) {
    final names = <String>[];
    for (final match in _cousinMention.allMatches(source)) {
      for (var index = 1; index <= 2; index++) {
        final value = match.group(index)?.trim();
        if (value != null &&
            value.isNotEmpty &&
            !names.any((name) => name.toLowerCase() == value.toLowerCase())) {
          names.add(value);
        }
      }
    }
    return names;
  }

  static void _inferStableTargets({
    required List<_TranslatedCousinBlock> blocks,
    required List<String> sourceNames,
    required Map<String, String> targets,
  }) {
    if (blocks.isEmpty || sourceNames.isEmpty) return;
    final blockSets = <String, Set<int>>{};
    for (var index = 0; index < blocks.length; index++) {
      for (final candidate in _relationCandidates(blocks[index].text)) {
        (blockSets[candidate] ??= <int>{}).add(index);
      }
    }
    var stable = blockSets.entries
        .where((entry) => entry.value.length >= 2)
        .toList();
    stable = [
      for (final entry in stable)
        if (!stable.any(
          (other) =>
              other.key.length > entry.key.length &&
              other.key.contains(entry.key) &&
              other.value.length == entry.value.length &&
              other.value.containsAll(entry.value) &&
              entry.value.containsAll(other.value),
        ))
          entry,
    ];
    int earliest(String candidate) {
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
        final position = blocks[blockIndex].text.indexOf(candidate);
        if (position >= 0) return blockIndex * 100000 + position;
      }
      return 1 << 30;
    }

    stable.sort((left, right) {
      final frequency = right.value.length.compareTo(left.value.length);
      if (frequency != 0) return frequency;
      final position = earliest(left.key).compareTo(earliest(right.key));
      return position != 0 ? position : left.key.compareTo(right.key);
    });
    final usedTargets = targets.values.toSet();
    final missing = [
      for (final name in sourceNames)
        if (!targets.containsKey(name.toLowerCase())) name,
    ];
    final available = [
      for (final candidate in stable)
        if (!usedTargets.contains(candidate.key)) candidate.key,
    ];
    // Ambiguous evidence is not enough to assign a person's name. Require an
    // exact one-to-one match between unresolved source names and stable target
    // candidates; otherwise leave the draft untouched.
    if (available.length != missing.length) return;
    for (var index = 0; index < missing.length; index++) {
      targets[missing[index].toLowerCase()] = available[index];
    }
  }

  static Set<String> _relationCandidates(String text) {
    final candidates = <String>{};
    for (final relation in _anyRelation.allMatches(text)) {
      final before = text.substring(
        (relation.start - 6).clamp(0, text.length),
        relation.start,
      );
      final after = text.substring(
        relation.end,
        (relation.end + 6).clamp(0, text.length),
      );
      for (final span in [before, after]) {
        for (var start = 0; start < span.length; start++) {
          for (var length = 2; length <= 4; length++) {
            final end = start + length;
            if (end > span.length) break;
            final candidate = span.substring(start, end);
            if (_cjkCandidate.hasMatch(candidate) &&
                !_anyRelation.hasMatch(candidate) &&
                !_candidateBoundary.hasMatch(candidate) &&
                !_commonTargetWords.contains(candidate)) {
              candidates.add(candidate);
            }
          }
        }
      }
    }
    return candidates;
  }

  static _RepairBlock? _repairBlock({
    required String chapterPath,
    required ExtractedBlock block,
    required List<String> sourceNames,
    required Map<String, String> targets,
  }) {
    final translated = block.translatedHtml!;
    var currentText = TranslationConsistencyChecker.text(translated);
    final edits = <Map<String, String>>[];
    final replacements = <String>[];

    for (final sourceName in sourceNames) {
      final targetName = targets[sourceName.toLowerCase()];
      if (targetName == null || targetName.isEmpty) continue;
      final neutral = '表亲$targetName';
      final escapedName = RegExp.escape(targetName);
      final patterns = <RegExp>[
        RegExp('$_relationPattern\\s*$escapedName'),
        RegExp('$escapedName\\s*$_relationPattern'),
      ];
      var replaced = false;
      for (final pattern in patterns) {
        for (final match in pattern.allMatches(currentText).toList()) {
          final before = match.group(0)!;
          if (before == neutral ||
              edits.any((edit) => edit['before'] == before)) {
            continue;
          }
          if (currentText.split(before).length - 1 != 1) continue;
          edits.add({'before': before, 'after': neutral});
          currentText = currentText.replaceFirst(before, neutral);
          replacements.add('$before => $neutral');
          replaced = true;
        }
      }
      if (!replaced &&
          sourceNames.length > 1 &&
          !currentText.contains(neutral) &&
          currentText.split(targetName).length - 1 == 1) {
        edits.add({'before': targetName, 'after': neutral});
        currentText = currentText.replaceFirst(targetName, neutral);
        replacements.add('$targetName => $neutral');
      }
    }

    if (edits.isEmpty) return null;
    try {
      final html = ReviewTextPatch.apply(translated, edits);
      final repairedText = TranslationConsistencyChecker.text(html);
      for (final sourceName in sourceNames) {
        final targetName = targets[sourceName.toLowerCase()];
        if (targetName != null &&
            repairedText.contains(targetName) &&
            !repairedText.contains('表亲$targetName')) {
          return null;
        }
      }
      if (_badRelation.hasMatch(repairedText)) return null;
      return _RepairBlock(
        html: html,
        correction: BookRelationshipCorrection(
          chapterPath: chapterPath,
          blockId: block.id,
          sourceName: sourceNames.join(', '),
          before: replacements.join('; '),
          after: repairedText,
        ),
      );
    } on FormatException {
      return null;
    }
  }

  static bool _isChinese(String targetLanguage) => RegExp(
    r'chinese|中文|汉语|漢語|^zh',
    caseSensitive: false,
  ).hasMatch(targetLanguage);

  static String _blockKey(String chapterPath, String blockId) =>
      '$chapterPath\u0000$blockId';
}

class _CousinMentions {
  const _CousinMentions({
    required this.chapterPath,
    required this.blockId,
    required this.names,
    required this.explicitAge,
  });

  final String chapterPath;
  final String blockId;
  final List<String> names;
  final bool explicitAge;
}

class _TranslatedCousinBlock {
  const _TranslatedCousinBlock(this.text);

  final String text;
}

class _RepairBlock {
  const _RepairBlock({required this.html, required this.correction});

  final String html;
  final BookRelationshipCorrection correction;
}
