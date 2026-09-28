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

  // --- Track C (Windows) additions ---
  /// Deterministic inspection failure: the EPUB declares a non-UTF-8
  /// encoding. Shown instead of the raw English FormatException, with no
  /// retry action (retrying cannot help).
  String get encodingUnsupportedHint => isChinese
      ? '该 EPUB 声明了非 UTF-8 编码（如 GBK），请先转码为 UTF-8 后再导入。'
      : 'This EPUB declares a non-UTF-8 encoding (e.g. GBK). Convert it to UTF-8 before importing.';

  /// The native file dialog has no owner window and may open behind the app.
  String get logFileDialogOpened => isChinese
      ? '正在打开文件选择对话框，如未看到请检查任务栏。'
      : 'Opening the file dialog — check the taskbar if you do not see it.';

  /// Chosen path exceeds MAX_PATH (260) while the system long-path policy
  /// is off.
  String logLongPathWithoutPolicy(String selectedPath) => isChinese
      ? '所选路径超过 260 个字符，但系统未开启长路径支持，文件操作可能失败。可在注册表中将 HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled 设为 1。路径：$selectedPath'
      : 'The selected path exceeds 260 characters but Windows long-path support is off, so file operations may fail. Set LongPathsEnabled to 1 under HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem. Path: $selectedPath';

  /// The chosen path lives under OneDrive; on-demand placeholders may need
  /// to download first.
  String get logOneDrivePlaceholderHint => isChinese
      ? '检测到 OneDrive 路径：按需占位文件可能需要先下载，导入可能较慢。'
      : 'OneDrive path detected: on-demand placeholder files may need to download first, so import may be slow.';
  // --- end Track C (Windows) additions ---

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
  String get epubFormatLabel => 'EPUB';
  String get previewFallbackTitle =>
      isChinese ? '尚无已检查的 EPUB' : 'No EPUB inspected yet';
  String get previewFallbackCategory => isChinese ? '等待中' : 'Waiting';
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
  String get etaCalculating => isChinese ? '计算中' : 'Calculating';
  String get etaLessThanOneMinute => isChinese ? '不到 1 分钟' : 'Less than 1 min';
  String etaSeconds(int seconds) => isChinese ? '$seconds 秒' : '$seconds sec';
  String etaMinutes(int minutes) => isChinese ? '$minutes 分钟' : '$minutes min';
  String etaMinutesSeconds(int minutes, int seconds) =>
      isChinese ? '$minutes 分钟 $seconds 秒' : '$minutes min $seconds sec';
  String get overviewIdleHint => '';
  String overviewBody({String? currentBlock}) =>
      currentBlock != null && currentBlock.isNotEmpty
      ? (isChinese ? '当前：$currentBlock' : 'Current: $currentBlock')
      : '';
  String translationProgressSemantics(int percent) =>
      isChinese ? '翻译进度 $percent%' : 'Translation progress $percent%';
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
  String get showDetails => isChinese ? '显示详情' : 'Show details';
  String get hideDetails => isChinese ? '隐藏详情' : 'Hide details';

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
  String get settingsSaveFailed => isChinese
      ? '设置保存失败，显示的值可能未实际保存，请重试'
      : 'Failed to save settings; the shown values may not have persisted. Please retry.';

  /// settings.json could not be written because another program holds a
  /// Windows file lock on it (a second app instance, antivirus, indexer).
  /// Actionable: close the locker and retry, instead of a raw OS error.
  String settingsFileLocked(String filePath) => isChinese
      ? '设置文件被其他程序占用，无法保存：$filePath。请关闭可能锁定它的程序（另一个正在运行的实例、杀毒软件或文件索引器）后重试。'
      : 'The settings file is locked by another program and could not be saved: $filePath. '
            'Close anything that might hold it (another running instance, antivirus, or file indexer) and retry.';

  /// Shown when settings.json was unreadable/corrupt at startup and defaults
  /// were restored. [backupPath] is null when the backup itself failed.
  String settingsCorruptResetNotice(String? backupPath) {
    final String where = backupPath == null
        ? (isChinese ? '（原文件备份失败）' : ' (backing up the original file failed)')
        : (isChinese
              ? '原文件已备份至：$backupPath'
              : 'The original file was backed up to: $backupPath');
    return isChinese
        ? '设置文件损坏或无法读取，已恢复默认设置。$where'
        : 'The settings file was corrupt or unreadable; defaults were restored. $where';
  }

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
  String httpAuthError(String host) => isChinese
      ? 'HTTP 401 认证失败（$host）：请前往设置页检查 API Key 是否有效、可用，且复制时没有多余空格。'
      : 'HTTP 401 authentication failed for $host. Check the API key in the settings page: it must be valid, active, and copied without extra spaces.';
  String httpForbiddenError(String host, String model) => isChinese
      ? 'HTTP 403 无权限（$host）：请前往设置页检查该 API Key 是否可以使用 $model，以及账号是否有访问权限。'
      : 'HTTP 403 permission denied for $host. Check in the settings page whether this API key can use $model and whether the account has access.';
  String httpNotFoundError(String host, String model) => isChinese
      ? 'HTTP 404（$host）：请前往设置页检查接口地址（只保留服务商根地址或 /v1 路径），并确认模型 $model 存在。'
      : 'HTTP 404 from $host. Check the Base URL in the settings page (keep only the provider root or /v1 path) and verify that $model exists.';
  String connectionDetail(String host, String content) => isChinese
      ? '已成功连接到 $host。模型回复：$content'
      : 'Connected to $host successfully. Model responded: $content';
  String rateLimitCooldownTooLong(String host, int minutes) => isChinese
      ? '$host 要求等待 $minutes 分钟后重试（服务端限流）。为避免长时间卡住，本次翻译已停止，请稍后再试。'
      : '$host asked to wait $minutes minutes before retrying (server rate limit). Stopped instead of stalling; please try again later.';
  String outputFileLocked(String path) => isChinese
      ? '输出文件被其他程序占用：$path。请关闭正在打开它的阅读器，然后重新开始翻译。'
      : 'The output file is locked by another program: $path. Close the reader that has it open, then restart the translation.';

  /// Pre-run probe variant: the exclusive-open probe failed, but the OS
  /// error is not a sharing/lock violation (e.g. ERROR_ACCESS_DENIED = 5
  /// on a read-only file) — telling the user to "close the reader" would
  /// be a lie, so report the access problem instead.
  String outputFileNotWritable(String path) => isChinese
      ? '无法写入输出文件（可能是只读文件或没有写入权限）：$path。请检查文件属性后重新开始翻译。'
      : 'Cannot write the output file (it may be read-only or you may lack write permission): $path. Check the file properties, then restart the translation.';

  /// Commit-time variant: the translation is already fully done and the
  /// temp file was preserved, so the user does NOT lose paid work — they
  /// close the locking program and retry (the block cache makes the retry
  /// fast with no extra API cost), or rename the temp file manually.
  String outputFileLockedAtCommit(String outputPath, String tempPath) =>
      isChinese
      ? '输出文件被其他程序占用，无法完成写入：$outputPath。已翻译好的文件保留在：$tempPath（将其重命名为 .epub 即可使用）。请关闭占用该文件的程序后重新翻译，已翻译内容会被复用，无需重复付费。'
      : 'The output file is locked by another program and could not be written: $outputPath. '
            'The translated file was kept at: $tempPath (rename it to .epub to use it). '
            'Close the program holding the file, then translate again — translated content is reused from the cache with no extra API cost.';

  /// Repack/inspect-time variant: the SOURCE file is locked (Windows sharing
  /// violation), usually a reader the user opened mid-run. No API work is
  /// lost beyond what was already billed — the block cache on disk is
  /// intact, so retrying after closing the reader is cheap.
  String inputFileLocked(String path) => isChinese
      ? '源文件被其他程序占用，无法读取：$path。请关闭正在打开它的阅读器后重试；已翻译的块已缓存，重试不会重复计费。'
      : 'The source file is locked by another program and could not be read: $path. '
            'Close the reader that has it open and retry — translated blocks are cached, so the retry costs no extra API calls.';

  /// Run-start precheck: the final output path plus the `.tmp.<16 digits>`
  /// suffix the commit appends would exceed Windows MAX_PATH (260) while the
  /// system long-path policy is off. Thrown before any API spend, so the
  /// user shortens the path instead of failing at ~98%.
  String outputPathTooLong(String outputPath) => isChinese
      ? '输出路径过长：最终文件路径（含程序追加的临时后缀）将超过 Windows 的 260 字符限制，但系统未开启长路径支持，翻译完成时将无法写入。请缩短输出目录或文件名，或在注册表中开启 LongPathsEnabled。路径：$outputPath'
      : 'The output path is too long: the final file path (including the temporary suffix the app appends) would exceed the Windows 260-character limit, but system long-path support is off, so the finished translation could not be written. Shorten the output directory or file name, or enable LongPathsEnabled in the registry. Path: $outputPath';

  /// Zip-bomb guard trip: the archive declares an implausible decompressed
  /// size and was refused before anything was materialized.
  String epubDecompressionLimit(String path) => isChinese
      ? '该 EPUB 解压后体积过大（疑似压缩包炸弹），已拒绝打开：$path。请检查文件来源。'
      : 'This EPUB expands to an unreasonably large size when decompressed (possible zip bomb) and was refused: $path. Please check where the file came from.';
  String get baseUrl => isChinese ? '接口地址' : 'Base URL';
  String get apiKey => 'API Key';
  String get showApiKey => isChinese ? '显示 API key' : 'Show API key';
  String get hideApiKey => isChinese ? '隐藏 API key' : 'Hide API key';
  String get model => isChinese ? '模型' : 'Model';
  String get httpProxy => isChinese ? 'HTTP 代理（可选）' : 'HTTP proxy (optional)';
  String get httpProxyHint => isChinese
      ? '如 127.0.0.1:7890；留空则不使用代理。本地地址不会走代理。'
      : 'e.g. 127.0.0.1:7890; leave empty for no proxy. Local addresses bypass it.';
  String get httpProxyInvalidFormat => isChinese
      ? '代理地址格式不正确，应为 host:port 或 http(s)://host:port。'
      : 'Invalid proxy address. Expected host:port or http(s)://host:port.';
  String get httpProxyUnsupportedScheme => isChinese
      ? '仅支持 HTTP/HTTPS 代理，不支持 SOCKS 等其他协议。'
      : 'Only HTTP/HTTPS proxies are supported, not SOCKS or other protocols.';
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
  String get clearHistoryConfirmTitle =>
      isChinese ? '清空历史记录？' : 'Clear history?';
  String get clearHistoryConfirmBody => isChinese
      ? '将删除全部历史任务记录，此操作不可撤销。'
      : 'This deletes all job history. This cannot be undone.';
  String get dialogCancel => isChinese ? '取消' : 'Cancel';
  String get dialogConfirm => isChinese ? '确定' : 'Confirm';
  String get openOutput => isChinese ? '打开' : 'Open';
  String get retryJob => isChinese ? '重试' : 'Retry';
  String get retryBlockedByActiveRun => isChinese
      ? '当前有任务正在运行，请等待它完成后再重试。'
      : 'A run is currently active. Wait for it to finish before retrying.';
  String get noRecentJobs => isChinese ? '暂无任务' : 'No jobs yet';
  String jobProgressBlocks(int done, int total) =>
      isChinese ? '$done / $total 块' : '$done / $total blocks';
  String jobProgressChapters(int done, int total) =>
      isChinese ? '$done / $total 章' : '$done / $total chapters';
  String jobProgressPercent(int percent) =>
      isChinese ? '$percent% 完成' : '$percent% complete';
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
  String get styleConfidenceHigh => isChinese ? '高' : 'High';
  String get styleConfidenceMedium => isChinese ? '中' : 'Medium';
  String get styleConfidenceLow => isChinese ? '低' : 'Low';
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
  String get dialogOk => isChinese ? '确定' : 'OK';

  // —— Runtime log messages (dashboard) ——
  String logSelectedEpub(String name) =>
      isChinese ? '已选择 EPUB：$name' : 'Selected EPUB: $name';
  String logDroppedEpub(String name) =>
      isChinese ? '已拖入 EPUB：$name' : 'Dropped EPUB: $name';

  /// Multi-file drop: only the first file is imported; tell the user the
  /// rest were ignored instead of silently dropping them.
  String dropMultipleFilesNotice(int fileCount) => isChinese
      ? '一次只能处理一个 EPUB，已导入第一个文件（共拖入 $fileCount 个，其余已忽略）。'
      : 'Only one EPUB can be processed at a time; the first file was '
            'imported ($fileCount dropped, the rest ignored).';

  // —— Inspection progress headers & log lines (dashboard) ——
  String get inspectProgressOpeningArchive =>
      isChinese ? '正在打开存档' : 'Opening archive';
  String inspectLogOpeningEpub(String name) =>
      isChinese ? '正在打开 EPUB：$name' : 'Opening EPUB: $name';
  String inspectLogLocatedPackage(String opfPath) =>
      isChinese ? '找到包文档：$opfPath' : 'Located package document: $opfPath';
  String get inspectProgressNoChapters =>
      isChinese ? '未找到章节' : 'No chapters found';
  String get inspectLogNoChapters => isChinese
      ? '该 EPUB 的 spine 中没有找到 HTML/XHTML 章节。'
      : 'No spine HTML/XHTML chapters were found in the EPUB.';
  String get inspectProgressSpineReady =>
      isChinese ? 'Spine 就绪' : 'Spine ready';
  String inspectLogFoundChapters(int count) => isChinese
      ? '在 spine 中找到 $count 个章节。'
      : 'Found $count chapters in the spine.';
  String inspectLogIndexedChapter(int index, int total, String chapterPath) =>
      isChinese
      ? '已索引章节 $index/$total：$chapterPath'
      : 'Indexed chapter $index/$total: $chapterPath';
  String get inspectProgressReady =>
      isChinese ? '就绪，可以开始翻译' : 'Ready for translation';
  String inspectLogComplete(int chapterCount) => isChinese
      ? 'EPUB 检查完成。预览现已显示 $chapterCount 个真实章节，并附带基础翻译筛选。'
      : 'EPUB inspection complete. Preview now shows $chapterCount real chapters with a basic translation filter.';
  String inspectLogPerformance(
    String duration,
    int chapterCount,
    int blockCount,
  ) => isChinese
      ? '性能：EPUB 检查耗时 $duration，共 $chapterCount 个章节、$blockCount 个文本块。'
      : 'Performance: EPUB inspection took $duration for $chapterCount chapters and $blockCount text blocks.';

  // —— Translation run progress headers & log lines (dashboard) ——
  String runLogCacheWriteFailing(String errorType) => isChinese
      ? '块缓存写入失败（$errorType），将继续翻译但不写缓存。'
      : 'Block cache writes are failing ($errorType); continuing without cache.';
  String runLogCheckpointSaveFailing(String errorType) => isChinese
      ? '断点保存失败（$errorType），将继续翻译但不再更新断点。'
      : 'Checkpoint saves are failing ($errorType); continuing without fresh checkpoints.';
  String runLogFoundCheckpoint(
    int checkpointBlocks,
    int totalBlocks,
    String updatedAt,
  ) => isChinese
      ? '发现已保存的翻译断点（$checkpointBlocks/$totalBlocks 块，$updatedAt）。在发起新的 API 请求前先校验本地缓存。'
      : 'Found a saved translation checkpoint with $checkpointBlocks/$totalBlocks blocks from $updatedAt. Verifying local cache before new API calls.';
  String get runLogCheckpointUnreadable => isChinese
      ? '已保存的断点无法读取，将在没有断点元数据的情况下扫描块缓存。'
      : 'Saved checkpoint is unreadable. Scanning block caches without checkpoint metadata.';
  String runLogRestoringCache(int chapterCount, int blockCount) => isChinese
      ? '正在为 $chapterCount 个章节、$blockCount 个文本块恢复本地缓存。'
      : 'Restoring local cache for $chapterCount chapters and $blockCount extracted blocks.';
  String get runProgressRestoringCache =>
      isChinese ? '正在恢复缓存译文' : 'Restoring cached translations';
  String runLogCacheScanProgress(int scanned, int total, int verified) =>
      isChinese
      ? '缓存扫描 $scanned/$total：已确认 $verified 个可复用块。'
      : 'Cache scan $scanned/$total: verified $verified reusable blocks.';
  String runLogCacheRestoredPartial(int cached, int remaining) => isChinese
      ? '复用了 $cached 个缓存块，本次缓存恢复未产生 API 请求。继续翻译剩余 $remaining 个块。'
      : 'Reused $cached cached blocks; cache restoration made no API requests. Continuing with $remaining blocks.';
  String runLogCacheRestoredAll(int total) => isChinese
      ? '复用了全部 $total 个块，本次运行未产生 API 请求。'
      : 'Reused all $total blocks; this run made no API requests.';
  String runLogStyleProfileConfirmed(String summary) => isChinese
      ? '风格画像：使用用户确认的画像（$summary）。'
      : 'Style profile: using user-confirmed profile $summary.';
  String runLogBookMemoryNone(String duration) => isChinese
      ? '全书记忆：在 $duration 内未找到可用的前言或开篇正文。'
      : 'Book memory: no useful front matter or early chapter text was found in $duration.';
  String runLogBookMemoryCreated(String duration) => isChinese
      ? '全书记忆：已根据前言和开篇章节生成初始摘要（用时 $duration）。'
      : 'Book memory: created initial summary from front matter and early chapters in $duration.';
  String get runLogStyleProfileDisabled => isChinese
      ? '风格画像：已在设置中关闭，使用通用翻译风格。'
      : 'Style profile: disabled in settings; using generic translation style.';
  String runLogStyleProfileWillGuide(String summary) => isChinese
      ? '风格画像：用户确认的 $summary 将指导后续批次。'
      : 'Style profile: user-confirmed $summary will guide later batches.';
  String runLogStyleProfileGenerated(String summary) => isChinese
      ? '风格画像：$summary。后续批次将遵循宽松的体裁/语气约束。'
      : 'Style profile: $summary. Soft genre/tone constraints will guide later batches.';
  String runLogStyleProfileLowConfidence(String summary) => isChinese
      ? '风格画像：置信度较低（$summary），保持通用翻译风格。'
      : 'Style profile: low confidence ($summary); keeping generic translation style.';
  String get runLogStyleProfileNoSignal => isChinese
      ? '风格画像：前言/开篇章节信号不足，保持通用翻译风格。'
      : 'Style profile: not enough signal from front matter/early chapters; keeping generic translation style.';
  String runLogBookMemorySkippedConfirmed(String reason) => isChinese
      ? '全书记忆：初始摘要已跳过（$reason），继续使用用户确认的风格画像。'
      : 'Book memory: initial summary skipped ($reason). Continuing with user-confirmed style profile.';
  String runLogBookMemorySkipped(String reason) => isChinese
      ? '全书记忆：初始摘要已跳过（$reason），在章节摘要可用前将不使用全书记忆继续翻译。'
      : 'Book memory: initial summary skipped ($reason). Translation will continue without whole-book memory until a chapter summary is available.';
  String runLogTranslatingChapter(int index, int total, String title) =>
      isChinese
      ? '正在翻译第 $index/$total 章：$title'
      : 'Translating chapter $index/$total: $title';
  String runLogReusedChapterCache(int hits, String title) => isChinese
      ? '“$title”复用了 $hits 个缓存块。'
      : 'Reused $hits cached blocks for $title.';
  String runLogPreparedFootnoteBatches(
    int batchCount,
    int blockCount,
    int fileCount,
    int cacheHits,
  ) => isChinese
      ? '已准备 $batchCount 个跨文件脚注批次：$blockCount 个块、$fileCount 个文件${cacheHits == 0 ? '' : '（另有 $cacheHits 次缓存命中）'}。'
      : 'Prepared $batchCount cross-file footnote batches for $blockCount blocks across $fileCount files${cacheHits == 0 ? '' : ' after $cacheHits cache hits'}.';
  String runLogFootnoteBatchPerformance(
    int index,
    int total,
    int blockCount,
    int requestCount,
    String duration,
    String apiDuration,
  ) => isChinese
      ? '性能：脚注批次 $index/$total（$blockCount 块，$requestCount 次 API 请求）用时 $duration，其中 API 用时 $apiDuration。'
      : 'Performance: footnote batch $index/$total ($blockCount blocks, $requestCount API ${requestCount == 1 ? 'request' : 'requests'}) took $duration; API time $apiDuration.';
  String runLogFootnoteBatchDone(int done, int total, int index, int batches) =>
      isChinese
      ? '跨文件脚注批次 $index/$batches 后，已翻译 $done/$total 块。'
      : 'Translated $done/$total blocks after cross-file footnote batch $index/$batches.';
  String runLogChapterCompleted(int done, int total, String title) => isChinese
      ? '已完成第 $done/$total 章：$title'
      : 'Completed chapter $done/$total: $title';
  String runLogPreparedBatches(int batchCount, String title) => isChinese
      ? '已为“$title”准备 $batchCount 个批量请求。'
      : 'Prepared $batchCount batched requests for $title.';
  String runLogBatchPerformance(
    int number,
    int total,
    String title,
    int blockCount,
    String duration,
  ) => isChinese
      ? '性能：“$title”的 API 批次 $number/$total（$blockCount 块）用时 $duration。'
      : 'Performance: API batch $number/$total for $title ($blockCount blocks) took $duration.';
  String runLogBatchDone(
    int done,
    int total,
    int number,
    int batches,
    String title,
  ) => isChinese
      ? '“$title”批次 $number/$batches 后，已翻译 $done/$total 块。'
      : 'Translated $done/$total blocks after batch $number/$batches for $title.';
  String runLogChapterPerformance(
    int index,
    int total,
    String duration,
    String apiDuration,
    int newBlocks,
    String cacheDuration,
    int cacheWrites,
    String throughput,
  ) => isChinese
      ? '性能：第 $index/$total 章用时 $duration；$newBlocks 个新块的 API 用时 $apiDuration；块缓存写入 $cacheWrites 次、用时 $cacheDuration；吞吐量 $throughput 新块/分钟。'
      : 'Performance: Chapter $index/$total took $duration. API time $apiDuration for $newBlocks new blocks; block cache writes $cacheDuration across $cacheWrites writes; throughput $throughput new blocks/min.';
  String runLogBookMemoryUpdated(String title, String duration) => isChinese
      ? '全书记忆：“$title”后已更新滚动摘要（用时 $duration）。'
      : 'Book memory: updated rolling summary after $title in $duration.';
  String runLogBookMemoryChapterSkipped(String title, String reason) =>
      isChinese
      ? '全书记忆：“$title”的章节摘要已跳过（$reason）。'
      : 'Book memory: chapter summary skipped for $title ($reason).';
  String runLogBookMemoryChapterSkippedNoNeed(String title) => isChinese
      ? '全书记忆：后续无未缓存块需要，“$title”后跳过章节摘要。'
      : 'Book memory: skipped chapter summary after $title because no later uncached blocks need it.';
  String get runProgressRepacking =>
      isChinese ? '正在重新打包 EPUB' : 'Repacking EPUB';
  String get runLogRepacking => isChinese
      ? '正在把译文 XHTML 写回 EPUB 包。'
      : 'Writing translated XHTML back into the EPUB package.';
  String runLogDegradedBlocks(int count, String sample) => isChinese
      ? '翻译中有 $count 个块保留了回退内容${sample.isEmpty ? '' : '：$sample'}。'
      : 'Translation retained fallback content for $count blocks${sample.isEmpty ? '' : ': $sample'}.';
  String get runLogRunFailedAllDegraded => isChinese
      ? '翻译失败：所有选中的文本块都保留了回退内容。'
      : 'Translation failed because every selected text block retained fallback content.';

  /// Terminal `errorMessage` shown on the job row when every selected block
  /// fell back (user-visible; kept separate from the log line above).
  String get runErrorAllBlocksDegraded => isChinese
      ? '所有选中的文本块在翻译失败后都使用了回退内容。'
      : 'Every selected text block fell back after translation failures.';
  String runLogRunCompletedWithWarnings(String path) => isChinese
      ? '翻译完成（有警告）。已将部分 EPUB 写入 $path'
      : 'Translation completed with warnings. Wrote partial EPUB to $path';
  String runLogRunComplete(String path) => isChinese
      ? '翻译完成。已将译后 EPUB 写入 $path'
      : 'Translation complete. Wrote translated EPUB to $path';
  String runLogRepackPerformance(String duration) => isChinese
      ? '性能：最终 EPUB 重新打包用时 $duration。'
      : 'Performance: Final EPUB repack took $duration.';
  String runLogFinalPerformance(
    String duration,
    int newBlocks,
    String throughput,
    String apiDuration,
    String memoryDuration,
    int memoryRequests,
    String cacheDuration,
    int cacheWrites,
    int footnoteBatches,
    int footnoteRequests,
  ) => isChinese
      ? '性能：本次翻译共用时 $duration。共翻译 $newBlocks 个新块（不含缓存与断点续翻命中），平均 $throughput 块/分钟；API 总用时 $apiDuration；全书记忆 $memoryDuration（$memoryRequests 次请求）；块缓存写入 $cacheWrites 次、用时 $cacheDuration。${footnoteBatches == 0 ? '' : '跨文件脚注共 $footnoteBatches 个批次、$footnoteRequests 次 API 请求。'}'
      : 'Performance: Translation run took $duration. Translated $newBlocks new blocks at $throughput blocks/min on average, excluding cache and resume hits. Total API time $apiDuration; book memory $memoryDuration across $memoryRequests requests; block cache writes $cacheDuration across $cacheWrites writes.${footnoteBatches == 0 ? '' : ' Cross-file footnotes used $footnoteBatches batches across $footnoteRequests API requests.'}';
  String runLogFinalCheckpointFailed(String errorType, String path) => isChinese
      ? '最终断点保存失败（$errorType）；EPUB 已就绪：$path。'
      : 'Final checkpoint could not be saved ($errorType); the EPUB is ready at $path.';
  String get runProgressContinuingTranslation =>
      isChinese ? '继续翻译' : 'Continuing translation';
  String get runProgressAllRestoredFromCache =>
      isChinese ? '已从缓存恢复全部译文' : 'All translations restored from cache';
  String get runProgressTranslationFailed =>
      isChinese ? '翻译失败' : 'Translation failed';
  String get runProgressEpubReadyWithWarnings =>
      isChinese ? 'EPUB 已就绪（有警告）' : 'EPUB ready with warnings';
  String get runProgressEpubReady => isChinese ? 'EPUB 已就绪' : 'EPUB ready';
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
      ? '$count 个块未能完成翻译，保留原文。当前 EPUB 仍可使用，也可重试。'
      : '$count blocks could not be translated and retain the original text. You can use this EPUB or retry.';
  String get partialOutputWarning => isChinese
      ? '部分内容未完成翻译，保留原文。当前 EPUB 仍可使用，也可重试。'
      : 'Some content could not be translated and retains the original text. You can use this EPUB or retry.';
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
  String logCouldNotSelectDirectory(String error) =>
      isChinese ? '无法选择目录：$error' : 'Could not select directory: $error';
  String get logNotEnoughSpace => isChinese
      ? '存储空间不足，无法导入该文件。请清理空间后重试。'
      : 'Not enough storage space to import this file. Free up space and retry.';

  /// The Windows file dialog itself cannot handle the over-long path: the
  /// PowerShell host is not covered by the app's longPathAware manifest
  /// entry, so this fails even when the system long-path policy is on.
  String get logWindowsDialogPathTooLong => isChinese
      ? '文件对话框无法处理超过约 260 个字符的路径。请把文件/文件夹移到更浅的目录，或启用系统的 Win32 长路径策略（组策略/注册表 LongPathsEnabled）后重试。'
      : 'The file dialog cannot handle paths longer than ~260 characters. Move the file/folder to a shallower directory or enable the Win32 long-path policy (LongPathsEnabled) and retry.';
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
  String get logClearHistoryFailed => isChinese
      ? '清空历史记录失败（未能写入磁盘），下次启动历史可能恢复，请重试。'
      : 'Failed to clear history (could not write to disk); it may reappear on next launch. Please try again.';
  String get clearBlockedByActiveRun => isChinese
      ? '当前有任务正在运行，请等待它完成后再清空历史。'
      : 'A run is currently active. Wait for it to finish before clearing history.';

  /// Job progress titles shown in the overview header. These used to be
  /// English literals coupled to the retry heuristic's `contains('translation')`
  /// match; the heuristic now reads `phase` instead, so they are localized.
  String get jobStatusInspectionFailed =>
      isChinese ? '检查失败' : 'Inspection failed';
  String get jobStatusRestoringCache =>
      isChinese ? '正在恢复缓存的翻译' : 'Restoring cached translations';
  String get jobStatusTranslationFailed =>
      isChinese ? '翻译失败' : 'Translation failed';
  String get jobStatusCancellationRequested =>
      isChinese ? '正在取消' : 'Cancelling';
  String get jobStatusTranslationInterrupted =>
      isChinese ? '翻译已中断' : 'Translation interrupted';
  String get jobStatusInspectionInterrupted =>
      isChinese ? '检查已中断' : 'Inspection interrupted';

  /// Shown in the job history for a task that was still running when the app
  /// closed. The companion `currentChapter` is localized as well — the retry
  /// heuristic reads `phase`/`status`, not the display string.
  String get jobInterruptedOnRestart => isChinese
      ? '应用在上次任务完成前已关闭。'
      : 'The app closed before this task finished.';
  String get logNoCompletedEpub => isChinese
      ? '尚无已完成的译后 EPUB。'
      : 'No completed translated EPUB is available yet.';
  String logRestoredEpub(String name) =>
      isChinese ? '已恢复上次 EPUB：$name' : 'Restored last EPUB: $name';
  String logRestoredOutput(String dir) =>
      isChinese ? '已恢复上次输出目录：$dir' : 'Restored last output directory: $dir';
  String logSkippedMissingInputPath(String name) => isChinese
      ? '上次的 EPUB 已不存在，跳过恢复：$name'
      : 'Last EPUB no longer exists; skipped restoring: $name';
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

  // —— Track D (round 5) additions ——
  /// H3: the Dart-side 5-minute timeout only stops waiting; the native
  /// worker keeps running to completion in the background.
  String get saveTimeoutContinuesBackground => isChinese
      ? '操作超时，但任务仍在后台继续，完成后可在下载目录查看。'
      : 'The operation timed out, but the task continues in the background; check the Downloads folder once it finishes.';

  /// C-M4: localized title for the Android share chooser.
  String get shareChooserTitle => isChinese ? '分享 EPUB' : 'Share EPUB';

  /// C-M6: shown when storage permission is permanently denied.
  String get storagePermissionPermanentlyDenied => isChinese
      ? '存储权限被永久拒绝，请前往应用设置开启。'
      : 'Storage permission was permanently denied. Please enable it in the app settings.';

  /// C-M6: Snackbar action label that opens the system app-settings screen.
  String get openAppSettingsAction => isChinese ? '前往设置' : 'Open settings';

  /// C-M7: Android foreground-service notification while translating.
  String get foregroundServiceTitle =>
      isChinese ? 'EPUB 翻译器正在翻译' : 'EPUB Translator is translating';
  String get foregroundServiceText => isChinese
      ? '翻译进行中，可在通知栏查看进度。'
      : 'Translation in progress; check the notification for progress.';

  /// Stop action on the foreground-service notification. Tapping it brings
  /// the app forward and cancels the run through the normal cancel path.
  String get foregroundServiceStopAction => isChinese ? '停止' : 'Stop';

  /// Final notification text after Android 15+ kills the foreground service
  /// for exceeding its background time budget (~6h). Reopening the app
  /// resets the budget, so the user can resume from the checkpoint.
  String get foregroundServiceTimeoutText => isChinese
      ? '后台运行时间已达上限，请重新打开应用以继续翻译。'
      : 'Background time limit reached — reopen the app to continue.';

  /// Log line when Android 15+ stops the foreground service for exceeding
  /// its background time budget and Dart winds the run down. Blocks already
  /// translated stay in the cache, so reopening resumes without re-paying.
  String get logForegroundServiceTimeout => isChinese
      ? 'Android 后台运行时间已达上限（约 6 小时），已停止继续翻译以保护进度。已翻译的块仍保留在缓存中，重新打开应用后可续传。'
      : 'Android background time limit reached (~6h); winding the run down to protect progress. Translated blocks stay cached — reopen the app to resume.';

  /// Log line when the Android 15+ timeout notice had to be persisted
  /// because notifications were disabled, and is now surfaced on app
  /// start: the run was already wound down when the timeout fired (or the
  /// process died with it), so this only informs — no new cancel needed.
  String get logForegroundServiceTimeoutRecovered => isChinese
      ? '检测到上次后台运行时间已达上限（约 6 小时），当时通知被关闭未能提醒。已翻译的块仍保留在缓存中，可随时重新开始续传。'
      : 'A previous run hit the Android background time limit (~6h) while notifications were off, so it could not alert you then. Translated blocks stay cached — resume any time.';

  /// Log line when Android 12+ refuses the foreground-service start
  /// because the app is in the background. Translation continues without
  /// the Doze keep-alive; returning to the foreground restores it.
  String get logForegroundServiceBackgroundDenied => isChinese
      ? '系统拒绝在后台启动前台服务，翻译将在无保活的情况下继续；回到应用前台可恢复保活。'
      : 'The system denied starting the foreground service from the background; translation continues without the keep-alive. Return to the app to restore it.';

  /// Settings-page warning when the Android KeyStore key was invalidated
  /// (lock-screen/biometric change) and regenerated: previously saved API
  /// keys are unrecoverable and must be re-entered.
  String get secretKeyRotatedWarning => isChinese
      ? '检测到设备锁屏或安全设置变更，已保存的密钥已失效，请重新输入 API 密钥。'
      : 'Device lock-screen/security settings changed; saved secrets were invalidated. Please re-enter your API keys.';

  /// Settings-page warning when the app runs elevated on Windows: DPAPI
  /// secrets are tied to the logon session, so keys saved as administrator
  /// are invisible to the normal user account and vice versa.
  String get windowsElevatedSecretWarning => isChinese
      ? '当前以管理员身份运行：保存的密钥与普通用户不互通；若密钥显示为空，请以普通权限重新打开应用。'
      : 'Running as administrator: saved secrets are not shared with your standard user account. If keys appear empty, relaunch the app without elevation.';
}
