# HTML 感知残留质量检测实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 接受源 EPUB 中结构对应的合法英文作品名，同时拒绝正文长英文和 `entitlement概念` 这类局部中英混排，并完成 Windows Release 构建。

**架构：** 在 `TranslationQuality` 中新增 HTML 感知分析入口，解析源 HTML 与结构锁定后的译文 HTML，只从检测副本中移除严格匹配的 `i/em/cite` 标题节点，再运行原有长英文检测和新增 CJK 紧贴小写英文检测。`EpubChapterTranslator` 只负责把分析结果转成带块 ID 的 `FormatException`，现有重试、脚注保护和缓存写入顺序不变。

**技术栈：** Dart、Flutter、`package:html` DOM 解析、`flutter_test`、Dio 测试适配器、Windows Flutter Release。

---

## 文件结构

- 修改：`lib/features/translation/infrastructure/translation_quality.dart` — 定义残留发现结果、作品名节点匹配、HTML 感知残留分析和 CJK 紧贴英文检测。
- 修改：`test/translation_quality_test.dart` — 覆盖合法作品名、斜体引文、模型新增标题和局部英文漏翻等纯质量规则。
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart` — 将块质量校验接入 HTML 感知分析结果。
- 修改：`test/repository_safety_test.dart` — 验证真实形态的 `p-2` 在批量路径一次通过，局部混排仍重试且不会缓存失败结果。
- 临时创建后删除：`test/_diagnose_html_residual_live_test.dart` — 使用环境变量注入已保存密钥，对真实 EPUB 的 `p-2` 做一次验收；不得提交。

### 任务 1：作品名节点的 HTML 感知豁免

**文件：**
- 修改：`test/translation_quality_test.dart`
- 修改：`lib/features/translation/infrastructure/translation_quality.dart`

- [ ] **步骤 1：编写合法作品名和非法斜体引文的失败测试**

在 `test/translation_quality_test.dart` 增加：

```dart
test('allows an exact source-owned italic work title in translated prose', () {
  final TranslationResidualFinding? finding =
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>Authors of <i>The 500-Year Delta: What Happens After What Comes Next</i> see a change.</p>',
        translatedHtml:
            '<p>《五百年跃迁》的作者<i>The 500-Year Delta: What Happens After What Comes Next</i>看到了变化。</p>',
        targetLanguage: 'Chinese',
      );
  expect(finding, isNull);
});

test('rejects an italic English sentence that is not a work title', () {
  final TranslationResidualFinding? finding =
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p><i>This entire sentence should still be translated into Chinese for the reader.</i></p>',
        translatedHtml:
            '<p><i>This entire sentence should still be translated into Chinese for the reader.</i></p>',
        targetLanguage: 'Chinese',
      );
  expect(finding?.kind, TranslationResidualKind.longSourceText);
});

test('rejects a preserved title when the source has no matching title node', () {
  final TranslationResidualFinding? finding =
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml: '<p>The authors see a change.</p>',
        translatedHtml:
            '<p>作者看到了变化：<i>The 500-Year Delta: What Happens After What Comes Next</i></p>',
        targetLanguage: 'Chinese',
      );
  expect(finding?.kind, TranslationResidualKind.longSourceText);
});
```

- [ ] **步骤 2：运行测试并确认因 API 不存在而失败**

运行：

```powershell
flutter test test/translation_quality_test.dart --plain-name "work title"
```

预期：编译失败，提示 `TranslationResidualFinding`、`TranslationResidualKind` 或 `findSuspiciousHtmlResidual` 未定义。

- [ ] **步骤 3：实现最小 HTML 感知分析类型和作品名匹配**

在 `translation_quality.dart` 导入：

```dart
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
```

新增公共结果类型：

```dart
enum TranslationResidualKind { longSourceText, cjkAdjacentLowercaseWord }

class TranslationResidualFinding {
  const TranslationResidualFinding(this.kind, {this.token});

  final TranslationResidualKind kind;
  final String? token;

  String messageForBlock(String blockId) {
    return switch (kind) {
      TranslationResidualKind.longSourceText =>
        'Possible untranslated source-language text remains in block $blockId.',
      TranslationResidualKind.cjkAdjacentLowercaseWord =>
        'Possible untranslated source-language word "${token ?? ''}" remains next to target-language text in block $blockId.',
    };
  }
}
```

在 `TranslationQuality` 新增：

```dart
static TranslationResidualFinding? findSuspiciousHtmlResidual({
  required String sourceHtml,
  required String translatedHtml,
  required String targetLanguage,
}) {
  if (!shouldCheckResidual(targetLanguage)) {
    return null;
  }
  final dom.DocumentFragment source = html_parser.parseFragment(sourceHtml);
  final dom.DocumentFragment translated = html_parser.parseFragment(
    translatedHtml,
  );
  _removeMatchingPreservedWorkTitles(source, translated);
  final String sourceText = (source.text ?? '').trim();
  final String translatedText = (translated.text ?? '').trim();
  if (hasSuspiciousSourceResidual(
    sourceText: sourceText,
    translatedText: translatedText,
    targetLanguage: targetLanguage,
  )) {
    return const TranslationResidualFinding(
      TranslationResidualKind.longSourceText,
    );
  }
  return null;
}
```

实现 `_removeMatchingPreservedWorkTitles`：按 `i, em, cite` 的文档顺序配对；标签、规范化文本完全一致且 `_looksLikePreservedWorkTitle` 为真时，把源副本和译文副本中对应节点的 `text` 设为空字符串。作品名判定严格执行规格中的 3–16 个词、140 字符、标题式大小写比例和非完整句子规则。

- [ ] **步骤 4：运行质量测试确认通过**

运行：

```powershell
flutter test test/translation_quality_test.dart
```

预期：全部通过；既有纯文本残留测试不回归。

- [ ] **步骤 5：提交纯质量规则**

```powershell
git add lib/features/translation/infrastructure/translation_quality.dart test/translation_quality_test.dart
git commit -m "fix: allow source-owned English work titles"
```

### 任务 2：CJK 紧贴小写英文漏翻检测

**文件：**
- 修改：`test/translation_quality_test.dart`
- 修改：`lib/features/translation/infrastructure/translation_quality.dart`

- [ ] **步骤 1：编写局部混排失败测试和安全反例**

```dart
test('rejects lowercase English words attached to CJK text', () {
  for (final String translated in <String>[
    '<p>随着边界消失，entitlement概念随之瓦解。</p>',
    '<p>有权享有associated的经济优势。</p>',
  ]) {
    final TranslationResidualFinding? finding =
        TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p>As borders disappear, entitlement and associated advantages fall apart.</p>',
          translatedHtml: translated,
          targetLanguage: 'Chinese',
        );
    expect(finding?.kind, TranslationResidualKind.cjkAdjacentLowercaseWord);
    expect(finding?.token, isNotEmpty);
  }
});

test('allows names acronyms URLs and spaced retained terms', () {
  final TranslationResidualFinding? finding =
      TranslationQuality.findSuspiciousHtmlResidual(
        sourceHtml:
            '<p>PayPal, Microsoft, UN, cyberspace and https://example.com remain relevant.</p>',
        translatedHtml:
            '<p>PayPal、Microsoft、UN、术语 cyberspace 与 https://example.com 仍然相关。</p>',
        targetLanguage: 'Chinese',
      );
  expect(finding, isNull);
});
```

- [ ] **步骤 2：运行测试确认局部混排尚未被检测**

运行：

```powershell
flutter test test/translation_quality_test.dart --plain-name "lowercase English words attached"
```

预期：FAIL，`finding` 为 `null`。

- [ ] **步骤 3：实现 CJK 紧贴检测**

在作品名节点从 DOM 副本移除后、长英文检测前调用：

```dart
final String? attachedWord = _cjkAdjacentLowercaseWord(translatedText);
if (attachedWord != null) {
  return TranslationResidualFinding(
    TranslationResidualKind.cjkAdjacentLowercaseWord,
    token: attachedWord,
  );
}
```

`_cjkAdjacentLowercaseWord` 先调用 `_stripNonLinguisticTokens` 去掉 URL 和邮箱，再用不依赖 lookbehind 的两个正则分支检测：

```dart
final RegExp attached = RegExp(
  r"(?:[a-z][a-z'-]{4,}[぀-ヿ㐀-鿿가-힯])|"
  r"(?:[぀-ヿ㐀-鿿가-힯][a-z][a-z'-]{4,})",
);
```

从命中内容中提取 `[a-z][a-z'-]{4,}` 作为安全日志 token。此规则只对中文、日文、韩文目标启用。

- [ ] **步骤 4：运行质量测试确认通过**

```powershell
flutter test test/translation_quality_test.dart
```

预期：全部通过。

- [ ] **步骤 5：提交局部混排检测**

```powershell
git add lib/features/translation/infrastructure/translation_quality.dart test/translation_quality_test.dart
git commit -m "fix: detect lowercase English leaks beside CJK text"
```

### 任务 3：翻译链路集成与真实 `p-2` 回归

**文件：**
- 修改：`lib/features/translation/infrastructure/epub/epub_chapter_translator.dart:3386`
- 修改：`test/repository_safety_test.dart`

- [ ] **步骤 1：添加批量路径一次接受合法书名的失败测试**

在 `repository_safety_test.dart` 增加一个记录请求次数的 Dio 适配器。它对包含真实结构形态的 `p-2` 返回：中文正文、源 `i` 节点中的原英文作品名、两个原脚注锚点。断言：

```dart
expect(adapter.fetchCount, 1);
expect(translated.single, contains('The 500-Year Delta'));
expect(translated.single, contains('href="part0023_split_006.html#ch06-en37"'));
expect(translated.single, contains('href="part0023_split_006.html#ch06-en38"'));
```

再增加局部混排响应：第一次返回 `entitlement概念`，第二次返回完整中文；断言请求发生重试，且最终结果不含 `entitlement`。

- [ ] **步骤 2：运行集成测试确认旧校验仍误拒绝合法标题**

```powershell
flutter test test/repository_safety_test.dart --plain-name "source-owned English work title"
```

预期：FAIL；旧 `_validateTranslatedBlockQuality` 仍使用纯文本入口并触发额外请求或抛出 `FormatException`。

- [ ] **步骤 3：接入 HTML 感知结果**

将 `_validateTranslatedBlockQuality` 的纯文本判断替换为：

```dart
final TranslationResidualFinding? finding =
    TranslationQuality.findSuspiciousHtmlResidual(
      sourceHtml: block.sourceHtml,
      translatedHtml: translatedHtml,
      targetLanguage: config.targetLanguage,
    );
if (finding == null) {
  return;
}
throw FormatException(finding.messageForBlock(block.id));
```

保留 `residualQualityCheck == false` 的早返回，不修改调用位置、结构锁、重试次数或缓存代码。

- [ ] **步骤 4：运行定向集成测试与安全测试**

```powershell
flutter test test/repository_safety_test.dart
flutter test test/translation_quality_test.dart
```

预期：全部通过；合法作品名只请求一次，局部漏翻会重试，脚注链接保持原值。

- [ ] **步骤 5：提交链路集成**

```powershell
git add lib/features/translation/infrastructure/epub/epub_chapter_translator.dart test/repository_safety_test.dart
git commit -m "fix: apply HTML-aware residual checks to EPUB blocks"
```

### 任务 4：完整验证、真实 API 验收和 Windows 编译

**文件：**
- 临时创建后删除：`test/_diagnose_html_residual_live_test.dart`
- 验证：`build/windows/x64/runner/Release/`

- [ ] **步骤 1：运行完整自动化验证**

```powershell
flutter test
flutter analyze lib test
git diff --check
```

预期：测试 0 失败；仅已有的可选真人/环境测试跳过；静态分析显示 `No issues found!`；`git diff --check` 无输出。

- [ ] **步骤 2：执行独立代码审查并修复 Critical/Important**

审查范围为本计划实现提交相对 `65e1742` 的差异，重点检查：作品名误豁免、斜体引文漏放、CJK 正则误报、脚注结构和缓存原子性。所有 Critical/Important 在继续前修复并重新运行定向测试。

- [ ] **步骤 3：用当前保存的 API 配置验收真实 `p-2`**

临时测试从环境变量读取 EPUB 路径、API 密钥和风格档案，不把密钥或完整响应写入文件。断言：

```dart
expect(translated.single, contains('The 500-Year Delta'));
expect(translated.single, isNot(contains('entitlement概念')));
expect(translated.single, isNot(contains('associated的')));
```

测试完成后用 `apply_patch` 删除临时测试，并运行 `git status --short` 确认无探针残留。

- [ ] **步骤 4：构建 Windows Release**

```powershell
flutter build windows --release
```

预期：生成 `build/windows/x64/runner/Release/epub_translator_flutter_clean.exe`，退出码为 0。

- [ ] **步骤 5：核验产物与本地 main 状态**

```powershell
Get-FileHash build/windows/x64/runner/Release/epub_translator_flutter_clean.exe -Algorithm SHA256
Get-FileHash build/windows/x64/runner/Release/data/app.so -Algorithm SHA256
git status --short --branch
```

记录两个哈希；确认工作区干净。本地 `main` 不自动推送 GitHub。
