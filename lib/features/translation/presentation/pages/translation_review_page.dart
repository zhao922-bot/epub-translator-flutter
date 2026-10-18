import 'translation_manual_review_page.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../../../../shared/platform/platform_utils.dart';
import '../../infrastructure/translation_review_store.dart';

class TranslationReviewPage extends StatefulWidget {
  const TranslationReviewPage({
    super.key,
    required this.reportPath,
    required this.outputPath,
    required this.isChinese,
  });
  final String reportPath, outputPath;
  final bool isChinese;
  @override
  State<TranslationReviewPage> createState() => _TranslationReviewPageState();
}

class _TranslationReviewPageState extends State<TranslationReviewPage> {
  final _store = const TranslationReviewStore();
  Map<String, dynamic>? _report;
  final _accepted = <String>{};
  String? _error, _exported;
  bool _busy = false, _bilingual = false;
  final _edited = <String, String>{};
  final _manualEdits = <String, String>{};
  final _manuallyReviewed = <String>{};
  int get _remaining => TranslationReviewStore.unresolvedBlockIds(
    _report ?? {},
    _manuallyReviewed,
  ).length;

  String t(String zh, String en) => widget.isChinese ? zh : en;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final report = await _store.load(
        widget.reportPath,
        expectedOutputPath: widget.outputPath,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _manualEdits.addAll(
          Map<String, String>.from(report['manualEdits'] as Map? ?? {}),
        );
        _manuallyReviewed.addAll(
          (report['manuallyReviewed'] as List? ?? []).cast<String>(),
        );
        _bilingual =
            report['lastExportBilingual'] as bool? ??
            (report['rendering'] as Map)['bilingual'] == true;
        _exported = report['lastExportPath'] as String?;
        for (final item in (report['corrections'] as List).cast<Map>()) {
          if (item['customHtml'] is String) {
            _edited[TranslationReviewStore.suggestionKey(item)] =
                item['customHtml'] as String;
          }
          if (item['accepted'] == true) {
            _accepted.add(TranslationReviewStore.suggestionKey(item));
          }
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '无法读取复核报告，文件可能已移动或来自旧版本。',
            'Could not read the review report. It may have moved or belong to an older version.',
          ),
        );
      }
    }
  }

  Future<void> _export() async {
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
      if (mounted) setState(() => _exported = output);
    } on ReviewChoicesSaveException catch (error) {
      if (mounted) {
        setState(() {
          _exported = error.outputPath;
          _error = t(
            '复核版已导出，但无法保存选择记录。请保留导出的文件。',
            'The reviewed EPUB was exported, but choices could not be saved. Keep the exported file.',
          );
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '导出未完成。请确认原译本仍在原位置且未修改，并检查输出目录是否可写。',
            'Export did not finish. Check that the baseline EPUB is unchanged and the output directory is writable.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualReview() async {
    setState(() => _busy = true);
    try {
      final blocks = await _store.manualBlocks(_report!);
      if (!mounted) return;
      final suggestions = {
        for (final item in (_report!['corrections'] as List).cast<Map>())
          TranslationReviewStore.suggestionKey(item): item,
      };
      for (final block in blocks) {
        final key = block['key']!;
        if (_accepted.contains(key)) {
          block['proposedHtml'] =
              _edited[key] ?? suggestions[key]!['afterHtml'] as String;
        }
      }
      final choices = await Navigator.push<ManualReviewSelection>(
        context,
        MaterialPageRoute(
          builder: (_) => TranslationManualReviewPage(
            blocks: blocks,
            edits: _manualEdits,
            reviewed: _manuallyReviewed,
            isChinese: widget.isChinese,
          ),
        ),
      );
      if (!mounted || choices == null) return;
      setState(() {
        _manualEdits
          ..clear()
          ..addAll(choices.edits);
        _manuallyReviewed
          ..clear()
          ..addAll(choices.reviewed);
        _accepted.removeAll(_manualEdits.keys);
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '无法读取可校对段落，请检查报告是否完整。',
            'Could not load paragraphs from this report.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Map item) async {
    final key = TranslationReviewStore.suggestionKey(item);
    final markup = _edited[key] ?? item['afterHtml'] as String;
    final initial = TranslationReviewStore.editableText(markup);
    if (initial == null) return;
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('调整这条建议', 'Edit this suggestion')),
        content: SizedBox(
          width: 600,
          child: TextField(controller: controller, minLines: 4, maxLines: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text);
              }
            },
            child: Text(t('保存并选用', 'Save and accept')),
          ),
        ],
      ),
    );
    // The dialog's exit animation may still reference its controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (!mounted || value == null) return;
    setState(() {
      _edited[key] = TranslationReviewStore.editText(markup, value);
      _accepted.add(key);
    });
  }

  String _reason(Object? code) => switch (code) {
    'budgetLimit' => t(
      '达到复核预算；下次继续可补审。',
      'Review budget reached; resume to continue.',
    ),
    'unsupportedRewrite' => t(
      '建议缺少可靠引文、明确理由或高置信度；保留原译文。',
      'Rewrite lacked supported evidence or confidence; draft retained.',
    ),
    'invalidHtml' => t(
      '建议未通过结构或文本质量校验；保留原译文。',
      'Suggestion failed structure or text validation; draft retained.',
    ),
    'requestFailed' => t(
      '复核请求失败；保留原译文。',
      'Review request failed; draft retained.',
    ),
    'invalidResponse' => t(
      '模型响应格式或内容不完整；保留原译文。',
      'Incomplete or invalid model response; draft retained.',
    ),
    _ => t('旧报告未记录具体原因。', 'This report has no detailed reason.'),
  };

  Future<void> _open() async {
    final output = _exported;
    if (output == null || _busy) return;
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
      if (mounted) {
        setState(
          () => _error = t(
            '无法打开文件，请检查阅读器或文件位置。',
            'Could not open the file. Check the reader or file location.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final remaining = _remaining;
    final items = report == null
        ? const <Map>[]
        : (report['corrections'] as List).cast<Map>();
    return Scaffold(
      appBar: AppBar(title: Text(t('译文复核', 'Translation review'))),
      body: report == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t(
                          '逐条对照原文，勾选要采用的建议。本地导出不调用 API，也不会继续复核；取消勾选后导出即可撤销修改。需要重试未通过的复核时，请在设置中开启重试，再继续翻译。',
                          'Compare suggestions with the source. Local export makes no API calls or further reviews. Uncheck to undo. Enable retry in Settings and resume translation to retry rejected reviews.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        t(
                          '已复核 ${report['reviewedBlocks'] ?? 0} 块；低风险跳过 ${report['skippedLowRiskBlocks'] ?? 0} 块；未完成 ${(report['unreviewed'] as List?)?.length ?? 0} 块。',
                          'Reviewed ${report['reviewedBlocks'] ?? 0}; low-risk skipped ${report['skippedLowRiskBlocks'] ?? 0}; incomplete ${(report['unreviewed'] as List?)?.length ?? 0}.',
                        ),
                      ),
                      Text(
                        t(
                          '人工已核对 ${_manuallyReviewed.length} 块；复核失败项中仍待处理 $remaining 块。',
                          'Human-reviewed: ${_manuallyReviewed.length}; unresolved model failures: $remaining.',
                        ),
                      ),
                      if ((report['rendering'] as Map)['completeSnapshot'] ==
                          true)
                        TextButton.icon(
                          onPressed: _busy ? null : _manualReview,
                          icon: const Icon(Icons.edit_note),
                          label: Text(t('人工校对任意段落', 'Review any paragraph')),
                        ),
                      Text(
                        t(
                          '预估预算已预留 ${report['reservedTokens'] ?? 0} / ${report['tokenLimit'] ?? 0} tokens。',
                          'Estimated budget reserved: ${report['reservedTokens'] ?? 0} / ${report['tokenLimit'] ?? 0} tokens.',
                        ),
                      ),
                      if ((report['findings'] as List?)?.isNotEmpty ?? false)
                        ExpansionTile(
                          title: Text(
                            t(
                              '数字、货币与术语检查（需结合上下文确认）',
                              'Consistency checks (confirm against context)',
                            ),
                          ),
                          children: [
                            for (final finding
                                in (report['findings'] as List)
                                    .take(200)
                                    .cast<Map>())
                              ListTile(
                                title: Text(finding['block'].toString()),
                                subtitle: Text(
                                  (finding['checks'] as List)
                                      .cast<Map>()
                                      .map((c) => c['detail'])
                                      .join('\n'),
                                ),
                              ),
                            if ((report['findings'] as List).length > 200)
                              Text(
                                t(
                                  '此处显示前 200 项，完整记录保存在报告中。',
                                  'Showing the first 200; the report contains all findings.',
                                ),
                              ),
                          ],
                        ),
                      if ((report['unreviewed'] as List?)?.isNotEmpty ?? false)
                        ExpansionTile(
                          title: Text(
                            t('尚未完成复核的文本块', 'Blocks with incomplete reviews'),
                          ),
                          children: [
                            for (final id
                                in (report['unreviewed'] as List).take(200))
                              ListTile(
                                dense: true,
                                title: Text(id.toString()),
                                subtitle: Text(
                                  _reason(
                                    (report['unreviewedReasons'] as Map?)?[id],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if ((report['rendering'] as Map)['completeSnapshot'] ==
                          true)
                        DropdownButtonFormField<bool>(
                          initialValue: _bilingual,
                          decoration: InputDecoration(
                            labelText: t('本地导出格式', 'Local export format'),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: false,
                              child: Text(t('仅译文', 'Translation only')),
                            ),
                            DropdownMenuItem(
                              value: true,
                              child: Text(t('原文与译文对照', 'Bilingual')),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) =>
                                    setState(() => _bilingual = value ?? false),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed:
                                _busy ||
                                    (items.isEmpty &&
                                        (report['rendering']
                                                as Map)['completeSnapshot'] !=
                                            true)
                                ? null
                                : _export,
                            icon: const Icon(Icons.save_alt),
                            label: Text(
                              _busy
                                  ? t('处理中…', 'Working…')
                                  : t(
                                      '本地导出（已选 ${_accepted.length} 条）',
                                      'Local export (${_accepted.length} selected)',
                                    ),
                            ),
                          ),
                          if (_exported != null)
                            OutlinedButton(
                              onPressed: _busy ? null : _open,
                              child: Text(
                                t('打开／分享复核版', 'Open / share reviewed EPUB'),
                              ),
                            ),
                        ],
                      ),
                      if (_exported != null) SelectableText(_exported!),
                      if (items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            t(
                              '没有可采用的修改建议。',
                              'No change suggestions available.',
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                  );
                }
                final item = items[index - 1];
                final key = TranslationReviewStore.suggestionKey(item);
                Widget textField(String label, String field) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      SelectableText(
                        html
                                .parseFragment(
                                  field == 'afterHtml'
                                      ? (_edited[key] ??
                                            item[field] as String? ??
                                            '')
                                      : item[field] as String? ?? '',
                                )
                                .text ??
                            '',
                      ),
                    ],
                  ),
                );
                return Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CheckboxListTile(
                        value: _accepted.contains(key),
                        onChanged: _busy || _manualEdits.containsKey(key)
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _accepted.add(key);
                                } else {
                                  _accepted.remove(key);
                                }
                              }),
                        title: Text('${item['chapter']} · ${item['id']}'),
                        subtitle: Text((item['issues'] as List).join('\n')),
                      ),
                      textField(t('原文', 'Source'), 'sourceHtml'),
                      textField(t('原译文', 'Draft'), 'beforeHtml'),
                      textField(t('建议译文', 'Suggestion'), 'afterHtml'),
                      if (TranslationReviewStore.editableText(
                            _edited[key] ?? item['afterHtml'] as String,
                          ) !=
                          null)
                        TextButton.icon(
                          onPressed: _busy || _manualEdits.containsKey(key)
                              ? null
                              : () => _edit(item),
                          icon: const Icon(Icons.edit_outlined),
                          label: Text(t('编辑此条译文', 'Edit this translation')),
                        ),
                      if ((item['checksAfter'] as List?)?.isNotEmpty ?? false)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            t(
                              '建议译文仍有数字或术语疑点，请核对后再采用。',
                              'The suggestion still has consistency flags. Check them before accepting.',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
