<div align="center">
  <img src="assets/icons/app_icon.png" width="112" height="112" alt="页渡 FolioFerry 图标：书页化作渡船" />
  <h1>页渡 · FolioFerry</h1>
  <p><strong>让好书跨越语言。</strong><br />Great books, in your language.</p>
</div>

[![Release](https://img.shields.io/github/v/release/zhao922-bot/epub-translator-flutter)](https://github.com/zhao922-bot/epub-translator-flutter/releases/latest)
[![CI](https://github.com/zhao922-bot/epub-translator-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/zhao922-bot/epub-translator-flutter/actions/workflows/ci.yml)
![Windows](https://img.shields.io/badge/Windows-x64-162B43?logo=windows)
![Android](https://img.shields.io/badge/Android-APK-162B43?logo=android)
[![License](https://img.shields.io/github/license/zhao922-bot/epub-translator-flutter)](LICENSE)

**页渡是一款面向 Windows 和 Android 的 AI 电子书翻译工具。** 导入 EPUB、连接自己的模型接口，即可按章节翻译整本书，检查疑似漏译，并导出中文、其他目标语言或双语对照的 EPUB。

从 **1.7** 开始，EPUB Translator Flutter 正式更名为 **页渡 / FolioFerry**，采用“书页化作渡船”的新图标。GitHub 仓库地址保持不变。

## 下载与升级

当前版本：**1.7.3+56**。安装包与 SHA-256 校验文件见 [1.7.3 发布页](https://github.com/zhao922-bot/epub-translator-flutter/releases/tag/v1.7.3)。

| 平台 | 下载 | 使用方式 |
| --- | --- | --- |
| Windows 10 / 11 x64 | [EXE 安装包](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.7.3/folioferry-v1.7.3-windows-x64-setup.exe) | 为当前用户安装，可从开始菜单启动 |
| Windows 便携版 | [ZIP 压缩包](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.7.3/folioferry-v1.7.3-windows-x64.zip) | 完整解压后运行 `FolioFerry.exe`，保留同目录 DLL 与 `data` 文件夹 |
| Android | [APK 安装包](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.7.3/folioferry-v1.7.3-android.apk) | 中文系统显示“页渡”，其他系统显示“FolioFerry” |

- **Android 升级**：沿用 v1.6.31 至 v1.7.2 的应用标识与发布签名，可覆盖安装这些版本，无需为更名卸载软件。更早的签名不同版本需先备份设置与数据。
- **Windows 升级**：安装包沿用原应用标识，已有安装会继续使用原安装目录；设置、密钥、任务记录和缓存继续从原数据位置读取。
- Windows 安装包目前未进行商业代码签名。若系统提示未知发布者，请核对下载来源及发布页提供的 SHA-256。

## 五步开始

1. **配置接口**：打开“设置”，选择 DeepSeek 或 Custom，填写接口地址、API Key 和模型名称。Custom 用于兼容 OpenAI Chat Completions 格式的服务。
2. **测试连接**：确认所填模型能够返回正常文本；API Key 和服务商用量由你自行提供与管理。
3. **导入 EPUB**：检查章节结构，选择需要翻译的章节，查看文本块数量与粗略工作量估算。
4. **确认风格并翻译**：按需生成、修改书籍风格档案，再开始翻译。中断后可继续，符合当前配置的有效缓存会被复用。
5. **检查并导出**：查看完成状态、警告和可选复核建议，将导出的 EPUB 保存到下载目录或交给阅读器打开。

首次使用建议先选一个短章节，确认模型、译文风格与费用符合预期。

## 主要功能

| 功能 | 能做什么 |
| --- | --- |
| 整书翻译 | 按章节与文本块组织请求，结合上下文、术语和滚动摘要协助保持连贯 |
| 书籍风格档案 | 从开篇内容分析文体与语气，由你确认或修改后用于后续翻译 |
| 结构与残留检查 | 检查异常回复、疑似漏译和结构问题，重试失败块并记录原因 |
| 缓存与续传 | 复用有效译文，中断后继续；支持在有效缓存基础上切换单语与双语导出 |
| 译文语义复核 | 检查数字、术语及语义风险；可选择自动应用经过独立验证的修正 |
| 人工校对 | 搜索原文、译文或段落编号，确认、修改并导出独立校对版 |
| EPUB 导出 | 尽量保留目录、章节顺序、图片、链接、脚注、代码、公式与原排版 |
| 用量记录 | 展示请求次数、接口返回的输入/输出 token、耗时和缓存命中情况 |

Android 翻译期间使用前台服务显示进度。系统省电、后台时限和强制停止仍可能中断任务，恢复后可继续处理未完成部分。

## 如何理解“完成但有警告”

进度达到 **100%** 表示本次任务流程已处理完成；部分段落仍可能没有通过检查。页渡会在日志中记录章节、文本块编号、失败原因，以及保留的是原文还是待复核译文。

你可以查看这些段落，再决定重试或人工校对。残留规则允许有原文依据的专名、公司名单及附带中文释义的外语短语；它只能识别部分风险，**不能证明整本书的翻译完全准确**。

## 可选复核与人工校对

“译文语义复核”默认关闭。开启后，可优先检查风险段落或检查全部段落，并设置额外请求次数与 token 预算。

- 默认仅保留建议。需要自动修正时，再开启“自动应用已验证的修正”：候选须通过原文证据、HTML 与一致性检查，并由同一配置模型的另一独立请求验证，才会写入本次译文和缓存。
- 自动修正保留原文、修改前后内容和验证理由。未通过验证或预算不足的建议仍保留，不会被强制应用；独立验证会增加 API 请求。
- 预算不足时可使用“重试上次未通过的复核”；未命中可复用草稿缓存的段落可能重新翻译，并产生额外用量。
- 在“运行概览”或“任务历史”打开检查结果，逐条选择建议，再导出新的复核版 EPUB。
- 也可搜索任意已翻译段落进行人工校对。复杂行内排版采用精确文字替换，以保留链接、强调和脚注。
- 人工选择建议和校对导出时，原译本与翻译缓存保留；取消选择后可重新导出。基准译本变化时，旧建议不会被直接套用。
- 译本旁的 `.epub.quality.json` 包含复核记录及重新导出所需内容，请与译本一起保存。

## 模型、费用与数据

页渡不附带模型额度。翻译质量、速度、可用模型和费用取决于你选择的服务商与配置。

- 待翻译文本，以及启用风格分析、摘要或复核时所需的书籍片段，会发送到你配置的 API 服务。
- API Key 使用平台提供的安全存储机制或加密保护；日志对常见凭据进行脱敏。请勿将密钥写入公开仓库。
- 书籍、设置、历史记录和缓存由应用保存在本机；导出的诊断与复核文件可能包含书籍内容。
- 工作量估算与 token 预算是本地参考值；界面统计以服务商返回的 usage 为依据，未返回的用量标记为未知，最终费用以服务商账单为准。
- 第三方接口的“兼容”程度可能不同。可以在高级设置中调整输出上限及受服务商支持的推理强度。

## 支持范围

- 当前提供 **Windows x64** 与 **Android APK**；仓库中的 macOS / Linux 工程尚不提供本轮验证过的安装包。
- 输入为无 DRM 的 EPUB；无法处理受 DRM 保护的书籍。
- 原书已有的格式问题、复杂 CSS、字体及阅读器差异，仍可能影响最终显示。
- 建议保留原始 EPUB，并使用有权处理的书籍；重要内容需要人工核对。

## 从源码运行与构建

发布环境使用 **Flutter 3.44.0 / Dart 3.12.0**。确保 `flutter` 和 `dart` 命令可用。

```powershell
git clone https://github.com/zhao922-bot/epub-translator-flutter.git
cd epub-translator-flutter
flutter pub get
flutter run -d windows
```

Windows 需要 Visual Studio 的“使用 C++ 的桌面开发”组件。打包脚本会附带必要的 VC++ 运行库；请使用 64 位 PowerShell，并将仓库放在较短的路径中。

```powershell
# Windows 便携 ZIP
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1

# Windows EXE 安装包：需 Inno Setup 6.3+，先完成上述打包
ISCC /DAppVersion=1.7.3 tool\windows_installer.iss

# Android：需 Android SDK 与 JDK（发布使用 JDK 21）
# 将 android/key.properties.example 复制为 android/key.properties，填写本机签名配置
flutter build apk --release
```

签名文件与密码不要提交到 Git。发布构建缺少签名配置时会报错，不会自动使用调试签名。

### 本地 EPUB 维护工具

在已执行 `flutter pub get` 的源码目录中运行：

```powershell
dart run tool/repair_epub_xhtml.dart input.epub repaired.epub
dart run tool/rebuild_translated_epub.dart input.epub rebuilt.epub
```

工具通过本机 Flutter 测试运行时执行现有 EPUB 处理逻辑，需要 Flutter SDK 可用。修复工具整理 XHTML，重建工具重新封装现有内容；两者均不调用翻译 API，并拒绝覆盖输入或已有输出。省略参数会打印用法并以状态码 64 退出。

### 图标资源

批准的原图保存在 `assets/branding/folioferry-master.png`。以下脚本从同一原图生成应用内 PNG、Android 各密度图标、自适应图标素材、Windows 多尺寸 ICO 与 macOS 图标：

```powershell
powershell -ExecutionPolicy Bypass -File tool\generate_app_icons.ps1
```

Android 自适应图标由系统套用圆形或圆角蒙版；图案留有安全边距。图标资源的生成只调整尺寸和编码，不重新设计图案。

### 开发验证

```powershell
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
```

GitHub CI 执行静态分析、完整测试，并使用 EPUBCheck 5.4.0 验证导出样本。需要真实服务的测试默认跳过；历史实书测试、性能与回归结果见 [更新日志](CHANGELOG.md)。

为兼容旧版数据，Dart 包名、Android applicationId、密钥服务标识及桌面数据目录保留原值。更名时请勿将这些持久化标识与显示名称一并替换。

## English

**FolioFerry** is an AI-powered EPUB translator for Windows and Android. Connect your own compatible API, select chapters, review the book's style, and export a translated or bilingual EPUB. Valid translations can be reused through caching and resume support. Optional semantic review can retain suggestions or, when explicitly enabled, automatically apply source-supported corrections after a separate verification request to the configured model. Manual review and export remain available. Verification and retries can incur additional API usage.

Version 1.7 introduces the **FolioFerry / 页渡** name and the book-and-ferry icon. Existing application identities and data locations are retained for upgrade compatibility. See [Releases](https://github.com/zhao922-bot/epub-translator-flutter/releases/latest) for downloads.

## 反馈与许可

- [提交问题或建议](https://github.com/zhao922-bot/epub-translator-flutter/issues)：请注明版本、系统与复现步骤，分享日志前检查是否含私人书籍内容或凭据。
- [更新日志](CHANGELOG.md)
- 项目使用 [MIT License](LICENSE)。
