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
      'completed' => isChinese ? '已完成' : 'Completed',
      _ => name,
    };
  }

  String stepProgress(int current, int total) =>
      isChinese ? '$current/$total' : '$current/$total';
  String get stepChooseEpub => isChinese ? '选择 EPUB' : 'Choose EPUB';
  String get stepReadyToInspect => isChinese ? '待检查' : 'Ready to inspect';
  String get stepInspecting => isChinese ? '检查中' : 'Inspecting…';
  String get stepReviewChapters => isChinese ? '确认章节' : 'Review chapters';
  String get stepReadyToTranslate => isChinese ? '待翻译' : 'Ready to translate';
  String get stepTranslating => isChinese ? '翻译中' : 'Translating…';
  String get stepExportDone => isChinese ? '已完成' : 'Done';

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
  String get textScaleLabel => isChinese ? '字号' : 'Text size';
  String get lockedGlossary => isChinese ? '锁定术语表' : 'Locked glossary';
  String get lockedGlossaryHint =>
      isChinese ? '每行：原文 => 译文' : 'One per line: source => target';
  String get supportedPlatformsNote =>
      isChinese ? '支持 Windows、Android' : 'Windows, Android';
  String get accessibilitySection => isChinese ? '无障碍' : 'Accessibility';
  String get qualitySection => isChinese ? '质量与术语' : 'Quality';
}
