# 跨文件脚注锚点修复实施计划

> **面向 AI 工作者：** 执行时使用 `executing-plans`，按任务顺序完成，每步保留测试证据。

**目标：** 防止翻译结果把跨文件脚注标记移出链接，并无 API 修复现有 Communion 译本的正文跳转与脚注回跳。

**架构：** 在现有 `EpubChapterTranslator` 的 HTML 结构锁中识别 EPUB 的跨文件脚注锚点，并在受保护文本槽失配时改用源 HTML 骨架重建。独立的本地修复脚本从原书取得锚点标记与结构，只修改译后 EPUB 的相关 `<a>` 内容和相邻文本，不调用翻译服务。

**技术栈：** Dart/Flutter 测试、`package:html` DOM、PowerShell/.NET ZIP 读写（仅一次性本地修复脚本）。

---

### 任务 1：锁定跨文件脚注锚点的回归用例

**文件：**
- 修改：`test/repository_safety_test.dart`（`strict HTML structure lock` 组）
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart`

- [ ] **步骤 1：编写两个失败测试**

```dart
test('rebuilds a cross-file body footnote marker moved outside its link', () {
  final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
    sourceHtml:
        '<p>Source<a href="chapter-fn.xhtml#note-1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>',
    translatedHtml:
        '<p>译文*<a href="chapter-fn.xhtml#note-1" id="footnote_ref_1"><span class="footnote_ref"></span></a></p>',
  );
  expect(locked, '<p>译文<a href="chapter-fn.xhtml#note-1" id="footnote_ref_1"><span class="footnote_ref">*</span></a></p>');
});

test('rebuilds a doc-backlink whose marker contains citation prose', () {
  final String locked = EpubTranslationRepository.lockHtmlStructureForTest(
    sourceHtml:
        '<p><a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">*</span></a> Citation <i>title</i>.</p>',
    translatedHtml:
        '<p><a href="chapter.xhtml#footnote_ref_1" role="doc-backlink"><span class="footnote_num">* 译后引文</span></a><i></i></p>',
  );
  expect(locked, contains('<span class="footnote_num">*</span>'));
  expect(locked, isNot(contains('<span class="footnote_num">* 译后引文</span>')));
});
```

- [ ] **步骤 2：运行测试，确认当前实现失败**

运行：
`E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat test test/repository_safety_test.dart --plain-name "cross-file"`

预期：两个测试因标记仍在链接外或引文仍位于 `doc-backlink` 内而失败。

- [ ] **步骤 3：最小实现保护与失配回退**

在 `_isProtectedTextElement` 中新增锚点判定：

```dart
if (tag == 'a' &&
    (role == 'doc-backlink' ||
     element.attributes['id']?.startsWith('footnote_ref_') == true ||
     _hasFootnoteMarkerClass(element))) {
  return true;
}
```

将 `_restoreProtectedTexts` 改为可失败的恢复：当源/译文文本槽数量不一致且源存在受保护槽时，返回 `null`；`_lockHtmlStructure` 遇到 `null` 时进入既有源骨架重建路径。这样可把可见 `*` 放回源 `<a>`，而不是接受空锚点。

- [ ] **步骤 4：运行定向测试，确认通过**

运行：
`E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat test test/repository_safety_test.dart`

预期：结构锁测试全部通过，既有普通外链与脚注正文可翻译用例不回归。

- [ ] **步骤 5：提交代码与测试**

```powershell
git add lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/repository_safety_test.dart
git commit -m "fix: 保护跨文件脚注锚点"
```

### 任务 2：无 API 修复现有 Communion 译本

**文件：**
- 创建（忽略、不提交）：`work/repair_communion_footnote_anchors.dart`
- 输入：`D:\下载\Chrome\Communion Finding My Way Back to Faith (J. D. Vance) (z-library.sk, 1lib.sk, z-lib.sk).epub`
- 输入：`C:\Books\Communion Finding My Way Back to Faith (J. D. Vance) (z-library.sk, 1lib.sk, z-lib.sk)_translated.epub`
- 输出：`C:\Books\Communion Finding My Way Back to Faith (J. D. Vance) (z-library.sk, 1lib.sk, z-lib.sk)_translated_anchors-fixed.epub`

- [ ] **步骤 1：实现只改变锚点节点的修复脚本**

脚本按 XHTML 路径配对原书与译本；对于源 `a#footnote_ref_*` 和 `a[role="doc-backlink"]`：

```dart
final String marker = sourceAnchor.text.trim();
final String targetText = targetAnchor.text.trim();
targetAnchor.innerHtml = sourceAnchor.innerHtml;
removeTrailingMarkerFromPreviousTextNode(targetAnchor, marker);
insertOverflowAfterAnchor(targetAnchor, targetText.substring(marker.length));
```

仅在译文锚点为空或包含超过源标记的文本时操作。复制所有其他 ZIP 条目与元数据，保留 `mimetype` 为存储条目；不触发网络请求。

- [ ] **步骤 2：运行脚本并核验输出存在**

运行：
`dart run work/repair_communion_footnote_anchors.dart`

预期：输出文件存在，脚本报告修复的正文标记数与回跳链接数，不打印 API 配置。

- [ ] **步骤 3：执行归档审计**

使用只读 ZIP 审计脚本验证：

```text
内部 href#fragment 的目标缺失数：0
空的 a#footnote_ref_* 数：0
doc-backlink 中超出源标记的文本数：0
```

- [ ] **步骤 4：抽样人工复核**

检查 `Chapter_9.xhtml#footnote_ref_1` 与
`9780063575059_Chapter_18_1-fn.xhtml#footnote_1`：正文 `*` 位于前往脚注的链接内；脚注只有 `*` 为回正文链接，译后引文不在该链接内。

### 任务 3：完整回归验证

**文件：**
- 修改：无（仅验证）

- [ ] **步骤 1：运行完整测试**

运行：
`E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat test --reporter compact`

预期：所有常规测试通过；仅既有的环境保护 live tests 跳过。

- [ ] **步骤 2：运行静态分析与差异检查**

运行：
`E:\flutter_windows_3.44.0-stable\flutter\bin\flutter.bat analyze lib test`

运行：`git diff --check`

预期：静态分析无问题，差异无空白错误。

- [ ] **步骤 3：报告结果**

报告软件提交、修复 EPUB 的绝对路径、修复计数、归档审计结果及测试结果；明确说明未调用 API。
