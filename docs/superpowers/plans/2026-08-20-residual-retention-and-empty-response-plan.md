# 残留文本误判与空响应恢复实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans（当前会话内联执行）。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让中文翻译正确保留合法的原文书名/人名/网址/短术语，同时对空 API 响应进行有限重试，避免误判和偶发空响应中断整本 EPUB。

**架构：** 在现有 `TranslationQuality.findSuspiciousHtmlResidual` 的质量检查副本中增加带上下文的 CJK 书名原文匹配；最终译文和 HTML 锁定流程不变。将空响应重试封装在单块翻译循环内，沿用现有取消、限流和重试上限策略。

**技术栈：** Dart/Flutter、`package:html` DOM、Dio、Flutter test。

---

## 文件职责

- 修改：`lib/features/translation/infrastructure/translation_quality.dart`——识别并清理带 CJK 书名/括号上下文的 source-owned 原文。
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`——把空 API 响应归类为可重试错误并生成明确的最终错误。
- 修改：`test/translation_quality_test.dart`——覆盖 HTML 锁定后标题包装器丢失但 CJK 书名仍保留的回归样本及反例。
- 修改：`test/repository_safety_test.dart`——覆盖单块空响应后成功、连续空响应耗尽两种 API 行为。

### 任务 1：完成 CJK 书名原文的失败回归测试

**文件：** `test/translation_quality_test.dart`

- [x] **步骤 1：编写失败测试**

加入测试 `allows a retained work title moved into CJK book-title marks after HTML locking`：源 HTML 使用 `<i class="calibre3">The Sovereign Individual</i>`，译 HTML 使用 `《The Sovereign Individual》` 并保留一个空的 `<i>` 包装器。

- [x] **步骤 2：运行测试验证失败**

运行：

```powershell
flutter test test/translation_quality_test.dart --plain-name "allows a retained work title moved into CJK book-title marks after HTML locking"
```

预期基线：失败，实际得到 `TranslationResidualFinding` 而非 `null`。

### 任务 2：实现保守的 CJK 书名匹配

**文件：** `lib/features/translation/infrastructure/translation_quality.dart:184-277`

- [x] **步骤 1：增加最小匹配辅助函数**

增加私有函数，接收译文可见文本和源作品名，只有当作品名出现在 CJK 开闭书名/括号标记包围的原文片段中且译文存在目标文字上下文时返回 `true`。函数必须使用大小写不敏感、末尾标点归一化和标记边界，不能把普通英文句子当标题。

- [x] **步骤 2：在候选配对失败时清理质量副本**

在 `sourceCandidates.length == translatedCandidates.length` 的路径中，若结构路径或包装器不匹配，调用该辅助函数；匹配成功时只清空源候选和译文文本节点中的对应作品名，继续后续残留检查。不要修改调用者拿到的最终 HTML 字符串。

- [x] **步骤 3：运行回归测试验证通过**

运行：

```powershell
flutter test test/translation_quality_test.dart --plain-name "allows a retained work title moved into CJK book-title marks after HTML locking"
```

预期：`All tests passed!`。

- [x] **步骤 4：补充反例并运行质量测试**

补充一个同样包含 `The Sovereign Individual`、但没有 CJK 书名标记且英文句子仍未翻译的测试，确认仍返回 `TranslationResidualKind.longSourceText`；运行：

```powershell
flutter test test/translation_quality_test.dart
```

预期：该文件全部通过。

### 任务 3：为空 API 响应建立失败回归测试

**文件：** `test/repository_safety_test.dart:846`、`test/repository_safety_test.dart` 的 `translation residual detection` 分组

- [x] **步骤 1：增加可编程响应适配器**

新增 `_EmptyThenValidHtmlAdapter`，第一次批量请求返回一个空 `html` 触发单块 fallback；随后单块请求第一次返回空 `message.content`，第二次返回 `<p>这句话已经翻译完成。</p>`。适配器记录 `fetchCount`，不使用真实网络。

- [x] **步骤 2：编写“空后成功”测试并确认基线失败**

调用 `EpubChapterTranslator().translateBlockBatchForTest`，配置 `targetLanguage: 'Chinese'`、`maxRetries: 2`、`retryDelaySeconds: 0`，断言返回有效中文 HTML 且 `fetchCount` 包含批量请求、空响应和成功重试。当前基线预期抛出 `StateError` 或未完成请求。

- [x] **步骤 3：编写“连续空响应”测试**

让单块 fallback 的所有响应都为空，断言抛出的 `StateError` 包含 block id、`empty`/`空` 和尝试次数；这保证修复不会静默返回空 HTML。

### 任务 4：完善空响应错误分类

**文件：** `lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:1632-1695`

- [x] **步骤 1：确认并保留现有空响应重试路径**

现有 `_translateBlock` 已经对 `FormatException('The translation API returned an empty block.')` 使用通用 `maxAttemptsForError` 循环和可取消退避；新增回归测试必须保持这一行为，不另造一套重试器，也不把空响应归入质量降级。

- [x] **步骤 2：为重试提示增加明确指令**

在已有 `[RETRY]` 内容中，对空响应追加“上一响应为空；必须返回完整 HTML 片段”的安全提示，不嵌入原始异常或敏感数据。

- [x] **步骤 3：耗尽后抛出带上下文错误**

在最终 `StateError` 文案中区分空响应与其他结构/网络错误，包含 block id 和尝试次数；空响应不能进入 `degradedBlockIds`。

- [x] **步骤 4：运行空响应回归测试**

运行：

```powershell
flutter test test/repository_safety_test.dart --plain-name "empty translation response"
```

预期：新增成功重试和耗尽失败测试通过。

### 任务 5：完整验证与交付

- [x] **步骤 1：运行相关测试**

```powershell
flutter test test/translation_quality_test.dart test/repository_safety_test.dart
```

预期：0 failures。

- [x] **步骤 2：运行静态分析与全量测试**

```powershell
flutter analyze lib test tool
flutter test
```

预期：分析无 error，全量测试通过。

- [x] **步骤 3：构建 Windows release**

```powershell
flutter build windows --release
```

预期：退出码 0，生成 `build/windows/x64/runner/Release/epub_translator_flutter_clean.exe`。

- [x] **步骤 4：检查差异并提交实现**

```powershell
git diff --check
git status --short
git add lib test
git commit -m "fix: recover retained titles and empty responses"
```
