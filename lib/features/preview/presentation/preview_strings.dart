import '../../../shared/localization/app_strings.dart';

extension PreviewStrings on AppStrings {
  String get searchChapters => isChinese ? '搜索章节' : 'Search chapters';
  String get searchExcerpt => isChinese ? '搜索摘录' : 'Search excerpt';
  String get searchBlockPage => isChinese ? '搜索此页文本' : 'Search this page';
  String get clearPreviewSearch => isChinese ? '清除搜索' : 'Clear search';
  String get warningsOnly => isChinese ? '仅显示有警告的章节' : 'Warnings only';
  String get noMatchingChapters =>
      isChinese ? '没有匹配的章节。' : 'No matching chapters.';
  String get noMatchingText => isChinese ? '没有匹配的文本。' : 'No matching text.';
  String get browseChapterBlocks => isChinese ? '浏览文本块' : 'Browse blocks';
  String get previousChapterBlock => isChinese ? '上一块' : 'Previous block';
  String get nextChapterBlock => isChinese ? '下一块' : 'Next block';
  String get previousBlockPage => isChinese ? '上一页' : 'Previous page';
  String get nextBlockPage => isChinese ? '下一页' : 'Next page';
  String get previewSourceUnavailable =>
      isChinese ? '此文本块的原文不可用。' : 'Source text is unavailable for this block.';
  String get previewBlockLoadFailed =>
      isChinese ? '无法读取此文本块。' : 'Could not read this block.';

  String chapterBlockPosition(int current, int total) =>
      isChinese ? '文本块 $current / $total' : 'Block $current of $total';

  String chapterBlockPage(int current) =>
      isChinese ? '第 $current 页' : 'Page $current';

  String degradedChapterBlocks(int count) => isChinese
      ? '$count 块降级保留'
      : count == 1
      ? '1 degraded block'
      : '$count degraded blocks';

  String reviewChapterBlocks(int count) => isChinese
      ? '$count 块待复核'
      : count == 1
      ? '1 block needs review'
      : '$count blocks need review';
}
