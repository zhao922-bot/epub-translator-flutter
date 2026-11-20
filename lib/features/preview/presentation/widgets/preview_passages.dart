import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../preview_strings.dart';

RegExp? previewSearchPattern(String text) {
  final query = text.trim();
  return query.isEmpty
      ? null
      : RegExp(RegExp.escape(query), caseSensitive: false, unicode: true);
}

class PreviewPassages extends StatelessWidget {
  const PreviewPassages({
    super.key,
    required this.strings,
    required this.source,
    required this.translation,
    required this.parallel,
    required this.pattern,
    this.sourcePlaceholder = '',
    this.translationPlaceholder,
  });

  final AppStrings strings;
  final String source;
  final String translation;
  final bool parallel;
  final RegExp? pattern;
  final String sourcePlaceholder;
  final String? translationPlaceholder;

  @override
  Widget build(BuildContext context) {
    final original = _Passage(
      title: strings.sourcePreview,
      body: source,
      placeholder: sourcePlaceholder,
      pattern: pattern,
    );
    final translated = _Passage(
      title: strings.translatedPreview,
      body: translation,
      placeholder: translationPlaceholder ?? strings.noTranslationYet,
      pattern: pattern,
    );
    final query = pattern;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (query != null &&
            !query.hasMatch(source) &&
            !query.hasMatch(translation))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(strings.noMatchingText),
            ),
          ),
        if (parallel)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: original),
              const SizedBox(width: 28),
              Expanded(child: translated),
            ],
          )
        else ...[
          original,
          const SizedBox(height: 28),
          translated,
        ],
      ],
    );
  }
}

class _Passage extends StatelessWidget {
  const _Passage({
    required this.title,
    required this.body,
    required this.placeholder,
    required this.pattern,
  });

  final String title;
  final String body;
  final String placeholder;
  final RegExp? pattern;

  List<TextSpan> _highlightedSpans(TextStyle style) {
    final query = pattern;
    if (query == null) return const [];
    final spans = <TextSpan>[];
    var position = 0;
    for (final match in query.allMatches(body)) {
      if (match.start > position) {
        spans.add(TextSpan(text: body.substring(position, match.start)));
      }
      spans.add(TextSpan(text: match.group(0), style: style));
      position = match.end;
    }
    if (spans.isNotEmpty && position < body.length) {
      spans.add(TextSpan(text: body.substring(position)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(height: 1.8);
    final spans = _highlightedSpans(
      TextStyle(
        backgroundColor: theme.colorScheme.tertiaryContainer,
        color: theme.colorScheme.onTertiaryContainer,
        fontWeight: FontWeight.w700,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        if (spans.isEmpty)
          SelectableText(body.isEmpty ? placeholder : body, style: bodyStyle)
        else
          SelectableText.rich(TextSpan(children: spans), style: bodyStyle),
      ],
    );
  }
}
