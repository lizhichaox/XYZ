# XYZ 项目分析报告

- **分析对象**：`/Users/lizhichao/Developer/XYZ`，HEAD `db12a62`（2026-11-07 11:12 +0800，merge PR #4），版本 **0.5.28 (build 44)**。
- **分析方式**：本机构建/测试基线（Xcode 27.2、Swift 6.4.2、macOS 27.2）+ 4 路并行静态深读（Core / Workspace / Editor+Preview / 工程化与 CI）+ GitHub Actions API 交叉核对 + 少量 AppKit/文件系统行为探针。未启动 GUI 应用、未跑 Instruments、未修改仓库代码。
- **证据口径**：下文 `file:line` 均指 HEAD 工作树；标"本机复现"的结论由本次分析实际执行过。原始深度报告见 `docs/analysis/`（core / workspace / editor / process，共约 1,700 行）。
- **报告时间**：2026-11-07。

---

## 一、执行摘要

**项目画像。** XYZ 是一个原生 SwiftUI 文本/Markdown 编辑器：macOS 上提供"文件夹工作区 + 标签页 + 侧栏 Explorer + 命令面板 + Reading/Editing 双模式"，iPhone/iPad 走 `DocumentGroup` 文档浏览器。代码约 **28.4k 行 / 66 个 Swift 文件**（App 20.5k、XYZCore 5.8k、测试 2.2k），15 天内产生 156 个提交、42 个版本段落，当前树为 0.5.28。代码和文档呈现出明显的 **AI 代理高频迭代**特征（提交信息是逐步调试日志，CHANGELOG 记录失败运行与撤回的声明）。

**工程质量的基本盘不差。** 本次本机验证：macOS Debug / macOS Release / iOS Simulator 三个构建全部成功，仅 1 条脚本阶段警告；`swift test --package-path XYZCore` **191 个测试、0 失败**；`Scripts/xyz-test.sh` 6/6 通过。`XYZCore` 的分层、纯函数策略（`WorkspaceFilePolicy`）、编码/行尾保真、Markdown 渲染的转义与 URL 白名单都达到了高于一般个人项目的水平；CHANGELOG 对"未安装、未验证、失败项"的诚实记录也是明显优点。

**但当前不是可发布状态，且存在真实的数据丢失与崩溃风险。**

1. **HEAD 在自家 CI 上是红的。** 新增的 UI acceptance 门禁（`da9730d` 引入）**自引入以来 7 次运行 0 次通过**；最近 100 次 CI 只有 10 次成功（详见 §4.4）。0.5.28 的 18 个提交共用同一个版本号、没有任何 tag，"候选版本"从未在门禁下绿过。
2. **4 个高严重度缺陷**（详见 §5）：
   - New File 在大小写不敏感 APFS 上会**清空**已有同名文件（本机复现：已有 `untitled.md` 时创建 `Untitled.md` → 0 字节）；
   - 重启恢复标签的回归（全局 `openSerial` + 过早 `persistOpenWindows`）会把恢复状态**覆盖成空/单标签**；
   - 关窗/⌘Q 的 flush 是 best-effort，冲突/IO 失败不会阻止退出，后台标签编辑可能**静默丢失**；
   - 文件夹窗口跨 tab 复用文本视图但**不清 undo 栈**，⌘Z 可能抛 `NSRangeException` 崩溃或把上一篇的编辑写到当前文档（AppKit 层已复现，产品内需按步骤确认）。
3. **验证体系与产品形态错位。** App target 没有测试 target；UI 验收靠 2,459 行、**随 Release 一起发布**的 `GutterSnapshot` 自检 + 窗口截图 OCR；CI 构建的是无签名、**无 entitlements** 的 app（本机实测 `codesign -d --entitlements -` 为空），沙盒、iCloud、security-scoped bookmark 从未进入 CI。
4. **发布链路不存在**：无 tag、无 release workflow、Release 关闭 Hardened Runtime、安装版用 Apple Development 证书（实测 `/Applications/XYZ.app` = 0.5.27/43，TeamIdentifier Z4FMG2KTPM），不可公证/分发。

**一句话判断：** 功能完成度和"单点代码质量"明显高于"验证与发布能力"。**先修 4 个 P0，再让门禁真实有意义，最后谈发布**；在此之前，任何"0.5.28 是候选版本"的说法都不成立。

---

## 二、项目全景

### 2.1 功能面

| 能力 | macOS | iOS/iPadOS | 证据/备注 |
|---|---|---|---|
| Markdown Reading（WebView）与 Editing（NSTextView/UITextView） | ✅ | ✅（Source 端能力弱） | Reading 渲染 heading/表格/代码/任务列表/相对图片 |
| 文件夹工作区、侧栏 Explorer、拖动移动、新建/重命名/回收站 | ✅ | ❌ | iOS 只有 `DocumentGroup` 文档浏览器 |
| 标签页（预览 tab、pin、关闭历史 ⇧⌘T） | ✅ | ❌ | |
| 命令面板（⌘P）、Go to Line、大纲（⌥⌘B）、⌘K 文件名+全文搜索 | ✅ | 部分（无 ⌘K 面板） | |
| 查找/替换（⌘F/⌥⌘F/⌘G）、文件夹级 Replace All | ✅ | ❌（iOS 无 find） | |
| 行号、当前行 band、语法着色 | ✅ | ❌（iOS 无行号/着色） | |
| 编码与行尾保真（UTF-8/BOM、UTF-16、Windows-1252、LF/CRLF/CR） | ✅（文件夹路径） | ❌（文档场景仅 UTF-8） | 见 §5 P1-11 |
| 图片/PDF/音视频查看器、Quick Look、JSON/CSV Reading | ✅ | 部分 | |
| `xyz` 命令行（`open -b` 语义）、中英双语、设置 | ✅ | 部分 | CLI 有边界小 bug，见 §5 P2 |
| iCloud Documents、App Sandbox、书签恢复 | 声明完成 | 声明完成 | **未在签名/iCloud 环境验证** |
| AI 能力 | ❌ | ❌ | GitHub 仓库描述是 "An AI Editor."，代码中无任何 AI/LLM 功能 |

### 2.2 规模画像

| 指标 | 数值 | 备注 |
|---|---|---|
| Swift 文件 / 行数 | 66 / 约 28,429 | App 20,456；XYZCore 源 5,761；测试 2,177 |
| 类型 / 函数（启发式解析） | 359 / 1,645 | 最大文件 `XYZ/Editor/GutterSnapshot.swift`（2,459 行） |
| 测试 | 9 文件 / 27 个 suite / **191 test / 741 XCTAssert** | 全部在 XYZCore；App target 0 单测 |
| 第三方依赖 | `swift-markdown` 0.9.0（+ swift-cmark 0.9.0）；`highlight.js` 11.11.1 内置 | 依赖面很小，是优点 |
| 版本 / 安装状态 | 树内 0.5.28/44；`/Applications/XYZ.app` = 0.5.27/43（本机实测） | 与 CHANGELOG 一致 |
| 发布状态 | 0 tag / 0 release；GitHub 仓库 public、MIT、2026-10-23 创建 | |
| 提交历史 | 156 个提交；151 个在 2026-11-03；0.5.x 版本共 42 段 | 明显的 agent 迭代节奏 |

**文件/类型热点**（行数）：`GutterSnapshot.swift` 2,459（单个 enum 2,400 行）、`XYZMacEditor.swift` 2,003（`XYZMacTextView` 922 + `EditorTypography` 520 + 入口 440）、`WorkspaceSession.swift` 1,977（`WorkspaceSession` 1,597 + `WorkspaceFileBuffer` 303）、`EditorCommands.swift` 1,918、`WorkspaceView.swift` 1,851、`WorkspaceSidebar.swift` 1,838、`EditorChrome.swift` 1,394、`MarkdownWebView.swift` 1,284。最长函数是 `MarkdownWebView.swift:839` 的 `shell`（433 行 HTML 字符串拼接）。

### 2.3 本次本机基线验证（全部实际执行）

| 检查 | 命令 | 结果 |
|---|---|---|
| Core 单元测试 | `swift test --package-path XYZCore` | ✅ **191 tests / 0 failures** |
| macOS Debug 构建 | `xcodebuild … -configuration Debug -destination 'platform=macOS'` | ✅ BUILD SUCCEEDED（1 条警告） |
| macOS Release 构建 | 同上 `-configuration Release` | ✅ BUILD SUCCEEDED（CI 不做 Release） |
| iOS Simulator 构建 | `-destination 'generic/platform=iOS Simulator'` | ✅ BUILD SUCCEEDED |
| CLI 脚本 | `sh Scripts/xyz-test.sh` | ✅ 6/6 |
| 编译警告 | `xcodebuild … \| grep -c warning:` | **1**（`Make xyz executable` 脚本阶段未声明 outputs） |
| 代码卫生扫描 | `grep TODO/FIXME/HACK` | 0；`assert/precondition/fatalError` 1 处；`print()` 43 处（诊断） |
| SwiftLint（默认规则，仓库无配置） | `swiftlint lint` | App 468 / Core 138 条，绝大多数是 `identifier_name`、`line_length`、`trailing_comma` 等风格项 |

> 注意：Release 构建、`swift test` 都不是 CI 的一部分；CI 只构建 Debug，且不运行 App 层测试。

---

## 三、架构评估

### 3.1 分层与数据流

```
XYZCore（纯逻辑、可单测）                  App target（AppKit/SwiftUI 集成）
├─ 文本 IO：TextBytes / TextDocument       ├─ 文档场景：DocumentGroup + MarkdownFileDocument
├─ 编辑纯函数：SourceEditing / Transforms  ├─ 文件夹场景：WorkspaceSession / Buffer / WindowController
├─ Markdown：Parser → ReadingSource → HTML ├─ 编辑器：XYZMacEditor / XYZIOSEditor（+ GutterSnapshot 自检）
├─ 策略：WorkspaceFilePolicy（分类/写入）   ├─ 预览：MarkdownWebView（每窗口一个 WKWebView）
├─ 工作区：Node / Loader / Search / Tabs   ├─ 菜单/命令：EditorCommands + FolderOpening（swizzling）
└─ 杂项：CommandPalette / SyntaxColoring   └─ 视图：WorkspaceView / Sidebar / EditorChrome
```

**做得好的地方：**

- `WorkspaceFilePolicy` 把"读安装/磁盘变化/写冲突/跟进保存"抽成可测纯函数（`XYZCore/.../WorkspaceFilePolicy.swift:237-280`），App 只消费决策；CHANGELOG 0.5.28 的三条竞态修复与代码一致（本次核对一致）。
- Markdown 管线边界清晰：public 只有 `MarkdownHTML` / `MarkdownOutline`，parser/renderer/预处理均 internal；原文 HTML 转义 + `javascript:/vbscript:/data:` 拒绝 + link/image scheme 白名单，静态审查未发现注入路径（`HTMLRenderer.swift:448-511`）。
- 编码与行尾保真是真实差异化能力：`TextBytes` 支持 7 种形态，保存写回原编码/行尾（`WorkspaceFileAccess.swift:99-154`）。

**主要架构矛盾：**

1. **SwiftUI `DocumentGroup` 与"文件夹窗口"的冲突，用运行时 swizzling 化解。** `FolderOpening.swift:64-258` 对 `NSSavePanel` 的 `beginWithCompletionHandler:` / `beginSheetModalForWindow:completionHandler:` / `runModal`，以及 `PlatformDocumentController` 的 `openDocumentWithContentsOfURL:display:completionHandler:`、`openUntitledDocumentAndDisplay:error:`、`reopenDocumentForURL:…`、`makeUntitledDocumentOfType:error:`、`newDocument:` 做 `method_setImplementation` + 手写 `unsafeBitCast` 转发。这是 OS 升级时最先碎的一层，且只有 `-XYZCheckFileMenu` 自检能发现失效。
2. **macOS 编辑器实际运行在 TextKit 1 上，但这不是设计选择。** `makeNSView` 先创建 TextKit 2 视图（`XYZMacEditor.swift:1058`），最后读取 `.layoutManager`（`:1128`）触发 AppKit 未公开的惰性降级；本次探针复现"读 `layoutManager` 后 `textLayoutManager` 变 nil"。这是为绕开"SwiftUI 图层不合成 TextKit 2 fragment 子视图，窗口空白"（CHANGELOG 0.5.26）而选择的逃生路径，代价是 acquire 了未公开行为、注释与文档仍在说 TextKit 2（`XYZMacEditor.swift:6`、`XYZEditor.swift:114`）。
3. **UI 验收是产品代码的一部分。** `GutterSnapshot.swift`（2,459 行，含 Vision OCR、截图、合成窗口）编进 Sources，无 `#if DEBUG`；Release 二进制中仍能 `strings` 到 `ACCEPTANCE_*`/`GUTTER_*`。`-XYZCheckGutter` / `-XYZCheckFileMenu` / `-XYZDiagnostics` / `-XYZOpenFolder` 四个调试入口都在发布包里。它既不是 XCTest，也没有 test target 可以承载 App 层测试。
4. **两条文本 IO 栈**：文件夹路径走 `TextBytes`（编码保真），文档场景（iOS 唯一入口、Mac ⌘O）只走 `TextDocument`（仅 UTF-8、剥 BOM）。同一产品的"打开文本"语义不一致（见 §5 P1-11）。

### 3.2 文档声明 vs 代码（重点抽查）

| 声明（README/CHANGELOG/docs） | 代码事实 | 判定 |
|---|---|---|
| Mac 编辑器走 TextKit 1（README:11） | 运行时确实被降级；但没有断言，注释仍写 TextKit 2 | ⚠️ 行为对、机制未固化 |
| Reading 每窗口一个 WKWebView、shell 只加载一次、220ms debounce | 成立（`MarkdownWebView.swift:536-644`、`MarkdownPreview.swift:46-79`）；`MarkdownWebView.swift:16` 的"one web view for one open note"注释错误 | ✅ 基本成立 |
| "The renderer still does not request remote images"（README:16） | `URLPolicy.imageSchemes = ["http","https"]`（`HTMLRenderer.swift:482`），无 CSP，单测甚至断言远程 `<img src>` 必须输出（`MarkdownHTMLTests.swift:156`） | ❌ **不成立**：远程图片会联网（P1-1） |
| Raw HTML 当文本、`javascript:`/`data:` 不成链接 | 成立（`HTMLRenderer.swift:128-134,279-281,500-510`） | ✅ |
| 文件 >5MB 不进编辑器 | 成立；另有 2MB 只读预览截断（两个阈值，README 未区分） | ✅ |
| 文件夹窗口恢复"每个窗口的文件夹与标签"（README / CHANGELOG） | 恢复路径被全局 `openSerial` + 过早持久化击穿（P0-B） | ❌ 回归 |
| 0.5.28/44 是候选版本、CI accepted `02dac3c` | 0.5.28 号段含 18 个提交、无 tag；`02dac3c` 的绿是无 acceptance 门禁时的绿，且早于 0.5.28 记录中的两个修复 | ⚠️ 表述需修正 |
| docs/architecture.md:15 的 gutter 算法"由 layoutManager 提供，跳过时重测" | live 代码在 `LineNumberGutter.swift`；XYZCore 的 `LogicalLineGutter` 同名算法大部分是死代码 | ⚠️ 归属描述错位 |
| README:53 "text view 的 undo 指向 document scene 的 undo manager" | 文件夹窗口下 `@Environment(\.undoManager)` 为 nil，文本视图用自身 NSUndoManager，且跨 tab 不清栈 | ❌ 与 P0-D 相关 |

---

## 四、代码与测试质量

### 4.1 优点（应保留）

- **零编译警告、零 TODO/FIXME**；命名与注释普遍解释"为什么"而不是"是什么"。
- **纯函数策略层**：`WorkspaceFilePolicy`、`SourceEditing`、`TextFind`、`EditorTabs` 都有直接测试；`shouldInstallRead`/`isCurrentObservation`/`needsFollowUpSave` 与 0.5.28 CHANGELOG 声明一一对应。
- **错误处理意识**：保存前二次读盘、编码不可表示时拒绝写入（`TextBytes.EncodingError.unrepresentable`）、文件被删/外部冲突有 UI 分支、`NSFileCoordinator` 协调读写。
- **安全边界总体扎实**：Markdown 注入面未发现绕过；`WKScriptMessageHandler` 未发现循环引用；`LocalAssetSchemeHandler` 对 `stop` 的竞态处理正确；Release 不开 `isInspectable`。
- **版本单一来源成立**：`Config/Base.xcconfig` 的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 在 pbxproj 无覆盖，Debug/Release/iOS 产物实测均为 0.5.28/44。
- **CHANGELOG 的诚实性**：记录失败运行、撤回旧声明、列出未验证项；这在 AI 驱动项目里是难得的纪律。

### 4.2 结构性问题

1. **巨型类型/文件**：`GutterSnapshotCheck` 2,400 行（测试夹具）、`WorkspaceSession` 1,597 行/约 110 个方法、`XYZMacTextView` 922 行、`PreviewPage.shell` 一条 433 行字符串。`WorkspaceSidebar.swift` 1,838 行内含 18 个类型；`WorkspaceSearch.swift` 438 行混了 15 个 public 类型（名字匹配、侧栏几何、图标、新建名、内容搜索）。
2. **重复实现**：编辑器的行号/行计算至少 **6 套**（`LineIndex`、`TextFind.lineNumber`、`EditorScrollAnchor`、`SourceEditing.lineRange`、`TextTransforms.coveringLines`、`WorkspaceContentSearch.newlineCount`，其中 2 套只数 `\n`，CR-only 文本会错）；扩展名/分类知识分散 5 处并已漂移（bmp/ico 是 image viewer，但没有对应图标，`WorkspaceSearch.swift:252`）；`EditorCommands` 与 `GlobalSearchPanel` 各有一份浮层面板代码（自动扫描出 42 处 ≥8 行重复块，最大簇在这两个文件之间）。
3. **死代码**：`SourceFormatting.swift`（283 行）+ `SourceEditing` 行内 toggle 是已移除的格式化功能，App 零调用，却有 16 个测试在维持；`LogicalLineGutter` 的 Reading 行号 API 在 0.5.26 删除 Reading 行号后遗留；`ReadingLineMap`、`ExplorerSection.fileCount`、`TextFind.step` 等只剩测试引用。
4. **App 层可测性差**：`WorkspaceSession` 的保存/恢复/替换逻辑大量留在 App target，核心决策没有单测入口；P0-B 这类回归属于"一改就坏、CI 看不见"的典型。

### 4.3 测试覆盖画像

- XYZCore：**191 tests / 741 asserts / 2,177 行测试 vs 5,761 行源码（≈0.38:1）**。覆盖厚的是 `TextBytes`、`TextFind`、`WorkspaceFilePolicy`、`EditorTabs`；薄的是 `SyntaxColoring`（488 行源码仅 4 个测试）、`HTMLRenderer`（无独立测试文件，经 `MarkdownHTML` 间接覆盖）、`FileOutline`。
- 主要缺口：UTF-16 无 BOM 启发式、`TextFind.scan/replacement/lineNumber`（查找条主路径）、`MarkdownFileDocument` 的 `init(configuration:)`/`fileWrapper`/脏标记、>5MB 打开路由、front matter + CRLF、`WorkspaceItemName.unique` 边界、`SyntaxColoring` 的 20 种语言。
- **没有任何 async/并发测试**；App target **没有测试 target**（pbxproj 只有 1 个 target，scheme 的 `TestAction` 为空）。
- 部分测试与实现细节耦合：HTML 断言精确到属性顺序；`testFacadeMatchesDecoupledRenderer` 用 `@testable` 比较门面与内部管线；依赖 8,192/250k 常量与真实符号链接。

### 4.4 CI 的真实状态（GitHub Actions API 交叉核对）

| 指标 | 数值 |
|---|---|
| 累计运行 | **380 runs**：success 137（36%）/ failure 172 / cancelled 71 |
| 最近 100 runs | **10 success（10%）** |
| acceptance 门禁（run 374 起，共 7 次） | **0 success** |
| HEAD `db12a62`（run `42332912178`） | ❌ 失败于 `Check original UI acceptance`；其后的 `Launch macOS app`、`Check Open Folder menu`、`Check Open Folder menu in Chinese` 因隐式 `success()` 语义被 **skip**；`Build iOS Simulator`、`Test XYZCore` 通过 |
| 最后一次绿 push | run 364（`ecd4594`，11-06 10:18 UTC）；最后一次绿 PR 为 run 373（`56bd310`）——与 CHANGELOG 记录一致 |
| 单个 CI run 结构 | `macos-latest` + "选最新 Xcode"（浮动工具链）；Debug 构建；`-XYZCheckGutter` 90 秒硬超时；acceptance 失败仍上传截图；无 Release/archive、无 lint、无缓存、无 `timeout-minutes`、无 app 测试 |

**两个结构性问题：**

1. **CI 跑的不是用户运行的那个 app。** CI 用 `CODE_SIGNING_ALLOWED=NO` 构建（`ci.yml:71-75`）后 `codesign --force --deep --sign -`（`:83/135/156/180`）ad-hoc 重签；本机同类产物实测 `--entitlements` 为空，而安装版带 App Sandbox / iCloud / bookmarks / network.client。也就是说 **沙盒、iCloud、书签、容器路径从未被 CI 执行过**——这解释了 CHANGELOG 里"iCloud 未验证"的结构性原因，也让"UI 检查通过"与"沙盒里可用"之间没有等号。
2. **自检 ≠ 验收。** acceptance 自 `da9730d` 引入后 0/7 通过，代码随后未再修改该文件；失败项包括 nested-file 点击、Collapse All、divider 双击、mode label、empty-line preferences。窗口截图看不到 WKWebView 像素（CHANGELOG 自述），而 Reading 是产品核心，属于验证盲区。

---

## 五、风险清单

> 编号前的 P0/P1/P2 是本次分析的统一严重度：P0 = 数据丢失/崩溃/发布阻断；P1 = 明显缺陷、安全隐私、高风险；P2 = 改进。每条给出主证据，完整证据见 `docs/analysis/`。

### 5.1 P0（4 个缺陷 + 1 个发布阻断）

**P0-1 New File 在大小写不敏感卷上截断已有文件（数据丢失，本机复现）**
`createItem` 用"树里已列名字 ∪ 目录实际名字"做唯一化（`WorkspaceSession.swift:410-421`），`WorkspaceItemName.unique` 是**精确字符串比较**（`WorkspaceSearch.swift:297-309`），随后 `Data().write(to:, options: .atomic)`（`WorkspaceSession.swift:429-435`）。macOS 默认 APFS 大小写不敏感：磁盘已有 `untitled.md` 时 `Untitled.md` 不在集合里，原子写覆盖同一目录项。
本机复现：`fmt 'precious content' > untitled.md`，再向 `Untitled.md` 做原子写 → `untitled.md` 变 0 字节。修复：`.withoutOverwriting`/`O_CREAT|O_EXCL` + 按卷大小写/Unicode 归一化语义做唯一化，把 `unique` 下沉到 Core 并补测试。

**P0-2 重启恢复标签被"全局打开串行号"击穿，并覆盖持久化状态（状态丢失，代码确认）**
`openFile` 每个请求递增全局 `openSerial`，异步读完成时要求 `openSerial == serial`（`WorkspaceSession.swift:539-563`）；`restoreTabs` 在同一个同步循环里打开所有 tab（`:727-761`），只有最后一次请求能安装；紧接着 `WorkspaceWindowController.open` 立即 `persistOpenWindows()`（`WorkspaceWindowController.swift:245-254`），此时 `tabStrip` 仍为空，把 `xyz.workspace.windows` 覆盖成空/单标签。该回归由 `d5c4f25` 引入，`restoreTabs` 无集成测试。修复：per-path 请求竞争 + 恢复完成后才允许持久化，或 `restoreTabs` 改为 async 串行。

**P0-3 关窗/⌘Q 不保证未保存编辑落盘（数据丢失风险，代码确认）**
`windowWillClose` 直接 `shutdown()`（`WorkspaceWindowController.swift:129-137`）；`applicationShouldTerminate` 恒返回 `.terminateNow`（`:652-657`），`prepareForQuit` 只做一次 `shutdown()`（`:445-451`）。`flush()` 只调用一次 `save(force:false)`，冲突/编码/IO 错误仅写 `status`（`WorkspaceSession.swift:1925-1933`），冲突弹窗还只对当前 buffer 生效（`:961-963`）。多标签未保存编辑在文件被外部修改/删除、iCloud 断网、只读卷时可能静默丢失。修复：`windowShouldClose`/`applicationShouldTerminate` 返回 `.terminateCancel` 并弹出保存/放弃/取消；`flush()` 返回结果；trash 前同步 flush。

**P0-4 跨文档 undo 栈未清空：⌘Z 崩溃或串改当前文档（崩溃/损坏，AppKit 层已复现）**
文件夹窗口的 `XYZEditor` 拿到 `@Environment(\.undoManager)`（`WorkspaceView.swift:1626-1658`；无 document scene 时为 nil），`XYZMacTextView.undoManager` 回退到自身的 `NSUndoManager`（`XYZMacEditor.swift:43-45`）；程序性替换只 `disableUndoRegistration` 不清栈（`XYZMacEditor.swift:1376-1393`），全仓库无 `removeAllActions`。本次 AppKit 探针复现：输入后 `canUndo=true`，`textView.string = "XY"` 后 `canUndo` 仍为 true（旧 typing action 仍在，undo 时 `NSRangeException`；先 `removeAllActions()` 则安全）。修复：`replaceContents`/buffer 切换时 `removeAllActions(withTarget:)` 或 per-buffer undo manager；补一个"切 tab 后 ⌘Z"回归用例。

**P0-5 发布阻断：HEAD CI 红、acceptance 从未通过、无 tag/release/公证/Developer ID（发布阻断）**
见 §4.4 与 §4.4 的签名差异。`git tag` 为空；无 release workflow；Release `ENABLE_HARDENED_RUNTIME=NO`（`project.pbxproj:487`）；安装版是 Apple Development 证书（非 Developer ID），无法公证分发。0.5.28/44 号段覆盖 18 个提交，`docs/architecture.md:3` 的 rollback commit `02dac3c` 早于 0.5.28 记录中的两个修复（`ee0b4bd`、`d834720`），"回滚到 0.5.28"不可执行。

### 5.2 P1（按主题）

**安全/隐私**

1. **预览远程图片静默联网，且与 README 相反。** `URLPolicy.imageSchemes = ["http","https"]`（`HTMLRenderer.swift:482`）、`visitImage` 原样输出（`:301-318`），shell 无 CSP，应用带 `network.client` 权限；打开含 `![](https://…)` 的笔记会在 Reading 首次渲染时请求第三方（IP/时间/阅读回执泄露）。建议：默认只允许本地图片（经 `xyz-asset`），或加 CSP 并显式提示。
2. **`xyz-asset` 无根目录约束。** `LocalAssets.fileURL(for:)` 只检查 scheme 与 `/` 前缀（`LocalAssets.swift:26-31`），不 canonicalize、不校验是否在笔记目录下；文件夹窗口持有整棵树授权，笔记 A 可用 `../../` 显示文件夹 B 的图片/媒体（而链接打开反而有 root 限制，`WorkspaceSession.swift:360-368`）。

**数据/正确性**

3. **陈旧 `LineIndex`。** `warmLineIndex` 只在 `makeNSView`/程序性 reload 调用（`XYZMacEditor.swift:1124,1386`），gutter 优先读 `textView.cachedLineIndex()`（`LineNumberGutter.swift:59-68`）；按一次 Return 后行号/状态栏行列/Source↔Reading 锚点会整体偏移。
4. **Gutter 全量排版 + 行盒不一致。** TK1+折行时每次重绘都在 `lineFragmentRows` 里 `ensureLayout(0..<全长)`（`LineNumberGutter.swift:313-322`），判断"跳过"发生在这之后，跳过时排两次；无折行时 gutter 行盒来自 gutter 字体而非编辑器字体（`:346-361`），行距 1.0–1.1 时每行漂移 2.84pt（本机探针实测，测试夹具恰好用 1.2 掩盖）。
5. **保存阻塞主线程。** `WorkspaceFileBuffer.save` 在 `@MainActor` 上同步执行 `NSFileCoordinator` + 整文件读 + 整文件写（`WorkspaceSession.swift:1890-1935`、`WorkspaceFileAccess.swift:112-150`），500ms debounce；大文件/iCloud/网络卷会掉帧甚至 beachball（读路径却用了 `Task.detached`）。
6. **Buffer 的 `@Published` 没有订阅者。** `kind/reloadToken/conflictText/isMissing/status` 全仓库无 `@ObservedObject`/sink（`WorkspaceSession.swift:1636-1640`）；外部文件变更、保存失败、文件消失可能长期不刷新 UI，`onEditorState` 只更新 tab 脏标记（`:947-952`）。
7. **Replace in Folder 可改隐藏文件，且对未打开文件不做磁盘再校验。** 计划扫描不过滤隐藏文件（`WorkspaceSession.swift:1241-1243`），执行时对未打开文件直接写（`:1326-1369`），计划与执行之间的外部修改会被旧计划覆盖；undo 同样直接写回旧字节。
8. **原子写破坏符号链接/硬链接。** 目录加载把 symlink 当普通文件（`WorkspaceDirectoryLoader.swift:10-27`），保存用 `bytes.write(.atomic)`（`WorkspaceFileAccess.swift:139-146`）→ 链接被替换成普通文件、真实目标未更新（本机实验证实）。
9. **`Task.detached` 取消失效 + 每次展开目录全根重扫。** `Task.isCancelled` 在 detached 任务里通常恒 false（`WorkspaceSession.swift:1110-1127,1386-1413,1938-1976`）；`load(parent:)` 成功后无条件 `scheduleIndex()`，大仓库下展开/刷新会产生叠加的全目录枚举。
10. **文档场景只支持 UTF-8。** `TextDocument` 仅 UTF-8、读时剥 BOM（`TextDocument.swift:5-40`），`MarkdownFileDocument.init` 失败即抛（`MarkdownFileDocument.swift:33-38`）；iOS 只能走文档浏览器（README:4-7），Windows-1252/UTF-16 文本在 iOS/⌘O 打不开，带 BOM 文件经文档场景保存后 BOM 消失。
11. **CRLF front matter 行号错位 + 大纲幽灵标题。** `ReadingSource.swift:65-71` 逐 `Character` 掩码，`"\r\n"` 是一个 Character → CRLF front matter 换行被吃掉、`data-line` 整体前移；`MarkdownOutline.swift:20-26` 直接解析原始文本，不经 `ReadingSource.prepare`，YAML front matter 会变成标题、wiki-link 标题与预览不一致。
12. **`MarkdownFileDocument.objectWillChange` 从不发送。** `MarkdownFileDocument.swift:16` 声明 publisher，`storeEditorText`（`:48-52`）从不 `send`；文档脏状态完全依赖 undo manager 这一条路，无测试证明"程序化替换/IME 提交/重载后关闭会提示保存"。

**性能**

13. 每击键把全文 String 同步外传（editor → buffer → preview bridge → outline → word count），1–5MB 文件输入延迟与内存抖动（`WorkspaceView.swift:1642-1657`、`XYZMacEditor.swift:1440`）；outline/字数也在每键重算。
14. `TextFind.matches` 无上限、`replaceAll` 对每个 match 做 `NSMutableString→String` 拷贝、`lineNumber` 复制前缀串；5MB 高频词可产生百万级 match（`TextFind.swift:29-39,66-79,126-136`）。
15. `SyntaxColoring` 每个字符一次 `NSMutableString.substring`（`SyntaxColoring.swift:154-157`），256KB 文件滚动可感；`TextBytes` 对 UTF-8 解码两次（`:187`）、逐 scalar 拼接（`:255-308`）。

**跨平台/产品一致性**

16. **iOS Source 端明显落后**：忽略字号/行距/字体/可读宽度/spellCheck（`XYZIOSEditor.swift:210-219,285-311`；`XYZEditor.swift:254-263`），无行号、无查找、无语法着色；而 Reading 用 `@AppStorage` 的字号/行距（`MarkdownWebView.swift:97-111`）→ 同一设置下 Source/Reading 不一致。
17. **国际化承诺未完成**：catalog 234 key / 232 zh-Hans，但源码抽取发现至少 47 条用户可见文案不在 catalog（菜单、tab 右键 Pin/Unpin/Close All、Find and Replace、Search Notes、Explorer/Collapse All、搜索面板、Settings 等）；CI 只 `grep` 一个"打开文件夹…"（`ci.yml:190`）。
18. **系统类 swizzling 是最大升级脆弱面**：`NSSavePanel`/`PlatformDocumentController` 共 5 处 hook（`FolderOpening.swift:64-258`），没有版本探测/回退；AppKit/SwiftUI 内部签名变化即可让"文件→打开/新建文档"静默失效。

**验证/工程**

19. **2,459 行自检代码常驻发布包**：`GutterSnapshot.swift` 是单个 enum，含 Vision OCR/WebKit/截图；其 offscreen 用例测的是 TK2 detached 路径，**不覆盖生产 TK1 窗口路径**（`GutterSnapshot.swift:1279-1281`），存在"自检绿但窗口错"的结构性风险。
20. **手写 pbxproj**（无 `project.yml`、UUID 为 `8A/8B/8C0…` 顺序合成）：新增/改名文件靠手工登记，漏登记会静默不参与编译；无 CI 一致性校验。
21. **无 tag/release/公证/Developer ID**（见 P0-5）；CHANGELOG 依赖 90 天过期的 Actions artifact 作为证据。

### 5.3 P2（摘要）

- **死代码**：`SourceFormatting` + 行内 toggle（283 行 + 16 测试）、`LogicalLineGutter` 大部分、`ReadingLineMap`、`ExplorerSection.fileCount`。
- **6 套行号实现不一致**（2 套只数 `\n`）；扩展名/分类知识 5 处漂移；`bmp/ico` 查看器可开但图标错。
- **`FileFormats.isTextualName` 对 dotfile 永远 false**（`FileFormat.swift:189-196`），`.gitignore` 的 textual 条目不可达 → 非 UTF-8 dotfile 被当二进制。
- **BOM-less UTF-16 若字节恰好合法 UTF-8 会被误判**，编辑保存后字节被改写（`TextBytes.swift:187-222`）。
- **`WorkspaceItemName.unique` 1 万次冲突后静默返回重名**（`WorkspaceSearch.swift:297-309`）。
- **CLI `xyz` 边界 bug**：`case` 中的 `~`/`~/*` 分支对字面量 `"~"` 永不匹配（POSIX 波浪号展开），交互 shell 因先展开而通常正常，但从脚本/引号传入会失败；`/tmp/xyz-cli-*.$$` 可预测临时文件有符号链接/并发风险（`XYZ/Resources/bin/xyz:53-54,98-117`）。
- **无 lint/format 配置**（本机已装 swiftlint/swiftformat），默认规则 app 468 / core 138 条；Swift 语言模式仍是 5.0（`SWIFT_STRICT_CONCURRENCY` 非 complete），大量 `Task`/`@MainActor` 代码的并发正确性不设防。
- **macOS 产物含 iOS-only plist 键**（`UILaunchScreen`、`UISupportsDocumentBrowser` 等，`project.pbxproj:447-500`）。
- **`tools/make_icons.py` 不可复现**：顶层 `import fontTools`（本机 `--help` 即 ModuleNotFoundError）、硬编码 Chrome 路径、无版本 pin/requirements。
- **可访问性**：全仓库仅 33 处 accessibility 标记，无 VoiceOver/键盘完整性验收；设置面板、状态栏、Reading 的 a11y 声明值得单列测试。
- **产品定位不一致**：GitHub 仓库描述 "An AI Editor."，但代码/README 无任何 AI 功能；若这是路线图，应在 README 说明，否则建议改掉描述。

---

## 六、产品评估

**优势（值得继续投入）：**

- 原生（非 Electron）的 macOS 质感 + 真实的文件夹工作区 + 标签/命令面板/大纲，组合上更接近"轻量 IDE 化的 Typora"，在 Markdown 编辑器赛道有明确差异点。
- 文本保真（编码/行尾/BOM/混合行尾）是许多同类产品忽略的能力，对中文/Windows 迁移用户尤其有价值。
- Reading（WebView）与 Editing（原生 TextKit）两条渲染路径都认真做了：相对图片、`#fragment`、外链、ASCII 表格、highlight.js、查找高亮、滚动锚点。
- README/CHANGELOG 的详细程度和"不把未验证写成通过"的纪律，是项目最可信的资产之一。

**主要产品缺口：**

1. **发布与分发不存在**：没有下载页/公证/自动更新/TestFlight；用户拿不到 0.5.28，安装的是开发签名 0.5.27。
2. **iOS 只是"文档场景的最小实现"**：没有文件夹工作区、标签、查找、语法着色；Source 端与 Reading 端设置不一致。若"一个 SwiftUI 代码库跑三端"是卖点，这是当前最大落差。
3. **同步只停留在 entitlements 声明**：iCloud 容器、书签、沙盒路径都未经签名环境验证，"iCloud Drive 里是普通文档"的产品承诺目前无法证明。
4. **验证盲区与产品核心错位**：Reading 窗口截图看不到 WebView 像素、真实 IME/iCloud/手势未跑；UI 验收失败的 5 项（Explorer 点击、Collapse All、divider、mode label、空行偏好）正好是"文件夹窗口好不好用"的关键交互。
5. **定位未落地**："An AI Editor." 没有对应功能；若未来要做 AI 能力，需要先解决隐私边界（远程请求默认关闭）、数据出域提示与本地/云端模型的选择。

**竞品简评（定性）：** 与 Typora 相比，XYZ 多文件夹工作区/标签/命令面板，但 Typora 更成熟、跨平台、已发布；与 Obsidian 相比，XYZ 更轻、更原生，但插件生态/同步/移动端不可比；与 VS Code 相比，XYZ 的 Markdown 阅读体验更专注，但没有扩展生态与发布渠道；与 MarkEdit 等原生小工具相比，XYZ 功能面更大，但工程风险也更大。**现实路径是"小而精的原生 macOS Markdown/文本工作台 + 后续 iOS 补齐"，而不是"通用编辑器平台"。**

---

## 七、建议路线图

### 立即（本周内，修 P0 + 让门禁可信）

1. **P0-1 新建文件安全**：改用 `withoutOverwriting`/`O_EXCL`；`unique` 按卷大小写/Unicode 归一化语义实现并下沉到 XYZCore + 单测（含 `Note.md`/`note.md`、NFC/NFD）。
2. **P0-2 标签恢复**：改为 per-path 请求竞争 + `restoreTabs` 完成后再持久化；补 restore 回归测试（纯函数 + 离屏 AppKit）。
3. **P0-3 退出保护**：`windowShouldClose` + `applicationShouldTerminate` 走 `.terminateCancel`；`flush()` 返回成功/失败；冲突/编码错误弹窗覆盖所有标签。
4. **P0-4 undo 清理**：`replaceContents`/切 buffer 时清 undo 栈（或 per-buffer undo manager）；补"切 tab 后 ⌘Z"用例。
5. **CI 可信化**：把 `Launch`/菜单检查的 `if` 改为 `always()`（否则 acceptance 失败会把它们永久 skip）；固定 Xcode 版本；加 `timeout-minutes`；acceptance 失败时输出结构化失败清单。若短期修不完 5 个 case，就把 acceptance 标为 advisory 并明确"HEAD 不绿"，不要继续用"候选版本"。
6. **冻结发布点**：在 acceptance 全绿（或明确豁免）的 commit 上打 annotated tag `v0.5.28`；Release 打开 Hardened Runtime；CI 增加 Release 构建（至少 macOS）+ archive/notary 脚本骨架（Developer ID 证书走 secrets）。

### 短期（1–2 个月，修 P1 与验证体系）

7. **把自检移出产品**：`GutterSnapshotCheck`/`FileMenuCheck` 拆到独立 UI test target（或至少 `#if DEBUG`），Release 二进制不再含 Vision/截图/OCR 依赖；同时让 offscreen 用例覆盖生产 TK1 路径。
8. **安全默认值**：Reading 默认不加载远程图片（或加 CSP + 设置项）；`xyz-asset` 增加根目录约束（canonicalize + `hasPrefix(allowedRoot)`，handler 按 webview/session 实例化）。
9. **正确性小修**：LineIndex 失效策略（`textDidChange` 清缓存/异步重建）；gutter 行盒统一用编辑器字体、去掉全量 `ensureLayout`；`ReadingSource` 按 scalar 掩码修 CRLF front matter；`MarkdownOutline` 复用 `ReadingSource.prepare`；文档场景编码接手 `TextBytes`。
10. **App 可测化**：为 `WorkspaceSession` 抽纯逻辑（恢复计划、保存序列、替换计划、路径包含）到 XYZCore；加 App 测试 target，先覆盖 5 条 P0/P1 路径。
11. **保存移出主线程**：读盘校验—编码—写入放到串行 actor/后台队列，结果回 MainActor；buffer 变化正确发布（订阅 buffer 的 `objectWillChange` 或让视图 `@ObservedObject`）。
12. **国际化/本地化**：抽取 47 条硬编码文案；CI 加 catalog diff 检查；补中文菜单/搜索面板。
13. **swizzling 收敛**：集中到一个模块，启动时做版本/选择器自检并写诊断；评估能否用 `NSOpenSavePanelDelegate`/`applicationShouldOpenUntitledFile` 替代部分 hook。

### 中期（3–6 个月，发布与平台）

14. **发布流水线**：Developer ID 签名 + notarytool + 下载页 + Sparkle 自动更新；iOS 走 TestFlight；版本号→tag→build 一一对应；CHANGELOG 关联 tag 而非易失的 run URL。
15. **真实环境验收**：签名沙盒构建的 smoke（含 security-scoped bookmark、iCloud Drive、sandbox 路径）；真实中文输入法；真实窗口手势/Explorer 点击（XCUITest 在 GitHub runner 上启动失败已被记录，需要自托管 runner 或人工验收清单）。
16. **iOS 补齐**：Source 端接入共享样式/查找/着色；评估 iPad 文件夹工作区（`WorkspaceSession` 已在 Core 侧预留模型，但当前 `XYZ/Workspace/*` 全是 macOS-only）。
17. **性能目标化**：定义并测量 1MB/5MB 打开、输入延迟、300KB 滚动、⌘K 搜索的 p95；按 §5 P1-13/14/15 的顺序优化。

### 长期（架构与产品方向）

18. **TextKit 策略定案**：显式声明 TextKit 1（`usingTextLayoutManager: false`）或验证 SwiftUI 窗口合成问题在目标 macOS 版本已修复后再迁 TextKit 2；无论哪条路，都用断言/诊断锁定运行时路径，避免未公开降级。
19. **单文件/工作区两条 IO 栈统一**（`TextBytes` 作为唯一编解码入口），消除 BOM/编码语义漂移。
20. **产品定位落地**：要么实现 AI 能力（先解决隐私/出域/本地模型），要么把仓库描述改成"native Markdown editor"；补齐可访问性与主题化，形成可宣传的差异点。

---

## 八、分析口径与局限

- **已验证**：本机三套构建 + Core 测试 + CLI 脚本；GitHub Actions API 的 380 次运行元数据（结论、步骤、提交）；4 路静态深读覆盖全部 66 个 Swift 文件、CI/构建配置、文档与本地化 catalog；AppKit 探针（TextKit 降级、undo 栈、行盒）、文件系统探针（大小写截断、原子写破坏链接）。
- **未验证**：未启动 GUI 应用（会在用户屏幕打开窗口）；未跑 Instruments/性能实测；未在 macOS 14/15 上实测；未跑真实中文 IME、iCloud、签名沙盒；GitHub 的 job 原生日志需管理员权限（API 返回 403），只能使用运行元数据与 CHANGELOG 记录；因此 P0-4 是 AppKit 机制已复现、产品内路径待按步骤确认。
- **团队产出**：`docs/analysis/core.md`、`workspace.md`、`editor.md`、`process.md` 为四路并行深读的原始报告（约 1,700 行，全部 file:line），未经合并润色，可作为本报告的附录与复核依据。
- **行号基准**：HEAD `db12a62`。后续提交会使行号漂移，复核时请以符号/函数名定位。

---

## 九、修复进展（按本报告优先级）

本节记录实际落地的改动，对应版本 0.5.29（build 45），详细叙述见 `CHANGELOG.md` 同号条目。行号以 HEAD `db12a62` 为基准；本节按函数名定位。

### 9.1 已修复：P0

| 编号 | 修复内容 | 主要位置 | 验证 |
|---|---|---|---|
| P0-1 | 新建文件/文件夹一律独占创建（`.withoutOverwriting` / `createDirectory`），名称在创建时刻按目录实况重选，文件系统报告已存在则换下一个名字重试（最多 20 次）；`unique` 按卷语义比较名称（大小写不敏感 + Unicode 预组合），1 万次冲突后返回 UUID 后缀而不是静默重名 | `WorkspaceSession.createItem` / `createItemExclusively`/`itemAlreadyExists`、`WorkspaceItemName.comparisonKey` | `WorkspaceTests.testNamesAndMoves` 新增 `untitled.md`、`NFC/NFD`、大小写敏感卷断言 |
| P0-2 | `openFile` 返回安装任务；恢复按 tab 串行 await 且 `activate: false`，最后选中保存的活动 tab；恢复完成才持久化窗口列表（失败时保留旧列表）；恢复任务随窗口关闭取消；`windowState()` 保存每 tab 真实 mode | `WorkspaceSession.restoreTabs`/`openRestored`/`present`、`WorkspaceWindowController.open` | `EditorTabTests.testSetActiveKeepsTheSet`、`testTabModeSurvivesTheStrip`；三平台构建通过 |
| P0-3 | `windowShouldClose` 与 `applicationShouldTerminate` 先 flush 全部 buffer（抑制逐文件冲突弹窗），再弹一个合并清单：「Keep Editing」为默认/Esc，或「Close Anyway」/「Quit Anyway」；保存失败的文件被前置展示，取消后可见其 banner | `WorkspaceWindowController.windowShouldClose`/`prepareForQuit`/`confirmUnsaved`、`WorkspaceSession.unsavedForClose`/`presentForClose` | 编译 + 路径审查；窗口实机验收未做（见 9.4） |
| P0-4 | 整篇替换在文本确实变化时清空 undo 栈（macOS `XYZMacTextView` 与 iOS `UITextView`），旧范围不再指向新文档 | `XYZMacEditor.replaceContents`、`XYZIOSEditor.replaceContents` | 代码路径审查；交互验收未做 |

### 9.2 已修复：P1（选定项）

| 编号 | 修复内容 | 验证 |
|---|---|---|
| P1-3 | `textDidChange` 立即作废 `LineIndex` 缓存并重绘行号，120 ms 防抖后在后台重建；gutter 与状态栏不再读到编辑前的行起点 | 构建通过 |
| P1-4（部分） | gutter 无折行行盒改用编辑器字体与段落样式，不再用较小的 gutter 字体 | 构建通过；全量 `ensureLayout` 仍在，未做性能重构 |
| P1-6 | session 转发 buffer 的 `objectWillChange`，磁盘重载/保存失败/文件消失会刷新正文与 banner | 构建通过 |
| P1-7（部分） | `searchableFiles()` 统一 ⌘K 与 Replace in Folder 的候选集：排除目录、跳过路径、且侧栏隐藏文件时不列入 | 构建通过；执行前的磁盘再校验未做 |
| P1-2 | `xyz-asset` 增加根目录约束：`WorkspacePathScope.contains` 标准化路径并解析符号链接；handler 按 webview 实例化并随笔记目录切换 | `WorkspaceTests.testPathScopeResolvesTraversalAndLinks`（`..` 越界、符号链接逃逸） |
| P1-1 | Reading 默认不加载远程图片：`MarkdownHTML.render(_:allowRemoteImages:)` 关闭时渲染器根本不写 `http(s)` 的 `<img src>`（web view 无从发起请求，协议相对 `//host` 一并拦），设置项「Load remote images」默认关闭、可在 Settings 打开；相对路径图片不受影响 | `MarkdownHTMLTests` 新增 2 个用例（关闭时无远程 src、相对图片仍渲染、协议相对地址拦截） |
| P1-17 | 补齐源码中缺失的 48 条用户可见文案（菜单、标签右键、⌘K 面板、Explorer、设置、状态栏、CLI 安装对话框、Replace in Folder）；catalog 238 → 286 key，全部带 zh-Hans | `Localizable.xcstrings` 校验；CI 新增 catalog 完整性步骤；未在真机看中文菜单 |
| P1-11 | CRLF front matter 按 Unicode scalar 掩码，不再把 `\r\n` 当一个 Character 吞掉；大纲改用 `ReadingSource.prepare` 后再解析，front matter 里的 `#` 不再是标题、wiki link 标题与 Reading 一致 | `DocumentInsightTests` 新增 3 个用例（LF/CRLF 行号、wiki link 标题） |
| P1-10 | 文档场景（iOS 文档浏览器 / Mac ⌘O）改为保留编码与换行：UTF-8/BOM/UTF-16/Windows-1252 均可读写，BOM 不再丢失；无法编码的新字符回退 UTF-8，避免写出空文件 | `TextDocument` 新增 5 个单测（BOM、UTF-16、Windows-1252、CRLF 原样、回退 UTF-8） |
| P1-8（部分） | 保存前用新增的 `WorkspaceWriteTarget.resolveForWriting` 解析符号链接（含链式链接、环回退），原子写落在链接目标而不是把链接替换成普通文件；`WorkspaceFileCoordination.updateText`/`writeData` 均已接入 | `WriteTargetTests` 5 个用例（普通路径、链接、链式链接、环、写后仍是链接） |
| P1-9（部分） | 分离的 detached 扫描改为可取消（关闭 ⌘K、切换文件夹时真正停下）；目录重载列表未变化时不再重扫整棵树 | 构建通过 |
| P1-15（部分） | `TextBytes.decodeUnicode` 去掉重复 UTF-8 解码；`TextFind.lineNumber` 不再复制前缀字符串；regex `replaceAll` 不再为每个 match 复制整篇文档 | 既有 208 个单测全过（含 regex group replace） |
| P1-14（部分） | 同 P1-15 的 `replaceAll` 拷贝消除；`matches` 仍无上限（需要 UI 语义决定） | — |
| P1-12（文档） | `objectWillChange` 保持不发送，并在代码中写明原因：脏状态由 undo manager 驱动，逐键发送只会重建场景 | 注释；未加运行时验证 |

### 9.3 已修复：P2 低成本项

| 项 | 修复 |
|---|---|
| dotfile 文本判定 | `FileFormats.isTextualName` 对 `.gitignore`/`.editorconfig`/`.env` 返回 true，`.DS_Store`/`.png` 仍为 false（含单测断言） |
| JSON/CSS 行注释 | `TextTransforms.lineComment(for:)` 返回 nil，命令被禁用而不是写出解析器拒绝的文件（含单测断言） |
| `unique` 冲突上限 | 9,998 个同名后返回带 UUID 后缀的名字，不再返回可能已存在的名字 |
| BOM-less UTF-16 | 启发式判定提前到 UTF-8 之前：纯 ASCII 的 UTF-16 不再被当成带 NUL 的 UTF-8 读入并在保存时改字节（含单测） |
| CLI `~` 边界 | `Resources/bin/xyz` 的 `case "~"`、`"~/"*` 加引号；`Scripts/xyz-test.sh` 新增 `tilde`、`tilde-dir` 用例（HOME 指向临时目录） |
| CLI 临时文件 | 可预测的 `/tmp/xyz-cli-*.$$` 改为 `mktemp -d` + `trap` 清理，避免预置/符号链接与 SIGINT 残留；dry-run 8/8 通过 |
| 图标脚本 | `tools/make_icons.py` 的 fontTools 改为惰性导入，`--help` 不再抛 traceback；Chrome 从多候选查找/`CHROME` 覆盖，缺依赖给一句话；新增 `tools/requirements.txt` |
| CI 可信化 | `timeout-minutes: 60`；bundle 版本与 `Config/Base.xcconfig` 一致性检查；窗口检查步骤 `always()` 运行；acceptance 每个失败用例输出 `::error` 注解；Release 构建；artifact 增加截图与各步骤日志；catalog 完整性检查 |

### 9.4 仍未完成（有意保留，按优先级）

- **P0-5 发布阻断（大幅推进，仍未收口）**：Release 已打开 Hardened Runtime；本机创建了 Developer ID Application 证书（Team `Z4FMG2KTPM`），archive → `method=developer-id` 导出 → zip 公证（submission `0e54a40b…`，Accepted）→ staple → `spctl` **accepted / source=Notarized Developer ID**；DMG 也已签名、公证（`a0e37293…`，Accepted）、staple 并被 `spctl` 接受。仍缺：tag/GitHub release、release workflow、acceptance 门禁（0/7）、安装版仍是 0.5.27、未做真机人工验收。步骤与记录见 `docs/release.md`。
- **P1-1 远程图片默认阻断**：属产品决策（默认关闭 + 设置项 + 外链提示），本次只改文档。
- **P1-5** 保存仍在主线程（1MB+ 文件/iCloud/网络卷可能卡顿）——需要一次无 GUI 验收的重构窗口。
- **P1-8 硬链接**：原子写仍会拆分硬链接（保持原子性优先）；符号链接已修。
- **P1-9 剩余**：目录加载本身（单次 `children` 调用）仍不可中断；`Task.detached` 取消只覆盖了有检查点的循环。
- **P1-13** 每击键全文外传（editor → buffer → preview/outline/字数）未做节流；**P1-16** iOS Source 端样式/查找/着色仍落后；**P1-18** swizzling 收敛；**P1-19** 自检代码移出发布包；**P1-20** 手写 pbxproj 一致性。
- **P2 死代码（部分）**：已删除 `ReadingLineMap`（+3 个测试）与 `ExplorerSection.fileCount`（+2 条断言），均无生产调用方；`SourceFormatting.swift` 的 6 个格式化命令与 `SourceEditing` 的行内 toggle **有意保留**——`FormatMenu.swift` 明确移除了 Format 菜单（"notes are written as Markdown text"），文件头已写明这一决定，删除需要产品层面确认。
- **P2 其余**：6 套行号统一、lint/format 配置、可访问性、仓库描述（"An AI Editor."）与发布定位。
- **P2 macOS 产物里的 iOS-only plist 键（试过，未成）**：把 6 个 `INFOPLIST_KEY_UI*` 改成 `[sdk=iphoneos*]`/`[sdk=iphonesimulator*]` 条件设置后，Xcode 的 Info.plist 生成器仍会在 macOS 产物里写出同名键（空值/false）——它按所有变体的键名合并、再取当前 SDK 的值。已回滚。要真正做到干净，需要关掉 `GENERATE_INFOPLIST_FILE` 改用完整 plist，或加一个删除这些键的 Process Info.plist 步骤；收益只是元数据整洁，未做。

### 9.5 本次验证基线

- `swift test --package-path XYZCore`：**207 tests / 0 failures**（第一轮后 194；第二轮 +14；第三轮 +2 远程图片用例、−3 已删的 `ReadingLineMap` 测试）。
- `sh Scripts/xyz-test.sh`：**8/8 ok**（新增 `tilde`、`tilde-dir`）。
- `xcodebuild`：macOS Debug、macOS Release、iOS Simulator Debug 均 **BUILD SUCCEEDED**（签名关闭，与 CI 同口径）。
- `python3 tools/make_icons.py --help` 在未安装 fontTools 的机器上正常输出；`--sheet` 给出可执行的安装提示。
- 未启动 GUI：退出/关窗弹窗、标签恢复、图片作用域、中文菜单只有编译 + 纯函数单测证据，没有窗口截图；签名沙盒、iCloud、真实中文 IME、性能测量均未跑。
- 本机签名与公证链路（Team `Z4FMG2KTPM`，2026-11-07）：Apple Development 的 Debug/Release 构建通过；Developer ID archive + `developer-id` 导出成功（entitlements：sandbox / network.client / user-selected / bookmarks / iCloud Production，无 `get-task-allow`）；app zip 公证 Accepted 并 staple，`spctl` accepted；DMG 已签名、公证 Accepted、staple，`spctl` accepted。未打开 app，未打 tag、未上传。


---

## 附录：关键证据索引

| 主题 | 关键位置 |
|---|---|
| 新建文件/唯一名 | `XYZ/Workspace/WorkspaceSession.swift:410-455`、`XYZCore/Sources/XYZCore/WorkspaceSearch.swift:297-309` |
| 标签恢复/持久化 | `XYZ/Workspace/WorkspaceSession.swift:539-563,727-761`、`XYZ/Workspace/WorkspaceWindowController.swift:245-254,461-468` |
| 退出/flush | `XYZ/Workspace/WorkspaceWindowController.swift:129-137,445-451,652-657`、`XYZ/Workspace/WorkspaceSession.swift:1767-1770,1890-1935` |
| undo | `XYZ/Editor/XYZMacEditor.swift:43-45,1376-1393`、`XYZ/Workspace/WorkspaceView.swift:1626-1658` |
| Swizzling | `XYZ/Workspace/FolderOpening.swift:64-258` |
| TextKit 降级 | `XYZ/Editor/XYZMacEditor.swift:1057-1128,1639-1644` |
| Gutter | `XYZ/Editor/LineNumberGutter.swift:154-179,273-290,313-322,346-361` |
| 预览安全 | `XYZCore/Sources/XYZCore/HTMLRenderer.swift:301-318,448-511`、`XYZ/Preview/LocalAssets.swift:15-81`、`XYZ/Preview/MarkdownWebView.swift:838-1271` |
| 保存主线程 | `XYZ/Workspace/WorkspaceSession.swift:1890-1935`、`XYZ/Workspace/WorkspaceFileAccess.swift:99-154` |
| Buffer 发布 | `XYZ/Workspace/WorkspaceSession.swift:1633-1770,947-957` |
| 文档编码 | `XYZCore/Sources/XYZCore/TextDocument.swift:5-40`、`XYZCore/Sources/XYZCore/MarkdownFileDocument.swift:33-38` |
| front matter/大纲 | `XYZCore/Sources/XYZCore/ReadingSource.swift:60-75`、`XYZCore/Sources/XYZCore/MarkdownOutline.swift:20-26` |
| 自检 harness | `XYZ/Editor/GutterSnapshot.swift:9-50,1279-1281`、`.github/workflows/ci.yml:77-199` |
| 构建/发布 | `XYZ.xcodeproj/project.pbxproj:384,442,487`、`Config/Base.xcconfig`、`.github/workflows/ci.yml:71-75,83,135,156,180` |
| CI 运行数据 | GitHub API `repos/lizhichaox/XYZ/actions/runs`（380 runs）；HEAD 失败 run `42332912178` |
| 本地化 | `XYZ/Resources/Localizable.xcstrings`、`ci.yml:190` |
