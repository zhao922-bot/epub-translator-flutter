# EPUB Translator Flutter

![GitHub Release](https://img.shields.io/github/v/release/zhao922-bot/epub-translator-flutter)
![Windows](https://img.shields.io/badge/Windows-x64-0078D6?logo=windows&logoColor=white)
![Android](https://img.shields.io/badge/Android-APK-3DDC84?logo=android&logoColor=white)
![License](https://img.shields.io/github/license/zhao922-bot/epub-translator-flutter)

整本书的 AI 翻译工具：解析 EPUB 结构 → 生成可确认的风格档案 → 按块批量翻译 → 质量校验 → 输出兼容的译本。支持断点续传，中断不用从头开始。

## 下载安装

当前版本：**1.6.35+51**。修复带中文释义的格言误报，拦截模型非译文回复，完善重试回退、旧缓存检查与逐块失败诊断。详见 [更新日志](CHANGELOG.md)。

安装包与校验值见 [v1.6.35 发布页](https://github.com/zhao922-bot/epub-translator-flutter/releases/tag/v1.6.35)。

| 平台 | 下载 | 说明 |
|------|------|------|
| Windows x64 | [EXE 安装包](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.6.35/epub-translator-flutter-v1.6.35-windows-x64-setup.exe) / [便携 ZIP](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.6.35/epub-translator-flutter-v1.6.35-windows-x64.zip) | 安装包为当前用户安装；便携包解压后运行 `epub_translator_flutter_clean.exe`，保留同目录 DLL 与 `data` 文件夹 |
| Android | [v1.6.35 APK](https://github.com/zhao922-bot/epub-translator-flutter/releases/download/v1.6.35/epub-translator-v1.6.35-android.apk) | 沿用 v1.6.31–v1.6.34 发布签名，可覆盖升级；更早的旧签名版本需先备份设置与数据，再卸载并安装 |

> Windows 首次运行可能被 SmartScreen 拦截（暂未商业代码签名），选择"仍要运行"即可。

## 核心能力

- **整书工作流**：章节选择、工作量预估、按块批量翻译，上下文与术语锁定保证前后连贯
- **风格档案**：翻译前采样分析文体语气，展示置信度供你确认修改，AI 误判不会扩散到全书
- **质量校验**：漏翻、源语言残留、异常输出自动检测重试；失败块可保留原文，输出可用译本
- **断点续传**：中断后复用有效缓存；重试保留章节选择。Android 使用前台服务维持后台任务，仍可能受系统省电策略限制
- **EPUB 兼容**：保留图片、目录、章节顺序与排版，输出前校验 XML，降低损坏概率
- **内容保护**：保留表格单元格和标题属性、正文 CDATA、代码与公式；术语替换跳过受保护内容，双语导出避免重复锚点并保留源语言元数据
- **源文件校验**：检查后若 EPUB 内容发生变化，翻译或导出会提示重新检查，避免混用旧章节与新文件
- **隐私**：Windows 下 API Key 系统级加密存储，日志自动脱敏；API Key 用于向你配置的服务商认证，不内置服务商密钥

## 使用流程

1. 在"设置"页选择 DeepSeek 或 Custom，填写接口地址、API Key 和模型
2. 导入无 DRM 的 EPUB，选择章节，查看块数与费用预估
3. 生成风格档案，检查 AI 的判断并按需修改
4. 开始翻译；完成后将译本导入阅读器验收

<details>
<summary>API 配置说明</summary>

- **DeepSeek**：默认接口 `https://api.deepseek.com`，默认模型 `deepseek-v4-flash`
- **Custom**：兼容 OpenAI Chat Completions 格式的第三方服务，配置独立保存，切换不互相覆盖
- 第三方服务即使声称兼容，也可能在返回格式、限流、模型行为上有差异，建议先用短章节验证
- API 请求会把待翻译文本发往你配置的服务商，请确认其隐私政策与计费规则

</details>

### 模型与质量设置

“设置 → 翻译 → 高级调优”可调整模型推理强度和单次输出上限。自动模式已适配 GLM-5.3/Flash，其他模型保留服务商默认行为；手动强度需要接口支持。

可选的“译文语义复核”默认关闭。开启后默认优先检查有数字、币种、术语或语义风险的段落，也可选择全部段落。数字检查识别阿拉伯数字、常见英文数字词及中文数字；人物检查结合锁定术语和书籍记忆。检查结果是待核实的提示，不会自动改写译文。

复核模型需要提供明确的原文依据；文风润色、缺少依据和不确定的改写会被拒绝，并标记未完成复核。通过结构校验的建议也需要用户确认：在“运行概览”或“任务历史”打开“查看检查结果与修改建议”，逐条选择后导出新的复核版 EPUB。取消选择并再次导出可撤销修改，原译本和翻译缓存保留。基准译本发生变化时拒绝套用旧建议。报告和原译本需要保留在原位置。

复核同时受额外请求次数和预估 token 预算限制。预算按输入 UTF-8 字节及最大输出额度保守预留，达到任一上限即停止新增复核，保留草稿供续跑；它是本地控制值，不代表服务商账单。重新运行时复用已完成的复核及修改建议，恢复尚未完成的工作。

风格、正文及书名有效缓存可跨单双语导出复用；运行概览和历史记录保存本次 API 请求量、服务商返回的输入/输出 token、任务耗时及各阶段累计请求耗时。并发请求耗时会重叠；未返回 usage 的请求标为用量未知。质量建议和未复核清单保存在译本旁的 `.epub.quality.json`，其中包含用于重新导出的章节内容。

审阅页支持“人工校对任意段落”，可搜索原文、译文或段落编号，修改或确认译文后本地导出。带行内排版的段落使用精确文字替换，保留链接、强调和脚注。人工核对与模型复核分别记录；模型复核失败的原因不会被人工操作改写成通过。

## 从源码构建

需要 Flutter 3.44+ / Dart 3.12+：

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
# 产物: dist\epub-translator-flutter-v<版本>-windows-x64.zip（便携包）
# 可选 EXE 安装包：先安装 Inno Setup 6.3+ 并将 ISCC 加入 PATH
ISCC /DAppVersion=1.6.35 tool\windows_installer.iss
flutter build apk --release       # 需配置 android/key.properties 签名
```

> Windows 便携包说明：`flutter build windows` 的输出不含 VC++ 运行库（`msvcp140.dll` 等），
> 在干净的 Win10/11 上会启动失败。`tool\package_windows.ps1` 会自动从本机查找并附带这些 DLL；
> 若本机没有安装 Visual Studio / VC++ Redistributable，脚本会明确报错并给出下载链接。
> 打包前请确认两点：① 用 64 位 PowerShell 运行脚本（32 位会直接报错并给出正确的重跑命令）；
> ② 仓库路径不要太深（超过约 200 字符脚本会拒绝打包，请移到如 `C:\src\epub-translator-flutter` 的浅目录），
> 否则 PowerShell 5.1 的 `Compress-Archive` 会因长路径莫名失败。

## 已知边界

- 不支持 DRM 保护的 EPUB；极少数自定义脚本、字体或复杂 CSS 在不同阅读器表现可能不同
- 翻译质量、速度、费用取决于模型与服务商；建议保留原始 EPUB，先用短章节验证
- v1.4.4 更新了表格单元格、表格标题和含代码/公式等受保护内容的缓存键；对应旧缓存可能需要重新翻译，其他未受影响的块仍可复用

## 开发验证

v1.6.35 在 Windows x64、Flutter 3.44.0 / Dart 3.12.0 下验证：**2625 项测试通过、24 项环境／显式运行用例跳过、0 失败**，静态分析无问题。覆盖非译文回复拦截、格言释义、重试回退、逐块诊断、缓存复用、人工编辑、复杂 EPUB 导出和长书恢复。对用户提供的原书及译本离线核对 1124 块，定位 4 处误报和 2 处受影响正文；独立修正版通过残留规则检查，EPUBCheck 无新增问题，原书已有格式错误仍保留说明。本轮未调用付费模型接口；残留检查不等同于全书逐句语义校对。此前真实 API 翻译及性能验证记录见更新日志。

```powershell
$env:LIVE_TRANSLATION_E2E='0'
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
```

## 更多

- [更新日志](CHANGELOG.md)
- 本项目使用 [MIT License](LICENSE)
