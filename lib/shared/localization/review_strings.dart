import 'app_strings.dart';

extension ReviewStrings on AppStrings {
  String get translationReviewTitle =>
      isChinese ? '译文复核' : 'Translation review';
  String get manualReviewTitle => isChinese ? '人工校对' : 'Manual review';
  String get openReview =>
      isChinese ? '查看检查结果与修改建议' : 'View checks and suggestions';
  String get missingReviewData => isChinese
      ? '请从翻译结果或任务记录打开复核。'
      : 'Open a review from the translation results or job history.';
  String get reviewReadFailed => isChinese
      ? '无法读取复核报告，文件可能已移动或来自旧版本。'
      : 'Could not read the review report. It may have moved or belong to an older version.';
  String get reviewChoicesSaveFailed => isChinese
      ? '复核版已导出，但无法保存选择记录。请保留导出的文件。'
      : 'The reviewed EPUB was exported, but choices could not be saved. Keep the exported file.';
  String get reviewExportFailed => isChinese
      ? '导出未完成。请确认原译本仍在原位置且未修改，并检查输出目录是否可写。'
      : 'Export did not finish. Check that the baseline EPUB is unchanged and the output directory is writable.';
  String get reviewParagraphsReadFailed => isChinese
      ? '无法读取可校对段落，请检查报告是否完整。'
      : 'Could not load paragraphs from this report.';
  String get reviewOpenFailed => isChinese
      ? '无法打开文件，请检查阅读器或文件位置。'
      : 'Could not open the file. Check the reader or file location.';
  String get reviewSuggestionsHelp => isChinese
      ? '逐条对照原文，勾选要采用的建议。本地导出不调用 API，也不会继续复核；取消勾选后导出即可撤销修改。需要重试未通过的复核时，请在设置中开启重试，再继续翻译。'
      : 'Compare suggestions with the source. Local export makes no API calls or further reviews. Uncheck to undo. Enable retry in Settings and resume translation to retry rejected reviews.';
  String automaticReviewCorrections(int count) => isChinese
      ? '已自动修正 $count 段（独立请求复核通过）'
      : '$count automatically corrected blocks (separately verified)';
  String get beforeAutomaticCorrection =>
      isChinese ? '自动修正前' : 'Before automatic correction';
  String get afterAutomaticCorrection =>
      isChinese ? '自动修正后' : 'After automatic correction';
  String get reviewVerification => isChinese ? '复核依据' : 'Verification';
  String reviewCoverage(Object reviewed, Object skipped, int incomplete) =>
      isChinese
      ? '已复核 $reviewed 块；低风险跳过 $skipped 块；未完成 $incomplete 块。'
      : 'Reviewed $reviewed; low-risk skipped $skipped; incomplete $incomplete.';
  String reviewRemaining(int reviewed, int remaining) => isChinese
      ? '人工已核对 $reviewed 块；复核失败项中仍待处理 $remaining 块。'
      : 'Human-reviewed: $reviewed; unresolved model failures: $remaining.';
  String get reviewAnyParagraph =>
      isChinese ? '人工校对任意段落' : 'Review any paragraph';
  String reviewReservedBudget(Object reserved, Object limit) => isChinese
      ? '预估预算已预留 $reserved / $limit tokens。'
      : 'Estimated budget reserved: $reserved / $limit tokens.';
  String get reviewConsistencyChecks => isChinese
      ? '数字、货币与术语检查（需结合上下文确认）'
      : 'Consistency checks (confirm against context)';
  String reviewFindingLimit(int limit) => isChinese
      ? '此处显示前 $limit 项，完整记录保存在报告中。'
      : 'Showing the first $limit; the report contains all findings.';
  String get reviewIncompleteBlocks =>
      isChinese ? '尚未完成复核的文本块' : 'Blocks with incomplete reviews';
  String reviewIncompleteReason(Object? code) => switch (code) {
    'budgetLimit' =>
      isChinese
          ? '达到复核预算；下次继续可补审。'
          : 'Review budget reached; resume to continue.',
    'unsupportedRewrite' =>
      isChinese
          ? '建议缺少可靠引文、明确理由或高置信度；保留原译文。'
          : 'Rewrite lacked supported evidence or confidence; draft retained.',
    'invalidHtml' =>
      isChinese
          ? '建议未通过结构或文本质量校验；保留原译文。'
          : 'Suggestion failed structure or text validation; draft retained.',
    'requestFailed' =>
      isChinese ? '复核请求失败；保留原译文。' : 'Review request failed; draft retained.',
    'invalidResponse' =>
      isChinese
          ? '模型响应格式或内容不完整；保留原译文。'
          : 'Incomplete or invalid model response; draft retained.',
    _ => isChinese ? '旧报告未记录具体原因。' : 'This report has no detailed reason.',
  };
  String get reviewLocalExportFormat =>
      isChinese ? '本地导出格式' : 'Local export format';
  String get reviewBilingual => isChinese ? '原文与译文对照' : 'Bilingual';
  String get reviewWorking => isChinese ? '处理中…' : 'Working…';
  String reviewExport(int selected) =>
      isChinese ? '本地导出（已选 $selected 条）' : 'Local export ($selected selected)';
  String get reviewOpenExport =>
      isChinese ? '打开／分享复核版' : 'Open / share reviewed EPUB';
  String get reviewNoSuggestions =>
      isChinese ? '没有可采用的修改建议。' : 'No change suggestions available.';
  String get reviewSuggestionSearch =>
      isChinese ? '搜索修改建议' : 'Search suggestions';
  String get reviewNoSearchMatches =>
      isChinese ? '没有匹配的结果。' : 'No matching results.';
  String get reviewDraft => isChinese ? '原译文' : 'Draft';
  String get reviewSuggestedText => isChinese ? '建议译文' : 'Suggestion';
  String get reviewEditSuggestion =>
      isChinese ? '编辑此条译文' : 'Edit this translation';
  String get reviewSuggestionFlagged => isChinese
      ? '建议译文仍有数字或术语疑点，请核对后再采用。'
      : 'The suggestion still has consistency flags. Check them before accepting.';
  String get reviewEditSuggestionTitle =>
      isChinese ? '调整这条建议' : 'Edit this suggestion';
  String get reviewSaveSuggestion => isChinese ? '保存并选用' : 'Save and accept';
  String get manualReviewHelp => isChinese
      ? '可查找并修改任何已翻译段落，也可确认原译文无误。人工核对单独记录，不会计为模型复核通过；返回后本地导出即可生成新文件。'
      : 'Edit any translated paragraph or confirm the existing text. Human review is recorded separately from model review. Export locally after keeping your choices.';
  String get manualReviewSearch =>
      isChinese ? '搜索原文、译文或段落编号' : 'Search source, translation or paragraph ID';
  String manualReviewCounts(int matches, int reviewed, int edited) => isChinese
      ? '显示 $matches 段；人工核对 $reviewed 段，修改 $edited 段。'
      : '$matches paragraphs; $reviewed human-reviewed, $edited edited.';
  String get manualReviewKeepChoices => isChinese ? '保留选择' : 'Keep choices';
  String get manualReviewEdited => isChinese ? '已修改' : 'Edited';
  String get manualReviewReviewed => isChinese ? '已人工核对' : 'Human-reviewed';
  String get manualReviewPending => isChinese ? '待核对' : 'Not reviewed';
  String get manualReviewCurrent => isChinese ? '当前译文' : 'Current translation';
  String get manualReviewConfirmParagraph =>
      isChinese ? '我已对照原文核对此段' : 'I checked this paragraph against the source';
  String get manualReviewEditParagraph => isChinese ? '修改此段' : 'Edit paragraph';
  String get manualReviewUndo => isChinese ? '撤销人工修改' : 'Undo manual edit';
  String get manualReviewInlineHelp => isChinese
      ? '此段包含行内排版，修改时使用精确替换以保留格式。'
      : 'This paragraph uses exact text replacement to preserve inline formatting.';
  String get manualReviewEditTitle => isChinese ? '人工修改译文' : 'Edit translation';
  String get manualReviewSave => isChinese ? '保存修改' : 'Save edit';
  String get manualReviewReplaceTitle =>
      isChinese ? '替换文字并保留排版' : 'Replace text, keep formatting';
  String get manualReviewReplaceHelp => isChinese
      ? '输入此段中唯一出现的一段文字。链接、强调和脚注格式会保留。'
      : 'Enter a unique passage within this paragraph. Links, emphasis and footnotes are preserved.';
  String get manualReviewFindText => isChinese ? '原文字' : 'Find exact text';
  String get manualReviewReplaceWith => isChinese ? '替换为' : 'Replace with';
  String get manualReviewReplaceFailed => isChinese
      ? '原文字须在单一文本片段中唯一出现，且不能修改受保护内容。请缩小替换范围。'
      : 'The text must appear exactly once within one unprotected text span. Try a smaller passage.';
  String runRequestKind(Object? kind) => switch (kind) {
    'translation' => isChinese ? '正文／脚注' : 'Body / notes',
    'bodyRepair' => isChinese ? '正文修复' : 'Body repair',
    'semanticReview' => isChinese ? '语义复核' : 'Review',
    'semanticReviewRepair' => isChinese ? '复核修复' : 'Review repair',
    'semanticSourceAnalysis' => isChinese ? '原文分析' : 'Source analysis',
    'semanticDraftAnalysis' => isChinese ? '译文分析' : 'Draft analysis',
    'semanticEquivalence' => isChinese ? '等义检查' : 'Equivalence check',
    'semanticVerification' => isChinese ? '修正验证' : 'Correction verification',
    'entityGlossary' => isChinese ? '实体术语表' : 'Entity glossary',
    'footnoteTranslation' => isChinese ? '脚注' : 'Footnotes',
    'protectedSlots' => isChinese ? '内联文本' : 'Inline text',
    'styleProfile' => isChinese ? '风格' : 'Style',
    'initialBookMemory' => isChinese ? '书籍记忆' : 'Book memory',
    'chapterMemory' => isChinese ? '章节记忆' : 'Chapter memory',
    'chapterMemoryBatch' => isChinese ? '批量章节记忆' : 'Batched chapter memory',
    'bookTitle' => isChinese ? '书名' : 'Title',
    'probe' => isChinese ? '连接测试' : 'Connection probe',
    _ => kind.toString(),
  };
  String runApiUsage(Object calls, Object input, Object output) => isChinese
      ? '本次 API：$calls 次 · 输入 $input / 输出 $output tokens'
      : 'API: $calls calls · $input input / $output output tokens';
  String runElapsed(String seconds) =>
      isChinese ? '任务耗时 $seconds 秒' : 'Run time $seconds s';
  String runRequestUsage(
    Object calls,
    Object input,
    Object output,
    String seconds,
  ) => isChinese
      ? '$calls 次；输入 $input / 输出 $output；累计请求耗时 $seconds 秒'
      : '$calls calls; $input in / $output out; cumulative request time $seconds s';
  String get runUsageHelp => isChinese
      ? '并发请求耗时会重叠。token 来自接口返回，不等于账单；未返回用量的请求不会计作已知用量。'
      : 'Concurrent request times overlap. Tokens are provider-reported, not a bill; requests without usage have unknown consumption.';
  String runUsageReported(Object reported, Object calls) => isChinese
      ? '返回完整用量的请求：$reported / $calls'
      : 'Requests reporting full usage: $reported / $calls';
}
