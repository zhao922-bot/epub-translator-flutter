# 模型 JSON 与合批失败恢复实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 安全恢复模型返回的未转义 JSON 引号，在受保护槽位合批结构异常时自动拆批，并让续传任务历史实时反映当前状态。

**架构：** `TranslationApiClient` 负责严格优先、保守兜底的 JSON 对象解析；`EpubChapterTranslator` 继续负责完整的块/槽位协议校验，并在验证失败后递归二分受保护槽位请求；`TranslationDashboardController` 保持仓库任务 ID 与用户历史任务 ID 分离，在进度回调中更新历史快照并限频持久化。

**技术栈：** Dart 3、Flutter、Dio、`flutter_test`、StateNotifier、Git worktree。

---

## 文件结构

- 创建：`test/translation_api_client_test.dart` — 模型 JSON 容错解析的独立回归测试。
- 修改：`lib/features/translation/infrastructure/epub/translation_api_client.dart` — 严格解析与裸引号保守修复。
- 修改：`test/repository_safety_test.dart` — 受保护槽位合批拆分和单块失败的 HTTP 级测试。
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart` — 单次合批与递归恢复职责拆分。
- 修改：`test/translation_dashboard_controller_test.dart` — 旧错误清除、实时历史同步与稳定历史 ID 测试。
- 修改：`lib/features/translation/application/translation_dashboard_controller.dart` — 运行历史条目同步和限频持久化。

### 任务 1：保守修复模型 JSON 内部的裸双引号

**文件：**
- 创建：`test/translation_api_client_test.dart`
- 修改：`lib/features/translation/infrastructure/epub/translation_api_client.dart:194-205`

- [ ] **步骤 1：编写失败测试**

新增独立测试，覆盖真实截图中的错误、合法转义和不可修复结构：

```dart
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const TranslationApiClient client = TranslationApiClient();

  test('repairs unescaped quotes inside model JSON strings', () {
    final Map<String, dynamic> decoded = client.decodeJsonObject(
      r'''{"blocks":[{"id":"p1","slots":[{"id":"s1","text":"而所谓的"玻璃天花板"——也就是那种"}]}]}''',
    );
    final List<dynamic> blocks = decoded['blocks'] as List<dynamic>;
    final List<dynamic> slots =
        (blocks.single as Map<String, dynamic>)['slots'] as List<dynamic>;
    expect(
      (slots.single as Map<String, dynamic>)['text'],
      '而所谓的"玻璃天花板"——也就是那种',
    );
  });

  test('keeps already escaped quotes unchanged', () {
    expect(
      client.decodeJsonObject(r'''{"text":"他说：\"你好\"。"}''')['text'],
      '他说："你好"。',
    );
  });

  test('still rejects structurally incomplete JSON', () {
    expect(
      () => client.decodeJsonObject(r'''{"blocks":[{"id":"p1"}'''),
      throwsA(isA<FormatException>()),
    );
  });
}
```

- [ ] **步骤 2：运行测试并验证红灯**

运行：

```powershell
flutter test test/translation_api_client_test.dart
```

预期：第一个测试因 `FormatException: Unexpected character` 失败；另外两个测试通过。

- [ ] **步骤 3：实现最小安全修复**

把 `decodeJsonObject` 改为严格解析优先，并添加私有状态机：

```dart
Map<String, dynamic> decodeJsonObject(String content) {
  final String normalized = content.trim();
  final Match? fenced = RegExp(
    r'```(?:json)?\s*([\s\S]*?)\s*```',
  ).firstMatch(normalized);
  final String candidate = fenced?.group(1)?.trim() ?? normalized;
  try {
    return _decodeJsonObjectStrict(candidate);
  } on FormatException catch (original, stackTrace) {
    final String repaired = _escapeBareQuotesInsideJsonStrings(candidate);
    if (repaired == candidate) {
      Error.throwWithStackTrace(original, stackTrace);
    }
    try {
      return _decodeJsonObjectStrict(repaired);
    } on FormatException {
      Error.throwWithStackTrace(original, stackTrace);
    }
  }
}

Map<String, dynamic> _decodeJsonObjectStrict(String candidate) {
  final Object? decoded = jsonDecode(candidate);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Model response is not a JSON object.');
  }
  return decoded;
}
```

状态机在 JSON 字符串内仅把后续非空白字符不是 `:`, `,`, `}`, `]` 或输入结束的裸 `"` 改为 `\"`；已转义字符原样保留。

- [ ] **步骤 4：运行定向测试并验证绿灯**

运行：

```powershell
flutter test test/translation_api_client_test.dart
```

预期：3 个测试全部通过。

- [ ] **步骤 5：提交任务 1**

```powershell
git add test/translation_api_client_test.dart lib/features/translation/infrastructure/epub/translation_api_client.dart
git commit -m "fix: 容错解析模型 JSON 引号"
```

### 任务 2：受保护槽位合批失败后递归拆分

**文件：**
- 修改：`test/repository_safety_test.dart`
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:2715-2859,2914-2949`

- [ ] **步骤 1：编写合批拆分失败测试**

在 `repository_safety_test.dart` 增加 `_ProtectedSlotSplitAdapter`。适配器读取用户载荷中的 `blocks`；多块请求只返回第一块，单块请求返回完整、合法的槽位响应，并记录每次请求的块 ID：

```dart
class _ProtectedSlotSplitAdapter implements HttpClientAdapter {
  final List<List<String>> requestIds = <List<String>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final BytesBuilder builder = BytesBuilder();
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        builder.add(chunk);
      }
    }
    final Map<String, dynamic> request =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
    final List<dynamic> messages = request['messages'] as List<dynamic>;
    final Map<String, dynamic> payload = jsonDecode(
      (messages.last as Map<String, dynamic>)['content'] as String,
    ) as Map<String, dynamic>;
    final List<Map<String, dynamic>> blocks =
        (payload['blocks'] as List<dynamic>).cast<Map<String, dynamic>>();
    requestIds.add(blocks.map((block) => block['id'] as String).toList());
    final Iterable<Map<String, dynamic>> returned =
        blocks.length > 1 ? blocks.take(1) : blocks;
    final List<Map<String, Object?>> responseBlocks = returned.map((block) {
      return <String, Object?>{
        'id': block['id'],
        'slots': (block['slots'] as List<dynamic>).map((slot) {
          return <String, Object?>{
            'id': (slot as Map<String, dynamic>)['id'],
            'text': '${block['id']} 译文',
          };
        }).toList(growable: false),
      };
    }).toList(growable: false);
    return _chatResponse(<String, Object?>{'blocks': responseBlocks});
  }
}
```

测试用两个带锚点的 `ExtractedBlock` 调用 `translateBlockBatchForTest`，配置 `maxRetries: 1`，期望请求顺序为 `[['protected-a', 'protected-b'], ['protected-a'], ['protected-b']]`，并验证两个结果都保留原 `href`。

- [ ] **步骤 2：运行测试并验证红灯**

运行：

```powershell
flutter test test/repository_safety_test.dart --plain-name "splits malformed protected slot batches and preserves every result"
```

预期：抛出 `Translated slot block count does not match request count.`，测试失败。

- [ ] **步骤 3：实现递归恢复包装器**

将现有请求实现重命名为 `_translateProtectedSlotBatchOnce`，新增同名恢复包装器：

```dart
Future<Map<String, String>> _translateProtectedSlotBatch({
  required Dio dio,
  required TranslationConfig config,
  required List<_ProtectedSlotRequest> requests,
  required TranslationBatchContext context,
  Duration? retryDelayOverride,
  CancelToken? cancelToken,
  void Function()? onRequestAttempt,
}) async {
  try {
    return await _translateProtectedSlotBatchOnce(
      dio: dio,
      config: config,
      requests: requests,
      context: context,
      retryDelayOverride: retryDelayOverride,
      cancelToken: cancelToken,
      onRequestAttempt: onRequestAttempt,
    );
  } on FormatException {
    if (requests.length == 1) rethrow;
  } on DioException catch (error) {
    if (_isCancelError(error)) {
      throw const TranslationCancelledException();
    }
    if (!TranslationApiClient.shouldFallbackBatchDioException(error) ||
        requests.length == 1) {
      rethrow;
    }
  }
  final int midpoint = requests.length ~/ 2;
  final Map<String, String> left = await _translateProtectedSlotBatch(
    dio: dio,
    config: config,
    requests: requests.sublist(0, midpoint),
    context: context,
    retryDelayOverride: retryDelayOverride,
    cancelToken: cancelToken,
    onRequestAttempt: onRequestAttempt,
  );
  final Map<String, String> right = await _translateProtectedSlotBatch(
    dio: dio,
    config: config,
    requests: requests.sublist(midpoint),
    context: context,
    retryDelayOverride: retryDelayOverride,
    cancelToken: cancelToken,
    onRequestAttempt: onRequestAttempt,
  );
  return <String, String>{...left, ...right};
}
```

删除 `_translateBlockBatch` 中只处理 HTTP 413 并行逐块的旧 `try/on DioException`，统一直接调用恢复包装器。递归拆分顺序执行，避免一次失败突然放大并发。

- [ ] **步骤 4：增加单块失败边界测试**

让适配器支持始终遗漏块的模式；用一个受保护块请求，期望仍抛出 `FormatException`，且请求次数等于 `maxRetries`，证明没有静默生成结果。

- [ ] **步骤 5：运行合批相关测试并验证绿灯**

运行：

```powershell
flutter test test/repository_safety_test.dart
```

预期：文件内全部测试通过，包括新增拆分和单块失败测试。

- [ ] **步骤 6：提交任务 2**

```powershell
git add test/repository_safety_test.dart lib/features/translation/infrastructure/epub/epub_chapter_translator.dart
git commit -m "fix: 拆分异常的受保护槽位批次"
```

### 任务 3：同步续传任务历史并清除旧错误

**文件：**
- 修改：`test/translation_dashboard_controller_test.dart`
- 修改：`lib/features/translation/application/translation_dashboard_controller.dart:210-217,784-946,1200-1265,1332-1447`

- [ ] **步骤 1：编写运行中历史失败测试**

扩展 `direct translation retry preserves the failed job checkpoint`：第一次失败应包含 `temporary failure`；第二次启动并阻塞后断言：

```dart
expect(controller.state.job?.phase, TranslationJobPhase.cacheRestoration);
expect(controller.state.job?.errorMessage, isNull);
expect(controller.state.jobHistory.first.errorMessage, isNull);
expect(controller.state.jobHistory.first.completedBlocks, 2);
```

扩展 `_RestorationCancellationRepository` 测试，在仓库发出 6/10、已验证 2 块的回调后断言历史首项同步为 `cacheRestoration`、`completedBlocks == 6`、`cachedBlocks == 2`，且历史中没有同一次运行的重复旧条目。

- [ ] **步骤 2：运行测试并验证红灯**

运行：

```powershell
flutter test test/translation_dashboard_controller_test.dart --plain-name "direct translation retry preserves the failed job checkpoint"
flutter test test/translation_dashboard_controller_test.dart --plain-name "cache restoration cancellation keeps translation resume semantics"
```

预期：旧 `errorMessage` 未清除或历史进度仍停留在 queued 状态，至少一个断言失败。

- [ ] **步骤 3：实现稳定历史 ID 与内存同步**

增加字段：

```dart
String? _activeHistoryJobId;
DateTime? _lastProgressHistoryPersistAt;
```

创建 queued 任务时显式设置 `errorMessage: null`，并保存 `_activeHistoryJobId = queuedJob.id`。进度回调中保持 `state.job` 使用仓库任务 ID，但历史任务使用稳定 ID：

```dart
final TranslationJob progressJob = job.copyWith(errorMessage: null);
final TranslationJob historyJob = progressJob.copyWith(
  id: _activeHistoryJobId ?? progressJob.id,
);
final List<TranslationJob> nextHistory = _jobHistoryWith(
  historyJob,
  persist: false,
);
state = state.copyWith(
  job: progressJob,
  jobHistory: nextHistory,
  runEstimate: _buildEstimate(job: progressJob),
  logs: nextLogs,
);
_persistProgressHistoryIfDue();
```

让 `_jobHistoryWith` 接受 `persist` 参数；进度持久化使用一秒限频，完成、失败、取消继续立即持久化。所有终态历史条目使用 `_activeHistoryJobId`，完成终态后清空该字段。

- [ ] **步骤 4：验证最终失败覆盖新错误**

扩展已有失败测试，确认运行开始时旧错误为空，而新失败后 `state.job.errorMessage` 和历史首项均为新的脱敏错误，`completedBlocks` 保持最新进度。

- [ ] **步骤 5：运行控制器测试并验证绿灯**

运行：

```powershell
flutter test test/translation_dashboard_controller_test.dart
```

预期：该文件全部测试通过。

- [ ] **步骤 6：提交任务 3**

```powershell
git add test/translation_dashboard_controller_test.dart lib/features/translation/application/translation_dashboard_controller.dart
git commit -m "fix: 实时同步续传任务历史"
```

### 任务 4：完整回归、静态分析与 Windows 构建

**文件：**
- 验证：全部生产与测试文件

- [ ] **步骤 1：格式化改动文件**

```powershell
dart format lib/features/translation/infrastructure/epub/translation_api_client.dart lib/features/translation/infrastructure/epub/epub_chapter_translator.dart lib/features/translation/application/translation_dashboard_controller.dart test/translation_api_client_test.dart test/repository_safety_test.dart test/translation_dashboard_controller_test.dart
```

- [ ] **步骤 2：运行定向回归测试**

```powershell
flutter test test/translation_api_client_test.dart test/repository_safety_test.dart test/translation_dashboard_controller_test.dart
```

预期：0 失败。

- [ ] **步骤 3：运行完整测试**

```powershell
flutter test
```

预期：所有自动化测试通过；仅标记为环境/真人的测试允许跳过。

- [ ] **步骤 4：运行静态分析**

```powershell
flutter analyze lib test
```

预期：`No issues found!`

- [ ] **步骤 5：构建 Windows Release**

```powershell
flutter build windows --release
```

预期：退出码 0，生成 `build/windows/x64/runner/Release/epub_translator_flutter_clean.exe` 及配套运行文件。

- [ ] **步骤 6：检查变更范围和构建产物**

```powershell
git status --short
git diff --check
Get-FileHash build/windows/x64/runner/Release/epub_translator_flutter_clean.exe -Algorithm SHA256
```

预期：没有意外生成文件进入 Git 变更；`git diff --check` 无输出；EXE 哈希成功生成。

- [ ] **步骤 7：提交计划执行后的必要整理**

仅当格式化或验证产生尚未提交的预期代码改动时执行：

```powershell
git add lib test
git commit -m "test: 完善模型响应恢复回归验证"
```
