# EPUB Translator Flutter

![GitHub Release](https://img.shields.io/github/v/release/zhao922-bot/epub-translator-flutter)
![Windows](https://img.shields.io/badge/Windows-x64-0078D6?logo=windows&logoColor=white)
![Android](https://img.shields.io/badge/Android-APK-3DDC84?logo=android&logoColor=white)
![License](https://img.shields.io/github/license/zhao922-bot/epub-translator-flutter)

整本书的 AI 翻译工具：解析 EPUB 结构 → 生成可确认的风格档案 → 按块批量翻译 → 质量校验 → 输出兼容的译本。支持断点续传，中断不用从头开始。

## 下载安装

当前源码版本：**1.4.8+12**。本次更新包含 HTML 重建脚注 marker 换位、重试画像阶段取消、spine media-type 参数、专名误判、语言标记、历史记录与 Android/Windows 平台修复，详见 [更新日志](CHANGELOG.md)。

以下为目前已发布的安装包；**尚未发布 v1.4.8 安装包**，体验本次修复请从源码构建。

| 平台 | 下载 | 说明 |
|------|------|------|
| Windows x64 | [v1.4.0 便携包](https://github.com/zhao922-bot/epub-translator-flutter/releases/tag/v1.4.0) | 解压后运行 `epub_translator_flutter_clean.exe`，保留同目录 DLL 与 `data` 文件夹 |
| Android | [v1.4.2 APK](https://github.com/zhao922-bot/epub-translator-flutter/releases/tag/v1.4.2) | 下载该版本发布页中的 APK 安装 |

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

## 从源码构建

需要 Flutter 3.44+ / Dart 3.12+：

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
# 产物: dist\epub-translator-flutter-v<版本>-windows-x64.zip（便携包）
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

v1.4.8 修复集本地验证：**1108 项测试通过、17 项依赖环境的测试跳过**，静态分析无问题；Android debug APK 构建通过（Windows 原生构建未验证）。测试覆盖模拟 API 和真实 EPUB 打包，未调用收费接口；不等同于所有设备与阅读器的兼容性认证。

```powershell
$env:LIVE_TRANSLATION_E2E='0'
flutter analyze --no-pub
flutter test --no-pub
```

## 更多

- [更新日志](CHANGELOG.md)
- 本项目使用 [MIT License](LICENSE)
