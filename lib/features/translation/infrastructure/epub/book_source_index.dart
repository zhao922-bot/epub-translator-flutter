import '../../domain/models/inspected_chapter.dart';

/// Bounded source-only hints from the entire selection, including logical
/// sections packed into a single XHTML. No additional model request is needed.
class BookSourceIndex {
  static Map<String, Object> build(List<InspectedChapter> chapters) {
    final counts = <String, int>{};
    final names = <String, int>{};
    final nameContextCounts = <String, int>{};
    final titledNames = <String>{};
    final nameEvidence = <String, String>{};
    final sentenceStart = RegExp(r'''(?:[.!?]["'”’)]*\s*|^["'“‘(\s]*)$''');
    const common = {
      'The',
      'This',
      'That',
      'Then',
      'There',
      'When',
      'What',
      'Which',
      'They',
      'Their',
      'Have',
      'From',
      'After',
      'Before',
      'With',
      'Without',
      'Upon',
      'Some',
      'Only',
      'Every',
      'Even',
      'But',
      'And',
      'His',
      'Her',
      'She',
      'You',
      'Your',
      'Yes',
      'One',
      'Two',
      'Three',
      'Four',
      'Five',
      'Six',
      'Seven',
      'Eight',
      'Nine',
      'Ten',
      'Chapter',
      'Project',
      'Gutenberg',
      'English',
      'Miss',
      'Mrs',
      'Sir',
      'Lord',
      'Lady',
      'Duke',
      'Mr',
      'New',
    };
    final evidence = <String, String>{};
    final relations = <String>[];
    final phrases = RegExp(
      r"\b[A-Z][a-z]{2,}(?:['’]s)?(?:\s+[A-Z][a-z]{2,}(?:['’]s)?){1,4}\b",
    );
    final relationships = RegExp(
      r'\b(eldest|younger|older|twins|brothers?|sisters?|children)\b',
      caseSensitive: false,
    );
    for (final chapter in chapters.where((c) => c.includeInTranslation)) {
      for (final block in chapter.blocks) {
        final text = block.sourceText.replaceAll(RegExp(r'\s+'), ' ');
        final seenNames = <String>{};
        final contextualNames = <String>{};
        for (final match in RegExp(r"\b[A-Z][a-z]{2,}\b").allMatches(text)) {
          final name = match[0]!;
          if (common.contains(name) ||
              (!names.containsKey(name) && names.length >= 1024)) {
            continue;
          }
          if (seenNames.add(name)) {
            names.update(name, (n) => n + 1, ifAbsent: () => 1);
            nameEvidence.putIfAbsent(
              name,
              () => text.substring(
                (match.start - 100).clamp(0, text.length),
                (match.end + 180).clamp(0, text.length),
              ),
            );
          }
          // Sentence-opening capitals alone are weak name evidence. Repeated
          // names inside sentences and possessives should survive the limit
          // even when common sentence starters occur more frequently.
          final possessive =
              text.startsWith("'s", match.end) ||
              text.startsWith('’s', match.end);
          final prefix = text.substring(
            (match.start - 80).clamp(0, match.start),
            match.start,
          );
          final titled = RegExp(
            r'\b(?:Mr|Mrs|Ms|Miss|Dr|Sir|Lady|Lord|Professor|Captain|Reverend)\.?\s+$',
          ).hasMatch(prefix);
          if (titled) titledNames.add(name);
          if ((titled ||
                  possessive ||
                  !sentenceStart.hasMatch(
                    text.substring(
                      (match.start - 80).clamp(0, match.start),
                      match.start,
                    ),
                  )) &&
              contextualNames.add(name)) {
            final weight = possessive ? 3 : 1;
            nameContextCounts.update(
              name,
              (n) => n + weight,
              ifAbsent: () => weight,
            );
          }
        }
        final seen = <String>{};
        for (final match in phrases.allMatches(text)) {
          final words = match[0]!.split(' ');
          for (var start = 0; start < words.length - 1; start++) {
            for (
              var size = 2;
              size <= 4 && start + size <= words.length;
              size++
            ) {
              final term = words.sublist(start, start + size).join(' ');
              if (term.contains('Gutenberg') ||
                  term.startsWith('The ') ||
                  !seen.add(term)) {
                continue;
              }
              if (!counts.containsKey(term) && counts.length >= 2048) continue;
              counts.update(term, (n) => n + 1, ifAbsent: () => 1);
              evidence.putIfAbsent(term, () {
                final from = (match.start - 35).clamp(0, text.length);
                return text.substring(
                  from,
                  (match.end + 85).clamp(from, text.length),
                );
              });
            }
          }
        }
        if (relations.length < 12) {
          for (final sentence in text.split(RegExp(r'(?<=[.!?])\s+'))) {
            if (sentence.length <= 400 &&
                relationships.hasMatch(sentence) &&
                !relations.contains(sentence)) {
              relations.add(sentence);
              if (relations.length == 12) break;
            }
          }
        }
      }
    }
    final ranked = counts.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) {
        final cmp = b.value.compareTo(a.value);
        return cmp != 0 ? cmp : a.key.compareTo(b.key);
      });
    final rankedNames = names.entries.where((e) => e.value >= 3).toList()
      ..sort((a, b) {
        // A title is strong person-name evidence. Its period must not demote
        // the following surname as an ordinary sentence-opening capital.
        final person = (titledNames.contains(b.key) ? 1 : 0).compareTo(
          titledNames.contains(a.key) ? 1 : 0,
        );
        if (person != 0) return person;
        final context = (nameContextCounts[b.key] ?? 0).compareTo(
          nameContextCounts[a.key] ?? 0,
        );
        if (context != 0) return context;
        final frequency = b.value.compareTo(a.value);
        return frequency != 0 ? frequency : a.key.compareTo(b.key);
      });
    return {
      'recurringTerms': [
        for (final e in ranked.take(24))
          {
            'source': e.key,
            'occurrences': e.value,
            'evidence': evidence[e.key]!,
          },
      ],
      'recurringNames': [
        for (final e in rankedNames.take(32))
          {
            'source': e.key,
            'occurrences': e.value,
            'evidence': nameEvidence[e.key]!,
          },
      ],
      'relationshipEvidence': relations,
    };
  }
}
