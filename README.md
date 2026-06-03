# EPUB Translator Flutter

一款功能强大的 EPUB 电子书翻译工具，使用 Flutter 框架重构，支持多平台运行。

## ✨ 项目背景

本项目是从 Python 版本 ([epub-translator](https://github.com/zhao922-bot/epub-translator)) 完全重构为 Flutter 版本，实现了以下改进：

- 🚀 **跨平台支持** - 从单一平台扩展到 Windows、macOS、Linux、Android、iOS
- 🎨 **现代化 UI** - Material Design 3 界面，深色/浅色主题自动切换
- ⚡ **性能提升** - Dart 语言原生性能，更快的启动速度和响应速度
- 📱 **原生体验** - 响应式设计，适配各种屏幕尺寸

---

## 🎯 核心功能

### 📚 EPUB 翻译
- ✅ 智能章节识别和分割
- ✅ 并发翻译支持（可配置 1-8 个并发）
- ✅ 翻译进度实时显示
- ✅ 翻译日志记录

### 🌍 多语言支持
- ✅ 支持任意源语言到目标语言的翻译
- ✅ 双语对照翻译模式（原文 + 译文）
- ✅ 中英文界面切换

### 🔌 API 集成
- ✅ 支持 DeepSeek API（默认）
- ✅ 可配置的 API 端点和密钥
- ✅ 连接测试功能
- ✅ 自动重试机制（可配置重试次数和延迟）

### ⚙️ 灵活配置
- ✅ 分块大小调节（1000-12000 字符）
- ✅ 并发数控制（1-8）
- ✅ 超时时间设置（30-300 秒）
- ✅ 输出文件后缀自定义

### 📦 导出功能
- ✅ 导出翻译后的 EPUB 文件
- ✅ 保存到下载目录
- ✅ 打开输出文件夹

---

## 🔄 Python vs Flutter 对比

| 特性 | Python 版本 | Flutter 版本 |
|------|-----------|-------------|
| **运行平台** | 仅限 Windows/macOS/Linux | 全平台（包括移动端） |
| **UI 框架** | PyQt/Tkinter（较旧） | Material Design 3（现代化） |
| **启动速度** | 较慢（解释型语言） | ⚡ 极快（原生编译） |
| **内存占用** | 较高 | ✅ 优化内存管理 |
| **并发性能** | 受 GIL 限制 | ✅ 真正的多线程 |
| **响应式设计** | ❌ 固定布局 | ✅ 自适应各种屏幕 |
| **主题支持** | 有限 | ✅ 深色/浅色主题 |
| **代码维护** | 复杂 | ✅ 模块化、易维护 |
| **国际化** | 手动实现 | ✅ Riverpod 状态管理 |
| **状态管理** | 全局变量 | ✅ 响应式状态管理 |

### 🚀 Flutter 版本优势

#### 1. **真正的跨平台**
- 一套代码库运行在 5 个平台
- 原生性能，无跨平台性能损失
- 统一的用户体验

#### 2. **现代化架构**
- **Riverpod** 状态管理：响应式、类型安全、易于测试
- **GoRouter** 路由管理：声明式路由，深度链接支持
- **Feature-based** 架构：模块化、易于扩展

#### 3. **更好的性能**
- Dart AOT 编译为原生代码
- 更快的启动速度（< 1 秒）
- 更低的内存占用
- 真正的多线程并发翻译

#### 4. **开发体验**
- Hot Reload 即时预览
- 强大的类型系统
- 优秀的 IDE 支持
- 完整的测试框架

#### 5. **用户体验**
- Material Design 3 设计语言
- 响应式布局，适配手机、平板、桌面
- 流畅的动画和过渡效果
- 原生手势支持

---

## 📸 界面预览

```
┌─────────────────────────────────────────┐
│  🎯 翻译工作台                           │
├─────────────────────────────────────────┤
│  📁 输入文件: book.epub                 │
│  📂 输出目录: /output                    │
│  🌍 目标语言: Chinese                   │
│  📖 双语对照: [关闭]                     │
│                                         │
│  [检查 EPUB]  [翻译选中章节]              │
├─────────────────────────────────────────┤
│  📊 翻译概览                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━ 75%            │
│  章节: 10/13 | 字符: 45,230 | 时间: 2:30 │
├─────────────────────────────────────────┤
│  📝 翻译日志                             │
│  14:30:01 ✅ 第1章翻译完成               │
│  14:30:15 ✅ 第2章翻译完成               │
│  14:30:28 ⏳ 第3章翻译中...              │
└─────────────────────────────────────────┘
```

---

## 🛠️ 技术栈

### 核心框架
- **Flutter 3.12+** - UI 框架
- **Dart 3.12+** - 编程语言

### 状态管理
- **flutter_riverpod** - 响应式状态管理
- **go_router** - 声明式路由

### 网络和 IO
- **dio** - HTTP 客户端
- **archive** - EPUB 文件处理
- **html/xml** - 内容解析

### 工具库
- **path** - 路径处理
- **crypto** - 加密支持
- **logger** - 日志记录

---

## 🚀 快速开始

### 前置要求

- Flutter SDK 3.12+
- Dart SDK 3.12+
- 任一目标平台的开发环境（Windows/macOS/Linux/Android/iOS）

### 安装

```bash
# 克隆仓库
git clone https://github.com/zhao922-bot/epub-translator-flutter.git
cd epub-translator-flutter

# 安装依赖
flutter pub get

# 运行应用
flutter run
```

### 构建发布版本

```bash
# Windows
flutter build windows

# macOS
flutter build macos

# Linux
flutter build linux

# Android
flutter build apk

# iOS
flutter build ios
```

---

## 📖 使用指南

### 1️⃣ 配置 API

1. 打开应用，进入 **设置** 页面
2. 输入 API 端点（默认：`https://api.deepseek.com`）
3. 输入 API 密钥
4. 选择模型（默认：`deepseek-chat`）
5. 点击 **测试连接** 验证配置

### 2️⃣ 翻译 EPUB

1. 进入 **翻译工作台** 页面
2. 选择输入的 EPUB 文件
3. 选择输出目录
4. 设置目标语言
5. 点击 **检查 EPUB** 查看章节信息
6. 选择要翻译的章节
7. 点击 **翻译选中章节**

### 3️⃣ 导出翻译

1. 翻译完成后，点击 **导出 EPUB**
2. 或点击 **保存到下载目录**
3. 翻译后的文件会自动命名（默认后缀：`_translated`）

---

## ⚙️ 配置说明

### 翻译参数

| 参数 | 范围 | 默认值 | 说明 |
|------|------|--------|------|
| `chunkSize` | 1000-12000 | 3000 | 每次翻译的字符数 |
| `maxConcurrent` | 1-8 | 3 | 并发翻译数 |
| `timeoutSeconds` | 30-300 | 120 | 翻译超时时间 |
| `maxRetries` | 1-6 | 3 | 失败重试次数 |
| `retryDelaySeconds` | 1-15 | 5 | 重试间隔时间 |
| `disableThinking` | true/false | true | 禁用 AI 思考模式 |

### 界面语言

- 🇺🇸 English
- 🇨🇳 中文

---

## 📁 项目结构

```
lib/
├── app/                          # 应用配置
│   ├── app.dart                 # 应用入口
│   ├── routes.dart              # 路由配置
│   └── theme/                   # 主题配置
├── features/                     # 功能模块
│   ├── jobs/                    # 任务管理
│   │   ├── domain/models/      # 数据模型
│   │   ├── application/        # 业务逻辑
│   │   └── presentation/       # UI 表现层
│   ├── preview/                 # 预览功能
│   ├── settings/                # 设置页面
│   └── translation/            # 翻译核心功能
│       ├── domain/             # 领域层（模型、仓库接口）
│       ├── application/        # 应用层（控制器）
│       ├── infrastructure/     # 基础设施层（实现）
│       └── presentation/       # 表现层（UI）
└── shared/                      # 共享组件
    ├── localization/           # 国际化
    ├── models/                 # 共享模型
    ├── platform/               # 平台相关
    └── widgets/                # 通用组件
```

---

## 🧪 测试

```bash
# 运行所有测试
flutter test

# 运行特定测试文件
flutter test test/widget_test.dart

# 生成测试覆盖率报告
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
```

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 开发流程

1. Fork 项目
2. 创建功能分支 (`git checkout -b feature/新功能`)
3. 提交更改 (`git commit -m '添加新功能'`)
4. 推送到分支 (`git push origin feature/新功能`)
5. 创建 Pull Request

### 代码规范

- 遵循 Dart 官方代码规范
- 使用 `flutter analyze` 检查代码质量
- 确保所有测试通过

---

## 📝 更新日志

### v1.0.0 (2026-06-03)
- 🎉 首个 Flutter 版本发布
- ✅ 从 Python 版本完全重构
- ✅ 支持 Windows、macOS、Linux、Android、iOS
- ✅ Material Design 3 界面
- ✅ Riverpod 状态管理
- ✅ 并发翻译支持
- ✅ 双语对照翻译

---

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

---

## 🙏 致谢

- [Flutter](https://flutter.dev/) - 强大的跨平台 UI 框架
- [DeepSeek](https://deepseek.com/) - AI 翻译 API
- [Riverpod](https://riverpod.dev/) - 响应式状态管理

---

## 📧 联系方式

如有问题或建议，请通过以下方式联系：

- 📧 GitHub Issues: [epub-translator-flutter/issues](https://github.com/zhao922-bot/epub-translator-flutter/issues)
- 💬 Discussions: [epub-translator-flutter/discussions](https://github.com/zhao922-bot/epub-translator-flutter/discussions)

---

**⭐ 如果这个项目对你有帮助，请给个 Star 支持一下！**
