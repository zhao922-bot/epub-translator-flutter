import 'package:flutter/material.dart';
import '../../infrastructure/translation_review_store.dart';
import '../../infrastructure/epub/translation_consistency_checker.dart';

class ManualReviewSelection {
  ManualReviewSelection(this.edits, this.reviewed);
  final Map<String, String> edits;
  final Set<String> reviewed;
}

/// Human review is independent of the model's suggestions and coverage.
class TranslationManualReviewPage extends StatefulWidget {
  const TranslationManualReviewPage({
    super.key,
    required this.blocks,
    required this.edits,
    required this.reviewed,
    required this.isChinese,
  });
  final List<Map<String, String>> blocks;
  final Map<String, String> edits;
  final Set<String> reviewed;
  final bool isChinese;
  @override
  State<TranslationManualReviewPage> createState() =>
      _TranslationManualReviewPageState();
}

class _TranslationManualReviewPageState
    extends State<TranslationManualReviewPage> {
  late final _edits = Map<String, String>.of(widget.edits);
  late final _reviewed = Set<String>.of(widget.reviewed);
  String _query = '';
  final _searchIndex =
      <String, ({String source, String markup, String id, String text})>{};
  String t(String zh, String en) => widget.isChinese ? zh : en;

  String _currentMarkup(Map<String, String> block) =>
      _edits[block['key']] ?? block['proposedHtml'] ?? block['beforeHtml']!;

  String _searchText(Map<String, String> block) {
    final key = block['key']!;
    final source = block['sourceHtml']!;
    final markup = _currentMarkup(block);
    final id = block['id']!;
    final cached = _searchIndex[key];
    if (cached != null &&
        cached.source == source &&
        cached.markup == markup &&
        cached.id == id) {
      return cached.text;
    }
    final text =
        '$id ${TranslationConsistencyChecker.text(source)} '
                '${TranslationConsistencyChecker.text(markup)}'
            .toLowerCase();
    _searchIndex[key] = (source: source, markup: markup, id: id, text: text);
    return text;
  }

  @override
  void didUpdateWidget(covariant TranslationManualReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.blocks, widget.blocks)) _searchIndex.clear();
  }

  Future<void> _edit(Map<String, String> block) async {
    final key = block['key']!;
    final markup = _currentMarkup(block);
    final initial = TranslationReviewStore.editableText(markup);
    if (initial == null) {
      await _replace(block, markup);
      return;
    }
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(t('人工修改译文', 'Edit translation')),
        content: SizedBox(
          width: 600,
          child: TextField(controller: controller, minLines: 4, maxLines: 8),
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
            child: Text(t('保存修改', 'Save edit')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (!mounted || value == null) return;
    setState(() {
      _edits[key] = TranslationReviewStore.editText(markup, value);
      _reviewed.add(key);
    });
  }

  Future<void> _replace(Map<String, String> block, String markup) async {
    final before = TextEditingController(), after = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(t('替换文字并保留排版', 'Replace text, keep formatting')),
          content: SizedBox(
            width: 600,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t(
                    '输入此段中唯一出现的一段文字。链接、强调和脚注格式会保留。',
                    'Enter a unique passage within this paragraph. Links, emphasis and footnotes are preserved.',
                  ),
                ),
                TextField(
                  controller: before,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: t('原文字', 'Find exact text'),
                  ),
                ),
                TextField(
                  controller: after,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: t('替换为', 'Replace with'),
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('取消', 'Cancel')),
            ),
            TextButton(
              onPressed: () {
                try {
                  Navigator.pop(
                    context,
                    TranslationReviewStore.replaceText(
                      markup,
                      before.text,
                      after.text,
                    ),
                  );
                } on FormatException {
                  update(
                    () => error = t(
                      '原文字须在单一文本片段中唯一出现，且不能修改受保护内容。请缩小替换范围。',
                      'The text must appear exactly once within one unprotected text span. Try a smaller passage.',
                    ),
                  );
                }
              },
              child: Text(t('保存修改', 'Save edit')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    before.dispose();
    after.dispose();
    if (!mounted || result == null) return;
    setState(() {
      _edits[block['key']!] = result;
      _reviewed.add(block['key']!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.blocks
        .where((b) => _query.isEmpty || _searchText(b).contains(_query))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(t('人工校对', 'Manual review')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              ManualReviewSelection(Map.of(_edits), Set.of(_reviewed)),
            ),
            child: Text(t('保留选择', 'Keep choices')),
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
                Text(
                  t(
                    '可查找并修改任何已翻译段落，也可确认原译文无误。人工核对单独记录，不会计为模型复核通过；返回后本地导出即可生成新文件。',
                    'Edit any translated paragraph or confirm the existing text. Human review is recorded separately from model review. Export locally after keeping your choices.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    labelText: t(
                      '搜索原文、译文或段落编号',
                      'Search source, translation or paragraph ID',
                    ),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
                Text(
                  t(
                    '显示 ${matches.length} 段；人工核对 ${_reviewed.length} 段，修改 ${_edits.length} 段。',
                    '${matches.length} paragraphs; ${_reviewed.length} human-reviewed, ${_edits.length} edited.',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: matches.length,
              itemBuilder: (context, index) {
                final block = matches[index], key = block['key']!;
                final source = TranslationConsistencyChecker.text(
                  block['sourceHtml']!,
                );
                final markup = _currentMarkup(block);
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: ExpansionTile(
                    key: ValueKey(key),
                    title: Text(
                      source,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${block['id']} · ${_edits.containsKey(key)
                          ? t('已修改', 'Edited')
                          : _reviewed.contains(key)
                          ? t('已人工核对', 'Human-reviewed')
                          : t('待核对', 'Not reviewed')}',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('原文', 'Source'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            SelectableText(source),
                            const SizedBox(height: 12),
                            Text(
                              t('当前译文', 'Current translation'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            SelectableText(
                              TranslationConsistencyChecker.text(markup),
                            ),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                t(
                                  '我已对照原文核对此段',
                                  'I checked this paragraph against the source',
                                ),
                              ),
                              value: _reviewed.contains(key),
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
                                  label: Text(t('修改此段', 'Edit paragraph')),
                                ),
                                if (_edits.containsKey(key))
                                  TextButton(
                                    onPressed: () => setState(() {
                                      _edits.remove(key);
                                      _reviewed.remove(key);
                                    }),
                                    child: Text(
                                      t('撤销人工修改', 'Undo manual edit'),
                                    ),
                                  ),
                              ],
                            ),
                            if (TranslationReviewStore.editableText(markup) ==
                                null)
                              Text(
                                t(
                                  '此段包含行内排版，修改时使用精确替换以保留格式。',
                                  'This paragraph uses exact text replacement to preserve inline formatting.',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
