# EPUB Translator Flutter

![GitHub Release](https://img.shields.io/github/v/release/zhao922-bot/epub-translator-flutter)
![Windows](https://img.shields.io/badge/Windows-x64-0078D6?logo=windows&logoColor=white)
![Android](https://img.shields.io/badge/Android-APK-3DDC84?logo=android&logoColor=white)
![License](https://img.shields.io/github/license/zhao922-bot/epub-translator-flutter)

整本书的 AI 翻译工具：解析 EPUB 结构 → 生成可确认的风格档案 → 按块批量翻译 → 质量校验 → 输出兼容的译本。支持断点续传，中断不用从头开始。

## 下载安装

| 平台 | 下载 | 说明 |
|------|------|------|
| Windows x64 | [v1.4.0 便携包](https://github.com/zhao922-bot/epub-translator-flutter/releases/tag/v1.4.0) | 解压后运行 `epub_translator_flutter_clean.exe`（需同目录 DLL 与 `data` 文件夹）；v1.4.1 的 Windows 包待补充 |
| Android | [v1.4.1 APK](https://github.com/zhao922-bot/epub-translator-flutter/releases/latest) | 正式签名，可覆盖升级 |

> Windows 首次运行可能被 SmartScreen 拦截（暂未商业代码签名），选择"仍要运行"即可。

## 核心能力

- **整书工作流**：章节选择、工作量预估、按块批量翻译，上下文与术语锁定保证前后连贯
- **风格档案**：翻译前采样分析文体语气，展示置信度供你确认修改，AI 误判不会扩散到全书
- **质量校验**：漏翻、源语言残留、异常输出自动检测重试；失败块可保留原文，输出可用译本
- **断点续传**：中断后从缓存继续；Android 有前台服务，灭屏或切后台翻译不中断
- **EPUB 兼容**：保留图片、目录、章节顺序与排版，输出前校验 XML，降低损坏概率
- **隐私**：Windows 下 API Key 系统级加密存储，日志自动脱敏；不内置、不上传任何密钥

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

## 从源码构建

需要 Flutter 3.44+ / Dart 3.12+：

```powershell
flutter pub get
flutter build windows --release   # 输出 build\windows\x64\runner\Release\
flutter build apk --release       # 需配置 android/key.properties 签名
```

## 已知边界

- 不支持 DRM 保护的 EPUB；极少数自定义脚本、字体或复杂 CSS 在不同阅读器表现可能不同
- 翻译质量、速度、费用取决于模型与服务商；建议保留原始 EPUB，先用短章节验证

## 更多

- [更新日志](CHANGELOG.md)
- 本项目使用 [MIT License](LICENSE)
