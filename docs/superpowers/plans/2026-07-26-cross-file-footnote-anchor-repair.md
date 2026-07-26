# 跨文件脚注锚点安全架构实施计划

> **面向 AI 工作者：** 按任务顺序执行，每个代码任务使用 TDD，并保留红灯、绿灯和静态分析证据。

**目标：** 模型只翻译源 DOM 中允许翻译的纯文本槽；脚注锚点 HTML 永远不交给模型修改，最终 HTML 结构只来自源 DOM。

**架构：** 先把单 root 源 HTML 解析为“源 DOM 骨架 + 文档顺序稳定的可翻译 text slots”。受保护脚注锚点的完整子树不进入 slots。模型只接收与返回 slot 纯文本；回填时严格校验 slot 数量，在源 DOM clone 上仅设置 `Text.data`。不再把“模型返回 HTML 后再修复”作为安全边界，也不继续扩展旧 post-hoc anchor lock 的复杂逻辑。

**技术栈：** Dart、Flutter tests、`package:html` DOM。组件与测试不访问网络或真实翻译 API。

---

### 任务 1：构建独立的受保护锚点文本槽组件

**文件：**

- 创建：`lib/features/translation/infrastructure/epub/protected_anchor_text_slots.dart`
- 创建：`test/protected_anchor_text_slots_test.dart`
- 修改：本设计文档与计划

- [x] **步骤 1：先写失败测试并确认红灯**

测试覆盖：

- 短 marker `a#footnote_ref_*`；
- token 化的 `role~="doc-backlink"` 与 `role~="doc-noteref"`；
- `epub:type~="noteref"`；
- 跨文件链接中的 `footnote_ref` / `footnote_num` marker class；
- 字母、罗马数字与上标数字等常见短 marker；
- 普通 prose link 仍是可翻译 slot；
- slot 顺序、严格数量校验、源边界空格与 marker 原样保留；
- `<script>`、`<img>`、`<span>` 等输入只能成为转义文本；
- `script`、`style` 等 raw-text 源子树不进入 slots；
- 无受保护 anchor 的普通 HTML 仍保留源元素骨架。

运行：

`E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat test test/protected_anchor_text_slots_test.dart --reporter expanded`

预期红灯原因：组件文件与类型尚不存在，而不是测试语法或环境错误。

- [x] **步骤 2：最小实现模板 API**

公开 API：

```dart
final template = ProtectedAnchorTextSlots.parse(sourceHtml);
final sourceTexts = template.slotTexts;
final renderedHtml = template.render(translatedSlotTexts);
```

`parse` 只接受单 root fragment；`slotTexts` 为只读且按 DOM 顺序稳定；`render` 必须收到完全相同数量的字符串。

- [x] **步骤 3：以源 DOM clone 安全回填**

每次 `render` 都重新 clone 源 root，并只把译文赋给未受保护的 `dom.Text.data`。禁止把译文传给 `innerHtml`、`parseFragment` 或属性 API。保留源 slot 的前导与尾随空白，避免内联元素和锚点两侧粘词。

- [x] **步骤 4：运行最终验证并提交相关文件**

运行：

```powershell
E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat test test/protected_anchor_text_slots_test.dart --reporter expanded
E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat analyze lib/features/translation/infrastructure/epub/protected_anchor_text_slots.dart test/protected_anchor_text_slots_test.dart
git diff --check
```

只暂存本任务的组件、测试和两份文档；不暂存 worktree 中既有的生成文件改动。

### 任务 2：把翻译管线切换为 slot-only 协议（后续任务）

当前组件提交不修改 `EpubChapterTranslator`，也不调用真实 API。后续集成必须遵守以下边界：

1. 请求只包含 slot ID/顺序与纯文本，不包含源 HTML 或 protected anchor HTML；
2. 响应只读取对应 slot 的纯文本；
3. slot 缺失、重复或数量不一致时整块失败，不能退回接受模型 HTML；
4. 最终 HTML 只通过 `ProtectedAnchorTextSlots.render` 生成；
5. 旧 structure lock 可作为迁移期兼容代码，但不得成为新路径的正确性依赖。

### 任务 3：既有损坏译本的无 API 一次性修复（独立任务）

既有 Communion 译本可继续由只读源 EPUB 驱动的本地脚本修复并执行 ZIP 审计。该脚本不属于在线翻译架构，不调用翻译服务，也不能替代任务 2 的 slot-only 集成。
