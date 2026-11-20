import 'package:html/parser.dart' as html;

import '../../infrastructure/epub/translation_consistency_checker.dart';
import '../../infrastructure/translation_review_store.dart';

String _plainText(String markup) => html.parseFragment(markup).text ?? '';

class _ReviewText {
  const _ReviewText(this.markup, this.text, this.editableText);

  factory _ReviewText.suggestion(String markup) => _ReviewText(
    markup,
    _plainText(markup),
    TranslationReviewStore.editableText(markup),
  );

  factory _ReviewText.paragraph(String markup) => _ReviewText(
    markup,
    TranslationConsistencyChecker.text(markup),
    TranslationReviewStore.editableText(markup),
  );

  final String markup;
  final String text;
  final String? editableText;
}

class ReviewSuggestion {
  ReviewSuggestion(Map item)
    : key = TranslationReviewStore.suggestionKey(item),
      title = '${item['chapter']} · ${item['id']}',
      source = _plainText(item['sourceHtml'] as String),
      draft = _plainText(item['beforeHtml'] as String),
      issues = (item['issues'] as List).join('\n'),
      consistencyFlags = (item['checksAfter'] as List?)?.isNotEmpty ?? false,
      accepted = item['accepted'] == true,
      customMarkup = item['customHtml'] is String
          ? item['customHtml'] as String
          : null {
    _updateText(customMarkup ?? item['afterHtml'] as String);
  }

  final String key, title, source, draft, issues;
  final bool consistencyFlags, accepted;
  final String? customMarkup;
  late final String _baseSearchText = '$title\n$issues\n$source\n$draft'
      .toLowerCase();
  late _ReviewText _translation;
  late String searchText;

  String get markup => _translation.markup;
  String get text => _translation.text;
  String? get editableText => _translation.editableText;

  void updateMarkup(String markup) => _updateText(markup);

  void _updateText(String markup) {
    _translation = _ReviewText.suggestion(markup);
    searchText = '$_baseSearchText\n${_translation.text.toLowerCase()}';
  }
}

class AutomaticReviewCorrection {
  AutomaticReviewCorrection(Map item)
    : title = '${item['chapter']} · ${item['id']}',
      source = _plainText(item['sourceHtml'] as String),
      before = _plainText(item['beforeHtml'] as String),
      after = _plainText(item['afterHtml'] as String),
      verification = item['verificationReason'] as String;

  final String title, source, before, after, verification;
}

class ManualReviewBlock {
  ManualReviewBlock(Map<String, String> block, String? edit)
    : key = block['key']!,
      id = block['id']!,
      chapter = block['chapter'] ?? '',
      source = TranslationConsistencyChecker.text(block['sourceHtml']!),
      _baselineMarkup = block['proposedHtml'] ?? block['beforeHtml']! {
    updateEdit(edit);
  }

  final String key, id, chapter, source, _baselineMarkup;
  late final String _baseSearchText = '$chapter\n$id\n$source'.toLowerCase();
  late final _ReviewText _baseline = _ReviewText.paragraph(_baselineMarkup);
  late _ReviewText _translation;
  late String searchText;

  String get markup => _translation.markup;
  String get text => _translation.text;
  String? get editableText => _translation.editableText;

  void updateEdit(String? edit) {
    _translation = edit == null ? _baseline : _ReviewText.paragraph(edit);
    searchText = '$_baseSearchText\n${_translation.text.toLowerCase()}';
  }
}

List<ManualReviewBlock> prepareManualReviewBlocks(
  ({List<Map<String, String>> blocks, Map<String, String> edits}) data,
) => [
  for (final block in data.blocks)
    ManualReviewBlock(block, data.edits[block['key']]),
];
