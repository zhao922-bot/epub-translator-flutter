import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../translation/domain/models/inspected_chapter.dart';
import '../../application/preview_block_reader.dart';
import '../preview_strings.dart';
import 'preview_passages.dart';
import 'preview_search_field.dart';

class ChapterBlockDialog extends StatefulWidget {
  const ChapterBlockDialog({
    super.key,
    required this.chapter,
    required this.strings,
    required this.initialQuery,
  });

  final InspectedChapter chapter;
  final AppStrings strings;
  final String initialQuery;

  @override
  State<ChapterBlockDialog> createState() => _ChapterBlockDialogState();
}

class _ChapterBlockDialogState extends State<ChapterBlockDialog> {
  static const _pageSize = 4000;
  late final PreviewBlockReader _reader;
  late final TextEditingController _search;
  late Future<PreviewBlockText> _content;
  RegExp? _pattern;
  int _block = 0;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _reader = PreviewBlockReader(widget.chapter, () => !mounted);
    _search = TextEditingController(text: widget.initialQuery);
    _pattern = previewSearchPattern(widget.initialQuery);
    _content = _reader.read(_block);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _selectBlock(int index) {
    setState(() {
      _block = index;
      _page = 0;
      _content = _reader.read(_block);
    });
  }

  String _pageText(String text) {
    final start = _page * _pageSize;
    if (start >= text.length) return '';
    final end = math.min(start + _pageSize, text.length);
    return text.substring(_safeBoundary(text, start), _safeBoundary(text, end));
  }

  int _safeBoundary(String text, int index) {
    if (index > 0 &&
        index < text.length &&
        (text.codeUnitAt(index) & 0xfc00) == 0xdc00) {
      return index - 1;
    }
    return index;
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final blockCount = widget.chapter.blocks.length;
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 920,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.chapter.title,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PreviewSearchField(
                controller: _search,
                label: strings.searchBlockPage,
                clearLabel: strings.clearPreviewSearch,
                onChanged: (text) =>
                    setState(() => _pattern = previewSearchPattern(text)),
              ),
              const SizedBox(height: 12),
              FutureBuilder<PreviewBlockText>(
                future: _content,
                builder: (context, snapshot) {
                  final ready =
                      snapshot.connectionState == ConnectionState.done;
                  final content = ready ? snapshot.data : null;
                  final source = content?.source ?? '';
                  final translation = content?.translation ?? '';
                  final textLength = math.max(
                    source.length,
                    translation.length,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _navigation(
                        position: strings.chapterBlockPosition(
                          _block + 1,
                          blockCount,
                        ),
                        previous: strings.previousChapterBlock,
                        next: strings.nextChapterBlock,
                        onPrevious: ready && _block > 0
                            ? () => _selectBlock(_block - 1)
                            : null,
                        onNext: ready && _block + 1 < blockCount
                            ? () => _selectBlock(_block + 1)
                            : null,
                      ),
                      if (textLength > _pageSize)
                        _navigation(
                          position: strings.chapterBlockPage(_page + 1),
                          previous: strings.previousBlockPage,
                          next: strings.nextBlockPage,
                          onPrevious: _page > 0
                              ? () => setState(() => _page--)
                              : null,
                          onNext: (_page + 1) * _pageSize < textLength
                              ? () => setState(() => _page++)
                              : null,
                        ),
                      const SizedBox(height: 8),
                      if (!ready)
                        const LinearProgressIndicator()
                      else if (content == null)
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(strings.previewBlockLoadFailed),
                            TextButton(
                              onPressed: () => _selectBlock(_block),
                              child: Text(strings.retryJob),
                            ),
                          ],
                        )
                      else
                        LayoutBuilder(
                          builder: (context, constraints) => PreviewPassages(
                            strings: strings,
                            source: _pageText(source),
                            translation: _pageText(translation),
                            sourcePlaceholder: source.isEmpty
                                ? strings.previewSourceUnavailable
                                : '',
                            translationPlaceholder: translation.isEmpty
                                ? strings.noTranslationYet
                                : '',
                            parallel:
                                constraints.maxWidth >=
                                640 * MediaQuery.textScalerOf(context).scale(1),
                            pattern: _pattern,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navigation({
    required String position,
    required String previous,
    required String next,
    required VoidCallback? onPrevious,
    required VoidCallback? onNext,
  }) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      IconButton(
        onPressed: onPrevious,
        tooltip: previous,
        icon: const Icon(Icons.chevron_left),
      ),
      Semantics(liveRegion: true, child: Text(position)),
      IconButton(
        onPressed: onNext,
        tooltip: next,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
}
