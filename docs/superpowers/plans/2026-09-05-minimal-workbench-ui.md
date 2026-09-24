# 极简工作台 UI 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将四个 Flutter 页面改为用户已批准的 B 极简工作台，并交付通过回归验证的 Windows Release。

**架构：** 保留现有 Riverpod、GoRouter、控制器与数据模型。先更新共享主题与页面框架，再在该框架中组合专注的展示组件；只保存局部展开状态，不修改翻译与密钥持久化协议。

**技术栈：** Flutter / Dart、Material 3、flutter_riverpod、go_router、flutter_test、Windows CMake 构建。

**规格：** `docs/superpowers/specs/2026-09-05-minimal-workbench-ui-design.md`，用户已批准。

## 实施与验证记录（2026-09-24）

- 分支：`codex/minimal-workbench-ui`，在当前项目 checkout 中实现。原计划的独立 worktree 未建立；分支与 `main` 隔离，未合并或推送。
- 共享主题、导航及四个页面已实现。视觉检查覆盖 1440×900、1024×768、800×600、390×844 的明暗及中英文组合，共 24 张 fixture 截图；窄窗口使用 1.3 倍文字。
- 页面顺序依据视觉验收微调：存在任务时先显示状态与输出操作，保证窄窗口警告和打开 EPUB 按钮位于首屏。规格第 4.1 节已同步记录。
- 全量 `flutter test --no-pub --reporter expanded test`：599 项通过、15 项跳过。`flutter analyze --no-pub lib test`：无新错误，仍有 2 条 warning 和 4 条 info，均在未改动的翻译基础设施和旧测试文件中。
- `flutter build windows --release --no-pub` 成功；Release 包含 EXE、DLL、`data/app.so` 和 Flutter 资源。实际程序已启动，系统窗口切换失败使原生导航交互未能完成；页面布局另由 widget 和截图检查验证。
- 完整便携包：`dist/epub-translator-minimal-workbench-windows-x64-20260924.zip`，已检查归档内的 EXE、DLL、`data/app.so` 与资源清单；不要只复制 EXE。
- 规格独立复核通过；首次复核发现的历史警告任务信息缺失已修复并补回归测试。最终代码质量审查通过，未发现确定性流程或状态回归。

## 文件职责与顺序

- 共享基础：`lib/app/theme/app_theme.dart`、`lib/shared/widgets/app_shell.dart`、`page_scaffold.dart`、`section_card.dart`。
- 翻译：现有 `translation_dashboard_page.dart`、`translation_inputs.dart`、`translation_overview.dart`、`translation_logs.dart`、`translation_workflow_steps.dart`、`translation_style_profile_card.dart`；必要时新增同目录 `translation_preferences.dart` 隔离偏好表单。
- 任务：`jobs_page.dart` 与新增 `features/jobs/presentation/widgets/job_row.dart`。
- 预览：`preview_page.dart` 与新增 `features/preview/presentation/widgets/chapter_checklist.dart`、`chapter_preview_content.dart`。
- 设置：`settings_page.dart` 与同目录相邻 `widgets/settings_fields.dart`、`settings_sections.dart`，仅在拆分现有字段/区块确有必要时创建。
- 文案：`lib/shared/localization/app_strings.dart`。
- 验证：保留 `test/widget_test.dart`、`test/typography_consistency_test.dart`、`test/translation_overview_test.dart`，新增 `test/minimal_workbench_test.dart`；复用现有内存 store fixture，避免真实配置写入。

## 任务 0：隔离与基线

- [x] 建立 `codex/minimal-workbench-ui` 分支；实际在当前 checkout 中实施，未建立独立 worktree。
- [x] 运行 `flutter pub get`、`flutter test --reporter compact`，记录通过与跳过数。依赖不升级。
- [x] 运行 `flutter analyze` 记录已有诊断，区别于本次新增问题。

## 任务 1：共享视觉与响应式框架

**修改文件：** 上述共享基础四个文件、`test/minimal_workbench_test.dart`。

- [x] 先添加 shell 与列表框架测试：800 宽桌面导航为窄栏且有 tooltip，390 宽使用底部文字导航；标题、操作与滚动主体在 1.3 倍文字下不溢出。

测试主体使用内存 store 和现有 `EpubTranslatorApp`，关键断言：

```dart
tester.view.devicePixelRatio = 1;
tester.view.physicalSize = const Size(800, 600);
addTearDown(tester.view.resetPhysicalSize);
addTearDown(tester.view.resetDevicePixelRatio);
await tester.pumpWidget(testApp());
await tester.pumpAndSettle();
expect(find.byType(NavigationBar), findsNothing);
expect(find.byTooltip('Settings'), findsOneWidget);
expect(tester.takeException(), isNull);
```

- [x] 运行 `flutter test test/minimal_workbench_test.dart --reporter expanded`。确认旧版 800 宽底部导航使断言失败，而非 fixture 或编译错误。
- [x] 实现黑白灰明暗主题、6–8 圆角控件和轻分隔。保留字体继承、文字缩放与原主题偏好。
- [x] 将 `AppShell` 桌面栏缩为 72，断点 760，保留现有导航图标标识、路由、品牌资源和 `_windowDropChannel` 处理；每个导航项有 tooltip 和语义选中状态。
- [x] 简化 `SectionCard`，取消渐变/明显投影/彩色图标底座；保留构造接口和现有 key，防止调用者大面积失配。
- [x] `PageScaffold` 增加可选滚动主体接口：默认仍包装 `child` 为 `SingleChildScrollView`，列表页显式传入自身滚动主体，bodyKey 在两种模式中都存在。标题不再有渐变与装饰竖线。

```dart
// 构造参数默认保持现有调用有效。
final bool scrollBody; // 默认 true
// scrollBody == false 时使用 Expanded 填充 child，
// 由 child 内的 ListView / LayoutBuilder 自己负责滚动。
```

- [x] 运行新增测试与 `flutter test test/widget_test.dart test/typography_consistency_test.dart`。旧测试若锁定被设计明确取消的装饰，改为验证对应可达功能，不删除功能断言。
- [x] 格式化本任务文件、`git diff --check`、提交 `feat: establish minimal workbench shell (task 1)`。
- [x] 共享基础测试通过；最终按规格审查、代码质量审查的顺序复核完整改版。

## 任务 2：四个页面与完整状态

**修改文件：** 文件职责中列出的页面、展示组件、文案与 UI 测试。

- [x] 先补失败测试：390 宽警告任务仍显示状态与打开/重试按钮；任务长列表不是一次构建全部行；预览空状态无示例章节；800 宽布局关键操作可达；风格待确认时提示可见。

```dart
expect(find.text('Completed with warnings'), findsOneWidget);
expect(find.byTooltip('Open output'), findsOneWidget);
expect(tester.takeException(), isNull);
// 列表 fixture 使用唯一标题 200 项；初始首项存在，末项尚未构建。
expect(find.text('book-0.epub'), findsOneWidget);
expect(find.text('book-199.epub'), findsNothing);
```

上述文案取自 `AppStrings` 实际 getter，若当前英文文本不同则使用 getter，不伪造常量。一次验证一种新行为，运行并记录正确的红灯后实现。

- [x] 翻译页以 840 实际内容宽度分为图书与偏好两列。已导入图书只显示真实路径/章节统计，保留输入路径编辑与全窗口拖入；不添加封面提取、假作者或固定输出目录。
- [x] 主动作集中于输入区下方，与输出路径并排或在窄窗口堆叠。移除页头重复开始按钮；继续使用当前 `hasInput`、`canTranslate`、`isRunActive` 条件与 controller 回调。未确认风格必须显式解释不可开始原因，零段落条件沿用现有判断。
- [x] 双语选择仅写回现有 bool；风格开启且待确认时展开，确认后可折叠；任务运行禁用修改。日志默认收起，但可操作错误和降级警告始终显示。
- [x] 进度区统一轻量样式，保留缓存扫描、阶段、计数、预计信息、取消与平台导出；警告琥珀色且保留文字/图标，输出路径真实可用时保持操作可用。
- [x] 任务页使用 `PageScaffold(scrollBody: false)` 与 `ListView.separated`，行组件在窄内容宽度下将状态及操作换到下一行；保留状态优先级、clear/retry/open 回调与顺序。
- [x] 预览页把章节目录与详情拆成两个专注组件。目录使用 `ListView.builder`，宽窗口限制高度并独立滚动；窄窗口目录作为有界区域后跟文本，避免一次构建所有章节。保留选择预设、重置、零块禁用、运行锁定与安全索引。
- [x] 预览正文达到 1040 内容宽度并列原译文；800–1039 为目录加堆叠原译文；更窄上下排布。读取现有正文/译文摘录，无译文显示提示，无书显示空状态，不新增编辑或渲染引擎。
- [x] 设置顺序为 API、翻译偏好、外观。拆分过长展示文件但保留原字段 StatefulWidget 同步逻辑、密钥隐藏及自动保存。连接测试加载/结果、服务商记忆、任务锁定、现有全部参数均保留。
- [x] 新文案写入 `AppStrings`。更新旧测试中的滚动定位：使用 `ensureVisible` 找到重排后的外观控件，不能因为原先在首屏而要求保持错误顺序。
- [x] 执行 `dart format`（仅改动文件）、`flutter test test/minimal_workbench_test.dart test/widget_test.dart test/typography_consistency_test.dart test/translation_overview_test.dart --reporter expanded`。
- [x] `git diff --check` 后提交 `feat: redesign translation workspace pages (task 2)`。依次规格审查、代码质量审查，修复问题并重跑相关测试。

## 任务 3：集成、视觉验收与交付

- [x] 运行 `flutter test --reporter compact`；未通过不宣称完成。运行 `flutter analyze`，本次新增错误/警告必须清零，已有无关诊断如实报告。
- [x] 用测试 fixture 分别渲染明暗、中英文及规格四种窗口尺寸，1.3 倍文字测试至少覆盖窄窗口。检查选择、按钮、错误文字和输出路径，不仅检查页面是否加载。
- [x] 编译 `flutter build windows --release`，确认退出码、EXE 与 `data/app.so`、DLL 存在。
- [ ] 启动新 Release 实际查看页面。仅做不调用外部 API 的烟雾检查，不覆盖用户密钥、不启动付费翻译。截图发现问题先复现并修复后重新验证。
- [x] 最终独立审查完整 diff。修复关键/重要问题；记录未处理的非阻塞项。
- [x] 更新规格状态和计划进度，提交验证记录。保留开发分支，给出新 EXE 与完整 Release 包；不自动合并或推送。

## 执行方式

推荐在当前任务内采用子代理驱动：一次只派遣一个实现者，各任务依次经过规格与代码质量审查；主代理同时进行不修改同一代码的验证准备和整体集成检查。也可采用当前任务内联执行，验证要求相同。

## 自检

共享框架覆盖规格 2、3、6；四页任务覆盖规格 4、5；集成覆盖规格 7。保持现有默认深色与全部业务判断，无数据迁移、依赖升级或新增产品功能。阶段提交只包含当前任务文件。
