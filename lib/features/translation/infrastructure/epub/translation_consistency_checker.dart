import 'dart:math' as math;

import 'package:html/parser.dart' as html;

import '../../domain/models/translation_config.dart';
import 'proper_name_normalizer.dart';

/// Cheap, deterministic signals, never automatic edits. Ambiguous amounts,
/// nicknames and negations need context; a signal is not proof of an error.
class TranslationConsistencyChecker {
  const TranslationConsistencyChecker();

  static String text(String markup) {
    final fragment = html.parseFragment(markup);
    for (final node in fragment.querySelectorAll(
      'script,style,code,pre,sup,math,svg,[translate="no"]',
    )) {
      node.remove();
    }
    return (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<Map<String, String>> check({
    required String sourceHtml,
    required String translatedHtml,
    required TranslationConfig config,
    Map<String, String> knownTerms = const {},
  }) {
    final source = text(sourceHtml);
    final target = text(translatedHtml);
    final findings = <Map<String, String>>[];
    String t(String zh, String en) =>
        config.uiLanguage == UiLanguage.chinese ? zh : en;
    void add(String code, String detail) =>
        findings.add({'code': code, 'detail': detail});
    final chinese = RegExp(
      r'chinese|中文|汉语|漢語|^zh',
      caseSensitive: false,
    ).hasMatch(config.targetLanguage);
    if (chinese) {
      if (RegExp(
            r'\bdollars?\b|\bUSD\b|\$',
            caseSensitive: false,
          ).hasMatch(source) &&
          !RegExp(
            r'美元|美金|加元|加币|澳元|港元|港币|新元|新币|新加坡元|纽元|紐元|纽币|紐幣|元美金|dollars?|USD|CAD|AUD|HKD|SGD|NZD|\$',
            caseSensitive: false,
          ).hasMatch(target)) {
        add(
          'currency',
          t(
            '美元等 dollar 币种的名称缺失或含糊，请结合原文确认。',
            'Dollar denomination is missing or ambiguous.',
          ),
        );
      }
      for (final entry in <String, String>{
        r'\beuros?\b|€': r'欧元|歐元|EUR|€',
        r'\bpounds?\s+sterling\b|£': r'英镑|英鎊|GBP|£',
        r'\bcents?\b': r'美分|欧分|歐分|加分|仙|cents?|¢',
      }.entries) {
        if (RegExp(entry.key, caseSensitive: false).hasMatch(source) &&
            !RegExp(entry.value, caseSensitive: false).hasMatch(target)) {
          add(
            'currency',
            t(
              '请核对原文币种及分币单位，避免替换成本地货币。',
              'Check the original currency/subunit; do not convert it to local currency.',
            ),
          );
        }
      }
    }
    final sourceNumbers = numbers(source, chinese: false);
    final targetNumbers = numbers(target, chinese: chinese);
    if (sourceNumbers.isNotEmpty &&
        sourceNumbers.any((n) => !targetNumbers.contains(n))) {
      add(
        'number',
        t(
          '原文数字可能缺失或变化：${sourceNumbers.where((n) => !targetNumbers.contains(n)).take(8).join(', ')}。请核对文字写法和单位换算。',
          'A source number is missing or changed: ${sourceNumbers.where((n) => !targetNumbers.contains(n)).take(8).join(', ')}. Check spelling and unit conversions.',
        ),
      );
    }
    if (chinese) {
      // Occurrence counts and temporal ordinals are not interchangeable.
      // This is a review signal, not permission to rewrite an ambiguous date.
      const ordinals = [
        'first',
        'second',
        'third',
        'fourth',
        'fifth',
        'sixth',
        'seventh',
        'eighth',
        'ninth',
        'tenth',
      ];
      final sourceOrdinals = <String, int>{};
      for (final match in RegExp(
        r'\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(?:time|day|morning|evening|night|week|month|year|occasion)\b',
        caseSensitive: false,
      ).allMatches(source)) {
        final value = '${ordinals.indexOf(match[1]!.toLowerCase()) + 1}';
        sourceOrdinals.update(value, (n) => n + 1, ifAbsent: () => 1);
      }
      final targetOrdinals = <String, int>{};
      for (final match in RegExp(
        r'第([零〇一二两兩三四五六七八九十百0-9]+)',
      ).allMatches(target)) {
        for (final value in numbers(match[1]!, chinese: true)) {
          targetOrdinals.update(value, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      if (sourceOrdinals.entries.any(
        (e) => (targetOrdinals[e.key] ?? 0) < e.value,
      )) {
        add(
          'ordinal',
          t(
            '请核对事件次数与日期先后，原文序数可能遗漏或重复。',
            'Check occurrence counts and chronological ordinals for omissions or duplicates.',
          ),
        );
      }
    }
    final letters = RegExp(
      r'\b[B-HJ-Z]\b',
    ).allMatches(source).map((m) => m[0]!).toSet();
    if (letters.any(
      (letter) => !RegExp('(?<![A-Za-z])$letter(?![A-Za-z])').hasMatch(target),
    )) {
      add(
        'literalLetter',
        t(
          '原文独立字母或姓名首字母可能被替换，请核对其书写形式。',
          'Check whether a standalone written letter or initial was replaced.',
        ),
      );
    }
    final lockedTerms = {
      for (final term in ProperNameNormalizer.parseGlossary(
        config.lockedGlossary,
      ))
        term.source: term.target,
    };
    final terms = <String, String>{...knownTerms, ...lockedTerms};
    for (final term in terms.entries) {
      final sourcePattern = RegExp(
        '(?<![A-Za-z])${RegExp.escape(term.key)}(?![A-Za-z])',
        caseSensitive: false,
      );
      if (term.key.isNotEmpty &&
          term.value.isNotEmpty &&
          sourcePattern.hasMatch(source) &&
          !target.contains(term.value) &&
          (lockedTerms.containsKey(term.key) ||
              !_allowsInsertedContext(target, term.value))) {
        add(
          'glossary',
          t(
            '请核对人物／术语：${term.key} => ${term.value}。有意使用的昵称和缩写需结合上下文判断。',
            'Check name/term: ${term.key} => ${term.value}. Intentional abbreviations need context.',
          ),
        );
      }
    }
    return findings;
  }

  // Soft memory hints may be separated by a modifier, e.g. 美国驻伦敦公使.
  // Explicit user locks remain exact; short names are never fuzzy-matched.
  static bool _allowsInsertedContext(String target, String term) {
    if (!RegExp(r'^[\u4e00-\u9fff]{4,8}$').hasMatch(term)) return false;
    final splits = {
      2,
      if (RegExp(r'(小姐|先生|夫人|公使)$').hasMatch(term)) term.length - 2,
    };
    return splits.any(
      (at) => RegExp(
        '${RegExp.escape(term.substring(0, at))}.{0,16}${RegExp.escape(term.substring(at))}',
      ).hasMatch(target),
    );
  }

  /// Include contextual risks even when a deterministic mismatch was not found.
  /// These select a review, but are not displayed as confirmed defects.
  int riskScore(String sourceHtml, List<Map<String, String>> findings) {
    final source = text(sourceHtml);
    var score = findings.length * 10;
    if (RegExp(
      r'\b(not|never|neither|without|unless|alas|but|however|yet|instead|nickname|called)\b|\b\w+n[’\x27]t\b',
      caseSensitive: false,
    ).hasMatch(source)) {
      score += 3;
    }
    if (RegExp(
      r'\b(dollars?|cents?|euros?)\b|[\d$£€]',
      caseSensitive: false,
    ).hasMatch(source)) {
      score += 2;
    }
    if (RegExp(
      r'\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b|\b(?:Mr|Mrs|Miss|Sir|Dr)\.?\s+[A-Z]|\b[B-HJ-Z]\b|\b(?:go|goes|went|gone|come|came|walked|travelled|traveled)\s+(?:up|down|over)\b',
    ).hasMatch(source)) {
      score += 3;
    }
    return score;
  }

  static Set<String> numbers(String text, {required bool chinese}) {
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    if (!chinese) {
      text = text.replaceAll(
        RegExp(
          r'\b(?:no|any|some|every) one\b|\bone another\b',
          caseSensitive: false,
        ),
        ' ',
      );
    } else {
      // 点 followed by a clock unit is not a decimal separator. Preserve
      // genuine decimal amounts such as 十一点一美元.
      text = text.replaceAllMapped(
        RegExp(r'([零〇一二两兩三四五六七八九十]+)[点點]([零〇一二两兩三四五六七八九十]+)(?=[刻分秒])'),
        (m) => '${m[1]}:${m[2]}',
      );
    }
    final result = <String>{};
    String normalized(num value) => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    for (final match in RegExp(
      r'(?<![\w])[−-]?\d+(?:,\d{3})*(?:\.\d+)?',
    ).allMatches(text)) {
      final value = num.tryParse(
        match[0]!.replaceAll(',', '').replaceAll('−', '-'),
      );
      if (value != null && value.isFinite) result.add(normalized(value));
    }
    if (!chinese) result.addAll(_englishNumbers(text).map(normalized));
    if (chinese) {
      for (final match in RegExp(
        r'[负負]?[零〇一二两兩三四五六七八九十百千万萬亿億]+(?:[点點][零〇一二三四五六七八九]+)?',
      ).allMatches(text)) {
        final value = _chineseNumber(match[0]!);
        if (value != null && value.isFinite) {
          final centuries = RegExp(
            r'^(?:个|個)?世[纪紀]',
          ).hasMatch(text.substring(match.end));
          result.add(normalized(value * (centuries ? 100 : 1)));
        }
      }
    }
    return result;
  }

  /// Conservative application gate, separate from source-omission warnings.
  /// A new numeric claim needs source support; ambiguous unit conversions or
  /// idioms remain proposals. Existing draft numbers do not become new risks.
  static Set<String> introducedNumbers({
    required String sourceHtml,
    required String beforeHtml,
    required String afterHtml,
  }) {
    Set<String> values(String markup) {
      var value = text(markup);
      const ordinals = [
        'first',
        'second',
        'third',
        'fourth',
        'fifth',
        'sixth',
        'seventh',
        'eighth',
        'ninth',
        'tenth',
      ];
      value = value.replaceAllMapped(
        RegExp(
          r'\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b',
          caseSensitive: false,
        ),
        (m) => '${ordinals.indexOf(m[0]!.toLowerCase()) + 1}',
      );
      return {
        ...numbers(value, chinese: false),
        ...numbers(value, chinese: true),
      };
    }

    return values(
      afterHtml,
    ).difference({...values(sourceHtml), ...values(beforeHtml)});
  }

  static Iterable<num> _englishNumbers(String text) sync* {
    const small = {
      'zero': 0,
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      'six': 6,
      'seven': 7,
      'eight': 8,
      'nine': 9,
      'ten': 10,
      'eleven': 11,
      'twelve': 12,
      'thirteen': 13,
      'fourteen': 14,
      'fifteen': 15,
      'sixteen': 16,
      'seventeen': 17,
      'eighteen': 18,
      'nineteen': 19,
      'twenty': 20,
      'thirty': 30,
      'forty': 40,
      'fifty': 50,
      'sixty': 60,
      'seventy': 70,
      'eighty': 80,
      'ninety': 90,
    };
    final word =
        '(?:${[...small.keys, 'hundred', 'thousand', 'million'].join('|')})';
    for (final match in RegExp(
      '\\b$word(?:[ -]+(?:and[ -]+)?$word)*\\b',
      caseSensitive: false,
    ).allMatches(text)) {
      var total = 0, section = 0;
      for (final token in match[0]!.toLowerCase().split(RegExp('[ -]+'))) {
        if (small.containsKey(token)) {
          section += small[token]!;
        }
        if (token == 'hundred') section = (section == 0 ? 1 : section) * 100;
        if (token == 'thousand' || token == 'million') {
          total +=
              (section == 0 ? 1 : section) *
              (token == 'thousand' ? 1000 : 1000000);
          section = 0;
        }
      }
      final tail = text.substring(match.end);
      final centuries = RegExp(
        r'^\s+centur(?:y|ies)\b',
        caseSensitive: false,
      ).hasMatch(tail);
      yield (total + section) * (centuries ? 100 : 1);
    }
  }

  static num? _chineseNumber(String text) {
    if (text.startsWith('负') || text.startsWith('負')) {
      final value = _chineseNumber(text.substring(1));
      return value == null ? null : -value;
    }
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = {
      '十': 10,
      '百': 100,
      '千': 1000,
      '万': 10000,
      '萬': 10000,
      '亿': 100000000,
      '億': 100000000,
    };
    final parts = text.split(RegExp('[点點]'));
    final chars = parts.first.split('');
    num integer;
    if (chars.every(digits.containsKey)) {
      integer = num.parse(chars.map((c) => digits[c]).join());
    } else {
      var total = 0, section = 0, digit = 0;
      for (final char in chars) {
        if (digits.containsKey(char)) {
          digit = digits[char]!;
        } else {
          final unit = units[char]!;
          if (unit < 10000) {
            section += (digit == 0 ? 1 : digit) * unit;
          } else {
            total += (section + digit) * unit;
            section = 0;
          }
          digit = 0;
        }
      }
      integer = total + section + digit;
    }
    if (parts.length == 1) return integer;
    return num.tryParse(
      '$integer.${parts[1].split('').map((c) => digits[c]).join()}',
    );
  }
}

/// Bounded source-only retrieval. Distant facts (e.g. an earlier gold watch)
/// can clarify a later reference without attaching the entire book each time.
class ReviewEvidenceIndex {
  final Map<String, List<String>> _byWord = {};
  final Map<String, int> _origins = {};
  final Map<String, int> _references = {};
  final Map<String, String> _cores = {};
  final Map<String, int> _documentFrequency = {};
  int _documentCount = 0;
  static const _stop = {
    'this',
    'that',
    'with',
    'from',
    'they',
    'them',
    'there',
    'their',
    'then',
    'were',
    'have',
    'been',
    'what',
    'when',
    'would',
    'could',
    'said',
    'into',
    'about',
    'which',
    'some',
    'only',
    'very',
    'your',
    'shall',
  };
  Iterable<String> _words(String text) => RegExp(r'[A-Za-z]{4,}')
      .allMatches(text.toLowerCase())
      .map((m) => m[0]!)
      .where((w) => !_stop.contains(w))
      .toSet()
      .take(96);
  void add(String text, {String before = '', String after = ''}) {
    // Index the complete paragraph, but retain only bounded evidence windows.
    // Neighbours include facts introduced immediately after a reference, such
    // as the six-line prophecy following the mention of a library window.
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    _documentCount++;
    final leading = before.length > 160
        ? before.substring(before.length - 160)
        : before;
    final trailing = after.length > 320 ? after.substring(0, 320) : after;
    final words = _words(normalized).toList();
    for (final word in words) {
      final pos = normalized.toLowerCase().indexOf(word);
      final start = pos > 160 ? pos - 160 : 0;
      final end = (start + 400).clamp(0, normalized.length);
      final snippet = '$leading ${normalized.substring(start, end)} $trailing'
          .trim();
      if (!_byWord.containsKey(word) && _byWord.length >= 768) continue;
      _documentFrequency.update(word, (n) => n + 1, ifAbsent: () => 1);
      final values = _byWord.putIfAbsent(word, () => []);
      if (!values.contains(snippet)) {
        // Keep early introductions and recent references. Keeping only the
        // first six occurrences loses later explanations in longer books.
        if (values.length == 6) {
          final removed = values.removeAt(2);
          final remaining = _references[removed]! - 1;
          if (remaining == 0) {
            _references.remove(removed);
            _origins.remove(removed);
            _cores.remove(removed);
          } else {
            _references[removed] = remaining;
          }
        }
        values.add(snippet);
        _origins[snippet] = normalized.hashCode;
        _cores[snippet] = normalized.substring(start, end);
        _references.update(snippet, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  List<String> retrieve(
    String source, {
    Iterable<String> excludeSources = const [],
  }) {
    final excluded = {
      source.replaceAll(RegExp(r'\s+'), ' ').trim().hashCode,
      ...excludeSources.map(
        (s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().hashCode,
      ),
    };
    final query = source.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final phrases = RegExp(
      r'\b[a-z]{4,} [a-z]{4,}\b',
    ).allMatches(query).map((m) => m[0]!).toSet();
    final scores = <String, double>{};
    for (final word in _words(source)) {
      final frequency = _documentFrequency[word] ?? 0;
      final weight = math.log(1 + (_documentCount + 1) / (frequency + 1));
      for (final snippet in _byWord[word] ?? const <String>[]) {
        if (excluded.contains(_origins[snippet]) || source.contains(snippet)) {
          continue;
        }
        scores.update(snippet, (v) => v + weight, ifAbsent: () => weight);
      }
    }
    for (final snippet in scores.keys.toList()) {
      // Neighbours supply context, but must not boost a match merely because
      // they repeat the query itself from an adjacent paragraph.
      final lower = _cores[snippet]!.toLowerCase();
      scores[snippet] =
          (scores[snippet]! + phrases.where(lower.contains).length * 4) /
          math.sqrt(12 + _words(lower).length);
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final origins = <int>{};
    return ranked
        .where((e) => origins.add(_origins[e.key]!))
        .take(3)
        .map((e) => e.key)
        .toList();
  }
}
