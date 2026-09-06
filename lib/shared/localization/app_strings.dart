import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/application/settings_controller.dart';
import '../../features/translation/domain/models/translation_config.dart';

final appStringsProvider = Provider<AppStrings>((ref) {
  final UiLanguage language = ref.watch(
    settingsProvider.select((TranslationConfig config) => config.uiLanguage),
  );
  return AppStrings(language);
});

class AppStrings {
  const AppStrings(this.language);

  final UiLanguage language;

  bool get isChinese => language == UiLanguage.chinese;

  String get appTitle => isChinese ? 'EPUB 翻译器' : 'EPUB Translator';
  String get appSubtitle => isChinese ? '本地 EPUB 翻译' : 'Local EPUB translation';
  String get navTranslate => isChinese ? '翻译' : 'Translate';
  String get navJobs => isChinese ? '任务' : 'Jobs';
  String get navPreview => isChinese ? '预览' : 'Preview';
  String get navSettings => isChinese ? '设置' : 'Settings';

  String get translationPageTitle => isChinese ? '翻译' : 'Translate';

  /// Kept for compatibility; prefer empty / state-driven UI instead of workflow prose.
  String get translationPageSubtitle => '';
  String get inspectEpub => isChinese ? '检查' : 'Inspect';
  String get reinspectEpub => isChinese ? '重新检查' : 'Re-inspect';
  String get translateSelected => isChinese ? '开始翻译' : 'Translate';

  String get bookSetup => isChinese ? '图书' : 'Book';
  String get inputEpub => isChinese ? '输入 EPUB' : 'Input EPUB';
  String get inputEpubHint => isChinese ? '本地 .epub 路径' : 'Local .epub path';
  String get chooseEpub => isChinese ? '选择 EPUB' : 'Choose EPUB';
  String get dropOrChooseEpub =>
      isChinese ? '拖入或选择 EPUB' : 'Drop or choose EPUB';
  String get noEpubSelected => isChinese ? '未选择' : 'None selected';
  String get browse => isChinese ? '浏览' : 'Browse';
  String get advancedPaths => isChinese ? '手动路径' : 'Manual paths';
  String get outputDirectory => isChinese ? '输出' : 'Output';
  String get outputDirectoryHint => isChinese ? '译后保存位置' : 'Save location';
  String get chooseOutputDirectory => isChinese ? '更改' : 'Change';
  String get targetLanguage => isChinese ? '目标语言' : 'Language';
  String get bilingualOutput => isChinese ? '双语' : 'Bilingual';
  String get translatedOnly => isChinese ? '仅译文' : 'Translation only';
  String get translationPreferences =>
      isChinese ? '翻译偏好' : 'Translation preferences';
  String get outputFormat => isChinese ? '译本格式' : 'Output format';
  String get noPreviewYet => isChinese
      ? '导入并检查 EPUB 后，在这里选择章节和预览正文。'
      : 'Import and inspect an EPUB to select chapters and preview text here.';
  String get noTranslationYet => isChinese
      ? '此章节尚无可预览的译文。'
      : 'No translated excerpt is available for this chapter yet.';
  String get reviewStyleFirst => isChinese
      ? '请先确认下方的书籍风格，再开始翻译。'
      : 'Review and confirm the book style below before translating.';

  String get runOverview => isChinese ? '进度' : 'Progress';
  String get statusLabel => isChinese ? '状态' : 'Status';
  String get chapterLabel => isChinese ? '章节' : 'Chapter';
  String get filesLabel => isChinese ? '文件' : 'Files';
  String get blocksLabel => isChinese ? '块' : 'Blocks';
  String get notStarted => isChinese ? '未开始' : 'Not started';
  String get saveToDownloads => isChinese ? '保存到下载' : 'Save to Downloads';
  String get shareEpub => isChinese ? '分享' : 'Share';
  String get openEpub => isChinese ? '打开' : 'Open';
  String get cancelRun => isChinese ? '取消' : 'Cancel';
  String get outputReady => isChinese ? '已完成' : 'Output ready';
  String get estimatedBatchesLabel => isChinese ? '预计批次' : 'Estimated batches';
  String get speedLabel => isChinese ? '速度' : 'Speed';
  String get etaLabel => isChinese ? '剩余' : 'ETA';
  String get overviewIdleHint => '';
  String overviewBody({String? currentBlock}) =>
      currentBlock != null && currentBlock.isNotEmpty
      ? (isChinese ? '当前：$currentBlock' : 'Current: $currentBlock')
      : '';
  String estimateSummary(int batches, int tokens) => isChinese
      ? '$batches 批次 · $tokens tokens'
      : '$batches batches · $tokens tokens';

  String jobStatusLabel(Object status) {
    final String name = status.toString().split('.').last;
    return switch (name) {
      'idle' => isChinese ? '空闲' : 'Idle',
      'queued' => isChinese ? '排队中' : 'Queued',
      'running' => isChinese ? '进行中' : 'Running',
      'inspected' => isChinese ? '检查完成' : 'Inspected',
      'cancelled' => isChinese ? '已取消' : 'Cancelled',
      'failed' => isChinese ? '失败' : 'Failed',
      'completedWithWarnings' =>
        isChinese ? '完成但有警告' : 'Completed with warnings',
      'completed' => isChinese ? '已完成' : 'Completed',
      _ => name,
    };
  }

  String stepProgress(int current, int total) =>
      isChinese ? '$current/$total' : '$current/$total';
  String get stepChooseEpub => isChinese ? '选择 EPUB' : 'Choose EPUB';
  String get stepReadyToInspect => isChinese ? '待检查' : 'Ready to inspect';
  String get stepInspecting => isChinese ? '检查中' : 'Inspecting…';
  String get stepRestoringCache => isChinese ? '恢复缓存中' : 'Restoring cache…';
  String get stepReviewChapters => isChinese ? '确认章节' : 'Review chapters';
  String get stepReadyToTranslate => isChinese ? '待翻译' : 'Ready to translate';
  String get stepTranslating => isChinese ? '翻译中' : 'Translating…';
  String get stepExportDone => isChinese ? '已完成' : 'Done';

  String get cacheRestorationTitle =>
      isChinese ? '正在恢复缓存' : 'Restoring cached translations';
  String resumeCheckpointSummary(int checkpoint, int total) => isChinese
      ? '待校验断点：$checkpoint/$total'
      : 'Checkpoint to verify: $checkpoint/$total';
  String cacheScanSummary(int scanned, int total) =>
      isChinese ? '缓存扫描：$scanned/$total' : 'Cache scan: $scanned/$total';
  String verifiedCacheSummary(int verified) =>
      isChinese ? '已确认复用：$verified 块' : 'Verified reusable: $verified blocks';
  String get continuingTranslation =>
      isChinese ? '继续翻译' : 'Continuing translation';

  String get logsTitle => isChinese ? '日志' : 'Logs';
  String get expandLogs => isChinese ? '展开' : 'Expand';
  String get collapseLogs => isChinese ? '收起' : 'Collapse';

  String get previewTitle => isChinese ? '预览' : 'Preview';
  String get previewSubtitle =>
      isChinese ? '勾选要翻译的章节' : 'Select chapters to translate';
  String get chapterChecklist => isChinese ? '章节' : 'Chapters';
  String get resetSelection => isChinese ? '重置' : 'Reset';
  String chapterChecklistSummary(
    int selectedChapters,
    int totalChapters,
    int selectedBlocks,
  ) => isChinese
      ? '$selectedChapters/$totalChapters 章 · $selectedBlocks 块'
      : '$selectedChapters/$totalChapters chapters · $selectedBlocks blocks';
  String chapterCategoryBlocks(String category, int blockCount) => isChinese
      ? '$category · $blockCount 块'
      : '$category · $blockCount blocks';
  String get manualOverrideTooltip =>
      isChinese ? '已手动覆盖默认过滤' : 'Manually overridden';
  String get defaultLabel => isChinese ? '默认' : 'Default';
  String get translateBadge => isChinese ? '译' : 'On';
  String get skipBadge => isChinese ? '跳过' : 'Skip';
  String get currentFilteringRule => isChinese ? '过滤规则' : 'Filter rules';
  String get currentFilteringRuleBody => isChinese
      ? '默认保留正文、前言、后记与参考；封面、广告、版权等默认取消，可在清单中手动覆盖。'
      : 'Keeps reading content by default; cover/promo/credits start unchecked. Override any chapter in the list.';

  String get settingsTitle => isChinese ? '设置' : 'Settings';
  String get settingsSubtitle => '';
  String get appearanceSection => isChinese ? '外观' : 'Appearance';
  String get uiLanguage => isChinese ? '语言' : 'Language';
  String get englishLabel => 'English';
  String get chineseLabel => '中文';
  String get themeSection => isChinese ? '主题' : 'Theme';
  String get systemThemeLabel => isChinese ? '系统' : 'System';
  String get lightThemeLabel => isChinese ? '浅色' : 'Light';
  String get darkThemeLabel => isChinese ? '深色' : 'Dark';
  String get apiSection => 'API';
  String get testConnection => isChinese ? '测试' : 'Test';
  String get testingConnection => isChinese ? '测试中…' : 'Testing…';
  String get connectionOk => isChinese ? '连接成功' : 'Connection OK';
  String get connectionFailed => isChinese ? '连接失败' : 'Connection failed';
  String get baseUrl => isChinese ? '接口地址' : 'Base URL';
  String get apiKey => 'API Key';
  String get model => isChinese ? '模型' : 'Model';
  String get translationSection => isChinese ? '翻译' : 'Translation';
  String get advancedTuning => isChinese ? '高级参数' : 'Advanced parameters';
  String get tuningPresets => isChinese ? '速度预设' : 'Speed presets';
  String get tuningPresetsBody => '';
  String get stablePreset => isChinese ? '稳定' : 'Stable';
  String get stablePresetBody => isChinese ? '低并发' : 'Lower concurrency';
  String get balancedPreset => isChinese ? '均衡' : 'Balanced';
  String get balancedPresetBody => isChinese ? '默认' : 'Default';
  String get fastPreset => isChinese ? '高速' : 'Fast';
  String get fastPresetBody => isChinese ? '高并发' : 'Higher concurrency';
  String chunkSizeLabel(int value) =>
      isChinese ? '合批字符：$value' : 'Batch: $value';
  String maxConcurrentLabel(int value) =>
      isChinese ? '并发：$value' : 'Concurrency: $value';
  String timeoutLabel(int value) =>
      isChinese ? '超时：$value 秒' : 'Timeout: ${value}s';
  String maxRetriesLabel(int value) =>
      isChinese ? '重试：$value' : 'Retries: $value';
  String retryDelayLabel(int value) =>
      isChinese ? '重试间隔：$value 秒' : 'Retry delay: ${value}s';
  String get outputSuffix => isChinese ? '输出后缀' : 'Output suffix';

  String get jobsTitle => isChinese ? '任务' : 'Jobs';
  String get jobsSubtitle => '';
  String get recentJobs => isChinese ? '最近任务' : 'Recent jobs';
  String get clearHistory => isChinese ? '清空' : 'Clear';
  String get openOutput => isChinese ? '打开' : 'Open';
  String get retryJob => isChinese ? '重试' : 'Retry';
  String get noRecentJobs => isChinese ? '暂无任务' : 'No jobs yet';
  String get activeRun => isChinese ? '运行中' : 'Active';
  String get canResumeLabel => isChinese ? '可续传' : 'Resumable';
  String get estimatedTokensLabel => isChinese ? '预估 Token' : 'Est. tokens';
  String get estimatedBatchesShort => isChinese ? '预估批次' : 'Est. batches';
  String get chapterPresets => isChinese ? '章节预设' : 'Chapter presets';
  String get presetRecommended => isChinese ? '推荐' : 'Recommended';
  String get presetContentOnly => isChinese ? '仅正文' : 'Content only';
  String get presetAll => isChinese ? '全选' : 'All';
  String get presetNone => isChinese ? '全不选' : 'None';
  String get sourcePreview => isChinese ? '原文' : 'Source';
  String get translatedPreview => isChinese ? '译文' : 'Translation';
  String get apiProviderPresets => isChinese ? 'API 模板' : 'API presets';
  String get residualQualityCheck =>
      isChinese ? '残留质量检查' : 'Residual quality check';
  String get residualQualityCheckBody =>
      isChinese ? '拒绝明显未译完整的文本块' : 'Reject largely untranslated blocks';
  String get styleProfileEnabled => isChinese ? '书籍风格档案' : 'Book style profile';
  String get styleProfileEnabledBody => isChinese
      ? '从前言/目录/前几章推断文体，并注入后续翻译'
      : 'Infer tone from front matter and guide later chapters';
  String get styleProfileSectionTitle =>
      isChinese ? '书籍风格档案' : 'Book style profile';
  String get styleProfileSectionBody => isChinese
      ? '翻译前先确认类型与文风；可手动修改后再开翻。'
      : 'Review genre and tone before translation. Edit freely, then confirm.';
  String get generateStyleProfile =>
      isChinese ? '生成风格档案' : 'Generate style profile';
  String get regenerateStyleProfile => isChinese ? '重新生成' : 'Regenerate';
  String get confirmStyleProfile =>
      isChinese ? '确认风格并用于翻译' : 'Confirm style for translation';
  String get styleProfileConfirmedBadge => isChinese ? '已确认' : 'Confirmed';
  String get styleProfilePendingBadge => isChinese ? '待确认' : 'Needs review';
  String get styleProfilePrimaryGenre => isChinese ? '主要类型' : 'Primary genre';
  String get styleProfileSecondaryGenres =>
      isChinese ? '次要类型（逗号分隔）' : 'Secondary genres (comma-separated)';
  String get styleProfileTone => isChinese ? '语气' : 'Tone';
  String get styleProfileSentenceStyle => isChinese ? '句式风格' : 'Sentence style';
  String get styleProfileConstraints =>
      isChinese ? '翻译约束（每行一条）' : 'Translation constraints (one per line)';
  String get styleProfileAvoid =>
      isChinese ? '应避免（每行一条）' : 'Avoid (one per line)';
  String get styleProfileConfidence => isChinese ? '置信度' : 'Confidence';
  String get styleProfileEmptyHint => isChinese
      ? '检查完成后可生成风格档案；也可先手填。'
      : 'Generate a style profile after inspection, or fill it in manually.';
  String get textScaleLabel => isChinese ? '字号' : 'Text size';
  String get lockedGlossary => isChinese ? '锁定术语表' : 'Locked glossary';
  String get lockedGlossaryHint => isChinese
      ? '每行：原文 => 译文。首个出现会给中文（原文），之后只给中文。'
      : 'One per line: source => target. First occurrence keeps 中文（原文）, later occurrences are Chinese only.';
  String get supportedPlatformsNote =>
      isChinese ? '支持 Windows、Android' : 'Windows, Android';
  String get accessibilitySection => isChinese ? '无障碍' : 'Accessibility';
  String get qualitySection => isChinese ? '质量与术语' : 'Quality';

  // —— Runtime log messages (dashboard) ——
  String logSelectedEpub(String name) =>
      isChinese ? '已选择 EPUB：$name' : 'Selected EPUB: $name';
  String logDroppedEpub(String name) =>
      isChinese ? '已拖入 EPUB：$name' : 'Dropped EPUB: $name';
  String get logChooseEpubFile =>
      isChinese ? '请选择 .epub 文件。' : 'Please choose a .epub file.';
  String get logPickEpubBeforeInspect => isChinese
      ? '请先选择 EPUB 再开始检查。'
      : 'Pick an EPUB file before starting inspection.';
  String logStartingInspection(String name) =>
      isChinese ? '开始检查 EPUB：$name' : 'Starting EPUB inspection for $name';
  String logInspectionFailed(String error) =>
      isChinese ? '检查失败：$error' : 'Inspection failed: $error';
  String get logInspectBeforeTranslate => isChinese
      ? '请先检查 EPUB 再开始翻译。'
      : 'Inspect an EPUB before starting translation.';
  String get logNoChaptersChecked => isChinese
      ? '尚未勾选要翻译的章节。'
      : 'No chapters are checked for translation yet.';
  String logQueuedTranslation(int chapters, int blocks) => isChinese
      ? '已排队翻译：$chapters 章 · $blocks 块。'
      : 'Queued translation for $chapters chapters and $blocks blocks.';
  String logRoughLoad(int batches, int tokens, int chars) => isChinese
      ? '粗估：约 $batches 个 API 批次 · $tokens 输入 tokens（源字符 $chars）。'
      : 'Rough load: ~$batches API batches, ~$tokens input tokens (source chars $chars).';
  String get logTranslationCompleteAndroid => isChinese
      ? '翻译完成。请用「分享」导出 EPUB。'
      : 'Translation complete. Use Share EPUB to export the book from Android.';
  String get logTranslationCompleteDesktop => isChinese
      ? '翻译完成。请用「打开」查看输出文件。'
      : 'Translation complete. Use Open EPUB to view the output file.';
  String logTranslationCompletedWithWarnings(int count) => isChinese
      ? '翻译已完成，但有 $count 个块保留了回退内容。'
      : 'Translation completed with $count blocks retaining fallback content.';
  String degradedBlocksWarning(int count) => isChinese
      ? '$count 个块未能完成翻译，可导出当前 EPUB 后重试。'
      : '$count blocks could not be translated. You can export this EPUB and retry.';
  String logCacheResume(int cached, int resumed) => isChinese
      ? '缓存/续传：$cached 缓存块 · $resumed 续传块。'
      : 'Cache/resume: $cached cached, $resumed resumed blocks.';
  String logCacheRestoredNoApi(int reused) => isChinese
      ? '已复用 $reused 块；缓存恢复阶段未产生 API 请求。'
      : 'Reused $reused blocks; cache restoration made no API requests.';
  String logAllBlocksRestoredNoApi(int total) => isChinese
      ? '已复用全部 $total 块，本次未产生 API 请求。'
      : 'Reused all $total blocks; this run made no API requests.';
  String logTranslationFailed(String error) =>
      isChinese ? '翻译失败：$error' : 'Translation failed: $error';
  String logCheckpointed(int blocks) => isChinese
      ? '进度已检查点（约 $blocks 块）。再次点「开始翻译」可从缓存续传。'
      : 'Progress was checkpointed (~$blocks blocks). Tap Translate again to resume from cache.';
  String get logRunAlreadyActiveInspect => isChinese
      ? '当前已有任务进行中。请取消或等待后再检查。'
      : 'A run is already in progress. Cancel it or wait before starting inspection.';
  String get logRunAlreadyActiveTranslate => isChinese
      ? '当前已有任务进行中。请取消或等待后再翻译。'
      : 'A run is already in progress. Cancel it or wait before starting translation.';
  String get logRunAlreadyActiveGeneric =>
      isChinese ? '当前已有任务进行中。请稍后再试。' : 'A run is already in progress.';
  String get logSelectAfterRun => isChinese
      ? '请等当前任务结束后再选择新的 EPUB。'
      : 'Select a new EPUB after the current run finishes.';
  String get logDropAfterRun => isChinese
      ? '请等当前任务结束后再拖入新的 EPUB。'
      : 'Drop a new EPUB after the current run finishes.';
  String get logChangeOutputAfterRun => isChinese
      ? '请等当前任务结束后再更改输出目录。'
      : 'Change the output directory after the current run finishes.';
  String get logInputLocked => isChinese
      ? '任务进行中，输入路径已锁定。'
      : 'Input path is locked while a run is in progress.';
  String get logOutputLocked => isChinese
      ? '任务进行中，输出目录已锁定。'
      : 'Output directory is locked while a run is in progress.';
  String logCouldNotSelectEpub(String error) =>
      isChinese ? '无法选择 EPUB：$error' : 'Could not select EPUB: $error';
  String logSelectedOutput(String dir) =>
      isChinese ? '已选择输出目录：$dir' : 'Selected output directory: $dir';
  String logAndroidOutputDir(String dir) => isChinese
      ? 'Android 使用应用管理的输出目录：$dir'
      : 'Android uses an app-managed output directory: $dir';
  String logAppliedPreset(String name) =>
      isChinese ? '已应用章节预设：$name。' : 'Applied chapter selection preset: $name.';
  String get logNoActiveRunToCancel =>
      isChinese ? '当前没有可取消的运行中任务。' : 'No active run is available to cancel.';
  String get logCancelAlreadyPending => isChinese
      ? '取消请求已提交，正在尽可能中止进行中的请求。'
      : 'Cancellation is already pending. In-flight HTTP requests are being aborted when possible.';
  String get logCancellationRequested => isChinese
      ? '已请求取消。将尽可能中止进行中的 API 调用。'
      : 'Cancellation requested. Aborting in-flight API calls when possible.';
  String logCachedProgressSoFar(int blocks) => isChinese
      ? '目前已缓存约 $blocks 块。取消后可再点翻译续传。'
      : 'Cached progress so far: ~$blocks blocks. After cancel, press Translate selected to resume.';
  String get logRunCancelled => isChinese ? '任务已取消。' : 'Run cancelled.';
  String logResumeHint(int blocks) => isChinese
      ? '之后可续传翻译；约 $blocks 块已缓存。'
      : 'You can resume translation later; about $blocks blocks are already cached.';
  String logOpenedShare(String name) => isChinese
      ? '已打开 Android 分享：$name。'
      : 'Opened Android share sheet for $name.';
  String logOpenedEpub(String name) =>
      isChinese ? '已打开译后 EPUB：$name' : 'Opened translated EPUB: $name';
  String logCouldNotOpenEpub(String message) => isChinese
      ? '无法打开译后 EPUB：$message'
      : 'Could not open translated EPUB: $message';
  String logCouldNotExport(String error) =>
      isChinese ? '无法导出 EPUB：$error' : 'Could not export EPUB: $error';
  String get logDownloadsAndroidOnly => isChinese
      ? '保存到下载仅在 Android 可用。'
      : 'Saving to Downloads is only available on Android.';
  String logSavedToDownloads(String path) =>
      isChinese ? '已保存译后 EPUB 到 $path。' : 'Saved translated EPUB to $path.';
  String logCouldNotSaveDownloads(String error) =>
      isChinese ? '无法保存到下载：$error' : 'Could not save EPUB to Downloads: $error';
  String get logNoOutputForHistory => isChinese
      ? '该历史项没有可打开的输出文件。'
      : 'No output file is available for this history item.';
  String logOutputNotFound(String path) =>
      isChinese ? '找不到输出文件：$path' : 'Output file was not found: $path';
  String logCouldNotOpenJobOutput(String error) =>
      isChinese ? '无法打开任务输出：$error' : 'Could not open job output: $error';
  String get logRetryWait => isChinese
      ? '请等当前任务结束后再重试历史项。'
      : 'Wait for the current run to finish before retrying a history item.';
  String get logHistoryNotFound =>
      isChinese ? '找不到该历史项。' : 'Could not find that history item.';
  String get logOnlyFailedOrCancelled => isChinese
      ? '仅失败、已取消或完成但有警告的任务可重试。'
      : 'Only failed or cancelled jobs, plus completed jobs with warnings, can be retried.';
  String get logHistoryMissingPath => isChinese
      ? '该历史项没有可重试的 EPUB 路径。'
      : 'This history item does not include an EPUB path to retry.';
  String logRetrying(String name) =>
      isChinese ? '从历史重试：$name。' : 'Retrying $name from history.';
  String get logRetryContinueTranslate => isChinese
      ? '检查完成，继续翻译重试。'
      : 'Inspection ready. Continuing with translation for the retry.';
  String get logClearedHistory =>
      isChinese ? '已清空任务历史。' : 'Cleared job history.';
  String get logNoCompletedEpub => isChinese
      ? '尚无已完成的译后 EPUB。'
      : 'No completed translated EPUB is available yet.';
  String logRestoredEpub(String name) =>
      isChinese ? '已恢复上次 EPUB：$name' : 'Restored last EPUB: $name';
  String logRestoredOutput(String dir) =>
      isChinese ? '已恢复上次输出目录：$dir' : 'Restored last output directory: $dir';
  String get logConfirmStyleBeforeTranslate => isChinese
      ? '请先确认书籍风格档案，再开始整书翻译。'
      : 'Confirm the book style profile before starting full-book translation.';
  String get logGeneratingStyleProfile => isChinese
      ? '正在根据前言/目录/前几章生成风格档案…'
      : 'Generating style profile from front matter and early chapters…';
  String logStyleProfileReady(String label) => isChinese
      ? '风格档案已生成：$label。请确认或修改后再翻译。'
      : 'Style profile ready: $label. Confirm or edit before translating.';
  String logStyleProfileConfirmed(String label) => isChinese
      ? '已确认风格档案：$label。后续翻译将按此风格执行。'
      : 'Style profile confirmed: $label. Later translation will follow it.';
  String get logStyleProfileDisabled => isChinese
      ? '风格档案已关闭，将使用通用翻译风格。'
      : 'Style profile disabled; using generic translation style.';
  String get logInspectBeforeStyleProfile => isChinese
      ? '请先检查 EPUB，再生成风格档案。'
      : 'Inspect an EPUB before generating a style profile.';
  String get logStyleProfileEmpty => isChinese
      ? '未能从前言/前几章抽出稳定风格，可手动填写。'
      : 'No stable style signal found; you can fill the profile manually.';
  String logStyleProfileFailed(String error) =>
      isChinese ? '风格档案生成失败：$error' : 'Style profile generation failed: $error';
  String get logStyleProfileNeedContent => isChinese
      ? '请先填写或生成风格档案内容，再确认。'
      : 'Fill or generate style profile content before confirming.';
}
