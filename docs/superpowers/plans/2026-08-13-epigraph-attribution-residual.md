# 题词／引文署名残留识别实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 仅对结构明确的题词署名保留姓名，避免误报，同时继续拒绝未翻题词正文。

**架构：** 扩展质量检查副本中的姓名清理阶段，加入严格的 blockquote 末段署名匹配。匹配只清空姓名节点，所有既有残留检测仍完整执行。

**技术栈：** Dart、Flutter test、package:html、真实 OpenAI-compatible API 验收。

---

### 任务 1：锁定真实回归行为

**文件：**
- 修改：`test/translation_quality_test.dart`

- [ ] 添加真实题词源 HTML 与已捕获译文，断言 `findSuspiciousHtmlResidual` 返回 `null`。
- [ ] 添加原样英文题词、部分漏翻题词、姓名被修改、普通段落姓名等负向用例，断言为 `longSourceText`。
- [ ] 运行 `flutter test --no-pub test/translation_quality_test.dart --plain-name "allows a retained epigraph attribution name after punctuation localization"`，确认正向用例因功能缺失而失败。

### 任务 2：实现最小结构化署名识别

**文件：**
- 修改：`lib/features/translation/infrastructure/translation_quality.dart`
- 测试：`test/translation_quality_test.dart`

- [ ] 在 `_clearRetainedProperNames` 中保留现有 credit 规则，并增加严格的题词末段署名匹配分支。
- [ ] 用辅助函数验证末尾直接子段、唯一 inline、破折号形态、相同 DOM 路径和完全相同的姓名 token。
- [ ] 只清空匹配的 inline 节点，不返回提前成功。
- [ ] 运行 `flutter test --no-pub test/translation_quality_test.dart`，确认全部通过。

### 任务 3：回归、审查和真实验收

**文件：**
- 验证：`test/repository_safety_test.dart`
- 验证：`work/_live_sovereign_blockquote_diagnostic_test.dart`
- 验证：`work/_live_sovereign_current_fullbook_test.dart`

- [ ] 运行 `flutter test --no-pub test/repository_safety_test.dart`。
- [ ] 请求只读代码审查并处理 Critical／Important 反馈。
- [ ] 开启生产残留检查运行真实题词单章测试，确认 API 返回可通过质量门。
- [ ] 运行整书长跑，复用兼容缓存并记录完成结果或下一个精确故障块。
- [ ] 所有证据确认后提交生产代码和回归测试。

### 任务 4：处理长跑发现的前言末尾署名

**文件：**
- 修改：`lib/features/translation/domain/models/inspected_chapter.dart`
- 修改：`lib/features/translation/infrastructure/epub/epub_html_extractor.dart`
- 修改：`lib/features/translation/infrastructure/translation_quality.dart`
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`
- 测试：`test/epub_html_extractor_selection_test.dart`
- 测试：`test/translation_quality_test.dart`
- 测试：`test/repository_safety_test.dart`

- [x] 用整章终止三行签名组标记作者，日期和地点保持普通块。
- [x] 允许作者原名保留或译为目标文字，拒绝另一英文名、嵌套结构和夹带英文。
- [x] 普通块保持 v12 缓存键完全兼容，仅隔离署名块。
- [ ] 完成全量相关测试、独立审查与真实整书断点续跑。
