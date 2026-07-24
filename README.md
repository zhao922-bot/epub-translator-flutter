# EPUB Translator Flutter

一款面向整本书翻译的 Flutter EPUB 工具。它不只是把文本发送给模型，而是围绕 EPUB 结构解析、风格确认、上下文翻译、质量校验、断点续传和兼容性输出，提供完整的书籍翻译工作流。

当前版本：**v1.2.0**

- Windows x64：已验证并发布完整便携包。
- Android：保留源码与构建支持；v1.2.0 暂不发布 APK，待完成真机全链路验证后再提供。

## 核心能力

### 面向整本书的翻译流程

- 读取 EPUB 书脊、章节、目录、图片和样式，识别真正需要翻译的正文块。
- 支持按章节选择、工作量与批次数预估，以及正式翻译前预览。
- 按块批量调用模型，并使用上下文、锁定术语、书籍记忆和缓存维持前后连贯。
- 对漏翻、源语言残留、异常短输出、格式破坏等情况进行校验和重试。
- 翻译中断后可从历史任务和缓存继续，避免整本书从头开始。

### 可确认、可编辑的风格档案

软件会在正式翻译前，从有代表性的正文、前言和中段章节中采样，分析书籍类型、语气、叙事视角、目标读者、术语策略等信息。目录、索引、版权页等低价值页面会尽量排除。

生成结果和置信度会先展示给用户。用户可以修改或补充风格档案，确认后才用于整本书翻译，因此 AI 的误判不会被直接锁死并扩散到全书。

### EPUB 输出兼容性

- 保留原书图片、目录、章节顺序、链接与大部分排版结构。
- 同步更新 OPF、NCX、HTML 目录和文档语言信息。
- 输出前检查 XML/XHTML 是否可解析，降低损坏 EPUB 的概率。
- 针对中文阅读优化段落排版、行高、首字下沉、小型大写和深色模式颜色继承。
- 修复空锚点、自闭合标签和英文装饰性首字母引起的目录失效、下划线、文字重叠或中英文混排问题。

### 稳定性与隐私

- 任务运行期间锁定 API、模型和关键翻译参数，避免误触改变正在执行的任务。
- DeepSeek 与 Custom 配置独立保存，切换提供商不会互相覆盖。
- Windows 下 API Key 使用系统级加密存储；日志、错误和历史记录会进行密钥脱敏。
- 临时文件与最终输出分离；失败或取消不会覆盖已有 EPUB。
- 软件不会内置、上传或提交任何用户 API Key。

## 使用流程

1. 在“设置”中选择 DeepSeek 或 Custom，填写接口地址、API Key 和模型名称。
2. 导入无 DRM 的 EPUB，并等待结构检查完成。
3. 选择需要翻译的章节，查看块数、批次数、Token 和时间预估。
4. 生成风格档案，检查 AI 的判断并按需修改。
5. 开始翻译；可随时查看进度、诊断信息或中断任务。
6. 完成后打开输出目录，将译后 EPUB 导入阅读器验收。

## API 配置

### DeepSeek

- 默认接口：`https://api.deepseek.com`
- 默认模型：`deepseek-v4-flash`

### Custom

用于兼容采用 OpenAI Chat Completions 请求格式的第三方服务。Custom 的接口地址、API Key 和模型名称会独立保存，不会被 DeepSeek 预设覆盖。

第三方服务即使声称兼容，也可能在返回格式、上下文长度、限流规则或模型行为上存在差异。建议先翻译短章节，通过质量校验后再进行整书任务。

> API 请求会发送书籍中待翻译的文本及必要上下文到你配置的服务商。请在使用前确认服务商的隐私政策和计费规则。

## Windows 安装

从 [GitHub Releases](https://github.com/zhao922-bot/epub-translator-flutter/releases/latest) 下载：

`epub-translator-flutter-v1.2.0-windows-x64-portable.zip`

完整解压 ZIP 后运行 `epub_translator_flutter_clean.exe`。请不要只单独复制 EXE；Flutter Windows 程序还需要同目录中的 DLL 和 `data` 文件夹。

当前发布包面向 64 位 Windows。由于应用暂未进行商业代码签名，Windows SmartScreen 首次运行时可能显示安全提醒。

## v1.2.0 重点更新

- 新增翻译前风格档案生成、置信度展示和用户编辑确认。
- 优化风格采样，避免目录、索引等页面干扰书籍类型判断。
- 修复 DeepSeek / Custom 配置切换丢失，以及翻译途中误改配置的问题。
- 加强任务历史续传、启动恢复、缓存失效和取消状态处理。
- 改进第三方兼容接口的响应清理、源语言残留判断和重试逻辑。
- 修复零文本章节被推荐、目录无法跳转、异常下划线、文字重叠、蓝色正文和英文首字母残留等 EPUB 兼容性问题。
- 重做主要工作台与设置界面，统一字体、间距、控件状态和错误反馈。

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

## 从源码构建

建议使用 Flutter 3.44 或更高版本。项目要求 Dart 3.12 或更高版本。

```powershell
flutter pub get
flutter analyze lib test tool
flutter test
flutter build windows --release
```

Windows 构建输出位于：

```text
build\windows\x64\runner\Release\
```

Android 构建命令仍可使用，但 v1.2.0 未将 APK 列为正式验证和发布产物：

```powershell
flutter build apk --release
```

## 项目结构

```text
lib/features/preview/       EPUB 导入、结构检查与章节选择
lib/features/settings/      API、模型和翻译参数配置
lib/features/translation/   风格档案、翻译编排、质量校验与 EPUB 回写
lib/shared/                 主题、本地化与通用组件
test/                       离线回归测试与可选真实 API 测试
tool/                       EPUB 诊断与修复工具
```

## 已知边界

- 不支持受 DRM 保护的 EPUB。
- 极少数出版商自定义脚本、字体或复杂 CSS 可能在不同阅读器中表现不同。
- 翻译质量、速度和费用受模型、接口服务商、网络和原书结构影响。
- 建议保留原始 EPUB，并先用短章节验证所选模型。

## 许可

本项目使用 [MIT License](LICENSE)。
