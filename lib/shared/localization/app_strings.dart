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
  String get appSubtitle =>
      isChinese ? 'Flutter 重写工作区' : 'Flutter rewrite workspace';
  String get navTranslate => isChinese ? '翻译' : 'Translate';
  String get navJobs => isChinese ? '任务' : 'Jobs';
  String get navPreview => isChinese ? '预览' : 'Preview';
  String get navSettings => isChinese ? '设置' : 'Settings';
  String get shellStatus => isChinese ? '状态' : 'Status';
  String get shellStatusBody => isChinese
      ? '当前已经接上 EPUB 解析、章节筛选、实时翻译和重新打包输出。'
      : 'EPUB inspection, chapter selection, live translation, and repack output are now wired in.';

  String get translationPageTitle =>
      isChinese ? '翻译工作台' : 'Translation Workspace';
  String get translationPageSubtitle => isChinese
      ? '选择本地 EPUB，检查结构，筛选章节，并把勾选内容翻译成新的 EPUB。'
      : 'Choose a local EPUB, inspect its structure, refine the chapter checklist, and translate the selected content into a new EPUB.';
  String get inspectEpub => isChinese ? '检查 EPUB' : 'Inspect EPUB';
  String get translateSelected => isChinese ? '翻译所选章节' : 'Translate selected';

  String get bookSetup => isChinese ? '图书设置' : 'Book Setup';
  String get inputEpub => isChinese ? '输入 EPUB' : 'Input EPUB';
  String get inputEpubHint =>
      isChinese ? '选择或粘贴本地 .epub 路径' : 'Select or paste a local .epub path';
  String get chooseEpub => isChinese ? '选择 EPUB' : 'Choose EPUB';
  String get outputDirectory => isChinese ? '输出目录' : 'Output Directory';
  String get outputDirectoryHint => isChinese
      ? '选择译后电子书输出目录'
      : 'Choose where translated books will be written';
  String get chooseOutputDirectory =>
      isChinese ? '选择输出目录' : 'Choose output directory';
  String get targetLanguage => isChinese ? '目标语言' : 'Target Language';
  String get bilingualOutput => isChinese ? '双语输出' : 'Bilingual Output';

  String get runOverview => isChinese ? '运行概览' : 'Run Overview';
  String get statusLabel => isChinese ? '状态' : 'Status';
  String get chapterLabel => isChinese ? '章节' : 'Chapter';
  String get filesLabel => isChinese ? '文件' : 'Files';
  String get blocksLabel => isChinese ? '文本块' : 'Blocks';
  String get cacheHitsLabel => isChinese ? '缓存命中' : 'Cache hits';
  String get resumeHitsLabel => isChinese ? '续跑命中' : 'Resume hits';
  String get notStarted => isChinese ? '未开始' : 'Not started';
  String get saveToDownloads => isChinese ? '保存到下载' : 'Save to Downloads';
  String get shareEpub => isChinese ? '分享 EPUB' : 'Share EPUB';
  String get openEpub => isChinese ? '打开 EPUB' : 'Open EPUB';
  String overviewBody({String? currentBlock}) =>
      currentBlock != null && currentBlock.isNotEmpty
      ? (isChinese ? '当前文本块：$currentBlock' : 'Current block: $currentBlock')
      : (isChinese
            ? '这里会显示真实的检查和翻译进度。先检查 EPUB，再调整章节勾选，然后启动实时 API 翻译。'
            : 'This panel now shows real inspection and translation progress. Inspect first, refine the chapter checklist, then launch live API translation.');

  String get logsTitle => isChinese ? '日志' : 'Logs';

  String get previewTitle => isChinese ? '预览' : 'Preview';
  String get previewSubtitle => isChinese
      ? '查看真实章节目录，决定哪些内容参与翻译，并确认已经提取出的正文块。'
      : 'Review the real chapter list, decide what stays in scope, and spot how many text blocks are ready for translation.';
  String get chapterChecklist => isChinese ? '章节清单' : 'Chapter checklist';
  String get resetSelection => isChinese ? '重置' : 'Reset';
  String chapterChecklistSummary(
    int selectedChapters,
    int totalChapters,
    int selectedBlocks,
  ) => isChinese
      ? '$selectedChapters/$totalChapters 个章节已选中，当前清单包含 $selectedBlocks 个待翻译文本块'
      : '$selectedChapters/$totalChapters chapters selected, $selectedBlocks extracted blocks queued by the current checklist';
  String chapterCategoryBlocks(String category, int blockCount) => isChinese
      ? '$category - $blockCount 个块'
      : '$category - $blockCount blocks';
  String get manualOverrideTooltip => isChinese
      ? '当前选择已手动覆盖默认过滤建议'
      : 'Manually overridden from the default filter';
  String get defaultLabel => isChinese ? '默认建议' : 'Default';
  String get translateBadge => isChinese ? '翻译' : 'Translate';
  String get skipBadge => isChinese ? '跳过' : 'Skip';
  String get currentFilteringRule =>
      isChinese ? '当前过滤规则' : 'Current filtering rule';
  String get currentFilteringRuleBody => isChinese
      ? '默认过滤会保留大概率属于正文、前言、后记和参考部分的章节；封面、注册引导、广告、版权和致谢页会默认取消勾选，但你可以在清单里手动覆盖。'
      : 'The default filter keeps likely reading content, front matter, back matter, and reference sections. Obvious cover, signup, promo, credit, and copyright pages start unchecked, but you can override any chapter in the checklist.';

  String get settingsTitle => isChinese ? '设置' : 'Settings';
  String get settingsSubtitle => isChinese
      ? '这些设置会自动保存在本地，下次打开应用时继续沿用。'
      : 'These settings are persisted locally and will be restored the next time you open the app.';
  String get uiLanguage => isChinese ? '界面语言' : 'UI Language';
  String get englishLabel => 'English';
  String get chineseLabel => '中文';
  String get apiSection => 'API';
  String get testConnection => isChinese ? '测试连接' : 'Test connection';
  String get testingConnection =>
      isChinese ? '正在测试连接...' : 'Testing connection...';
  String get connectionOk => isChinese ? '连接成功' : 'Connection OK';
  String get connectionFailed => isChinese ? '连接失败' : 'Connection failed';
  String get baseUrl => isChinese ? '接口地址' : 'Base URL';
  String get apiKey => 'API Key';
  String get model => isChinese ? '模型' : 'Model';
  String get translationSection => isChinese ? '翻译参数' : 'Translation';
  String chunkSizeLabel(int value) =>
      isChinese ? '合批字符预算：$value' : 'Batch character budget: $value';
  String maxConcurrentLabel(int value) =>
      isChinese ? '并发请求数：$value' : 'Max concurrent requests: $value';
  String timeoutLabel(int value) =>
      isChinese ? '单次请求超时（秒）：$value' : 'Request timeout (seconds): $value';
  String maxRetriesLabel(int value) =>
      isChinese ? '失败重试次数：$value' : 'Max retries: $value';
  String retryDelayLabel(int value) =>
      isChinese ? '重试间隔（秒）：$value' : 'Retry delay (seconds): $value';
  String get disableThinking =>
      isChinese ? '禁用思维链字段' : 'Disable thinking field';
  String get outputSuffix => isChinese ? '输出后缀' : 'Output suffix';

  String get jobsTitle => isChinese ? '任务' : 'Jobs';
  String get jobsSubtitle => isChinese
      ? '这里会承载可恢复任务、失败重试和持久化历史。'
      : 'This view will host resumable runs, failures, retries, and persistent job history.';
  String get recentJobs => isChinese ? '最近任务' : 'Recent Jobs';
}
