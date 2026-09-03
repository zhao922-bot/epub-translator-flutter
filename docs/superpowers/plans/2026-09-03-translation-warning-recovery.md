# 翻译警告与恢复机制实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将部分降级的 EPUB 翻译结果明确标记为“完成但有警告”，支持导出和缓存续跑，同时修复降级状态串扰、诊断信息泄露及安全密钥误删问题。

**架构：** 在 `TranslationJob` 中持久化终态和降级数量；翻译器以单次运行的块对象集合追踪降级，在重打包后选择完成、警告或失败终态；控制器和 UI 将警告任务作为可导出、可重试的终态处理。设置存储引入逐密钥读取状态和显式密钥变更集合，使普通设置保存不会修改读取失败的安全项。

**技术栈：** Flutter、Dart、Riverpod、Dio、`flutter_test`、本地 JSON 任务历史、平台安全存储。

---

## 文件结构

- 修改 `lib/features/translation/domain/models/translation_job.dart`：新增警告终态、降级计数、序列化和导出/续跑语义。
- 修改 `lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`：隔离降级追踪、计算终态、移除敏感诊断写入。
- 修改 `lib/features/translation/application/translation_dashboard_controller.dart`：接收警告/全降级结果并允许警告任务重试。
- 修改 `lib/features/jobs/application/jobs_provider.dart`：向任务列表暴露警告状态和重试能力。
- 修改 `lib/features/translation/presentation/widgets/translation_overview.dart`：渲染黄色警告状态及降级数量。
- 修改 `lib/shared/localization/app_strings.dart`：增加中英文警告状态、摘要和重试校验文案。
- 修改 `lib/features/settings/infrastructure/settings_store.dart`：实现安全密钥读取三态和选择性保存。
- 修改 `lib/features/settings/application/settings_controller.dart`：仅在 API key 编辑时声明显式密钥变更。
- 修改 `test/translation_job_test.dart`、`test/job_history_store_test.dart`：验证模型与历史兼容。
- 修改 `test/repository_safety_test.dart`、`test/epub_repository_performance_test.dart`：验证降级隔离、终态和缓存续跑。
- 修改 `test/translation_dashboard_controller_test.dart`、`test/jobs_provider_test.dart`：验证控制器和任务操作。
- 修改 `test/translation_overview_test.dart`：验证警告 UI 和本地化。
- 修改 `test/settings_store_test.dart`、`test/settings_controller_test.dart`：验证密钥读取失败保护和显式修改。
- 创建 `test/production_diagnostics_test.dart`：防止硬编码敏感诊断路径回归。

### 任务 1：建立警告任务领域模型

**文件：**
- 修改：`lib/features/translation/domain/models/translation_job.dart`
- 测试：`test/translation_job_test.dart`
- 测试：`test/job_history_store_test.dart`

- [ ] **步骤 1：编写失败的领域模型测试**

在 `test/translation_job_test.dart` 增加以下测试，覆盖警告结果可导出、可续跑以及降级数量的健壮反序列化：

```dart
test('warning jobs are exportable and resumable', () {
  const TranslationJob job = TranslationJob(
    id: 'warning-job',
    inputPath: 'book.epub',
    outputPath: 'book_translated.epub',
    status: TranslationJobStatus.completedWithWarnings,
    phase: TranslationJobPhase.translation,
    progress: 1,
    completedBlocks: 4,
    totalBlocks: 4,
    degradedBlockCount: 1,
  );

  expect(job.hasExportableEpub, isTrue);
  expect(job.canResumeTranslation, isTrue);
  expect(TranslationJob.fromJson(job.toJson()).degradedBlockCount, 1);
});

test('legacy and invalid degraded counts load as zero', () {
  for (final Object? value in <Object?>[null, -1, 'invalid']) {
    final TranslationJob job = TranslationJob.fromJson(<String, Object?>{
      'id': 'legacy-$value',
      'status': 'completed',
      'phase': 'translation',
      'progress': 1,
      if (value != null) 'degradedBlockCount': value,
    });
    expect(job.degradedBlockCount, 0);
  }
});
```

在 `test/job_history_store_test.dart` 增加一个 `completedWithWarnings` 任务保存后重新读取的断言，确认状态和 `degradedBlockCount` 均保持。

- [ ] **步骤 2：运行测试并确认按预期失败**

运行：

```powershell
flutter test test/translation_job_test.dart test/job_history_store_test.dart
```

预期：编译失败，提示 `TranslationJobStatus.completedWithWarnings` 和 `degradedBlockCount` 尚未定义。

- [ ] **步骤 3：实现最小领域模型变更**

在 `translation_job.dart` 中加入枚举值、字段和序列化：

```dart
enum TranslationJobStatus {
  idle,
  queued,
  running,
  inspected,
  cancelled,
  failed,
  completedWithWarnings,
  completed,
}

final int degradedBlockCount;
```

构造函数默认 `this.degradedBlockCount = 0`；`copyWith` 接受 `int? degradedBlockCount`；`toJson` 写出该字段；`fromJson` 使用现有 `_readNonNegativeInt` 读取。

将派生属性改为：

```dart
bool get hasExportableEpub {
  if (status != TranslationJobStatus.completed &&
      status != TranslationJobStatus.completedWithWarnings) {
    return false;
  }
  if (phase != TranslationJobPhase.translation) {
    return false;
  }
  return outputPath.trim().toLowerCase().endsWith('.epub');
}

bool get canResumeTranslation {
  final bool resumableStatus =
      status == TranslationJobStatus.failed ||
      status == TranslationJobStatus.cancelled ||
      status == TranslationJobStatus.completedWithWarnings;
  return (phase == TranslationJobPhase.translation ||
          phase == TranslationJobPhase.cacheRestoration) &&
      resumableStatus &&
      (cachedBlocks > 0 || resumedBlocks > 0 || completedBlocks > 0);
}
```

在 `_readPhase` 的 legacy fallback 中，将 `completedWithWarnings` 与 `completed` 一并视为 translation phase。

- [ ] **步骤 4：运行领域模型测试确认通过**

运行：

```powershell
dart format lib/features/translation/domain/models/translation_job.dart test/translation_job_test.dart test/job_history_store_test.dart
flutter test test/translation_job_test.dart test/job_history_store_test.dart
```

预期：全部通过，0 个失败。

- [ ] **步骤 5：提交领域模型变更**

```powershell
git add -- lib/features/translation/domain/models/translation_job.dart test/translation_job_test.dart test/job_history_store_test.dart
git commit -m "feat: add completed-with-warnings job state"
```

### 任务 2：隔离降级状态并生成诚实终态

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`
- 修改：`test/repository_safety_test.dart`
- 修改：`test/epub_repository_performance_test.dart`

- [ ] **步骤 1：编写失败的降级隔离测试**

在 `test/repository_safety_test.dart` 为 test-only 批处理入口增加连续调用场景。第一次让块 `p-0` 超时并降级，第二次使用另一个同 ID 块成功；第二次结束后降级集合必须为空：

```dart
test('test translation runs do not retain degraded block state', () async {
  final EpubChapterTranslator translator = EpubChapterTranslator();
  const ExtractedBlock first = ExtractedBlock(
    id: 'p-0',
    tagName: 'p',
    sourceHtml: '<p>First.</p>',
    sourceText: 'First.',
  );
  const ExtractedBlock second = ExtractedBlock(
    id: 'p-0',
    tagName: 'p',
    sourceHtml: '<p>Second.</p>',
    sourceText: 'Second.',
  );
  final _AlwaysConnectionTimeoutAdapter timeoutAdapter =
      _AlwaysConnectionTimeoutAdapter();
  final Dio timeoutDio =
      Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = timeoutAdapter;

  await translator.translateBlockBatchForTest(
    dio: timeoutDio,
    config: TranslationConfig.defaults().copyWith(
      apiKey: 'sk-test',
      targetLanguage: 'Chinese',
      maxRetries: 0,
      retryDelaySeconds: 0,
    ),
    blocks: <ExtractedBlock>[first],
  );
  expect(translator.getDegradedBlockIdsForTest(), <String>{'p-0'});

  final _SequencedHtmlBatchAdapter successAdapter =
      _SequencedHtmlBatchAdapter(<String>['<p>第二段。</p>']);
  final Dio successDio =
      Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'))
        ..httpClientAdapter = successAdapter;
  await translator.translateBlockBatchForTest(
    dio: successDio,
    config: TranslationConfig.defaults().copyWith(
      apiKey: 'sk-test',
      targetLanguage: 'Chinese',
      maxRetries: 0,
      retryDelaySeconds: 0,
    ),
    blocks: <ExtractedBlock>[second],
  );
  expect(translator.getDegradedBlockIdsForTest(), isEmpty);
});
```

- [ ] **步骤 2：编写失败的完整运行终态测试**

在 `test/epub_repository_performance_test.dart` 扩展本地 fake server，使其可按 block 请求序号返回正常译文或连接超时，并增加三个集成测试：

```dart
expect(partial.job.status, TranslationJobStatus.completedWithWarnings);
expect(partial.job.degradedBlockCount, 1);
expect(partial.job.hasExportableEpub, isTrue);

expect(success.job.status, TranslationJobStatus.completed);
expect(success.job.degradedBlockCount, 0);

expect(allDegraded.job.status, TranslationJobStatus.failed);
expect(allDegraded.job.degradedBlockCount, allDegraded.job.totalBlocks);
expect(allDegraded.job.hasExportableEpub, isFalse);
```

部分降级用两个短块且 `chunkSize` 足够小以形成两个请求；首次请求超时，第二次返回合法翻译。随后用同一 repository 和配置重试，断言服务器只收到原降级块的翻译请求，证明正常块缓存被复用。

- [ ] **步骤 3：运行测试并确认按预期失败**

运行：

```powershell
flutter test test/repository_safety_test.dart test/epub_repository_performance_test.dart
```

预期：连续调用测试因旧降级集合残留失败；完整运行仍返回 `completed` 或缺少降级计数。

- [ ] **步骤 4：将降级集合改为运行级块对象集合**

在翻译器中使用身份相等的 `ExtractedBlock` 作为键：

```dart
final Set<ExtractedBlock> _degradedBlocks = <ExtractedBlock>{};

Set<String> getDegradedBlockIdsForTest() =>
    _degradedBlocks.map((ExtractedBlock block) => block.id).toSet();

void _beginDegradedTracking() {
  _degradedBlocks.clear();
}
```

在 `translateChapters` 的 `try` 之前、`translateBlockBatchForTest` 和 `translateFootnoteBatchForTest` 的 wrapper 中调用 `_beginDegradedTracking()`。把所有 `add(block.id)` 改为 `add(block)`，把批量 `addAll` 改为加入对应 block 对象，把两个 cache-write 判断改为 `_degradedBlocks.contains(block)`。

缓存写入计数只对实际执行的写入递增，避免降级块被统计为成功缓存。

- [ ] **步骤 5：计算并回传终态**

在重打包前计算稳定计数，并在最终 job 中持久化：

```dart
final int degradedBlockCount = _degradedBlocks.length;
final bool allBlocksDegraded =
    totalBlocks > 0 && degradedBlockCount >= totalBlocks;
final TranslationJobStatus terminalStatus = allBlocksDegraded
    ? TranslationJobStatus.failed
    : degradedBlockCount > 0
    ? TranslationJobStatus.completedWithWarnings
    : TranslationJobStatus.completed;

final TranslationJob terminalJob = currentJob.copyWith(
  status: terminalStatus,
  phase: TranslationJobPhase.translation,
  progress: 1,
  currentChapter: allBlocksDegraded
      ? 'Translation failed'
      : degradedBlockCount > 0
      ? 'EPUB ready with warnings'
      : 'EPUB ready',
  currentBlock: null,
  degradedBlockCount: degradedBlockCount,
  errorMessage: allBlocksDegraded
      ? 'Every selected text block fell back after translation failures.'
      : null,
  completedFiles: completedFiles,
  totalFiles: selectedChapters.length,
  completedBlocks: completedBlocks,
  totalBlocks: totalBlocks,
  cachedBlocks: cachedBlocks,
  resumedBlocks: resumedBlocks,
);
```

日志只输出总数和最多 20 个块 ID：

```dart
final String sample = _degradedBlocks
    .take(20)
    .map((ExtractedBlock block) => block.id)
    .join(',');
emit(
  currentJob.copyWith(degradedBlockCount: degradedBlockCount),
  'Translation retained fallback content for $degradedBlockCount blocks'
  '${sample.isEmpty ? '' : ': $sample'}.',
);
```

不要记录 source HTML、translation HTML、API key 或完整响应。

- [ ] **步骤 6：运行聚焦测试确认通过**

运行：

```powershell
dart format lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/repository_safety_test.dart test/epub_repository_performance_test.dart
flutter test test/repository_safety_test.dart test/epub_repository_performance_test.dart
```

预期：全部通过，部分降级、全降级、无降级、缓存重试和跨运行隔离均符合断言。

- [ ] **步骤 7：提交翻译终态与隔离修复**

```powershell
git add -- lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/repository_safety_test.dart test/epub_repository_performance_test.dart
git commit -m "fix: isolate degraded translation results"
```

### 任务 3：移除敏感诊断写入

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`
- 创建：`test/production_diagnostics_test.dart`

- [ ] **步骤 1：添加失败的源码回归测试**

创建 `test/production_diagnostics_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production translator has no hard-coded sensitive diagnostic sink', () {
    final String source = File(
      'lib/features/translation/infrastructure/epub/'
      'epub_chapter_translator.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('_p13_failure_diag.log')));
    expect(source, isNot(contains('RAW=\$lastCleaned')));
    expect(source, isNot(contains('SOURCE=\$sourcePreview')));
  });
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：

```powershell
flutter test test/production_diagnostics_test.dart
```

预期：FAIL，源码仍包含 `_p13_failure_diag.log`。

- [ ] **步骤 3：删除生产诊断文件写入块**

从 `_translateBlock` 的异常处理删除创建 `File`、`RandomAccessFile`、`SOURCE`、`RAW`、`LOCKED` payload 的整个 `if` 块。保留现有内存中的 `lastCleaned` 回退和经过脱敏的应用日志；不读取或删除磁盘上的旧诊断文件。

- [ ] **步骤 4：运行测试确认通过并提交**

```powershell
dart format lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/production_diagnostics_test.dart
flutter test test/production_diagnostics_test.dart test/repository_safety_test.dart
git add -- lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/production_diagnostics_test.dart
git commit -m "fix: remove sensitive translation diagnostics"
```

预期：测试全部通过，提交不包含任何 `work/` 文件变更。

### 任务 4：让控制器、任务列表和 UI 识别警告终态

**文件：**
- 修改：`lib/features/translation/application/translation_dashboard_controller.dart`
- 修改：`lib/features/jobs/application/jobs_provider.dart`
- 修改：`lib/features/translation/presentation/widgets/translation_overview.dart`
- 修改：`lib/shared/localization/app_strings.dart`
- 修改：`test/translation_dashboard_controller_test.dart`
- 修改：`test/jobs_provider_test.dart`
- 修改：`test/translation_overview_test.dart`

- [ ] **步骤 1：编写失败的 provider 与控制器测试**

在 `test/jobs_provider_test.dart` 的历史 fixture 中加入：

```dart
TranslationJob(
  id: 'warning-job',
  inputPath: r'C:\Books\partial.epub',
  outputPath: r'C:\Translated\partial_translated.epub',
  status: TranslationJobStatus.completedWithWarnings,
  phase: TranslationJobPhase.translation,
  progress: 1,
  completedBlocks: 10,
  totalBlocks: 10,
  degradedBlockCount: 2,
),
```

断言 status 为 `Completed with warnings`，`canOpenOutput`、`canRetry`、`canResume` 均为 true，`isActive` 为 false。

在 `test/translation_dashboard_controller_test.dart` 复用现有 fake repository，令 `translateChapters` 返回警告 job，断言控制器原样保留状态、降级数和历史记录；再从历史调用 `retryJob('warning-job')`，断言会检查 EPUB 并继续翻译，而不是写入 “Only failed or cancelled” 日志。

- [ ] **步骤 2：编写失败的警告概览组件测试**

在 `test/translation_overview_test.dart` 构造中文警告任务：

```dart
const TranslationJob warningJob = TranslationJob(
  id: 'warning-job',
  inputPath: 'book.epub',
  outputPath: 'book_translated.epub',
  status: TranslationJobStatus.completedWithWarnings,
  phase: TranslationJobPhase.translation,
  progress: 1,
  completedBlocks: 12,
  totalBlocks: 12,
  degradedBlockCount: 2,
);
```

断言页面包含 `完成但有警告`、`2 个块未能完成翻译，可导出当前 EPUB 后重试。`、输出文件名以及打开/分享按钮，并能找到 `Icons.warning_amber_rounded`。

- [ ] **步骤 3：运行 UI/控制器测试确认失败**

```powershell
flutter test test/jobs_provider_test.dart test/translation_dashboard_controller_test.dart test/translation_overview_test.dart
```

预期：switch 未覆盖新状态、警告任务不可重试或缺少警告文案/图标。

- [ ] **步骤 4：实现状态映射和重试许可**

在 `jobs_provider.dart` 增加状态标签并将 retry 逻辑改为使用 job 的领域属性：

```dart
canRetry: job.canResumeTranslation,

TranslationJobStatus.completedWithWarnings => 'Completed with warnings',
```

在控制器的 `currentJobIsResumable` 和 `retryJob` 许可条件中加入 `completedWithWarnings`。将拒绝日志文案改为“Only failed, cancelled, or warning jobs can be retried.”及对应中文。处理 repository 结果时：

```dart
final TranslationJob terminalJob = _translationHistoryJob(
  result.job.copyWith(phase: TranslationJobPhase.translation),
);
final bool failedResult = terminalJob.status == TranslationJobStatus.failed;
state = state.copyWith(
  job: terminalJob,
  jobHistory: _jobHistoryWith(terminalJob),
  inspectedChapters: result.chapters,
  actionableError: failedResult
      ? ActionableErrorFactory.fromMessage(
          terminalJob.errorMessage ?? 'Translation failed.',
          isChinese: state.config.uiLanguage == UiLanguage.chinese,
          preferredKind: ActionableErrorKind.retryTranslation,
        )
      : null,
  logs: <String>[
    ...state.logs,
    if (failedResult)
      _s.logTranslationFailed(terminalJob.errorMessage ?? 'Translation failed.')
    else if (terminalJob.status ==
        TranslationJobStatus.completedWithWarnings)
      _s.logTranslationCompletedWithWarnings(terminalJob.degradedBlockCount)
    else if (PlatformUtils.isAndroid)
      _s.logTranslationCompleteAndroid
    else
      _s.logTranslationCompleteDesktop,
  ],
);
```

确保 all-degraded `failed` 结果不追加成功日志。

- [ ] **步骤 5：实现本地化和警告视觉**

在 `AppStrings.jobStatusLabel` 加入 `completedWithWarnings`。增加：

```dart
String degradedBlocksWarning(int count) => isChinese
    ? '$count 个块未能完成翻译，可导出当前 EPUB 后重试。'
    : '$count blocks could not be translated. You can export this EPUB and retry.';

String logTranslationCompletedWithWarnings(int count) => isChinese
    ? '翻译已完成，但有 $count 个块保留了回退内容。'
    : 'Translation completed with $count blocks retaining fallback content.';
```

在 `TranslationOverview` 中计算 `hasWarnings`，状态 pill 使用 `scheme.tertiaryContainer/onTertiaryContainer`，输出行图标在警告状态下使用 `Icons.warning_amber_rounded`，并在进度与输出区域之间渲染 `strings.degradedBlocksWarning(job!.degradedBlockCount)`。普通 completed 保持当前成功样式。

- [ ] **步骤 6：运行聚焦测试确认通过**

```powershell
dart format lib/features/translation/application/translation_dashboard_controller.dart lib/features/jobs/application/jobs_provider.dart lib/features/translation/presentation/widgets/translation_overview.dart lib/shared/localization/app_strings.dart test/translation_dashboard_controller_test.dart test/jobs_provider_test.dart test/translation_overview_test.dart
flutter test test/jobs_provider_test.dart test/translation_dashboard_controller_test.dart test/translation_overview_test.dart
```

预期：全部通过，0 个失败。

- [ ] **步骤 7：提交控制器和 UI 变更**

```powershell
git add -- lib/features/translation/application/translation_dashboard_controller.dart lib/features/jobs/application/jobs_provider.dart lib/features/translation/presentation/widgets/translation_overview.dart lib/shared/localization/app_strings.dart test/translation_dashboard_controller_test.dart test/jobs_provider_test.dart test/translation_overview_test.dart
git commit -m "feat: surface partial translation warnings"
```

### 任务 5：保护读取失败的安全密钥

**文件：**
- 修改：`lib/features/settings/infrastructure/settings_store.dart`
- 修改：`lib/features/settings/application/settings_controller.dart`
- 修改：`test/settings_store_test.dart`
- 修改：`test/settings_controller_test.dart`

- [ ] **步骤 1：增强 fake secret store 并编写失败测试**

在 `test/settings_store_test.dart` 的 fake 中增加每个 slot 的 write/delete 调用计数。增加读取失败后普通保存测试：

```dart
test('unrelated save preserves secrets whose reads failed', () async {
  final _FakeSettingsSecretStore secrets = _FakeSettingsSecretStore()
    ..apiKey = 'still-stored'
    ..deepSeekApiKey = 'deepseek-stored'
    ..customApiKey = 'custom-stored'
    ..failReads = true;
  final SettingsStore store = SettingsStore(
    settingsFileProvider: () async => settingsFile,
    secretStore: secrets,
  );

  final TranslationConfig loaded = await store.load();
  await store.save(
    loaded.copyWith(themeMode: AppThemeMode.dark),
    explicitSecretMutations: const <SettingsSecretSlot>{},
  );

  expect(secrets.secretMutationCount, 0);
  expect(secrets.apiKey, 'still-stored');
  expect(secrets.deepSeekApiKey, 'deepseek-stored');
  expect(secrets.customApiKey, 'custom-stored');
});
```

增加显式替换和清空测试，分别传入 active provider slot 与 legacy slot，断言调用 write 或 delete 并更新读取状态。

在 `test/settings_controller_test.dart` 增加：加载时 secret read 失败，调用 `setThemeMode` 不产生 secret mutation；调用 `setApiKey('replacement')` 只写 legacy slot 和当前 provider slot。

- [ ] **步骤 2：运行测试确认失败**

```powershell
flutter test test/settings_store_test.dart test/settings_controller_test.dart
```

预期：`SettingsSecretSlot` 和 `explicitSecretMutations` 未定义，或普通保存错误删除三个 key。

- [ ] **步骤 3：实现逐 slot 的读取三态**

在 `settings_store.dart` 定义：

```dart
enum SettingsSecretSlot { legacy, deepSeek, custom }

enum _SecretReadStatus { value, missing, readFailure }

class _SecretReadResult {
  const _SecretReadResult(this.status, this.value);

  final _SecretReadStatus status;
  final String? value;
}
```

`SettingsStore` 保存每个 slot 最近的状态：

```dart
final Map<SettingsSecretSlot, _SecretReadStatus> _secretReadStatuses =
    <SettingsSecretSlot, _SecretReadStatus>{};

Future<_SecretReadResult> _readSecret(
  SettingsSecretSlot slot,
  Future<String?> Function() read,
) async {
  try {
    final String? value = await read();
    final _SecretReadStatus status = value?.trim().isNotEmpty == true
        ? _SecretReadStatus.value
        : _SecretReadStatus.missing;
    _secretReadStatuses[slot] = status;
    return _SecretReadResult(status, value);
  } catch (_) {
    _secretReadStatuses[slot] = _SecretReadStatus.readFailure;
    return const _SecretReadResult(_SecretReadStatus.readFailure, null);
  }
}
```

`load()` 使用 result.value 进行现有配置解析，不再把异常和 missing 合并为同一内部状态。

- [ ] **步骤 4：实现选择性保存和显式 key 编辑**

修改 `save` 签名：

```dart
Future<void> save(
  TranslationConfig config, {
  Set<SettingsSecretSlot>? explicitSecretMutations,
}) async {
  final Set<SettingsSecretSlot> explicit =
      explicitSecretMutations ?? SettingsSecretSlot.values.toSet();
  await _saveSecret(
    SettingsSecretSlot.legacy,
    config.apiKey,
    explicit: explicit,
    write: _secretStore.writeApiKey,
    delete: _secretStore.deleteApiKey,
  );
  await _saveSecret(
    SettingsSecretSlot.deepSeek,
    config.deepseekApiKey,
    explicit: explicit,
    write: _secretStore.writeDeepSeekApiKey,
    delete: _secretStore.deleteDeepSeekApiKey,
  );
  await _saveSecret(
    SettingsSecretSlot.custom,
    config.customApiKey,
    explicit: explicit,
    write: _secretStore.writeCustomApiKey,
    delete: _secretStore.deleteCustomApiKey,
  );
  await _writeSettingsJson(config);
}
```

slot 保存规则实现为：

```dart
Future<void> _saveSecret(
  SettingsSecretSlot slot,
  String value, {
  required Set<SettingsSecretSlot> explicit,
  required Future<void> Function(String value) write,
  required Future<void> Function() delete,
}) async {
  if (_secretReadStatuses[slot] == _SecretReadStatus.readFailure &&
      !explicit.contains(slot)) {
    return;
  }
  final String trimmed = value.trim();
  if (trimmed.isEmpty) {
    await delete();
    _secretReadStatuses[slot] = _SecretReadStatus.missing;
  } else {
    await write(trimmed);
    _secretReadStatuses[slot] = _SecretReadStatus.value;
  }
}
```

在 `SettingsController` 让 `_persist`、`_update` 接受默认空集合；`setApiKey` 根据当前 provider 传入：

```dart
final Set<SettingsSecretSlot> slots = <SettingsSecretSlot>{
  SettingsSecretSlot.legacy,
  state.apiProviderSelection == ApiProviderSelection.deepseek
      ? SettingsSecretSlot.deepSeek
      : SettingsSecretSlot.custom,
};
```

普通设置和 provider preset 传空集合。直接调用 `SettingsStore.save(config)` 保持旧语义：调用者未提供集合时同步全部三个安全项，保证现有测试和迁移代码兼容。

- [ ] **步骤 5：验证 legacy 迁移不会在失败时误删**

增加测试：JSON 含 legacy plaintext key，目标 secure write 抛错时，`load()` 返回可用配置且 JSON 中仍保留该 plaintext key；写入成功后再保存无密钥 JSON。若当前 `TranslationConfig.toJson()` 会无条件移除 key，把 migration 写文件动作拆为“secure writes 全部成功后”执行，不在 catch 后覆盖原文件。

- [ ] **步骤 6：运行设置测试确认通过**

```powershell
dart format lib/features/settings/infrastructure/settings_store.dart lib/features/settings/application/settings_controller.dart test/settings_store_test.dart test/settings_controller_test.dart
flutter test test/settings_store_test.dart test/settings_controller_test.dart test/widget_test.dart
```

预期：全部通过；读取失败后的主题变更为 0 次 secret mutation，显式 key 编辑只修改指定 slots，legacy 迁移失败不丢明文回退。

- [ ] **步骤 7：提交安全存储修复**

```powershell
git add -- lib/features/settings/infrastructure/settings_store.dart lib/features/settings/application/settings_controller.dart test/settings_store_test.dart test/settings_controller_test.dart
git commit -m "fix: preserve unreadable secure settings"
```

### 任务 6：全量验证与回归检查

**文件：**
- 修改：仅修复本任务验证暴露的直接问题
- 测试：全部 `test/`

- [ ] **步骤 1：检查所有 enum switch 和状态判断**

运行：

```powershell
rg -n "TranslationJobStatus\.completed|TranslationJobStatus\.failed|switch \(.*status" lib test
```

逐项确认 `completedWithWarnings` 在导出、重试、活动状态、进度步骤、任务标签和历史恢复中语义正确；不要把警告任务当成 active。

- [ ] **步骤 2：运行格式与静态分析**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze lib test tool
```

预期：format exit code 0；analyze 没有新增 error 或 warning。若仓库基线仍有已知 info，记录数量并确认没有来自本次改动的诊断。

- [ ] **步骤 3：运行完整测试套件**

```powershell
flutter test
```

预期：所有非 live 测试通过；需要外部 API/本地图书的 live 测试仅按原有 guard 跳过，0 个失败。

- [ ] **步骤 4：检查隐私和改动范围**

```powershell
rg -n "_p13_failure_diag|RAW=|SOURCE=|Authorization: Bearer|api_key=" lib
git diff 045a4c2...HEAD --check
git status --short
git log --oneline 045a4c2..HEAD
```

预期：翻译器中没有固定诊断路径或原文/响应 payload；diff check 无错误；工作区干净；提交只覆盖本计划文件和列出的实现/测试文件。

- [ ] **步骤 5：提交验证过程中必要的小修复**

仅当步骤 1-4 暴露直接回归时执行：

```powershell
git add -- lib test tool
git commit -m "fix: complete warning state integration"
```

若无需修复，不创建空提交。

- [ ] **步骤 6：请求代码审查并处理反馈**

使用 `requesting-code-review` 技能检查规格符合性、错误处理、测试覆盖、隐私和安全存储语义。若审查提出技术问题，使用 `receiving-code-review` 验证后逐项修复，并重新运行步骤 2-4。

- [ ] **步骤 7：进入分支收尾**

使用 `verification-before-completion` 再次确认新鲜验证输出，然后调用 `finishing-a-development-branch`，向用户提供合并回 `main`、保留分支或清理 worktree 的选择。
