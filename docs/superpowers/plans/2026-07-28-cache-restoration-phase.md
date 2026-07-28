# 续传缓存恢复阶段实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为续传任务增加独立、可观察且零 API 调用的缓存恢复阶段，立即展示历史断点，并在完整校验缓存后才开始新的翻译请求。

**架构：** 控制器负责保留历史任务的待校验断点提示；新的 `CacheRestorationScanner` 在仓库层一次性扫描全部块缓存并返回内存命中表；`EpubChapterTranslator` 必须消费扫描结果且只能在扫描完成后进入现有 API 翻译流程。任务模型增加恢复阶段与扫描计数，使 UI 不再通过章节文案猜测状态。

**技术栈：** Flutter、Dart、Riverpod、Dio、`flutter_test`、现有 JSON 任务历史与文件块缓存。

---

## 文件结构

- 创建 `lib/features/translation/infrastructure/cache_restoration_scanner.dart`：只负责读取和校验块缓存，不依赖 Dio 或翻译 API。
- 创建 `test/cache_restoration_scanner_test.dart`：覆盖完整扫描、不可读缓存和取消行为。
- 修改 `lib/features/translation/domain/models/translation_job.dart`：增加恢复阶段与扫描字段，并保持旧 JSON 兼容。
- 修改 `lib/features/translation/application/translation_dashboard_controller.dart`：保留一次性断点提示，创建恢复阶段任务并正确切换状态。
- 修改 `lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`：在任何 API 请求之前执行完整预扫描，并让正文/脚注共用命中结果。
- 修改 `lib/shared/localization/app_strings.dart`：增加中英文缓存恢复日志和状态文案。
- 修改 `lib/features/translation/presentation/widgets/translation_overview.dart`：展示待校验断点、扫描进度和实际复用数量。
- 修改 `lib/features/translation/presentation/widgets/translation_workflow_steps.dart`：将恢复阶段显示在检查和翻译之间。
- 修改 `test/translation_job_test.dart`：覆盖新增字段序列化和旧历史兼容。
- 修改 `test/translation_dashboard_controller_test.dart`：覆盖点击续传后立即显示旧断点及阶段切换。
- 修改 `test/repository_safety_test.dart`：覆盖 API 顺序、部分/全部缓存、取消和脚注缓存复用。
- 修改 `test/translation_overview_test.dart`：覆盖恢复阶段 UI。

### 任务 1：扩展任务阶段和可序列化恢复状态

**文件：**
- 修改：`lib/features/translation/domain/models/translation_job.dart`
- 测试：`test/translation_job_test.dart`

- [ ] **步骤 1：编写失败的模型测试**

在 `test/translation_job_test.dart` 增加：

```dart
test('round-trips cache restoration progress', () {
  const TranslationJob job = TranslationJob(
    id: 'resume-1',
    inputPath: 'book.epub',
    outputPath: 'out.epub',
    status: TranslationJobStatus.running,
    phase: TranslationJobPhase.cacheRestoration,
    progress: 0.37,
    completedBlocks: 605,
    totalBlocks: 1643,
    resumeCheckpointBlocks: 605,
    cacheScanScannedBlocks: 820,
    cacheScanTotalBlocks: 1643,
    cachedBlocks: 354,
    resumedBlocks: 354,
  );

  final TranslationJob restored = TranslationJob.fromJson(job.toJson());
  expect(restored.phase, TranslationJobPhase.cacheRestoration);
  expect(restored.resumeCheckpointBlocks, 605);
  expect(restored.cacheScanScannedBlocks, 820);
  expect(restored.cacheScanTotalBlocks, 1643);
});

test('legacy jobs default cache restoration counters to zero', () {
  final TranslationJob restored = TranslationJob.fromJson(<String, dynamic>{
    'id': 'legacy',
    'status': 'failed',
    'phase': 'translation',
    'progress': 0.37,
    'completedBlocks': 605,
    'totalBlocks': 1643,
  });
  expect(restored.resumeCheckpointBlocks, 0);
  expect(restored.cacheScanScannedBlocks, 0);
  expect(restored.cacheScanTotalBlocks, 0);
});
```

- [ ] **步骤 2：运行测试并确认红灯**

运行：`flutter test test/translation_job_test.dart`

预期：编译失败，提示 `cacheRestoration` 和三个恢复字段不存在。

- [ ] **步骤 3：实现最小模型变更**

将阶段定义改为：

```dart
enum TranslationJobPhase { inspection, cacheRestoration, translation }
```

在构造函数、字段、`fromJson`、`copyWith` 和 `toJson` 中一致增加：

```dart
this.resumeCheckpointBlocks = 0,
this.cacheScanScannedBlocks = 0,
this.cacheScanTotalBlocks = 0,
```

反序列化统一使用现有 `_readNonNegativeInt`，保证旧记录默认归零。

- [ ] **步骤 4：运行模型测试并确认绿灯**

运行：`flutter test test/translation_job_test.dart`

预期：全部通过。

- [ ] **步骤 5：提交模型变更**

```powershell
git add lib/features/translation/domain/models/translation_job.dart test/translation_job_test.dart
git commit -m "feat: 增加缓存恢复任务阶段"
```

### 任务 2：实现无 API 依赖的缓存预扫描器

**文件：**
- 创建：`lib/features/translation/infrastructure/cache_restoration_scanner.dart`
- 创建：`test/cache_restoration_scanner_test.dart`

- [ ] **步骤 1：编写失败的扫描器测试**

测试使用内存读取函数，不 mock Dio：

```dart
test('scans every block and returns cached translations by chapter and id', () async {
  final List<String> requestedKeys = <String>[];
  final CacheRestorationScanner scanner = CacheRestorationScanner(
    readTranslation: (String key) async {
      requestedKeys.add(key);
      return key == 'c1:p1' ? '<p>译文</p>' : null;
    },
  );
  final List<CacheRestorationProgress> events = <CacheRestorationProgress>[];

  final CacheRestorationResult result = await scanner.scan(
    chapters: <InspectedChapter>[_chapterWithTwoBlocks()],
    cacheKeyFor: (chapter, block) => '${chapter.path}:${block.id}',
    onProgress: events.add,
    throwIfCancelled: () {},
  );

  expect(requestedKeys, <String>['c1:p1', 'c1:p2']);
  expect(result.scannedBlocks, 2);
  expect(result.cachedBlocks, 1);
  expect(result.translationFor('c1', 'p1'), '<p>译文</p>');
  expect(events.last.scannedBlocks, 2);
});

test('treats empty and unreadable cache files as misses', () async {
  int reads = 0;
  final CacheRestorationResult result = await CacheRestorationScanner(
    readTranslation: (_) async {
      reads += 1;
      if (reads == 1) throw const FileSystemException('broken cache');
      return '   ';
    },
  ).scan(
    chapters: <InspectedChapter>[_chapterWithTwoBlocks()],
    cacheKeyFor: (chapter, block) => '${chapter.path}:${block.id}',
    throwIfCancelled: () {},
  );
  expect(result.cachedBlocks, 0);
  expect(result.unreadableBlocks, 1);
});
```

另加取消测试：第二次 `throwIfCancelled` 抛出 `TranslationCancelledException` 后，读取次数必须小于总块数。

- [ ] **步骤 2：运行扫描器测试并确认红灯**

运行：`flutter test test/cache_restoration_scanner_test.dart`

预期：编译失败，扫描器类型尚不存在。

- [ ] **步骤 3：实现扫描器和结果类型**

核心接口固定为：

```dart
typedef CacheTranslationReader = Future<String?> Function(String cacheKey);
typedef CacheKeyResolver = String Function(
  InspectedChapter chapter,
  ExtractedBlock block,
);

class CacheRestorationProgress {
  const CacheRestorationProgress({
    required this.scannedBlocks,
    required this.totalBlocks,
    required this.cachedBlocks,
    required this.unreadableBlocks,
  });
  final int scannedBlocks;
  final int totalBlocks;
  final int cachedBlocks;
  final int unreadableBlocks;
}

class CacheRestorationResult {
  const CacheRestorationResult({
    required this.translationsByChapter,
    required this.scannedBlocks,
    required this.cachedBlocks,
    required this.unreadableBlocks,
  });
  final Map<String, Map<String, String>> translationsByChapter;
  final int scannedBlocks;
  final int cachedBlocks;
  final int unreadableBlocks;

  String? translationFor(String chapterPath, String blockId) =>
      translationsByChapter[chapterPath]?[blockId];
}
```

`scan` 对每个块先调用 `throwIfCancelled`，再读取缓存；只保存非空字符串；捕获单个文件读取异常并累计 `unreadableBlocks`。每 20 块或扫描完成时发送一次进度，避免大量 UI 重建。

- [ ] **步骤 4：运行扫描器测试并确认绿灯**

运行：`flutter test test/cache_restoration_scanner_test.dart`

预期：全部通过。

- [ ] **步骤 5：提交扫描器变更**

```powershell
git add lib/features/translation/infrastructure/cache_restoration_scanner.dart test/cache_restoration_scanner_test.dart
git commit -m "feat: 增加块缓存预扫描器"
```

### 任务 3：将预扫描置于所有 API 请求之前

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`
- 修改：`lib/features/translation/infrastructure/translation_cache_store.dart`
- 测试：`test/repository_safety_test.dart`

- [ ] **步骤 1：编写 API 顺序和缓存复用失败测试**

在 `test/repository_safety_test.dart` 增加一个带事件记录的翻译运行：

```dart
test('finishes cache restoration before the first API request', () async {
  final List<String> events = <String>[];
  final _RecordingCacheStore cache = _RecordingCacheStore(
    onRead: (key) => events.add('cache:$key'),
  );
  final _RecordingApiClient api = _RecordingApiClient(
    onRequest: () => events.add('api'),
  );

  await _runTwoBlockBook(cacheStore: cache, apiClient: api);

  final int firstApi = events.indexOf('api');
  expect(firstApi, greaterThanOrEqualTo(2));
  expect(events.take(firstApi), everyElement(startsWith('cache:')));
});
```

再增加：

- 部分命中时只请求未命中块，正文缓存与脚注缓存均来自预扫描结果；
- 全部命中时块翻译、脚注翻译和书籍记忆请求总数均为零；
- 扫描中取消时请求总数为零，原 `JobResumeState.completedBlocks` 不被改成零；
- 不可读缓存按 miss 重新翻译且整书不失败。

- [ ] **步骤 2：运行定向测试并确认红灯**

运行：`flutter test test/repository_safety_test.dart --plain-name "finishes cache restoration before the first API request"`

预期：失败，因为现有实现逐章交错缓存读取与 API 请求。

- [ ] **步骤 3：注入并执行预扫描器**

在 `EpubChapterTranslator` 构造函数增加可选 `CacheRestorationScanner`，默认使用 `_cacheStore.getBlockTranslation`。计算 `jobKey` 并加载 `previousState` 后：

```dart
final int checkpointBlocks = min(
  previousState?.completedBlocks ?? 0,
  totalBlocks,
);
currentJob = currentJob.copyWith(
  status: TranslationJobStatus.running,
  phase: TranslationJobPhase.cacheRestoration,
  progress: totalBlocks == 0 ? 0 : checkpointBlocks / totalBlocks,
  completedBlocks: checkpointBlocks,
  resumeCheckpointBlocks: checkpointBlocks,
  cacheScanScannedBlocks: 0,
  cacheScanTotalBlocks: totalBlocks,
  currentChapter: 'Restoring cached translations',
);
```

调用扫描器时，缓存键必须继续使用现有 `_blockCacheKey(config, block, chapterPath, confirmedStyleProfile)`。进度回调更新扫描字段与实际 `cachedBlocks`，但在扫描完成前不调用 `ensureInitialBookMemory`、`_translateBlockBatch` 或 `_translateFootnoteBatch`。

- [ ] **步骤 4：让正文和脚注消费预扫描结果**

把各章节循环中的磁盘调用：

```dart
await _cacheStore.getBlockTranslation(cacheKey)
```

替换为：

```dart
restoration.translationFor(chapter.path, block.id)
```

扫描结束后统一设置：

```dart
completedBlocks = restoration.cachedBlocks;
cachedBlocks = restoration.cachedBlocks;
resumedBlocks = previousState == null ? 0 : restoration.cachedBlocks;
```

若 `cachedBlocks == totalBlocks`，跳过所有 API/书籍记忆逻辑并直接重打包；否则切换 `phase` 为 `translation`，文案为“继续翻译”。

- [ ] **步骤 5：保护持久化断点不回退**

删除加载 `previousState` 后立即用零进度强制保存的路径。扫描完成前取消或异常时，若旧状态存在则保留旧状态；扫描完成后才保存实际命中数。为单个缓存读取增加安全方法或在扫描器内捕获异常，不改变已有块缓存文件格式。

- [ ] **步骤 6：运行仓库定向测试并确认绿灯**

运行：

```powershell
flutter test test/repository_safety_test.dart --plain-name "cache restoration"
flutter test test/cache_restoration_scanner_test.dart
```

预期：全部通过，记录的首个 API 事件位于全部缓存读取事件之后。

- [ ] **步骤 7：提交仓库集成**

```powershell
git add lib/features/translation/infrastructure/cache_restoration_scanner.dart lib/features/translation/infrastructure/epub/epub_chapter_translator.dart lib/features/translation/infrastructure/translation_cache_store.dart test/repository_safety_test.dart
git commit -m "feat: 翻译前完整恢复块缓存"
```

### 任务 4：控制器立即展示历史断点并正确切换阶段

**文件：**
- 修改：`lib/features/translation/application/translation_dashboard_controller.dart`
- 测试：`test/translation_dashboard_controller_test.dart`

- [ ] **步骤 1：编写失败的续传控制器测试**

使用阻塞仓库捕获翻译调用开始时的状态：

```dart
test('retry immediately exposes checkpoint as cache restoration progress', () async {
  final _BlockingResumeRepository repository = _BlockingResumeRepository();
  final TranslationDashboardController controller =
      TranslationDashboardController(
        repository: repository,
        historyStore: _MemoryJobHistoryStore(initial: <TranslationJob>[
          const TranslationJob(
            id: 'failed-605',
            inputPath: r'C:\Books\book.epub',
            outputPath: r'C:\Books',
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.translation,
            progress: 605 / 1643,
            completedBlocks: 605,
            totalBlocks: 1643,
          ),
        ]),
      );
  await Future<void>.delayed(Duration.zero);

  final Future<void> retry = controller.retryJob('failed-605');
  await repository.translationStarted.future;

  expect(controller.state.job?.phase, TranslationJobPhase.cacheRestoration);
  expect(controller.state.job?.completedBlocks, 605);
  expect(controller.state.job?.resumeCheckpointBlocks, 605);
  expect(controller.state.job?.progress, closeTo(605 / 1643, 0.0001));
  repository.complete();
  await retry;
});
```

另加测试：普通首次翻译恢复提示为零；收到仓库实际命中 598 的回调后界面更新为 598；进入翻译回调后清除一次性提示。

- [ ] **步骤 2：运行控制器测试并确认红灯**

运行：`flutter test test/translation_dashboard_controller_test.dart --plain-name "retry immediately exposes checkpoint"`

预期：失败，当前 `startTranslation` 把进度重置为零且阶段直接是 `translation`。

- [ ] **步骤 3：实现一次性 `ResumeProgressHint`**

在控制器文件内增加私有不可变类型：

```dart
class _ResumeProgressHint {
  const _ResumeProgressHint({
    required this.completedBlocks,
    required this.totalBlocks,
  });
  final int completedBlocks;
  final int totalBlocks;
}
```

`retryJob` 在清空当前任务前从历史任务建立提示。`startTranslation` 创建 `queuedJob` 时，如果提示总数与本次检查后的 `selectedBlocks` 相同，则设置 `phase=cacheRestoration`、待校验完成数和对应进度；不相同则从零恢复扫描。首次收到 `translation` 或终止状态回调后清除提示。

- [ ] **步骤 4：运行控制器测试并确认绿灯**

运行：`flutter test test/translation_dashboard_controller_test.dart`

预期：全部通过。

- [ ] **步骤 5：提交控制器变更**

```powershell
git add lib/features/translation/application/translation_dashboard_controller.dart test/translation_dashboard_controller_test.dart
git commit -m "fix: 续传时立即显示待校验断点"
```

### 任务 5：增加恢复阶段 UI 和准确日志

**文件：**
- 修改：`lib/shared/localization/app_strings.dart`
- 修改：`lib/features/translation/presentation/widgets/translation_overview.dart`
- 修改：`lib/features/translation/presentation/widgets/translation_workflow_steps.dart`
- 修改：`test/translation_overview_test.dart`

- [ ] **步骤 1：编写失败的组件测试**

```dart
testWidgets('shows checkpoint scan and verified cache during restoration', (
  WidgetTester tester,
) async {
  await tester.pumpWidget(_appWithJob(const TranslationJob(
    id: 'resume',
    inputPath: 'book.epub',
    outputPath: 'out.epub',
    status: TranslationJobStatus.running,
    phase: TranslationJobPhase.cacheRestoration,
    progress: 605 / 1643,
    completedBlocks: 605,
    totalBlocks: 1643,
    resumeCheckpointBlocks: 605,
    cacheScanScannedBlocks: 820,
    cacheScanTotalBlocks: 1643,
    cachedBlocks: 354,
    resumedBlocks: 354,
  )));

  expect(find.textContaining('正在恢复缓存'), findsOneWidget);
  expect(find.textContaining('605/1643'), findsOneWidget);
  expect(find.textContaining('820/1643'), findsOneWidget);
  expect(find.textContaining('354'), findsWidgets);
  expect(find.textContaining('继续翻译'), findsNothing);
});
```

另加翻译阶段测试，确认扫描完成后才显示“继续翻译”。

- [ ] **步骤 2：运行组件测试并确认红灯**

运行：`flutter test test/translation_overview_test.dart`

预期：失败，恢复阶段和对应文案尚不存在。

- [ ] **步骤 3：实现本地化文案和展示**

在 `AppStrings` 增加中英文方法：

```dart
String restoringCache(int checkpoint, int total) => isChinese
    ? '正在恢复缓存 · 待校验 $checkpoint/$total'
    : 'Restoring cache · checkpoint $checkpoint/$total';

String cacheScanProgress(int scanned, int total, int verified) => isChinese
    ? '缓存扫描：$scanned/$total · 已确认复用：$verified 块'
    : 'Cache scan: $scanned/$total · verified: $verified blocks';

String cacheRestoredNoApi(int reused) => isChinese
    ? '已复用 $reused 块；缓存恢复阶段未产生 API 请求。'
    : 'Reused $reused blocks; cache restoration made no API requests.';
```

另加断点与实际命中不一致、全部命中零 API、无兼容断点和继续翻译文案。`TranslationOverview` 仅在 `cacheRestoration` 阶段展示三类数字；`translation` 阶段沿用正常翻译进度。工作流步骤将恢复阶段映射为独立活动标签，不通过 `currentChapter` 字符串判断。

- [ ] **步骤 4：运行组件测试并确认绿灯**

运行：`flutter test test/translation_overview_test.dart`

预期：全部通过。

- [ ] **步骤 5：提交 UI 变更**

```powershell
git add lib/shared/localization/app_strings.dart lib/features/translation/presentation/widgets/translation_overview.dart lib/features/translation/presentation/widgets/translation_workflow_steps.dart test/translation_overview_test.dart
git commit -m "feat: 展示缓存恢复进度"
```

### 任务 6：回归验证、真实断点验收与 Windows 构建

**文件：**
- 必要时修改：上述测试发现问题所对应的最小文件
- 不创建临时密钥、EPUB 解包内容或构建产物的 Git 跟踪文件

- [ ] **步骤 1：运行全部定向测试**

```powershell
flutter test test/translation_job_test.dart test/cache_restoration_scanner_test.dart test/translation_dashboard_controller_test.dart test/translation_overview_test.dart test/repository_safety_test.dart
```

预期：全部通过，无未处理异常。

- [ ] **步骤 2：运行完整测试和静态分析**

```powershell
flutter test
flutter analyze lib test
```

预期：测试零失败；静态分析显示 `No issues found!`。

- [ ] **步骤 3：验证红绿回归测试有效**

临时回退“排队任务保留断点”这一处生产修改，运行 `retry immediately exposes checkpoint` 测试并确认失败；恢复修改后重新运行并确认通过。不得提交临时回退。

- [ ] **步骤 4：在活动翻译结束后执行真实续传验收**

使用现有 Communion EPUB 和已保存任务状态：

1. 启动新构建，打开失败/取消任务并点击继续；
2. 首屏确认显示历史断点而非 0%；
3. 观察扫描计数递增，阶段保持“正在恢复缓存”；
4. 检查日志出现“缓存恢复阶段未产生 API 请求”；
5. 确认扫描完成前服务端请求计数不增加，完成后才继续翻译未命中块。

验收不得打印或提交 API 密钥。

- [ ] **步骤 5：构建 Windows Release**

确认没有正在运行的旧版进程锁定构建目录后运行：

```powershell
flutter build windows --release
```

预期：退出码 0，产物位于 `build/windows/x64/runner/Release/epub_translator_flutter_clean.exe`。

- [ ] **步骤 6：检查工作区和敏感信息**

```powershell
git diff --check
git status --short
rg -n "sk-[A-Za-z0-9_-]{16,}" --glob "!build/**" --glob "!.git/**"
```

预期：无空白错误；只存在计划内文件；源码和文档中没有真实密钥。

- [ ] **步骤 7：提交最终修正**

仅当验证过程中产生必要修正时执行：

```powershell
git add <验证修正涉及的精确文件>
git commit -m "test: 完善缓存恢复回归验证"
```

若没有额外修正，不创建空提交。
