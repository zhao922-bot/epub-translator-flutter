import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/review_strings.dart';
import '../../domain/models/translation_config.dart';
import '../../infrastructure/translation_review_store.dart';
import 'review_dialogs.dart';
import 'review_models.dart';
import 'review_search.dart';

class ManualReviewSelection {
  ManualReviewSelection(this.edits, this.reviewed);

  final Map<String, String> edits;
  final Set<String> reviewed;
}

class ManualReviewRouteData {
  const ManualReviewRouteData({
    required this.blocks,
    required this.edits,
    required this.reviewed,
    required this.isChinese,
  }) : _prepared = null;

  const ManualReviewRouteData._prepared(
    this._prepared, {
    required this.blocks,
    required this.edits,
    required this.reviewed,
    required this.isChinese,
  });

  static const location = '/review/manual';
  final List<Map<String, String>> blocks;
  final Map<String, String> edits;
  final Set<String> reviewed;
  final bool isChinese;
  final List<ManualReviewBlock>? _prepared;
}

/// Human review is independent of the model's suggestions and coverage.
class TranslationManualReviewPage extends StatefulWidget {
  const TranslationManualReviewPage({
    super.key,
    required this.blocks,
    required this.edits,
    required this.reviewed,
    required this.isChinese,
  }) : _prepared = null;

  TranslationManualReviewPage.fromRoute(ManualReviewRouteData data, {super.key})
    : blocks = data.blocks,
      edits = data.edits,
      reviewed = data.reviewed,
      isChinese = data.isChinese,
      _prepared = data._prepared;

  final List<Map<String, String>> blocks;
  final Map<String, String> edits;
  final Set<String> reviewed;
  final bool isChinese;
  final List<ManualReviewBlock>? _prepared;

  static Future<ManualReviewSelection?> open(
    BuildContext context, {
    required List<Map<String, String>> blocks,
    required Map<String, String> edits,
    required Set<String> reviewed,
    required bool isChinese,
  }) async {
    final initialEdits = Map<String, String>.of(edits);
    final initialReviewed = Set<String>.of(reviewed);
    final prepared = await compute(prepareManualReviewBlocks, (
      blocks: blocks,
      edits: initialEdits,
    ));
    if (!context.mounted) return null;
    final data = ManualReviewRouteData._prepared(
      prepared,
      blocks: blocks,
      edits: initialEdits,
      reviewed: initialReviewed,
      isChinese: isChinese,
    );
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      return router.push<ManualReviewSelection>(
        ManualReviewRouteData.location,
        extra: data,
      );
    }
    return Navigator.of(context).push<ManualReviewSelection>(
      MaterialPageRoute(
        builder: (_) => TranslationManualReviewPage.fromRoute(data),
      ),
    );
  }

  @override
  State<TranslationManualReviewPage> createState() =>
      _TranslationManualReviewPageState();
}

class _TranslationManualReviewPageState
    extends State<TranslationManualReviewPage> {
  final _search = ReviewSearch();
  late final _edits = Map<String, String>.of(widget.edits);
  late final _reviewed = Set<String>.of(widget.reviewed);
  late List<ManualReviewBlock> _blocks;
  late List<ManualReviewBlock> _matches;

  AppStrings get _strings =>
      AppStrings(widget.isChinese ? UiLanguage.chinese : UiLanguage.english);

  @override
  void initState() {
    super.initState();
    _blocks = widget._prepared ?? _prepareBlocks();
    _filterBlocks();
  }

  @override
  void didUpdateWidget(covariant TranslationManualReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.blocks, widget.blocks)) {
      _blocks = _prepareBlocks();
      _filterBlocks();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ManualReviewBlock> _prepareBlocks() =>
      prepareManualReviewBlocks((blocks: widget.blocks, edits: _edits));

  void _filterBlocks() {
    final query = _search.query;
    _matches = query.isEmpty
        ? _blocks
        : _blocks.where((block) => block.searchText.contains(query)).toList();
  }

  Future<void> _edit(ManualReviewBlock block) async {
    final strings = _strings;
    final initial = block.editableText;
    final markup = block.markup;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => initial == null
          ? ReviewReplaceDialog(markup: markup, strings: strings)
          : ReviewTextDialog(
              initialText: initial,
              strings: strings,
              title: strings.manualReviewEditTitle,
              saveLabel: strings.manualReviewSave,
              maxLines: 8,
            ),
    );
    if (!mounted || result == null || !_blocks.contains(block)) return;
    final edit = initial == null
        ? result
        : TranslationReviewStore.editText(markup, result);
    setState(() {
      _edits[block.key] = edit;
      _reviewed.add(block.key);
      block.updateEdit(edit);
      _filterBlocks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.manualReviewTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              ManualReviewSelection(Map.of(_edits), Set.of(_reviewed)),
            ),
            child: Text(strings.manualReviewKeepChoices),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.manualReviewHelp),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    labelText: strings.manualReviewSearch,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      _search.update(value, () => setState(_filterBlocks)),
                ),
                Text(
                  strings.manualReviewCounts(
                    _matches.length,
                    _reviewed.length,
                    _edits.length,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _matches.isEmpty && _search.query.isNotEmpty
                ? Center(child: Text(strings.reviewNoSearchMatches))
                : ListView.builder(
                    itemCount: _matches.length,
                    itemBuilder: (context, index) =>
                        _paragraph(_matches[index], strings),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(ManualReviewBlock block, AppStrings strings) {
    final key = block.key;
    final edited = _edits.containsKey(key);
    final reviewed = _reviewed.contains(key);
    final status = edited
        ? strings.manualReviewEdited
        : reviewed
        ? strings.manualReviewReviewed
        : strings.manualReviewPending;
    return Card(
      key: ValueKey(key),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ExpansionTile(
        key: ValueKey(key),
        title: Text(block.source, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${block.id} · $status'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.sourcePreview,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText(block.source),
                const SizedBox(height: 12),
                Text(
                  strings.manualReviewCurrent,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SelectableText(block.text),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.manualReviewConfirmParagraph),
                  value: reviewed,
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _reviewed.add(key);
                    } else {
                      _reviewed.remove(key);
                    }
                  }),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _edit(block),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(strings.manualReviewEditParagraph),
                    ),
                    if (edited)
                      TextButton(
                        onPressed: () => setState(() {
                          _edits.remove(key);
                          _reviewed.remove(key);
                          block.updateEdit(null);
                          _filterBlocks();
                        }),
                        child: Text(strings.manualReviewUndo),
                      ),
                  ],
                ),
                if (block.editableText == null)
                  Text(strings.manualReviewInlineHelp),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
