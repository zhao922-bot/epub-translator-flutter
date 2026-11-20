import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/localization/review_strings.dart';
import '../../../../shared/platform/platform_utils.dart';
import '../../domain/models/translation_config.dart';
import '../../infrastructure/translation_review_store.dart';
import 'review_dialogs.dart';
import 'review_models.dart';
import 'review_search.dart';
import 'translation_manual_review_page.dart';

class TranslationReviewRouteData {
  const TranslationReviewRouteData({
    required this.reportPath,
    required this.outputPath,
    required this.isChinese,
  });

  static const location = '/review';
  final String reportPath, outputPath;
  final bool isChinese;
}

class TranslationReviewPage extends StatefulWidget {
  const TranslationReviewPage({
    super.key,
    required this.reportPath,
    required this.outputPath,
    required this.isChinese,
  });

  final String reportPath, outputPath;
  final bool isChinese;

  static Future<void> open(
    BuildContext context, {
    required String reportPath,
    required String outputPath,
    required bool isChinese,
  }) async {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      await router.push<void>(
        TranslationReviewRouteData.location,
        extra: TranslationReviewRouteData(
          reportPath: reportPath,
          outputPath: outputPath,
          isChinese: isChinese,
        ),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TranslationReviewPage(
          reportPath: reportPath,
          outputPath: outputPath,
          isChinese: isChinese,
        ),
      ),
    );
  }

  @override
  State<TranslationReviewPage> createState() => _TranslationReviewPageState();
}

const _detailLimit = 200;

class _PreparedReview {
  _PreparedReview(this.report)
    : suggestions = (report['corrections'] as List)
          .cast<Map>()
          .map(ReviewSuggestion.new)
          .toList(),
      automaticCorrections =
          (report['automaticCorrections'] as List? ?? const [])
              .take(_detailLimit)
              .cast<Map>()
              .map(AutomaticReviewCorrection.new)
              .toList(),
      manualEdits = Map<String, String>.from(
        report['manualEdits'] as Map? ?? {},
      ),
      manuallyReviewed = (report['manuallyReviewed'] as List? ?? const [])
          .cast<String>()
          .toSet() {
    remaining = TranslationReviewStore.unresolvedBlockIds(
      report,
      manuallyReviewed,
    ).length;
    for (final suggestion in suggestions) {
      final custom = suggestion.customMarkup;
      if (custom != null) edited[suggestion.key] = custom;
      if (suggestion.accepted) accepted.add(suggestion.key);
    }
  }

  final Map<String, dynamic> report;
  final List<ReviewSuggestion> suggestions;
  final List<AutomaticReviewCorrection> automaticCorrections;
  final Map<String, String> manualEdits;
  final Set<String> manuallyReviewed;
  final edited = <String, String>{};
  final accepted = <String>{};
  late final int remaining;
}

class _TranslationReviewPageState extends State<TranslationReviewPage> {
  final _store = const TranslationReviewStore();
  final _search = ReviewSearch();
  final _searchController = TextEditingController();
  Map<String, dynamic>? _report;
  List<ReviewSuggestion> _suggestions = [];
  List<ReviewSuggestion> _matches = [];
  List<AutomaticReviewCorrection> _automaticCorrections = [];
  Set<String> _accepted = {};
  Map<String, String> _edited = {};
  Map<String, String> _manualEdits = {};
  Set<String> _manuallyReviewed = {};
  String? _error, _exported;
  bool _busy = false, _bilingual = false;
  int _remaining = 0, _loadVersion = 0;

  AppStrings get _strings =>
      AppStrings(widget.isChinese ? UiLanguage.chinese : UiLanguage.english);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TranslationReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reportPath != widget.reportPath ||
        oldWidget.outputPath != widget.outputPath) {
      _report = null;
      _suggestions = [];
      _matches = [];
      _automaticCorrections = [];
      _accepted.clear();
      _edited.clear();
      _manualEdits.clear();
      _manuallyReviewed.clear();
      _search.reset();
      _searchController.clear();
      _error = _exported = null;
      _busy = false;
      _load();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    try {
      final prepared = await _store.loadPrepared(
        widget.reportPath,
        _PreparedReview.new,
        expectedOutputPath: widget.outputPath,
      );
      if (!mounted || version != _loadVersion) return;
      final report = prepared.report;
      setState(() {
        _report = report;
        _suggestions = prepared.suggestions;
        _automaticCorrections = prepared.automaticCorrections;
        _filterSuggestions();
        _manualEdits = prepared.manualEdits;
        _manuallyReviewed = prepared.manuallyReviewed;
        _remaining = prepared.remaining;
        _accepted = prepared.accepted;
        _edited = prepared.edited;
        _bilingual =
            report['lastExportBilingual'] as bool? ??
            (report['rendering'] as Map)['bilingual'] == true;
        _exported = report['lastExportPath'] as String?;
      });
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = _strings.reviewReadFailed);
      }
    }
  }

  void _countRemaining() {
    _remaining = TranslationReviewStore.unresolvedBlockIds(
      _report!,
      _manuallyReviewed,
    ).length;
  }

  void _filterSuggestions() {
    final query = _search.query;
    _matches = query.isEmpty
        ? _suggestions
        : _suggestions
              .where((item) => item.searchText.contains(query))
              .toList();
  }

  Future<void> _export() async {
    final version = _loadVersion;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final output = await _store.export(
        reportPath: widget.reportPath,
        baseOutputPath: widget.outputPath,
        accepted: Set.of(_accepted),
        bilingual: _bilingual,
        editedSuggestions: Map.of(_edited),
        manualEdits: Map.of(_manualEdits),
        manuallyReviewed: Set.of(_manuallyReviewed),
      );
      if (mounted && version == _loadVersion) {
        setState(() => _exported = output);
      }
    } on ReviewChoicesSaveException catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() {
          _exported = error.outputPath;
          _error = _strings.reviewChoicesSaveFailed;
        });
      }
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = _strings.reviewExportFailed);
      }
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _manualReview() async {
    final version = _loadVersion;
    setState(() => _busy = true);
    try {
      final blocks = await _store.manualBlocks(_report!);
      if (!mounted || version != _loadVersion) return;
      final acceptedMarkup = {
        for (final item in _suggestions)
          if (_accepted.contains(item.key)) item.key: item.markup,
      };
      for (final block in blocks) {
        final proposed = acceptedMarkup[block['key']];
        if (proposed != null) block['proposedHtml'] = proposed;
      }
      final choices = await TranslationManualReviewPage.open(
        context,
        blocks: blocks,
        edits: _manualEdits,
        reviewed: _manuallyReviewed,
        isChinese: widget.isChinese,
      );
      if (!mounted || version != _loadVersion || choices == null) return;
      setState(() {
        _manualEdits
          ..clear()
          ..addAll(choices.edits);
        _manuallyReviewed
          ..clear()
          ..addAll(choices.reviewed);
        _accepted.removeAll(_manualEdits.keys);
        _countRemaining();
      });
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = _strings.reviewParagraphsReadFailed);
      }
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _edit(ReviewSuggestion item) async {
    final version = _loadVersion;
    final initial = item.editableText;
    if (initial == null) return;
    final strings = _strings;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => ReviewTextDialog(
        initialText: initial,
        strings: strings,
        title: strings.reviewEditSuggestionTitle,
        saveLabel: strings.reviewSaveSuggestion,
        maxLines: 12,
      ),
    );
    if (!mounted || version != _loadVersion || value == null) return;
    final markup = TranslationReviewStore.editText(item.markup, value);
    setState(() {
      item.updateMarkup(markup);
      _edited[item.key] = markup;
      _accepted.add(item.key);
      _filterSuggestions();
    });
  }

  Future<void> _openExport() async {
    final output = _exported;
    if (output == null || _busy) return;
    final version = _loadVersion;
    setState(() => _busy = true);
    try {
      if (PlatformUtils.isAndroid) {
        await PlatformUtils.shareFile(
          sourcePath: output,
          displayName: path.basename(output),
        );
      } else {
        final result = await OpenFilex.open(output);
        if (result.type != ResultType.done) throw StateError('Could not open');
      }
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = _strings.reviewOpenFailed);
      }
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: Text(strings.translationReviewTitle)),
      body: report == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _matches.length + 1,
              itemBuilder: (context, index) => index == 0
                  ? _summary(report, strings)
                  : _suggestionCard(_matches[index - 1], strings),
            ),
    );
  }

  Widget _summary(Map<String, dynamic> report, AppStrings strings) {
    final completeSnapshot =
        (report['rendering'] as Map)['completeSnapshot'] == true;
    final automaticCount =
        (report['automaticCorrections'] as List?)?.length ?? 0;
    final findings = (report['findings'] as List? ?? const []).cast<Map>();
    final unreviewed = report['unreviewed'] as List? ?? const [];
    final reasons = report['unreviewedReasons'] as Map?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.reviewSuggestionsHelp),
        const SizedBox(height: 12),
        if (automaticCount > 0)
          ExpansionTile(
            title: Text(strings.automaticReviewCorrections(automaticCount)),
            children: [
              for (final correction in _automaticCorrections)
                ListTile(
                  title: Text(correction.title),
                  subtitle: SelectableText(
                    '${strings.sourcePreview}: ${correction.source}\n'
                    '${strings.beforeAutomaticCorrection}: ${correction.before}\n'
                    '${strings.afterAutomaticCorrection}: ${correction.after}\n'
                    '${strings.reviewVerification}: ${correction.verification}',
                  ),
                ),
            ],
          ),
        Text(
          strings.reviewCoverage(
            report['reviewedBlocks'] ?? 0,
            report['skippedLowRiskBlocks'] ?? 0,
            unreviewed.length,
          ),
        ),
        Text(strings.reviewRemaining(_manuallyReviewed.length, _remaining)),
        if (completeSnapshot)
          TextButton.icon(
            onPressed: _busy ? null : _manualReview,
            icon: const Icon(Icons.edit_note),
            label: Text(strings.reviewAnyParagraph),
          ),
        Text(
          strings.reviewReservedBudget(
            report['reservedTokens'] ?? 0,
            report['tokenLimit'] ?? 0,
          ),
        ),
        if (findings.isNotEmpty)
          ExpansionTile(
            title: Text(strings.reviewConsistencyChecks),
            children: [
              for (final finding in findings.take(_detailLimit))
                ListTile(
                  title: Text(finding['block'] as String),
                  subtitle: Text(
                    (finding['checks'] as List)
                        .cast<Map>()
                        .map((check) => check['detail'])
                        .join('\n'),
                  ),
                ),
              if (findings.length > _detailLimit)
                Text(strings.reviewFindingLimit(_detailLimit)),
            ],
          ),
        if (unreviewed.isNotEmpty)
          ExpansionTile(
            title: Text(strings.reviewIncompleteBlocks),
            children: [
              for (final id in unreviewed.take(_detailLimit))
                ListTile(
                  dense: true,
                  title: Text(id as String),
                  subtitle: Text(strings.reviewIncompleteReason(reasons?[id])),
                ),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (completeSnapshot)
          DropdownButtonFormField<bool>(
            initialValue: _bilingual,
            decoration: InputDecoration(
              labelText: strings.reviewLocalExportFormat,
            ),
            items: [
              DropdownMenuItem(
                value: false,
                child: Text(strings.translatedOnly),
              ),
              DropdownMenuItem(
                value: true,
                child: Text(strings.reviewBilingual),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _bilingual = value ?? false),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy || (_suggestions.isEmpty && !completeSnapshot)
                  ? null
                  : _export,
              icon: const Icon(Icons.save_alt),
              label: Text(
                _busy
                    ? strings.reviewWorking
                    : strings.reviewExport(_accepted.length),
              ),
            ),
            if (_exported != null)
              OutlinedButton(
                onPressed: _busy ? null : _openExport,
                child: Text(strings.reviewOpenExport),
              ),
          ],
        ),
        if (_exported != null) SelectableText(_exported!),
        if (_suggestions.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(strings.reviewNoSuggestions),
          )
        else ...[
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: strings.reviewSuggestionSearch,
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (value) =>
                _search.update(value, () => setState(_filterSuggestions)),
          ),
          if (_matches.isEmpty) Text(strings.reviewNoSearchMatches),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _suggestionCard(ReviewSuggestion item, AppStrings strings) {
    final editable = !_busy && !_manualEdits.containsKey(item.key);
    Widget paragraph(String label, String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          SelectableText(text),
        ],
      ),
    );
    return Card(
      key: ValueKey(item.key),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            value: _accepted.contains(item.key),
            onChanged: editable
                ? (value) => setState(() {
                    if (value == true) {
                      _accepted.add(item.key);
                    } else {
                      _accepted.remove(item.key);
                    }
                  })
                : null,
            title: Text(item.title),
            subtitle: Text(item.issues),
          ),
          paragraph(strings.sourcePreview, item.source),
          paragraph(strings.reviewDraft, item.draft),
          paragraph(strings.reviewSuggestedText, item.text),
          if (item.editableText != null)
            TextButton.icon(
              onPressed: editable ? () => _edit(item) : null,
              icon: const Icon(Icons.edit_outlined),
              label: Text(strings.reviewEditSuggestion),
            ),
          if (item.consistencyFlags)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(strings.reviewSuggestionFlagged),
            ),
        ],
      ),
    );
  }
}
