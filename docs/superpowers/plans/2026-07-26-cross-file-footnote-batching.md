# 跨文件脚注合批翻译实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将连续独立脚注 XHTML 的未缓存块合并为少量 API 请求，同时保持逐文件回写、逐块缓存、链接完整性和可续传能力。

**架构：** 新增纯 Dart 脚注批次规划器，负责候选识别、跨文件唯一请求 ID 和按字符预算分组。EpubChapterTranslator 在主章节循环中识别连续脚注区间，使用新规划器翻译未命中块，再按 chapterPath + block.id 写回原章节。正文继续使用既有章节内批处理、上下文和书籍记忆，块缓存键不变。

**技术栈：** Flutter、Dart、Dio、现有 EPUB 解析/打包器、flutter_test、本地 HttpServer 假 API。

---

## 文件结构

- 创建：`lib/features/translation/infrastructure/epub/footnote_batch_planner.dart`：识别独立脚注章节，创建跨文件块引用和微批次；不执行 API 或文件写入。
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`：在主循环处理连续脚注区间，调用 API、逐块缓存并按原章节回填。
- 创建：`test/footnote_batch_planner_test.dart`：验证候选识别、重复 p-1 的请求 ID、预算和隔离。
- 修改：`test/epub_repository_performance_test.dart`：假 API 验证请求数、逐文件回写和缓存复用。
- 修改：`test/repository_safety_test.dart`：验证响应 ID 映射、缺失/重复 ID 和缓存键兼容。
- 创建：`work/live_communion_footnote_batch_test.dart`：受环境变量保护的真实 API 验收脚本；该文件被 Git 忽略。

## 任务 1：建立脚注批次规划器

**文件：**
- 创建：`test/footnote_batch_planner_test.dart`
- 创建：`lib/features/translation/infrastructure/epub/footnote_batch_planner.dart`

- [ ] **步骤 1：编写失败的规划器测试**

```dart
test('groups contiguous standalone footnotes with duplicate block ids', () {
  final chapters = <InspectedChapter>[
    _chapter('Chapter_11.xhtml', 'Chapter 11', '<p>Body.</p>'),
    _footnote('978_Chapter_11_1-fn.xhtml', '<p id="p-1">One.</p>'),
    _footnote('978_Chapter_11_2-fn.xhtml', '<p id="p-1">Two.</p>'),
    _footnote('978_Chapter_11_3-fn.xhtml', '<p id="p-1">Three.</p>'),
  ];
  final batches = const FootnoteBatchPlanner().plan(
    chapters: chapters,
    startIndex: 1,
    pendingByPath: <String, List<ExtractedBlock>>{
      for (final item in chapters.skip(1)) item.path: item.blocks,
    },
    chunkSize: 1000,
  );
  expect(batches, hasLength(1));
  expect(
    batches.single.refs.map((ref) => ref.requestId),
    <String>['f1:p-1', 'f2:p-1', 'f3:p-1'],
  );
});
```

再添加测试：13 个单块脚注必须拆为 12 条和 1 条两个批次；普通章节必须终止脚注区间。

- [ ] **步骤 2：运行测试，确认正确失败**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\footnote_batch_planner_test.dart
```

预期：编译失败，提示 FootnoteBatchPlanner、FootnoteBatch 和 FootnoteBlockRef 未定义。

- [ ] **步骤 3：实现最小规划器和值对象**

```dart
class FootnoteBlockRef {
  const FootnoteBlockRef({
    required this.requestId,
    required this.chapterIndex,
    required this.chapterPath,
    required this.chapterTitle,
    required this.block,
  });
  final String requestId;
  final int chapterIndex;
  final String chapterPath;
  final String chapterTitle;
  final ExtractedBlock block;
}

class FootnoteBatch {
  const FootnoteBatch(this.refs);
  final List<FootnoteBlockRef> refs;
}

class FootnoteBatchPlanner {
  const FootnoteBatchPlanner({this.maxRefsPerBatch = 12});
  final int maxRefsPerBatch;

  bool isStandaloneFootnote(InspectedChapter chapter) {
    final path = chapter.path.toLowerCase();
    final token = path + ' ' + chapter.title.toLowerCase();
    return chapter.blocks.isNotEmpty &&
        (RegExp(r'(^|[-_])fn\.xhtml$').hasMatch(path) ||
            token.contains('footnote') || token.contains('endnote'));
  }
}
```

在 plan 内部仅扫描从 startIndex 开始连续的 isStandaloneFootnote 章节。使用 TranslationBatchPlanner.blockBudgetFor 的预算；达到 chunkSize 或 maxRefsPerBatch 时切批。每个引用使用 f<chapterIndex>:<block.id>。

- [ ] **步骤 4：运行规划器测试确认通过**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\footnote_batch_planner_test.dart
```

预期：候选识别、预算、12 条上限、普通章节隔离和重复 p-1 的唯一请求 ID 全部通过。

- [ ] **步骤 5：提交规划器**

```powershell
git add lib/features/translation/infrastructure/epub/footnote_batch_planner.dart test/footnote_batch_planner_test.dart
git commit -m "feat: plan cross-file footnote batches"
```

## 任务 2：让 API 响应支持跨文件唯一 ID

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:1812-1948`
- 修改：`test/repository_safety_test.dart`

- [ ] **步骤 1：编写失败的映射测试**

```dart
test('cross-file batch maps duplicate p-1 responses to their owners', () async {
  final adapter = _RecordingBatchAdapter(
    responseBlocks: <Map<String, String>>[
      <String, String>{'id': 'f3:p-1', 'html': '<p>第二条</p>'},
      <String, String>{'id': 'f2:p-1', 'html': '<p>第一条</p>'},
    ],
  );
  final translated = await translator.translateFootnoteBatchForTest(
    dio: _dioFor(adapter),
    refs: <FootnoteBlockRef>[firstRef, secondRef],
    config: config,
  );
  expect(translated['f2:p-1'], '<p>第一条</p>');
  expect(translated['f3:p-1'], '<p>第二条</p>');
});
```

在同一测试文件中扩展既有 `_RecordingBatchAdapter`，令其构造函数接收 `responseBlocks`，并在响应 JSON 中原样返回该列表；新增 `_dioFor(HttpClientAdapter adapter)`，返回使用该 adapter 的 `Dio`。再添加缺失 ID、重复 ID 和未知 ID 三个伪响应，均断言抛出 FormatException。

- [ ] **步骤 2：运行测试，确认入口不存在**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\repository_safety_test.dart
```

预期：编译失败，提示 translateFootnoteBatchForTest 未定义。

- [ ] **步骤 3：提取带显式请求 ID 的内部翻译方法**

```dart
class _IdentifiedHtmlBlock {
  const _IdentifiedHtmlBlock({
    required this.requestId,
    required this.block,
  });
  final String requestId;
  final ExtractedBlock block;
}

Future<Map<String, String>> _translateIdentifiedHtmlBatch({
  required Dio dio,
  required TranslationConfig config,
  required List<_IdentifiedHtmlBlock> blocks,
  required TranslationBatchContext context,
  CancelToken? cancelToken,
}) async {
  // payload blocks[].id 使用 requestId。
  // 先验证响应数量、未知 ID 和重复 ID。
  // 对每条 html 用原 block 锁定结构并执行质量校验。
}
```

现有 _translateBlockBatch 以原块 ID 调用此方法，正文请求协议不变。新的 _translateFootnoteBatch 使用 FootnoteBlockRef.requestId。

- [ ] **步骤 4：运行安全测试确认通过**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\repository_safety_test.dart
```

预期：乱序响应正确映射；缺失、重复、未知 ID 被拒绝；既有批次重试测试继续通过。

- [ ] **步骤 5：提交请求 ID 映射**

```powershell
git add lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/repository_safety_test.dart
git commit -m "feat: map cross-file footnote batch responses safely"
```

## 任务 3：调度连续脚注区间并逐文件回填

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:760-1120`
- 修改：`test/epub_repository_performance_test.dart`

- [ ] **步骤 1：编写失败的仓库性能测试**

```dart
test('translates three one-block footnote files in one API request', () async {
  final requestIds = <List<String>>[];
  final server = await _startFakeTranslationServer(requestIds);
  final epub = await _writeTestEpub(
    chapters: <String, String>{
      'OPS/Text/chapter.xhtml': '<p>Main text.</p>',
      'OPS/Text/chapter_1-fn.xhtml':
          '<aside epub:type="footnote"><p>One.</p></aside>',
      'OPS/Text/chapter_2-fn.xhtml':
          '<aside epub:type="footnote"><p>Two.</p></aside>',
      'OPS/Text/chapter_3-fn.xhtml':
          '<aside epub:type="footnote"><p>Three.</p></aside>',
    },
  );
  final run = await repository.translateChapters(
    inputPath: epub.path,
    outputDirectory: temp.path,
    config: config,
    chapters: inspection.chapters,
  );
  expect(run.job.status, TranslationJobStatus.completed);
  expect(requestIds.where((ids) => ids.length == 3), hasLength(1));
  expect(await _readXhtml(run.job.outputPath, 'OPS/Text/chapter_1-fn.xhtml'),
      contains('Translated'));
});
```

再断言另两个脚注 XHTML 各自有译文，且原始 footnote id 与 href 仍在。

- [ ] **步骤 2：运行测试，确认当前逻辑逐条请求**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\epub_repository_performance_test.dart
```

预期：新测试失败，因为记录到 3 个单块脚注请求，而非 1 个三块请求。

- [ ] **步骤 3：实现连续脚注区间处理器**

```dart
Future<_FootnoteRunResult> _translateFootnoteRun({
  required int startIndex,
  required List<InspectedChapter> selectedChapters,
  required Map<String, _ChapterTranslationState> statesByPath,
  required TranslationConfig config,
  required TranslationStyleProfile? userStyleProfile,
  required _BookMemory? bookMemory,
  required Dio dio,
  required CancelToken cancelToken,
}) async {
  // 读取脚注区间每块缓存，创建 FootnoteBatch。
  // 翻译未命中块，按原 chapterPath 计算 _blockCacheKey 并写入缓存。
  // 将 requestId 映射回状态中的原 block.id。
}

class _ChapterTranslationState {
  _ChapterTranslationState(this.chapter);
  final InspectedChapter chapter;
  final Map<String, ExtractedBlock> translatedById =
      <String, ExtractedBlock>{};
  int cacheHits = 0;
}

class _FootnoteRunResult {
  const _FootnoteRunResult({
    required this.lastChapterIndex,
    required this.completedBlocksDelta,
    required this.completedFilesDelta,
  });
  final int lastChapterIndex;
  final int completedBlocksDelta;
  final int completedFilesDelta;
}
```

在章节循环起点加入：

```dart
if (_footnoteBatchPlanner.isStandaloneFootnote(chapter)) {
  final run = await _translateFootnoteRun(
    startIndex: chapterIndex,
    selectedChapters: selectedChapters,
    statesByPath: statesByPath,
    config: config,
    userStyleProfile: userStyleProfile,
    bookMemory: bookMemory,
    dio: dio,
    cancelToken: cancelToken,
  );
  chapterIndex = run.lastChapterIndex;
  continue;
}
```

必须保持：每个脚注文件在所有块完成后才增加 completedFiles；completedBlocks 按原块数增长；updatedByPath 保留原路径；脚注区间不更新书籍记忆；缓存读取、每个 API 窗口和每次写回之间均检查取消状态。

- [ ] **步骤 4：运行性能测试确认通过并验证第二次运行零请求**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\epub_repository_performance_test.dart
```

预期：3 条脚注仅产生 1 个请求；第二次相同配置运行不产生 blocks 请求；三个 XHTML 均保留原 id 与 href。

- [ ] **步骤 5：提交调度器接入**

```powershell
git add lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/epub_repository_performance_test.dart
git commit -m "feat: batch contiguous footnote files"
```

## 任务 4：验证降级、续传和缓存兼容性

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:1928-1975`
- 修改：`test/epub_repository_performance_test.dart`
- 修改：`test/repository_safety_test.dart`

- [ ] **步骤 1：编写失败的 413 降级与续传测试**

```dart
test('falls back to individual footnotes after a 413 batch response', () async {
  final server = _FootnoteServer(respond413WhenBlockCountExceeds: 1);
  final run = await repository.translateChapters(
    inputPath: epub.path,
    outputDirectory: temp.path,
    config: config,
    chapters: inspection.chapters,
  );
  expect(run.job.status, TranslationJobStatus.completed);
  expect(server.requestBlockCounts, <int>[3, 1, 1, 1]);
});
```

再添加取消测试：第一个微批写入后请求取消；第二次运行只请求未缓存脚注块。

测试文件中定义 `_FootnoteServer`：它绑定 loopback 端口、解码最后一条 user message 的 JSON，向 `requestBlockCounts` 追加 `payload['blocks'].length`；当长度大于 `respond413WhenBlockCountExceeds` 时返回 HTTP 413，否则逐个回显 `{id, html}` 译文。

- [ ] **步骤 2：运行测试，确认降级与续传尚未满足**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\epub_repository_performance_test.dart test\repository_safety_test.dart
```

预期：413 或取消续传测试失败，因为跨文件批次尚未逐条降级与保存。

- [ ] **步骤 3：实现受限的批次降级**

```dart
Future<Map<String, String>> _translateFootnoteBatchWithFallback(
  FootnoteBatch batch,
) async {
  try {
    return await _translateFootnoteBatch(batch);
  } on DioException catch (error) {
    if (!TranslationApiClient.shouldFallbackBatchDioException(error)) rethrow;
    final translated = <String, String>{};
    for (final window in _windows(batch.refs, config.maxConcurrent)) {
      final entries = await Future.wait(window.map(_translateOneFootnoteRef));
      translated.addEntries(entries);
    }
    return translated;
  }
}

Iterable<List<T>> _windows<T>(List<T> values, int size) sync* {
  for (int start = 0; start < values.length; start += size) {
    yield values.sublist(start, min(start + size, values.length));
  }
}
```

只对现有 shouldFallbackBatchDioException 允许的错误降级。认证、权限和普通全局错误原样抛出。每条降级成功译文必须立即写入对应原块缓存。

- [ ] **步骤 4：运行降级与续传测试确认通过**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test test\epub_repository_performance_test.dart test\repository_safety_test.dart
```

预期：413 后请求序列为 3、1、1、1；取消后第二次只请求未缓存脚注；现有缓存键测试仍通过。

- [ ] **步骤 5：提交可靠性处理**

```powershell
git add lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/epub_repository_performance_test.dart test/repository_safety_test.dart
git commit -m "test: cover footnote batch recovery"
```

## 任务 5：全量验证、真实 EPUB 验收与 Windows 交付

**文件：**
- 创建：`work/live_communion_footnote_batch_test.dart`

- [ ] **步骤 1：编写受环境变量保护的真实 API 验收**

```dart
test(
  'live Communion footnotes use cross-file batches',
  () async {
    int recordedFootnoteRequests = 0;
    int recordedFootnoteBlocks = 0;
    // onProgress 遇到 "footnote batch" 日志时递增请求数，
    // 并从日志中的 "(N blocks)" 解析块数。
    final config = await SettingsStore().load();
    final run = await repository.translateChapters(
      inputPath: communionPath,
      outputDirectory: outputDirectory,
      config: config,
      chapters: inspection.chapters,
    );
    expect(run.job.status, TranslationJobStatus.completed);
    expect(recordedFootnoteRequests, lessThan(recordedFootnoteBlocks));
    expect(await File(run.job.outputPath).exists(), isTrue);
    expect(await _footnoteLinksRemainValid(run.job.outputPath), isTrue);
  },
  skip: Platform.environment['LIVE_TRANSLATION_E2E'] == '1'
      ? false
      : 'Set LIVE_TRANSLATION_E2E=1',
);
```

日志只记录请求数、块数、耗时、文件路径和脱敏错误；不得记录 API Key、完整请求体或完整服务端错误体。

- [ ] **步骤 2：运行自动化全量验证**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' analyze lib test
```

预期：全部常规测试通过；analyze lib test 显示 No issues found!。

- [ ] **步骤 3：运行真实 API 验收并记录脚注请求数**

运行：

```powershell
$env:LIVE_TRANSLATION_E2E='1'
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' test work\live_communion_footnote_batch_test.dart --reporter expanded
Remove-Item Env:LIVE_TRANSLATION_E2E
```

预期：正式译后 EPUB 完成；脚注 API 请求数少于脚注块数；所有脚注 XHTML 仍有有效 id 与 href。

- [ ] **步骤 4：构建并打包 Windows Release**

运行：

```powershell
& 'E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat' build windows --release
Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath 'dist\epub-translator-flutter-v1.2.0-windows-x64-footnote-batching.zip' -CompressionLevel Optimal
Get-FileHash -Algorithm SHA256 'dist\epub-translator-flutter-v1.2.0-windows-x64-footnote-batching.zip'
```

预期：生成 epub_translator_flutter_clean.exe；压缩包包含 data/app.so、flutter_windows.dll 和可执行文件。

- [ ] **步骤 5：提交实现与测试**

```powershell
git add lib/features/translation/infrastructure/epub/footnote_batch_planner.dart lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/footnote_batch_planner_test.dart test/epub_repository_performance_test.dart test/repository_safety_test.dart
git commit -m "feat: batch standalone footnote translations"
```

## 计划自检

- 规格中的候选识别、跨文件 ID、缓存复用、错误降级、进度日志和真实 EPUB 验收分别由任务 1、2、3、4、5 覆盖。
- requestId 在任务 1 定义，并在任务 2、3、4 使用同一名称。
- 缓存键不变由任务 3 的第二次运行断言与任务 4 的现有缓存键测试共同验证。
- 计划不包含待定项、占位实现或未定义的实现步骤。
