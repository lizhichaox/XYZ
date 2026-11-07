# XYZ 编辑器与预览层分析（editor-analyst）

- 仓库：`/Users/lizhichao/Developer/XYZ`，版本 0.5.28 (build 44)（`Config/Base.xcconfig`）。
- 范围：`XYZ/Editor/`（7 个文件，7237 行中的编辑器部分）、`XYZ/Preview/`（3 个文件 1486 行）、`XYZ/Resources/Preview.css`、`XYZ/Resources/highlight.min.js` 接入；按需参考 `XYZCore`（HTMLRenderer / MarkdownHTML / MarkdownParser / ReadingSource / LogicalLineGutter / SourceEditing / SyntaxColoring / TextFind / TextStatistics / MarkdownFileDocument / WorkspaceFilePolicy / TextBytes / EditorViewMode）以及 `XYZ/Workspace/` 的读写与窗口代码、entitlements、CI 脚本。
- 方法：只用 `read`/`grep`/`glob` 读代码，行号均来自工具输出；未运行 `xcodebuild`，未修改仓库。另用两个独立的 AppKit 探针脚本（`/tmp/xyz_probe.swift`、`/tmp/xyz_probe2.swift`）核实 TextKit 隐式降级、跨文档 undo 栈和行盒计算，结果见 §7.4（探针只用于验证 AppKit 行为，不是产品运行结果）。
- 本机环境：macOS 27.2 (26B123)，Xcode 27.2，SDK 27.2；工程部署目标 macOS 14.0 / iOS 17.0（`project.pbxproj:377-378`）。因此凡是"AppKit 行为"的结论只在本机与 27.x SDK 上实证，macOS 14/15 上的表现未实测。

---

## 0. 结论速览：README/CHANGELOG/docs 的声称与代码核对

| # | 声称（出处） | 代码事实 | 判定 |
|---|---|---|---|
| 1 | 文本视图实际走 TextKit 1，因为读 `layoutManager` 会安装 TextKit 1（`README.md:11`、`CHANGELOG.md:12`、`docs/architecture.md:15`） | `makeNSView` 用 `XYZMacTextView(usingTextLayoutManager: true)` 创建（`XYZ/Editor/XYZMacEditor.swift:1058`），随后读 `textView.layoutManager?.allowsNonContiguousLayout = true`（`XYZMacEditor.swift:1128`）；`keepViewportLayout` 每次重设属性后又读一次（`XYZMacEditor.swift:1639-1644`）。本机探针确认：TK2 视图的 `layoutManager` 为 nil，读取后 `textLayoutManager` 变为 nil（§7.4-A）。 | **基本成立，但依赖未公开的 AppKit 隐式降级**；代码注释与文档互相矛盾（见 P1-5） |
| 2 | 行号 gutter 由同一个 layoutManager 提供，对非连续布局做跳过检测与重测量（`README.md:11`、`CHANGELOG.md:13`、`docs/architecture.md:15`） | TK1 分支确实使用 `textView.layoutManager` + `textContainer`（`XYZ/Editor/LineNumberGutter.swift:273-290`）；但同一 gutter 里还有 TK2 fragment 分支（`:190-245`）和统一行盒分支（`:346-361`），跳过检测只在"TK1 + 折行开"时生效，且检测前先做了全文档 `ensureLayout`（`:313-343`，`:320`）。 | **部分成立**：实现存在三套测量；检测条件窄、代价大、无回归用例（§1.3） |
| 3 | Reading 是每窗口一个 WKWebView，shell 只加载一次，220ms debounce 替换 body（`README.md:16`） | Host 按窗口持有：文件夹窗口在 `WorkspaceSession.swift:108-109`，文档窗口在 `DocumentEditorView.swift:40,52`；`MarkdownWebView.swift:16` 的注释"One web view for one open note"与实现不符。shell 只加载一次由 `didStartLoad/isReady` 保证（`MarkdownWebView.swift:458-459,536-539,599-607`），仅 WebContent 进程终止时重载（`:569-578`）。220/420ms 在 `MarkdownPreview.swift:56`，>20KB 的渲染在后台（`:41,67-74`），版本丢弃用 generation（`:44-63`）。 | **成立**（每窗口一个；注释需改） |
| 4 | Raw HTML 当文本显示，`javascript:`/`data:` 不变成链接（`README.md:16`） | 块级/行内 Raw HTML 都走 `HTMLText.escape`（`XYZCore/Sources/XYZCore/HTMLRenderer.swift:128-134,279-281`）；链接 scheme 白名单 `http/https/mailto`（`:481,492-510`），显式拒绝 `javascript:/vbscript:/data:`（`:500-502`）；图片 scheme 白名单 `http/https`（`:482`）。 | **成立** |
| 5 | "The renderer still does not request remote images"（`README.md:16`） | 图片白名单包含 `http/https`（`HTMLRenderer.swift:482,488-490`），`visitImage` 原样输出 `<img src>`（`:301-318`），shell 无 CSP（`MarkdownWebView.swift:838-1271`），页面 JS 全开（`:435`）；单元测试甚至断言远程图片必须输出：`XCTAssertTrue(html.contains("<img alt=\"A &amp; B\" src=\"https://example.com/a.png\" title=\"Pic\">"))`（`XYZCore/Tests/XYZCoreTests/MarkdownHTMLTests.swift:156`）。 | **不成立**：远程图片会被请求（P1-6） |
| 6 | 文件超过 5 MB 不进编辑器；只读路径（`README.md:68`） | `WorkspaceFileClassifier.editLimit = 5_000_000`（`WorkspaceFilePolicy.swift:30`），`kind` 返回 `.tooLarge`（`:48-50`），界面显示占位（`WorkspaceView.swift:1467-1481`）；只读预览上限 `TextBytes.previewByteLimit = 2_000_000`（`TextBytes.swift:103`，`WorkspaceSession.swift:1597-1607`）；`.readOnly` 文件不给编辑（`EditorViewMode.swift:45-54`）。 | **成立**（注意 2 MB 截断与 5 MB 是两个阈值） |
| 7 | "Find and replace, and large-file updates, can still land on `textLayoutManager`"（`README.md:58`） | macOS 视图在首次读 `layoutManager` 后 `textLayoutManager` 为 nil；`visibleSpan` 等都以 `guard let manager = textView.textLayoutManager` 回退（`XYZMacEditor.swift:1676-1689`）。 | **误导**：macOS 上这条路径不可用，代码实际回退 |
| 8 | 「两端都是 TextKit 2」（`XYZEditor.swift:114`、`MarkdownFileDocument.swift:10`、`XYZMacEditor.swift:6`） | iOS 保持 TK2 并断言（`XYZIOSEditor.swift:210,250`）；macOS 运行时被降级为 TK1（探针实证）。 | **不成立（macOS）**：注释/文档漂移 |
| 9 | highlight.js 11.11.1，common 语言，随包分发（`README.md:169`） | 文件头 `Highlight.js v11.11.1 (git: 08cb242e7d)`（`XYZ/Resources/highlight.min.js:2`），127,496 字节；运行时从 Bundle 读一次并内联进 shell（`MarkdownWebView.swift:807-816,855-857`），`hljs.configure({ignoreUnescapedHTML:true})`（`:877`），只对 `pre code[class*='language-']` 高亮、上限 400 块（`:1129-1133`）。 | **成立** |
| 10 | iOS 与 macOS 共享 `XYZEditor`/`XYZTextEditing`，重复实现（`README.md:58`） | 协议只有 `text/textLayoutManager/perform` 三个成员（`XYZEditor.swift:117-122`）；两端 Coordinator 分别实现（mac `XYZMacEditor.swift:1304-1481`，iOS `XYZIOSEditor.swift:326-369`）；大量逻辑是两份拷贝（§5）。 | **成立**，但有明显漂移 |

---

## 1. 文本视图架构

### 1.1 实际使用的 TextKit 版本：macOS 是"被隐式降级的 TextKit 1"，iOS 是 TextKit 2

- macOS `makeNSView` 的创建顺序（`XYZ/Editor/XYZMacEditor.swift:1057-1129`）：
  1. `XYZMacTextView(usingTextLayoutManager: true)`（`:1058`）——创建时是 TextKit 2；
  2. 设置 `isRichText/importsGraphics/allowsUndo/...`（`:1059-1087`）；
  3. `pane.attach(textView)`、`applyChrome`、`textView.string = text`、`warmLineIndex()`、`restyle(edited: nil)`、`observeScroll`、`applyWrap`（`:1120-1127`）；
  4. **最后一行**才是 `textView.layoutManager?.allowsNonContiguousLayout = true`（`:1128`）——这一读让 AppKit 把视图从 TextKit 2 惰性降级为 TextKit 1。
- 之后的 `EditorTypography.keepViewportLayout` 每次 restyle 都会再读一次 `layoutManager` 并把 `allowsNonContiguousLayout` 置回 true（`:1639-1644`），说明作者在实测中观察到 `setAttributes` 会把它清掉——这也从侧面证明运行时确实是 TK1。
- 诊断路径：`LineNumberGutter.swift:129` 与 `GutterSnapshot.swift:200` 用 `textView.textLayoutManager == nil ? "textkit1" : "textkit2"` 输出 api 名，但只在 `-XYZDiagnostics` 打开时真正写日志（`XYZDiagnostics.swift:87-98`），且没有任何断言/CI 判定要求它是 `textkit1`。
- iOS 不同：`XYZIOSTextView(usingTextLayoutManager: true)`（`XYZIOSEditor.swift:210`）后从不读 `layoutManager`，并断言 `textLayoutManager != nil`（`:250`），所以 iOS 真的在 TextKit 2 上。
- 探针（§7.4-A）在本机确认了降级：`A tk2 before: textLayoutManager != nil: true layoutManager == nil: false` → `B after read .layoutManager: textLayoutManager != nil: false`。这与仓库文档的结论一致，但它是一个**未写入 AppKit 文档的副作用**：外部项目也记录了"默认初始化的视图是 TextKit 2，首次访问 `.layoutManager` 时惰性降级，可能留下 layoutManager/textContainer 配对不一致，随后在 `glyphRangeForTextContainer:` 抛 `NSInvalidArgumentException`"（[osaurus 的回归测试](https://github.com/osaurus-ai/osaurus/blob/b4f10dfd86b94d7a00848b0ec941d0fe0b205328/Packages/OsaurusCore/Tests/Chat/TextViewTextKitModeTests.swift)）。这条风险见 P1-5。

### 1.2 为什么选这条路径（从 CHANGELOG 判断）

历史不是"设计成 TextKit 1"，而是被窗口截图逼回去的：

- 0.5.23：折行不再把视觉行当源码行（`CHANGELOG.md:75-77`）。
- 0.5.24：曾坚持 TextKit 2，但"Reading `layoutManager` was installing TextKit 1, and a wrapped gutter then had no fragments to number"（`CHANGELOG.md:69`）。
- 0.5.25：又回到 TextKit 2 viewport（`CHANGELOG.md:64`）。
- 0.5.26：真正的问题被记录——"TextKit 2 puts the body in fragment subviews. A layer-backed SwiftUI window was compositing the text view's layer without those subviews, so the gutter showed and the page stayed white. `cacheDisplay` still called `draw` and counted that ink."（`CHANGELOG.md:52`）；同一版本还说明 Reading 行号被删除（`:55`）。
- 0.5.27：编辑文件回退到"窗口能显示正文"的版本（`CHANGELOG.md:48`）。
- 0.5.28：接受 TextKit 1，保留"可见行号跳过时连续重测一次"的补丁，并明确拒绝 TextKit 2 重写（`CHANGELOG.md:11-13,21-23`、`docs/architecture.md:15,25`）。

结论：这是为了绕开"layer-backed SwiftUI 窗口 + TK2 fragment 子视图不参与合成"的 AppKit 问题而选择的逃生路径；代价是放弃 TK2 的 viewport 布局与按需排版，并把行号正确性押在 TK1 的 `allowsNonContiguousLayout` 估计行为上。

### 1.3 Gutter 与非连续布局/重测量策略的正确性

live gutter 是 `LineNumberGutter`（368 行），绘制入口 `draw(_:)`（`XYZ/Editor/LineNumberGutter.swift:70-142`）。它每次绘制调用 `placedRows`（`:154-179`），后者依次尝试：

1. **TK2 fragment 分支**：`fragmentRows`（`:190-245`）；
2. **TK1 + 折行**：`layoutManagerRows`（`:273-290`）；
3. **再试一次 viewport layout 后的 fragment**（`:167-172`）；
4. **空文档**：`emptyRow`（`:292-304`）；
5. **不折行**：`lineBoxRows`（`:346-361`），按统一行盒估算。

`layoutManagerRows` 的"跳过检测/重测量"逻辑（`:273-290`）：

```swift
let first = lineFragmentRows(...)            // 内部已 ensureLayout 全文档（:320）
let numbered = first.filter(\.showsNumber).count
if Self.isSourceRun(first), first.count > numbered { return first }   // 编号连续且有换行续行 → 认为正常
guard layout.allowsNonContiguousLayout else { return first }
layout.allowsNonContiguousLayout = false
layout.ensureLayout(forCharacterRange: 0..<length)                    // 第二次全文档排版
let second = lineFragmentRows(...)
layout.allowsNonContiguousLayout = true                               // 恢复，但不在 defer 里
return second
```

正确性问题（按严重度）：

1. **检测发生在两次全量排版之后**：`lineFragmentRows` 一开始就 `layout.ensureLayout(forCharacterRange: 0..<length)`（`:320`），而 `layoutManagerRows` 在判断"要不要重测"之前已经调用了它。也就是说，这个"只在跳过时重测"的优化并没有省下全量排版：**TK1 + 折行时，每次 gutter 重绘都至少有一次全文档 `ensureLayout`，跳过时是两次**（P1-4）。
2. **检测只认"编号不连续 + 有换行续行"**：`isSourceRun`（`:306-311`）要求 visible 编号是从 first 开始的连续整数。若估计把某些行整体压缩（编号仍连续、但 y 错位），它不会触发重测；反过来，若第一次估计刚好连续，第二次也可能给出错误 y。
3. **折行关闭时不走 TK1 fragment 分支**，直接 `lineBoxRows` 用统一行盒（`:346-361`）；而 `lineBoxRows` 的行盒来自 **gutter 字体**（`Self.font`：`max(10, 0.75*fontSize)`，`:23-25,347-349`），不是编辑器字体。行距设置低于约 1.2 时两者不一致，行号会逐行漂移（P1-3，实测 2.84pt/行 @ 1.0）。
4. **恢复 flag 没有 `defer`**：`:282` 置 false，`:288` 置 true，中间若 `lineFragmentRows` 或 `ensureLayout` 触发 Objective-C 异常（隐式降级场景下并非不可能），进程内该 layoutManager 会永久处于连续排版模式，之后的排版/滚动代价全部变大。当前代码没有 Swift `throw` 路径，所以不是必然漏洞，但属于"恢复 flag 不完整"的典型写法。
5. **无回归覆盖**：`GutterSnapshot.swift` 的 `layoutGutter` 明确注释"Detached `EditorPane`. It never calls `XYZMacEditor.makeNSView` and never reads `layoutManager`, so a pass here does not mean the window drew numbers."（`:1279-1281`）；也就是说 `checkEditing`（`:1240-1265`，断言 `api == "textLineFragments"`）验证的是 TK2 路径，**不是生产使用的 TK1 路径**。生产路径只有 `renderProductionEditors` 的 28 行小样本（`:68-81,183-232`），没有窄窗折行跳号场景，也没有"编辑后行号"检查。CHANGELOG 里 `1,2,3,13,22,23` 的具体故障因此没有对应的自动化用例（P2-14）。

另外，`GutterSnapshot.swift` 与 `LineNumberGutter.swift` 都各自维护一套行号来源；`XYZCore/LogicalLineGutter.swift` 里还有第三套 `labels/editingLabels/readingLabels`（`:11-41`），但 live 代码只用了 `highlighted`（`LineNumberGutter.swift:88-92`），其余只出现在单元测试（`XYZCore/Tests/XYZCoreTests/TextFindTests.swift:73-128`）。

### 1.4 每次绘制的性能代价

`LineNumberGutter` 的重绘触发路径：

- 选中变化 → `textViewDidChangeSelection`（`XYZMacEditor.swift:1405-1409`）→ `caretMoved`（`:632-643`）→ `editorPane?.gutter.needsDisplay = true`；
- 文本变化 → `lineNumbersChanged`（`:625-629`）→ `invalidateLines()` + pane `needsLayout`；
- 滚动 → `EditorPane.attach` 注册 clip bounds 通知（`:961-980`）→ `gutter.noteGeometryChanged()`（`LineNumberGutter.swift:41-52`）；
- 文本视图自身 `layout()` 也会调用 `editorPane?.noteTextLayout()`（`XYZMacEditor.swift:584-598`）→ `gutter.noteGeometryChanged()`。

几何 key 做了去重（`:42-52`），但 key 里的行数/当前行来自可能陈旧的 `LineIndex`（P1-2）。**只要 "TK1 + 折行开"（默认设置就是折行开）成立，每次重绘都会走到 `:320` 的全文档 `ensureLayout`**；大文档输入/滚动时这是主线程 O(n) 的工作量（§6-H2）。

---

## 2. 编辑正确性

### 2.1 Markdown 列表续行/缩进（`XYZCore/SourceEditing.swift`）

- 续行：`newline(in:selection:)`（`:57-83`）。逻辑：只处理零长选区、在代码围栏外（`:61`）、当前行有列表标记（`:64`），且光标必须已越过 marker 区（`:66`）；空列表项则调用 `closeEmptyItem`（`:68-69,109-132`），把 marker（或一级缩进）删掉，实现"在空项上回车离开列表"。
- 缩进/反缩进：`indent/outdent` → `shift`（`:134-183`），多行选区按行重建文本；只有至少一行带列表标记才改（`:175`），否则返回 nil，由平台视图回退到原生 Tab（mac `XYZMacEditor.swift:96-108`；iOS 的 Tab 走 `insertText` 重写，`XYZIOSEditor.swift:80-85`）。
- 有序列表：`orderedMarker` 会解析数字并在续行时 +1（`:321-348`）；任务列表续行固定输出 `" [ ] "`（`:297-313`）。
- 围栏检测：`insideFence`（`:377-391`）从文档头扫描到光标行——**每次回车/缩进都 O(位置) 扫描**；对长文档连续按回车代价随位置线性增长（§6-H1 的一部分）。
- 续行细节：`:73-75` 只在光标右侧是空格时吞掉一个空格（`replaced = 1`），避免 `- |item` 变成两个空格；这是刻意的。

潜在缺陷：`shift` 在"多行选区"与"零长选区"下的 `locationShift/lengthShift` 计算（`:142-178`）只按行起点比较，若选区起点在某行中间且该行被缩进，光标所在行之后的偏移会正确 +2，但*选区起点在同一行内*时 `line.location <= selection.location` 成立，也会 +2，符合预期；边界情况（选区 end 恰在行首）会多算一次 lengthShift，属于 P2 级细节，未在本次静态检查中定论（需 XCTest 覆盖）。`SourceEditing` 本身已有测试（`XYZCore/Tests/XYZCoreTests/TextFindTests.swift:73` 附近之外的 SourceEditing 测试文件未在本任务范围内核对，标为待确认）。

### 2.2 Undo 与 document scene 的 undo manager

- 文档场景：`DocumentEditorView` 从 SwiftUI 环境取 `@Environment(\.undoManager)`（`DocumentEditorView.swift:34`），传给 `XYZEditor(undoManager:)`（`:124-141,143-158`）→ `XYZMacEditor/XYZIOSEditor` → 平台视图。
- macOS：`XYZMacTextView` 重写 `undoManager` 返回 `documentUndoManager ?? super.undoManager`（`XYZMacEditor.swift:43-45`）；`allowsUndo = true`（`:1065`）。SwiftUI 场景用 undo 注册来跟踪 dirty（`MarkdownFileDocument.swift:10-12` 注释；`MarkdownFileDocument` 只在 `storeEditorText` 存文本，不调用 `updateChangeCount`，`:47-58`）。
- 程序性替换（磁盘重载/换文件）时只 `disableUndoRegistration` 包住 `textView.string = replacement`（`XYZMacEditor.swift:1376-1393`），**没有清空 undo 栈**。
- 全仓库没有 `removeAllActions` 调用（grep 结果为空）；文件夹窗口同一 `XYZMacTextView` 在多个 tab 之间复用（`WorkspaceView.swift:1626-1658` 的 `editor` 分支不随 tab 重建；`session.buffer?.editorToken` 变化只触发 `perform(.replaceContents)`）。本机探针确认：`textView.string = "XY"` 之后 `canUndo` 仍为 true，执行 undo 直接抛 `NSRangeException`（§7.4-B）。这是 **P0-1（崩溃 + 潜在数据损坏）**。

### 2.3 marked text / 输入法

- mac：`restyle` 在 `hasMarkedText()` 时跳过（`XYZMacEditor.swift:1425-1439,1445,1468`）；`applyMarkupEdit/applySourceEdit` 也 guard（`:117,132`）。iOS：`applyMarkupEdit` guard `markedTextRange == nil`（`XYZIOSEditor.swift:98`）。
- 但 `textDidChange` 在组合期间仍然把 `textView.string`（含 marked text）推给 `onTextChange`（`XYZMacEditor.swift:1440`），workspace buffer 会当作用户编辑并排队自动保存（`WorkspaceSession.swift:1750-1766,1881-1895`）；组合被取消时再推一次。通常最终文本正确，但**磁盘/自动保存可能短暂写入组合中的拼音**。
- `perform(.replaceContents)` 没有 `hasMarkedText()` 检查（`XYZMacEditor.swift:1376-1393`），磁盘外部变更触发重载时若正在组合，会直接替换字符串并丢掉组合；`docs/architecture.md:29` 与 `CHANGELOG.md:44` 自述"Real IME composition is not covered here / A real Chinese input method was not run"，这一点与代码一致：只做了浅层保护。归 P2-9。

### 2.4 选区与查找替换（含 regex / whole word）

- 编辑器侧：`FindQuery`（`TextFind.swift:4-16`）；`matches` 用 `NSRegularExpression`，非 regex 时先 `escapedPattern`，whole word 用 lookaround `(?<![\p{L}\p{N}_])…(?![\p{L}\p{N}_])`（`:138-148`），非法正则通过 `try?` 变 nil → `isValid` 为 false（`:91-93`），UI 显示 `regexInvalid`（`EditorChrome.swift:28`；`XYZMacEditor.swift:360-374`）。
- 查找整个流程在后台：`scheduleReveal` 用 `Task.detached` 跑 `FindScan.make`（`XYZMacEditor.swift:333-350,451-510`），带 generation 防旧结果（`:339,346`）。
- **replaceCurrent / replaceAll / selectNextOccurrence 在主线程同步扫描全文**：`TextFind.matches(in: string, ...)`（`XYZMacEditor.swift:514,540,569`；`TextFind.swift:29-39`），`replaceAll` 还对全文 `NSRegularExpression.matches` + 反向替换（`TextFind.swift:66-79`）。大文档（≤5 MB）下会明显卡顿（§6-H7）。
- replace 的 undo：`applySourceEdit` 用 `beginUndoGrouping/endUndoGrouping` + `defer`（`XYZMacEditor.swift:130-144`），一次 replace 一个 undo 组；`replaceEvery` 把全文替换成新字符串（`:538-549`），undo 恢复旧全文，行为正确。
- Reading 侧的 find 走 WebKit `WKFindConfiguration`（`ReadingSurface.swift` 内 `MarkdownWebView.swift:364-382`）或自研 JS 高亮（`xyzHighlightFind`，`MarkdownWebView.swift:901-962`）；两者都与编辑器实现不同（P2-10）。Reading 里 replace 直接 beep（`EditorChrome.swift:144-145`），与 README "换行那一行只用于 Editing"一致。
- 选区：mac 支持多选区插入（`XYZMacEditor.swift:234-245`），`selectNextOccurrence`（`:551-582`）；`applySelectionChrome` 在 appearance 变化时更新选中色（`:55-64,1276-1282`）。`paste` 被强制为纯文本（`:47-49`），`changeFont/changeColor` 被禁用（`:51-53`），避免富文本污染 buffer。

### 2.5 行号逻辑：确实是两套（甚至三套）实现

1. live mac gutter：`LineNumberGutter.placedRows`（`LineNumberGutter.swift:154-179`）自己算 `showsNumber`（first fragment 编号、wrap 续行空号），`draw` 里只用 `XYZCore.LogicalLineGutter.highlighted` 做当前行 band 的选择（`:88-102`）。
2. `XYZCore/LogicalLineGutter`：`labels/editingLabels/readingLabels/placedReading`（`LogicalLineGutter.swift:11-121`）完整实现了一遍"视觉行→源码行"的映射，但 live 代码只用了 `highlighted`（`:23-25`），其余只在单测中（`TextFindTests.swift:73-128`）。
3. Reading 的 JS 行号：`xyzLayoutGutter`（`MarkdownWebView.swift:1041-1108`）完整存在，但 `PreviewPrefs.script` 恒调用 `setLineNumbers(false)`（`:51,55-63`），`data-lines` 永远不是 `"true"`（`:1048-1054`），消息处理器 `xyzGutter`（`:473-494`）永远收不到计数。0.5.26 起 Reading 已明确无行号（`CHANGELOG.md:55`），这段是死代码。

### 2.6 折行与当前行 band

- band：`drawBackground` → `drawCurrentLineBand`（`XYZMacEditor.swift:682-705`）。折行开时用 `currentLineBand()` 取 TK2 fragment 的 `layoutFragmentFrame`（`:667-680`）；折行关时退化为"第 (line-1) 个统一行盒"（`:699-701`），与 `lineBoxHeight()`（`:744-748`，用编辑器字体）一致；但 gutter 的 `lineBoxRows` 用 gutter 字体（P1-3），所以 band 和数字在无折行 + 低行距时会错位（band 按编辑器盒，数字按 gutter 盒）。
- 选中变化时 band 的刷新靠 `caretMoved` 的 `setNeedsDisplay(previous/next)`（`:632-643`）；band 只在 `isEditable` 时画（`:685`）。
- 缩进参考线：`drawIndentGuides`（`:708-742`）同样按"统一行盒"定位（`:712-715`），并用 `lineIndexCache ?? LineIndex(string)`（`:711`）→ 复用可能陈旧的索引（P1-2）。
- TK2 分支的 band 依赖 `textLayoutManager`（`:667-680`），但 macOS 运行时该值为 nil，所以"折行开"时 band 实际总是走 `currentLineBand()` 失败 → 落在 uniform box 分支？注意 `drawCurrentLineBand` 的判断是 `if style.wraps, let laid = currentLineBand()`（`:694`）：`currentLineBand()` 在 TK1 下返回 nil，于是进入 `else` 的统一行盒分支（`:696-701`）。因此在真实 macOS 生产路径（TK1）上，**折行时当前行 band 也是统一行盒，不覆盖被折行的多视觉行**；与 `:690-691` 注释"Wrapping uses the laid-out fragment, which covers every visual row of that line"不符（P2-11，行为退化但不崩）。

### 2.7 5 MB 大文件与只读路径

- 打开：`WorkspaceSession.readForEditing`（`:1564-1607`）先读 8 KiB 样本（`WorkspaceFileClassifier.sampleLimit = 8_192`，`WorkspaceFilePolicy.swift:28`）判类；>5 MB → `.tooLarge`，`FileOpenRouting` → `.readOnlyPreview`（`WorkspaceFilePolicy.swift:196-213`），编辑器分支显示"File Too Large / Open with Default App"（`WorkspaceView.swift:1467-1481`）。
- 只读预览：2 MB 截断（`TextBytes.previewByteLimit`，`TextBytes.swift:103`；`WorkspaceSession.swift:1597-1607`），`WorkspaceFileBuffer.previewTruncated` 标记（`:1660-1663`），状态栏显示 "Preview truncated"（`WorkspaceView.swift:1488-1490`）；`.readOnly` 的 `isDirty` 恒 false 且 `userEdited` 直接 return（`WorkspaceSession.swift:1657-1658,1750-1752`），不会被保存。
- 编辑器内的 >5 MB 情况不会出现；但 3–5 MB 文件仍会被完整读成 Swift String 进 `NSTextStorage`，每个击键都经 `onTextChange(String)` → buffer → preview bridge → outline 全量传递（§6-H4），这是"限制 5 MB"之外仍需关注的成本。
- 只读（Reading）路径：非 Markdown 的 Reading 复用同一个文本视图，`isEditable=false`（`EditorViewMode.swift:66-77`；`WorkspaceView.swift:1559-1573`），band/缩进线/查找替换都被 `isEditable` 或 `EditorModeChoice` 关掉；Markdown 的 Reading 是 WKWebView（`WorkspaceView.swift:1574-1576,1619-1625`）。

---

## 3. 预览侧

### 3.1 WKWebView 的创建/复用/销毁

- `PreviewWebHost` 懒创建 `WKWebView` 与 `PreviewWebCoordinator`（`MarkdownWebView.swift:17-41`）：`webView` getter 第一次访问时 `PreviewWebViewFactory.make()`（`:24-34`），此后复用。
- 持有者：文件夹窗口是 `WorkspaceSession.previewHost`（每窗口一个，`WorkspaceSession.swift:108-109`）；文档窗口是 `DocumentEditorView` 的 `@State webHost`（每个文档窗口一个，`DocumentEditorView.swift:39-40,51-52`）。所以事实是"每窗口一个，跨笔记复用"；`MarkdownWebView.swift:16` 的 "One web view for one open note" 是错的（P2-12）。
- 销毁：没有显式的 `dismantle`/teardown；Reading 离开时 `ReadingSurface` 把 webview 从父视图移除（`MarkdownWebView.swift:246-260`、iOS `:405-413` + `claim()` `:425-430`），但 host 仍持有 webview，直到窗口/session 释放。这是 README 描述的有意设计（"The view stays with the window"）。
- 注意：文档窗口在 `macBody.onAppear` 里无条件 `commands.readingWeb = webHost.webView`（`DocumentEditorView.swift:209-212`），**即使当前文件不是 Markdown、或一直停在 Editing，也会为每个文档窗口创建 WebContent 进程**（P2-13）。

### 3.2 shell 只加载一次的实现

- 状态机：`didStartLoad`、`isReady`、`pendingHTML/appliedHTML`、`pendingTheme/appliedTheme`、`pendingPrefs/appliedPrefs`（`MarkdownWebView.swift:458-471`）。
- 首次 `update` → `loadShell`（`:536-539`），`webView.loadHTMLString(PreviewPage.shell(...), baseURL: nil)`（`:599-607`）——`baseURL: nil` 意味着页面 origin 是 opaque/about:blank。
- 之后 `update` 只把最新状态存进 pending，`push` 用 `evaluateJavaScript` 做增量：`setTheme/setBase/setPrefs/setContent/xyzRevealLine/xyzReport`（`:609-644`）。`appliedHTML` 相等则跳过（`:626-630`），所以同一 HTML 不会重复注入。
- 脚本错误只记录一次（`:466,667-676`），不会重载 shell。
- 进程崩溃：`webViewWebContentProcessDidTerminate` 重置全部状态并重新 `loadShell`（`:569-578`）。
- 缺陷：`didFail/didFailProvisionalNavigation` 只写日志（`:557-567`），既不重试也不把 `isReady` 复位；若首次 shell 加载失败（极少数情况），Reading 会一直空白到下次 `didStartLoad` 被重置（P2-15）。

### 3.3 渲染版本丢弃（PreviewBridge / PreviewModel）

- `PreviewBridge` 只保存 `latestText` 和唯一 listener（`MarkdownPreview.swift:10-34`），editor 每次变更 `send`（`WorkspaceView.swift:1645`、`DocumentEditorView.swift:163`、`WorkspaceSession.swift:893`）。
- `PreviewModel.schedule`（`MarkdownPreview.swift:46-65`）：先 `task?.cancel()`、`generation += 1`；220ms（>120KB 时 420ms）后渲染，渲染完再判 `generation == token` 才 publish（`:62`）；`publish` 还做 `html != rendered` 去重（`:76-79`）。`immediate` 且 ≤20KB 时同步 publish（`:50-53`）；>20KB 的渲染在 `Task.detached`（`:67-74`）。这就是 docs 说的 "PreviewModel drops a render when a newer one has been scheduled"。**成立**。
- 细节：`adopt` 对 >20KB 的文件什么都不做（`:82-85`），所以大文档首次 shell 的 `<article>` 是空的，随后才注入（`:626-630`）——用户会看到 Reading 先空白再出现内容。

### 3.4 消息传递与 WKScriptMessageHandler

- 注册：`add(coordinator, name: "xyzAnchor"/"xyzGutter")`（`MarkdownWebView.swift:29-30`），没有对应的 `removeScriptMessageHandler`。
- 引用关系：`WKUserContentController` 强持有 coordinator；`PreviewWebHost` 强持有 webview 和 coordinator；coordinator 不持有 host/webview（`scrollLink.capture` 与 reveal 闭包都是 `[weak self, weak webView]`，`:525-534`）。因此**没有发现循环引用/泄漏**；但生命周期与窗口绑定——窗口存活期间 coordinator 与页面都不会被释放，页面里 `setInterval` 式的 `xyzScheduleGutter` 也仍在。若以后需要多窗口频繁开关，应补 `removeScriptMessageHandler`（P2-12）。
- 性能：页面在 `scroll` 事件里每帧 `xyzReport()`（`:1257`）；coordinator 的 `didReceive` 在主线程（`:473-518`），每次消息还会 `MainActor.assumeIsolated` 调 `scrollLink.onViewportLine`（`:504-506`）→ SwiftUI 状态更新。长文档滚动时这是 WebContent→UI 进程的高频 IPC（§6-H9）。

### 3.5 220ms debounce 与打字延迟

- 220ms / 420ms（`MarkdownPreview.swift:56`），与 README "about 220ms (a little longer for a large note)" 一致；`syncLimit` 20,000（`:41`）。
- 打字延迟链条：`textDidChange` → `onTextChange`（同步、全文）→ `PreviewBridge.send` → `schedule`（取消旧 task）→ 220ms 后渲染。大文档（>20KB）渲染在后台线程，主线程只负责最后的 `publish` 与 SwiftUI 更新；但 `setContent` 后的 `innerHTML` 替换、`hljs` 高亮（最多 400 个代码块，`MarkdownWebView.swift:1129-1133`）都在 WebContent 进程主线程执行（§6-H5）。

### 3.6 沙盒例外（network client）与攻击面

- macOS entitlements 含 `com.apple.security.network.client`（`XYZ/XYZ-macOS.entitlements:7`）；iOS entitlements 没有该键（`XYZ/XYZ-iOS.entitlements` 全文）。
- README 的说辞是"so the web content process can start"（`:16,134`）。从静态代码只能确认：这是**应用级网络权限**，不是预览专用；当前渲染器确实允许 http/https 图片（`HTMLRenderer.swift:482`），所以该权限有实际用武之处。它也确实扩大了攻击面：页面 JS 全开（`MarkdownWebView.swift:435`）、shell 由字符串拼接而成、WebContent 进程一旦被攻破可直连网络。
- 建议：如果产品目标是"Reading 不联网"，应把 `URLPolicy.imageSchemes` 收紧为仅相对路径（或 `xyz-asset`），并给 shell 加 CSP（`img-src xyz-asset: data:; script-src 'unsafe-inline' …`），然后再实测能否去掉 network client（去掉后若 WebContent 无法启动，则保留并在文档中说明真实原因）。见 P1-6。

---

## 4. 安全

### 4.1 Markdown → HTML 的转义与 URL 白名单

- Raw HTML：`visitHTMLBlock` 输出 `<pre class="raw-html">` + `HTMLText.escape`（`HTMLRenderer.swift:128-134`）；`visitInlineHTML` 直接 escape（`:279-281`）。转义覆盖 `& < > " '`（`:448-477`），属性值额外把换行压成空格（`:474-477`）。
- 链接：`URLPolicy.linkDestination` 只放行 `http/https/mailto` 与"无 scheme 的相对路径"（`:484-486,492-510`）；`sanitize` 先拒绝控制字符（`:496-498`），再显式拒绝 `javascript:/vbscript:/data:`（`:500-502`），未知 scheme 一律拒绝（`:503-508`）。
- 图片：`imageSource` 只放行 `http/https` 与相对路径（`:482,488-490`）；`xyz-asset` 绝对 URL 会被当作未知 scheme 拒绝，但**相对路径会通过 `<base>` 解析成 `xyz-asset://…`**。
- 代码块语言：`languageToken` 只保留字母/数字/`-`/`_`（`:349-354`），再经属性转义；标题 id 走 `HeadingAnchor.slug` + `HTMLText.attribute`（`:26-38`，`389-420`）；`data-line/data-end` 是纯数字（`:326-334`）。
- 表格对齐等 style 来自枚举（`:336-347`），不可注入。
- 注入面结论：**在本静态检查范围内没有发现 Markdown 内容 → HTML 属性/标签注入的路径**。`setContent` 使用 `innerHTML`（`MarkdownWebView.swift:861-872`），但输入是渲染器输出，转义/白名单如上；shell 里 `html` 首次内联（`:854`）同理。`hljs` 用 `ignoreUnescapedHTML: true`（`:877`），避免旧版 highlight.js 的"未转义 HTML 再解析"风险。

### 4.2 远程图片/网络（与 README 矛盾）

`imageSchemes` 包含 `http/https`（`HTMLRenderer.swift:482`），`visitImage` 原样输出（`:301-318`），单元测试把"远程图片必须输出"钉死（`XYZCore/Tests/XYZCoreTests/MarkdownHTMLTests.swift:156` 断言 `src="https://example.com/a.png"`），shell 无 CSP，WKWebView 允许内容 JS（`MarkdownWebView.swift:435`）、应用带 network.client（entitlements:7）。因此打开一个包含 `![](https://attacker/x.png?note=…)` 的笔记会在 Reading 首次渲染时**静默发出网络请求**：泄露 IP、打开时间、文档与用户的关联（若 URL 带唯一参数），并可做"已读回执"。这与 `README.md:16` 的 "The renderer still does not request remote images" 直接冲突。归 P1-6。

（同一机制的反向利用有限：内容不能执行 JS，因此不能携带文档正文；但 `xyz-asset` 相对路径读取见下。）

### 4.3 相对图片路径解析与 `xyz-asset` 自定义 scheme

- `<base id="xyz-base" href="…">` 由 `LocalAssets.baseHref(for: baseDirectory)` 生成：`xyz-asset://local` + 笔记目录的绝对路径（`LocalAssets.swift:15-23`），目录来自 `session.buffer?.url.deletingLastPathComponent()`（`WorkspaceView.swift:1620-1625`）或 `DocumentEditorView` 的 `fileURL`（`DocumentEditorView.swift:169-175`）。
- 读取：`LocalAssets.fileURL(for:)` 只看 scheme 和 `url.path` 是否以 `/` 开头（`LocalAssets.swift:26-31`），**没有 canonicalize、没有 symlink 解析、没有"必须位于 baseDirectory 之下"的检查**；handler 只按扩展名过滤 `image`/`audiovisual`（`:33-37`），然后 `Data(contentsOf:)`（`:58`）。
- 后果：
  1. `![](../../../../<任意绝对路径>/x.png)` 经 URL 归一化后变成 `xyz-asset://local/<绝对路径>`，只要目标是图片/媒体且 sandbox 允许读，就会被显示。单个文档窗口的 sandbox 只授权该文件，通常挡住；**文件夹窗口会授权整棵树，多开文件夹窗口时 app 同时持有多个文件夹的 sandbox extension（`WorkspaceWindowController.swift:41,517`，书签见 `WorkspaceFileAccess.swift:228-271`），因此笔记 A 可以显示文件夹 B 里的图片/媒体**。
  2. `LocalAssets.fileURL` 忽略 host，`xyz-asset://anything/…` 同样按绝对路径读；没有校验请求是否来自当前笔记目录。
  3. `Data(contentsOf:)` 在后台线程整文件读入（`:57-58`），对超大视频没有大小上限、没有 Range 支持。
- 对照：**链接**的打开路径反而做了目录约束——`WorkspaceSession.openLinked` 要求 `path.hasPrefix(root + "/")`（`WorkspaceSession.swift:360-368`），超出根目录则交给 `NSWorkspace.shared.open`；文档窗口的 `openFile` 则直接 `NSDocumentController.openDocument`（`DocumentEditorView.swift:179-182`）。所以"图片/媒体无约束、链接有约束"是不对称的。
- 归 P1-7（安全/越权读，sandbox 兜底所以不是任意文件读取，但违背了"仅笔记目录"的模型，且跨文件夹窗口可见）。

### 4.4 其他 preview 安全细节

- `openIfSafe` 只对 `http/https/mailto` 调 `NSWorkspace.shared.open`/`UIApplication.shared.open`（`MarkdownWebView.swift:686-699`）；`file:` 等被丢弃。
- `decidePolicyFor` 只对 `.linkActivated` 做特殊处理，其余导航 `.allow`（`:580-597`）；内容 HTML 不含可执行标签，且 `#fragment` 由页面 JS `preventDefault`（`:1144-1156`），未发现可让 WebView 导航到任意页面的输入。
- Debug 构建 `webView.isInspectable = true`（`:449`），Release 不开启。
- `LocalAssetSchemeHandler.shared` 是单例，`active` 集合只在主线程读写（`LocalAssets.swift:42-81`）；`stop` 与完成回调的竞态处理是正确的（`:60`）。
- `highlight.js` 11.11.1 的 common bundle 以字符串内联进 shell（`MarkdownWebView.swift:807-816,855-857`）；文件内不含 `</script`（grep 计数 0），版本本身没有已知的高危 XSS 公告（10.4.1 之前的 ReDoS 已修复；11.11.1 不在受影响范围）。

### 4.5 降级（内容被拦截时）

- 图片加载失败由页面 `error` 事件替换为 `.missing-image` 文本（`MarkdownWebView.swift:1120-1142`）。
- 代码高亮失败被 `try/catch` 吞掉（`:1132`），退化为普通 `<code>`。
- 渲染失败/脚本失败：只写日志（`:557-567,667-676`），Reading 可能空白（P2-15）。
- 没有 `WKContentRuleList`/CSP/`WKNavigationDelegate` 的"content blocked"降级概念；当前实现也没有内容过滤器。

---

## 5. iOS / macOS 共享层漂移

### 5.1 共享结构

- `XYZEditor`（`XYZ/Editor/XYZEditor.swift`，411 行）按平台分派到 `XYZMacEditor` / `XYZIOSEditor`（`:228-265`）；`XYZTextEditing` 协议（`:117-122`）只有 `text`、`textLayoutManager`、`perform(.replaceContents)` 三个成员；两端 Coordinator 分别实现（mac `XYZMacEditor.swift:1304-1481`，iOS `XYZIOSEditor.swift:326-369`）。
- 平台分支密度：`XYZ/Editor` + `XYZ/Preview` 共 24 处 `#if os(`（其中 23 处 macOS，1 处 iOS；`XYZIOSEditor.swift` 整个文件是 iOS-only）。`MarkdownWebView.swift` 自己就有 11 处。
- 重复代码（不是共享实现）：
  - 滚动锚点/恢复：mac `scrollAnchor/jump/reveal/alignIfReady/scrollLineToTop/lineOffset/viewportTopLine`（`XYZMacEditor.swift:772-927`）vs iOS 同名实现（`XYZIOSEditor.swift:48-196`）——两份 ~150 行高度相似代码；
  - `applyMarkupEdit`：mac 直接改 `textStorage`（`XYZMacEditor.swift:116-127`），iOS 走 `UITextInput.replace/textRange`（`XYZIOSEditor.swift:97-111`）；
  - `perform(.replaceContents)`：mac 关 undo + clear chrome + 异步 restyle（`XYZMacEditor.swift:1376-1393`），iOS 直接 `textView.text = replacement`（`XYZIOSEditor.swift:342-351`）；
  - 样式：mac 有 ~519 行 `EditorTypography`（`XYZMacEditor.swift:1483-2001`，heading/marker/code/syntax），iOS 只有 27 行 `applyTypingStyle`（`XYZIOSEditor.swift:285-311`，只设 font/paragraph）。

### 5.2 iOS 的功能缺口 / 不一致（有代码证据）

| 能力 | macOS | iOS | 证据 |
|---|---|---|---|
| 行号 gutter | 有 | 无 | `LineNumberGutter.swift:1` macOS-only；`lineNumbersVisible` 是 macOS-only 参数（`XYZEditor.swift:211-215`） |
| 查找/替换 | 有（编辑器 + Reading） | 无 | `find` 参数 macOS-only（`XYZEditor.swift:214-215`）；`EditorChrome.swift:1`/`EditorFindModel` macOS-only；`XYZIOSEditor.swift:6` 注释"future … find/replace" |
| 语法/Markdown 着色 | 有 | 无 | `syntax` 没传给 iOS（`XYZEditor.swift:254-263`）；`applyTypingStyle` 只设 font/paragraph（`XYZIOSEditor.swift:285-311`） |
| 字号/行距/字体/可读宽度设置 | 应用到编辑器 | 编辑器忽略 | iOS 用 `XYZEditorStyle.markdown` 默认 16pt（`XYZIOSEditor.swift:211`）和 `XYZEditorStyle(monospaced:)` 默认值（`:286`）；Reading 侧却用 `@AppStorage`（`MarkdownWebView.swift:97-111`）→ Source 与 Reading 字号不一致 |
| 拼写检查开关 | 按文件类型 | 恒定开启 | mac 用 `spellCheck`（`XYZMacEditor.swift:1072,1149-1151`）；iOS 固定 `.yes`（`XYZIOSEditor.swift:219`），`XYZEditor.swift:254-263` 根本没传 `spellCheck` |
| 折行开关 | 有（`wordWrapKey`） | 无 | `XYZEditor.swift:224-226` macOS-only |
| 状态栏行列 | 有（`onSelection`） | 无 | `onSelection` macOS-only（`XYZEditor.swift:209`）；iOS 调用未传（`:254-263`） |
| 文件夹模式/标签页/大纲/Go to Line | 有 | 无 | `WorkspaceView.swift:1` 是 `#if os(macOS)`；iOS 只注册 `DocumentGroup` + `ViewModeCommands`（`XYZApp.swift:10-40`） |
| Reading 内查找 | 有（ReadingSurface/JS） | 无 | `ReadingSurface` 在 `#if os(macOS)`（`MarkdownWebView.swift:121-396`）；iOS 分支 `:398-422` 没有 find |

结论：README 的"共享 `XYZEditor`/`XYZTextEditing`"在协议层成立，但两端实现只有骨架相同；iOS 的 Source 侧明显落后于 Reading 侧（设置不一致是最容易复现的漂移）。归 P1-8。

---

## 6. 性能：8 个具体热点与验证方法

> 以下时间数字均为"应测"目标，不是本次实测值；本次没有运行 app/Instruments。

**H1 每击键全量属性重写（≤80k 字符）**
- 证据：`textDidChange` → `restyle`（`XYZMacEditor.swift:1422-1441,1467-1479`）→ `EditorTypography.apply`：`immediateLimit = 80_000` 以下 `span = full`（`:1484-1486,1579-1585`），对全文 `storage.setAttributes([...], range: span)`（`:1586-1602`）；紧接着 `styleMarkup` 逐行处理（`:1736-1760`），其中 `fenceIsOpen` 从文档头扫到 span 起点（`:1762-1776`），`applyInlineCode` 逐字符扫描（`:1939-1985`）。
- 验证：在 `apply` 与 `styleMarkup` 外围加 `os_signpost`/`SignpostInterval`，用 Instruments Time Profiler + os_signpost 录制 30 秒连续输入；合成 60KB/79KB/81KB 三档 Markdown 与代码文件对比。
- 预期：≤80k 时每击键主线程 O(n)（含字符串逐行 substr），>80k 时跳变到只处理编辑行 + `laterRestyle` 280ms 后全量（`:1431-1438`）。

**H2 TK1 gutter 每次重绘的全文档 `ensureLayout`**
- 证据：`draw`（`LineNumberGutter.swift:70`）→ `placedRows`（`:154`）→ `layoutManagerRows`（`:273`）→ `lineFragmentRows` 的 `layout.ensureLayout(forCharacterRange: 0..<length)`（`:320`）；跳过时再来一次（`:282-288`）。触发点：选中变化（`XYZMacEditor.swift:632-643`）、文本变化（`:625-629`）、滚动（`EditorPane` 通知 `:970-978`）、视图 layout（`:596`）。
- 验证：在 `LineNumberGutter.draw` 与 `lineFragmentRows` 加 signpost；打开 300KB/1MB Markdown（折行开）连续滚轮滚动/按住方向键；对比 `layoutManagerRows` 是否被调用、`ensureLayout` 调用次数与耗时；可临时用环境变量开关 `allowsNonContiguousLayout` 做 A/B。
- 预期：随文档长度线性增长的主线程尖峰；这是"为什么大文档行号很贵"的首因。

**H3 击键把全文复制出文本视图**
- 证据：`textDidChange` 直接调 `onTextChange(textView.string)`（`XYZMacEditor.swift:1440`）；`WorkspaceView` 的闭包对每次击键执行 `session.buffer?.userEdited(newText)`（String 比较全文，`WorkspaceSession.swift:1750-1766`）、`previewBridge.send(newText)`、`wordCount.update`、`outline.update(text:language:)`（`WorkspaceView.swift:1642-1657`）。
- 验证：Instruments Allocations + Time Profiler，1MB Markdown 连续输入；观察 `String` 桥接与 `MarkdownOutline` 解析是否出现在主线程火焰图；对比关掉 Show Word Count/无 outline 时的差异。
- 预期：O(n) 复制 + 每键一次 outline 解析；1MB 文件输入有可感知延迟。

**H4 预览重渲染 + `innerHTML` 整体替换**
- 证据：220/420ms 后 `MarkdownHTML.render`（`MarkdownPreview.swift:46-74`；`MarkdownHTML.swift:6-16`），随后 coordinator 执行 `setContent(html)`（`MarkdownWebView.swift:626-630`）→ `node.innerHTML = html`（`:861-872`）→ `xyzDecorate` 重新给最多 400 个代码块 `hljs.highlightElement`（`:1128-1133`）并 `xyzScheduleGutter`（`:1120-1141`）。
- 验证：Web Inspector（Debug 下 `isInspectable` 已开）+ Timeline；或页面内注入 `performance.mark` 统计 `setContent` 到下一帧的时间。用 200KB/1MB 笔记连续输入，测 keystroke→paint 的 P95。

**H5 Reading 滚动时每帧 O(blocks) 的 JS 扫描**
- 证据：`window.addEventListener("scroll", …xyzReport(); xyzMarkCurrentLine())`（`MarkdownWebView.swift:1257`）；`xyzReport → xyzTop` 里 `document.querySelectorAll("[data-line]")` 并逐个 `getBoundingClientRect()`（`:1185-1207`）；`xyzMarkCurrentLine` 又 `querySelectorAll(".xyz-ln")`（`:1109-1119`；虽然 Reading 行号已关，但函数仍被调用）。
- 验证：Web Inspector Timeline 录长文档滚动；或在 `xyzTop` 里临时打印 `nodes.length` 与耗时；用一份 5000 个块的文档测滚动 FPS。

**H6 查找/替换在主线程扫描全文**
- 证据：`replaceCurrent` 先 `TextFind.matches(in: string, …)`（`XYZMacEditor.swift:514`），`replaceEvery` 走 `TextFind.replaceAll`（`:538-548`），`selectNextOccurrence` 再一次 `matches`（`:569`）；`TextFind.matches` 对全文跑 `NSRegularExpression`（`TextFind.swift:29-39`），`lineNumber` 还会 `substring` 前缀（`:126-136`）。
- 验证：在 1MB/3MB 文档执行 ⌘⌥F 替换；Instruments Time Profiler 观察主线程 `NSRegularExpression` 采样；同时测 `paintFindMarks`（最多 2000 个 `.backgroundColor`，`XYZMacEditor.swift:299-321,1610`）。

**H7 大文档首次上色/滚动补色的可见闪烁**
- 证据：`apply` 在 `full.length > immediateLimit` 时用 `lineSpan(around: edited ?? visibleSpan(in: textView))`（`XYZMacEditor.swift:1579-1585`）；`visibleSpan` 在 viewport 尚未建立时回退为 `0..<min(len,4000)`（`:1676-1689`）；>250k 时 Markdown 不做任何 markup 着色（`:1594-1600`），代码只在 span ≤64k 时着色。滚动后 40ms 的 `scheduleVisibleRecolor` 才补（`:1357-1366`）。
- 验证：打开 200KB Markdown/代码，立即截图 + `sample`/Instruments；滚动后观察补色延迟；用 `-XYZDiagnostics` 的日志确认 `visibleSpan` 的回退分支。

**H8 5MB 上限内的内存与字符串复制**
- 证据：`editLimit = 5_000_000`（`WorkspaceFilePolicy.swift:30`），`.tooLarge` 不读（`WorkspaceSession.swift:1564-1607`）；但 3–5MB 文件会完整进 `NSTextStorage`，而每次击键仍走 H3 的全文传递；只读预览被截到 2MB（`TextBytes.swift:103`）。
- 验证：打开 4MB `.txt`/`.log`（非 Markdown，避免 markup 成本）测内存与输入延迟；用 Instruments VM Tracker 看 `NSTextStorage`/`NSString` 峰值；再测 5MB+ 走 `.tooLarge` 占位是否即时。

**H9 Reading→Editor 的滚动锚点往返**
- 证据：Reading 滚动每帧 postMessage（`MarkdownWebView.swift:1180-1184,1257`）→ coordinator `onViewportLine`（`:495-518`）；Editor 侧 `viewportTopLine` 用 `lineIndexCache`（可能陈旧，P1-2），`scrollLineToTop` 需要 `ensureLayout` 到目标行（`XYZMacEditor.swift:846-877`）。
- 验证：长文档在 Reading 滚动后 ⌘/ 切到 Editing（连按 10 次），记录 ViewAnchorLog（`XYZEditor.swift:6-16`）的 requested/landed 差异与切换耗时；对比 `warmLineIndex` 是否及时。

---

## 7. 发现清单（P0 / P1 / P2）

> 每条含：结论、证据（file:line）、影响、建议（含最小验证步骤）。
> 行号均来自本报告的读取；探针为 AppKit 层实证，不是产品运行结果。

### P0（崩溃 / 数据损坏）

**P0-1 切文件/切 tab 后 undo 栈未清空：⌘Z 会抛 `NSRangeException` 崩溃，或把上一篇笔记的编辑应用到当前笔记（数据损坏）**
- 证据：
  - `XYZMacTextView` 在程序性替换时只关 undo 注册、不清栈：`XYZMacEditor.swift:1376-1393`（`disableUndoRegistration` → `textView.string = replacement` → `enableUndoRegistration`）。
  - 全仓库无 `removeAllActions`（grep：0 命中）；`clearDocumentChrome()` 只清 find 与选区（`XYZMacEditor.swift:291-296`）。
  - 文件夹窗口里同一个 `XYZMacTextView` 跨 tab 复用：`editor` 分支只随 `viewMode` 变化（`WorkspaceView.swift:1559-1573,1614-1658`），`onChange(of: session.buffer?.editorToken)` 只在文本变化时发通知（`WorkspaceView.swift:1440-1455`），不重建视图；切 tab 流程见 `WorkspaceSession.swift:888-918`。
  - 本机 AppKit 探针（§7.4-B）：输入 `B` 后 `canUndo=true`；`textView.string = "XY"` 后 `canUndo` 仍是 true；`undo()` 直接抛 `NSRangeException`（`NSBigMutableString substringWithRange:` 越界，调用栈 `NSTextStorage(NSUndo) _undoRedoAttributedSubstringFromRange:`）。
  - CI 的 undo 检查只对同一个视图立刻 undo（`GutterSnapshot.swift:768-788`），覆盖不到"换文档后 undo"。
- 影响：⌘Z 崩溃（首次进入旧 undo 组时）；若旧 range 恰好落在新文本长度内，会静默改错文本，随后 `WorkspaceFileBuffer` 自动保存把错误写盘（`WorkspaceSession.swift:1881-1895`）——数据损坏。
- 建议：在 `perform(.replaceContents)` 与文件夹窗口的 buffer 切换处调用 `documentUndoManager?.removeAllActions(withTarget: textView)`（或清空当前 undo manager 的所有 action），再替换字符串；更彻底的做法是每个 buffer 一个 `NSUndoManager`（或 per-buffer text storage）。探针已验证"先 `removeAllActions()` 再 `string=` → `canUndo=false`、undo 安全"（§7.4-B 第二段）。
- 最小验证：① 用探针脚本复现；② 产品内：打开 `a.md` / `b.md`（都短），在 a 里打字 → 切到 b → ⌘Z，观察崩溃或 b 内容被改；③ 修复后同步骤应无 undo 可用。

### P1（明显缺陷 / 高代价 / 安全）

**P1-2 陈旧的 `LineIndex` 缓存：编辑后行号、状态栏行列、源码/Reading 锚点会整体偏移**
- 证据：`warmLineIndex` 只在 `makeNSView`（`XYZMacEditor.swift:1124`）和程序性 reload（`:1386`）调用；`lineIndexCache` 是静态快照（`LineIndex` 只保存行起点数组，`XYZCore/TextStatistics.swift:75-115`）。读取方：`LineNumberGutter.lineIndex()` 优先用 `textView!.cachedLineIndex()`（`LineNumberGutter.swift:59-68`）、`viewportTopLine`（`XYZMacEditor.swift:913`）、`viewportLine`（`:920-927`）、`drawIndentGuides`（`:711`）、`reportSelection → EditorCaret.measure(..., index:)`（`:1411-1420`；`XYZCore/EditorCaret.swift:25-40`）。文本变化时 gutter 只清自己的缓存（`LineNumberGutter.swift:35-39`，由 `lineNumbersChanged` 于 `XYZMacEditor.swift:625-629` 调用），随后又会把陈旧的 `cachedLineIndex()` 塞回自己的缓存。
- 影响：在中间按一次 Return，其下所有行号、状态栏行号、大纲跟随行、Source↔Reading 恢复行都会多算/少算，且随编辑累积；与 CHANGELOG 里"行号跳号 1,2,3,13,22,23"的旧症状也可能混淆（那条更可能是非连续估计，但两者叠加时难以区分）。
- 建议：`textDidChange` 时把 `lineIndexCache = nil`（或异步重建并带 generation），gutter 优先用当前字符串构建；`LineIndex` 构建 O(n) 可后台做，`invalidate` 后先按需临时构建可见段。
- 最小验证：打开 100 行文件，光标放到第 10 行，按 3 次 Return；观察第 20 行以下的行号是否比实际少 3（gutter + 状态栏）。修复后重复同上，行号应与文本一致。

**P1-3 无折行模式下 gutter 行盒来自 gutter 字体，行距较低时行号逐行漂移**
- 证据：`lineBoxRows` 与 `emptyRow` 用 `Self.font(textView.style.fontSize)`（gutter 字体 = 0.75×字号，最小 10）算 `natural` 再取 `max(natural, fontSize*lineHeight)`（`LineNumberGutter.swift:23-25,292-304,346-361`）；编辑器自己的 `lineBoxHeight()` 用编辑器字体（`XYZMacEditor.swift:744-748`）。本机探针（§7.4-C）：16pt 系统字体 natural=18.84，gutter 12pt natural=14.13；行距 1.0 时编辑器盒 18.84、gutter 盒 16.0 → 每行漂移 2.84pt；行距 1.1 时 0.84pt；≥1.2 时才相等。默认 1.7 与测试用的 1.2 都相等，所以现有测试（`GutterSnapshot.swift:1311-1314` 设 `lineHeight = 1.2`）与默认路径都掩盖了该问题。
- 影响：设置里把行距调到 1.0–1.15 且关闭折行时，行号与正文越往下差得越多（100 行累计约 284pt，约 10 行），当前行高亮带也会错位（band 用编辑器盒、数字用 gutter 盒）。
- 建议：行盒统一由 `textView.font`/typingAttributes 计算（或抽到共享函数）；测试矩阵加入 `lineHeight=1.0` + `wraps=false`。
- 最小验证：设置行距 1.0、关折行，打开 200 行文件，看第 100 行的行号是否与正文差出多行。

**P1-4 TK1 + 折行时 gutter 每次重绘都全文档 `ensureLayout`（主线程 O(n)）**
- 证据：`LineNumberGutter.draw`（`:70`）→ `placedRows`（`:154`）→ `layoutManagerRows`（`:273`）→ `lineFragmentRows` 内无条件 `layout.ensureLayout(forCharacterRange: 0..<length)`（`:313-320`）；判断"跳过"在这一次全量排版之后，跳过时再全量排一次（`:282-288`）。触发者包括每次选中变化（`XYZMacEditor.swift:632-643`）、每次文本变化（`:625-629`）、每次 clip 滚动（`XYZMacEditor.swift:961-980`）和视图 layout（`:596`）。
- 影响：默认"折行开 + 行号开"的 macOS 编辑路径下，滚动/输入/移动光标都可能触发全文档排版；文件越大越明显，且与 `allowsNonContiguousLayout` 的初衷相反（本应只排可见区域）。
- 建议：不要对全文档 `ensureLayout`；改为只取可见范围（`glyphRange(forBoundingRect:)`/fragment 枚举）；把"跳过检测"移到单次可见范围测量之后；恢复 flag 用 `defer`。
- 最小验证：在 `lineFragmentRows` 的 `ensureLayout` 前后加 signpost，300KB 折行 Markdown 连续滚动/输入，Instruments 看每次 draw 的耗时与调用次数；去掉该行做 A/B。

**P1-5 macOS 编辑器依赖 TextKit 1 的"惰性降级"未公开行为，且注释/文档/断言互相矛盾**
- 证据：TK2 创建（`XYZMacEditor.swift:1058`）→ 读 `layoutManager` 触发降级（`:1128,1641`）；`XYZMacEditor.swift:6`、`XYZEditor.swift:114`、`MarkdownFileDocument.swift:10` 仍写"TextKit 2"；`XYZIOSEditor.swift:250` 有 TK2 断言但 macOS 没有对应的"必须是 TK1"断言；行号路径只在运行时用 `textLayoutManager == nil` 分支（`LineNumberGutter.swift:129,161`；`GutterSnapshot.swift:200`），CI 不校验该值；本机探针确认降级（§7.4-A），外部项目记录了惰性降级导致 `NSInvalidArgumentException`（`glyphRangeForTextContainer:`）的案例（见 §1.1 链接）。
- 影响：① 未来 AppKit 若改变降级行为，代码会静默切到 TK2，`allowsNonContiguousLayout`/`ensureLayout` 那套逻辑失效甚至无意义，但不会报错；② 惰性降级本身有 stale pairing 崩溃风险；③ 阅读代码的人会按注释误以为在 TK2 上工作（README:58 已经这样误导）。
- 建议：明确用 `XYZMacTextView(usingTextLayoutManager: false)` 创建（或保留隐式路径但启动即断言 `textLayoutManager == nil` 并写诊断日志）；统一注释与 README；为 TK1/TK2 分支各写一个 `-XYZCheckGutter` 用例。
- 最小验证：在 `makeNSView` 末尾加 `XYZDiagnostics.note("path=\(textView.textLayoutManager == nil ? "textkit1" : "textkit2")")`，跑步进日志；改成显式 `usingTextLayoutManager: false` 后跑现有 gutter 检查，对比行号/滚动/窗口截图。

**P1-6 预览允许远程图片加载（静默联网），与 README 明确说法相反**
- 证据：`URLPolicy.imageSchemes = ["http","https"]`（`HTMLRenderer.swift:482`），`sanitize` 放行（`:492-510`），`visitImage` 输出 `<img src>`（`:301-318`）；shell 无 CSP（`MarkdownWebView.swift:838-1271`）；网络权限在应用级 entitlements（`XYZ-macOS.entitlements:7`）；README:16 声称 "The renderer still does not request remote images"。
- 影响：打开含远程图片的笔记会静默请求第三方（IP/时间/文档指纹泄露、阅读回执），企业环境可能直接触发告警；同时让 network client 权限有实际用途，且该权限本身扩大 WebContent 被攻破后的攻击面。
- 建议：图片 scheme 收紧为仅相对路径（经 `xyz-asset` 加载本地资源）；若必须支持远程图，加 CSP `img-src xyz-asset: https:` 并在 UI 上说明"远程图片会联网"；修正 README；然后再测能否去掉 `network.client`。
- 最小验证：写一个 `![](https://example.com/pixel.png)` 笔记，在 Reading 打开，用 `log stream`/Charles/`nettop` 观察是否有请求；或在页面 `xyzDecorate` 里对 img 的 `load/error` 打日志。

**P1-7 `xyz-asset` scheme 没有目录约束：可读取笔记目录之外（包括其他已授权文件夹窗口）的图片/媒体**
- 证据：`baseHref` 用笔记目录绝对路径（`LocalAssets.swift:15-23`）；`fileURL` 只检查 scheme 和 `/` 前缀，无 canonicalize/无 base 检查（`:26-31`）；handler 仅按扩展名过滤（`:33-37,48-54`）后 `Data(contentsOf:)`（`:58`）。对照：链接打开做了根目录检查（`WorkspaceSession.swift:360-368`）；多文件夹窗口会各自 `startAccessingSecurityScopedResource`（`WorkspaceWindowController.swift:41,517`）。
- 影响：恶意/被污染的 Markdown 用 `![](../../<其它已授权目录>/x.png)` 即可让 Reading 显示本不属于该笔记文件夹的图片/视频；跨文件夹窗口时至少是跨笔记树的越权读取（sandbox 之外的路径仍被系统拒绝，所以不是任意文件读取）。另外大媒体没有大小上限、无 Range 支持（`:57-73`）。
- 建议：`fileURL` 后做 `standardizedFileURL.resolvingSymlinksInPath()` 并校验 `path.hasPrefix(allowedRoot)`；把 allowedRoot 存到 `LocalAssetSchemeHandler`（每个 webview/session 一个 handler 实例而不是单例，或按 webview 维护 root）；加文件大小/类型白名单。
- 最小验证：两份笔记放在不同文件夹，A 里写 `![](../../B/x.png)`，同时打开两个文件夹窗口，观察 A 的 Reading 是否显示 B 的图片。

**P1-8 iOS 编辑器忽略设置、缺渲染与查找能力，与 Reading 侧不一致**
- 证据：iOS 用默认 16pt/1.7/13pt inset（`XYZIOSEditor.swift:211,285-311`），`XYZEditor` 的 iOS 分支不传字号/字体/行距/可读宽度/syntax/spellCheck（`XYZEditor.swift:254-263`）；而 Reading 使用 `@AppStorage` 的字号/行距/字体/可读宽度（`MarkdownWebView.swift:97-111`）；iOS 无行号/查找/Reading find（`LineNumberGutter.swift:1`；`XYZEditor.swift:211-215`；`MarkdownWebView.swift:121-396`）。
- 影响：设置里调大字号后，iOS 的 Reading 变大而 Source 不变（其实是 Source 永远 16pt）；代码文件在 iOS 上没有语法着色；用户找不到 iPad 上的查找；作为"共享层"的承诺不成立。
- 建议：把 `XYZEditorStyle` 与 `EditorTypography` 抽成跨平台模块（iOS 至少复用 baseFont/paragraphStyle/syntax 着色）；`@AppStorage` 提到 `XYZEditor` 并传给 iOS；加 iOS find（编辑器 + Reading）。
- 最小验证：iOS 设置 24pt 后在 Source/Reading 间切换截图对比；在 iPad 上打开 `.swift` 文件看是否有着色；⌘F 是否可用。

**P1-9（性能）每击键全文外传 + outline/word count/预览全量重算**
- 证据：见 §6-H3；`WorkspaceView.swift:1642-1657`；`XYZMacEditor.swift:1440`。另有 `WorkspaceSession.userEdited` 的 `text != lastSaved` 全文比较（`WorkspaceSession.swift:1750-1766`）。
- 影响：1–5MB 文件输入时主线程被字符串复制/比较/解析占满，出现输入延迟与内存抖动；预览 220ms debounce 只是把渲染推后，文本本身每键都复制。
- 建议：`onTextChange` 改成"脏区间 + 拉取"（协议注释 `XYZEditor.swift:114-116` 已经预留了这个方向）；outline/word count 对大文档提高 debounce 或只算可见范围；`isDirty` 用脏标记而不是全文比较。
- 最小验证：1MB 文件连续输入 10 秒，Instruments Time Profiler 看 `String`/`MarkdownOutline`/`TextStatistics` 占比；改脏区间推送后对比。

### P2（改进）

**P2-10 无折行 + TK1 时当前行 band/缩进参考线不覆盖真实折行视觉行**
- 证据：`drawCurrentLineBand` 在 `style.wraps` 时先试 `currentLineBand()`（`XYZMacEditor.swift:692-705`），但 `currentLineBand` 依赖 `textLayoutManager`（`:667-680`），TK1 下降级后恒为 nil，于是落入统一行盒分支（`:696-701`）；`drawIndentGuides` 同样用统一盒（`:708-742`）。与 `:690-691` 注释和 CHANGELOG:75 的"band 用同一 fragment"不符。
- 影响：折行 + TK1 时 band 只高亮一行高度，跨视觉行的折行行看起来高亮不全；缩进参考线在折行文档里位置靠估算。
- 建议：用 TK1 的 `layoutManager.enumerateLineFragments` 或 `boundingRect(forGlyphRange:)` 取当前行真实范围；或者把 band 的 `if style.wraps` 改成"取不到 fragment 时回退并接受"。

**P2-11 输入法组合期间仍上报文本/可能触发自动保存；重载不检查 marked text**
- 证据：`XYZMacEditor.swift:1425-1440`（restyle 跳过但 `onTextChange` 不跳过）、`:1376-1393`（replaceContents 无 `hasMarkedText` 检查）；`docs/architecture.md:29`、`CHANGELOG.md:44` 自述未测真实 IME。
- 影响：自动保存窗口内可能把未上屏的拼音写盘（通常随后被正确文本覆盖）；磁盘重载会吞掉组合。
- 建议：`onTextChange` 在 `hasMarkedText()` 时不发（或单独走 composition 通道），`replaceContents` 先 `unmarkText()`/等组合结束；补一个真实 PingFang 输入的 UI 用例。

**P2-12 WKWebView 生命周期/消息处理器没有显式拆除，文档窗口会提前创建 WebView**
- 证据：`add(coordinator, name:)`（`MarkdownWebView.swift:29-30`）没有 remove；`DocumentEditorView.swift:209-212` 在 `onAppear` 无条件 `webHost.webView`；`MacMarkdownWebView` 没有 `dismantleNSView`。
- 影响：每个文档窗口一个 WebContent 进程与渲染树常驻，内存偏高；coordinator/页面按窗口存活；对普通 `.txt` 文档也创建一个 WebView。
- 建议：只在 Reading 出现时创建 webview；窗口/文档销毁时 `removeScriptMessageHandler` + `stopLoading`；给 `DocumentEditorView` 的 `readingWeb` 赋一个懒包装。

**P2-13 Preview 首载失败无重试/`isReady` 不复位**
- 证据：`didFail`/`didFailProvisionalNavigation` 只 `logNavigationFailure`（`MarkdownWebView.swift:557-567`）；`update` 在 `didStartLoad && !isReady` 时直接 return（`:540-541`）。
- 影响：极少数 shell 加载失败会让 Reading 永久空白，直到文件切换/进程崩溃重置。
- 建议：失败时把 `didStartLoad=false` 并在退避后重试一次；记录到 unified log。

**P2-14 Reading 行号死代码与两套 find 实现**
- 证据：`PreviewPrefs.script` 永远 `setLineNumbers(false)`（`MarkdownWebView.swift:51,55-63`），`xyzLayoutGutter/xyzScheduleGutter/xyzGutter` handler 仍在（`:473-494,983-1119`）；Reading find 的 JS 正则（`:901-962`）与编辑器 `NSRegularExpression`（`TextFind.swift:138-148`）是两套语义（ICU vs JS），whole-word 在 JS 里依赖 lookbehind。
- 影响：死代码增加维护面与 shell 体积（每页都解析）；只读用户看到的 find 行为与 Editing 有差异（如 `\p{L}` 类、大小写折叠、零宽匹配）。
- 建议：删除 Reading 行号 JS 与 handler；把 find 语义收拢到共享描述 + 两端各自执行（或明确文档化差异）。

**P2-15 `GutterSnapshot` 2459 行 CI 夹具编进 app target，且不覆盖生产 TK1 路径**
- 证据：`GutterSnapshot.swift` 是单个 2459 行的 `enum GutterSnapshotCheck`（`:9`），`GutterSnapshot.swift:4` import Vision、`:9-51`（`-XYZCheckGutter` 时 `exit()`）、`:409-425`/`:1205-1220`（`cacheDisplay`）、`:1003-1016`（`takeSnapshot`）、`:1028-1034`（`CGWindowListCreateImage`）、`:1156`（Vision OCR）；`project.pbxproj:38,328` 显示它在 Sources（不是独立 Check target，Lead 另用 Release 二进制 `strings` 也证实了）；CI 以 `-XYZCheckGutter` 运行（`.github/workflows/ci.yml:87`，并用 Vision OCR 验收窗口截图）。`:1279-1281` 明确说 detached harness 不经过 `makeNSView`、不读 `layoutManager`。
- 影响：Vision/WebKit/AVKit 等测试依赖进入生产二进制；OCR 相关代码路径有系统版本依赖；测试覆盖的是 TK2 的 detached pane 而不是实际 TK1 窗口路径，容易"测试全绿但窗口是错的"（CHANGELOG:11 描述过类似情况）。
- 建议：拆成独立的 UI 测试 target/helper app，不编进主 app；或至少把 `layoutGutter` 改成走 `makeNSView` 的窗口路径，并为 TK1/TK2 两条路径各加断言。

**P2-16 恢复 flag 与 undo 组的若干"非 defer"写法**
- 证据：`LineNumberGutter.swift:282-288`（`allowsNonContiguousLayout` false→true 无 defer）；`XYZMacEditor.swift:299-321`（`paintFindMarks` 的 `disableUndoRegistration` 无 defer）；`:234-245`（多选区 `insertText` 的 `beginUndoGrouping`/`endUndoGrouping` 无 defer）；`EditorPane.layout` 的 `clamping`（`:987-1009`）无 defer。
- 影响：当前没有 Swift `throw` 路径，但任何 ObjC 异常/未来早期 return 都会让 flag 永久错位（尤其 undo 注册被永久禁用 → 用户编辑不再可撤销）。
- 建议：全部换成 `defer`；对 undo 禁用的地方用 `defer { enableUndoRegistration() }`。

**P2-17 语法颜色取全局 `NSApp.effectiveAppearance` 而非视图自身 appearance**
- 证据：`EditorTypography.syntaxColor` 用 `NSApp.effectiveAppearance`（`XYZMacEditor.swift:1646-1648`）；而编辑器其他颜色用 `NSColor.xyzDynamic` 由视图解析（`XYZEditor.swift:296-377`），预览按窗口 `colorScheme`（`MarkdownWebView.swift:113-117`）。
- 影响：混合外观窗口（例如强制深色的浮层/不同 appearance 的窗口）里代码 token 颜色与背景不匹配。
- 建议：用 `textView.effectiveAppearance`/`textView.layer?.contentsScale` 处解析，或把颜色做成动态 NSColor。

**P2-18 `TextFind.lineNumber` 对大文档每次构造前缀子串**
- 证据：`TextFind.swift:126-136`（`ns.substring(with: 0..<utf16)` 后再遍历 unicodeScalars），被 `FindScan.make`（`XYZMacEditor.swift:460-471`）在后台调用、也被 `matches` 的调用方用来定位；`replaceCurrent` 在主线程还会 `matches` 后再算 range。
- 影响：大文档查找结果定位成本 O(n) 内存分配；不致命但可优化。
- 建议：用 `LineIndex`（可缓存）替代前缀 substring；或在 `FindScan` 里复用 `TextFind.stepDetail` 已得到的匹配序号。

---

## 7.4 探针与复现证据

### A. TextKit 隐式降级（`/tmp/xyz_probe.swift` 第 1 段）

```swift
let tv = NSTextView(usingTextLayoutManager: true)
print(tv.textLayoutManager != nil, tv.layoutManager == nil) // true false
_ = tv.layoutManager
print(tv.textLayoutManager != nil, tv.layoutManager == nil) // false false
```

输出：

```
A tk2 before: textLayoutManager != nil: true layoutManager == nil: false
B tk2 after read .layoutManager: textLayoutManager != nil: false layoutManager == nil: false
```

结论：在本机 macOS 27.2 / Xcode 27.2 上，读取 `.layoutManager` 会把 `usingTextLayoutManager: true` 的 NSTextView 降级为 TextKit 1，`textLayoutManager` 变 nil——与 `docs/architecture.md:15`、`CHANGELOG.md:12` 一致，与 `XYZMacEditor.swift:6`、`XYZEditor.swift:114` 的"TextKit 2"注释矛盾。

### B. 跨文档 undo 栈（`/tmp/xyz_probe.swift` 第 2 段 / `/tmp/xyz_probe2.swift`）

```swift
let win = NSWindow(...); let tv = NSTextView(usingTextLayoutManager: true)
win.contentView = tv; tv.isEditable = true; tv.allowsUndo = true
tv.string = "AAAA"; tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.insertText("B", replacementRange: NSRange(location: 4, length: 0)) // "AAAAB", canUndo=true
tv.string = "XY"
print(tv.undoManager?.canUndo)      // true  ← 旧文档的 undo 动作仍在
tv.undoManager?.undo()              // NSRangeException: Range {4, 1} out of bounds; string length 2
```

输出：

```
C after typing: AAAAB undoable: true undoManager class: NSUndoManager
D after set string: XY undoable: true
*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** -[NSBigMutableString substringWithRange:]: Range {4, 1} out of bounds; string length 2'
...
A tk2 after read .layoutManager: ...（略）
after clear+set string canUndo=false text=XY
```

（最后一行是 `xyz_probe2.swift`：先 `removeAllActions()` 再换字符串，`canUndo=false`、undo 安全。）

结论：`textView.string = …` 不会清空 undo 栈；旧文档的 `NSUndoTyping` 仍指向同一个 `NSTextStorage`，在新文档上 undo 会越界崩溃或错误改写。应用侧恰好没有清栈（P0-1）。

### C. 行盒不一致（`/tmp/xyz_probe2.swift`）

```
editor natural=18.84375 gutter natural=14.1328125
spacing=1.0 editorBox=18.84375 gutterBox=16.0 -> drift/line=2.84375
spacing=1.1 editorBox=18.84375 gutterBox=18.0 -> drift/line=0.84375
spacing=1.2 editorBox=20.0 gutterBox=20.0 -> drift/line=0.0
spacing=1.7 editorBox=28.0 gutterBox=28.0 -> drift/line=0.0
```

结论：设置行距 1.0–1.1 且关折行时，`LineNumberGutter.lineBoxRows` 的行盒比编辑器小，行号逐行上移漂移（P1-3）；测试夹具用 1.2（`GutterSnapshot.swift:1311-1314`）恰好避开。

---

## 8. 覆盖与未覆盖声明

已核对：
- `XYZ/Editor/` 7 个文件全部；`XYZ/Preview/` 3 个文件全部；`XYZ/Resources/Preview.css` 关键规则（`:288-290` 图片、`:319` raw-html、`:350` 深色）与 `highlight.min.js` 版本/内联方式；entitlements；CI 脚本的 `-XYZCheckGutter` 运行方式；`project.pbxproj` 的资源/源码归属。
- `XYZCore`：HTMLRenderer 全文、MarkdownHTML、ReadingSource、SourceEditing、LogicalLineGutter、TextFind、SyntaxColoring（前 160 行 + scan 入口）、TextStatistics（LineIndex）、EditorCaret、MarkdownFileDocument、EditorViewMode、WorkspaceFilePolicy、TextBytes（预览上限）。
- `XYZ/Workspace`：WorkspaceView 的 fileBody/editor/preview 段、WorkspaceSession 的 preview/undo/readForEditing/openLinked 段、WorkspaceFileAccess 的书签/监视、WorkspaceWindowController 的多窗口/security scope 段、EditorChrome 的 EditorFindModel/Reading find、XYZDiagnostics、EditorCommands 的 undo 菜单线索；`DocumentEditorView` 全文；`XYZApp` 全文。
- AppKit 行为用两个探针脚本实证（TextKit 降级、undo 栈、行盒）。

未覆盖 / 无法验证：
- 没有运行 `xcodebuild`/app/Instruments；所有性能数字是待测目标；P0-1 的 AppKit 机制已实证，但**应用内**的崩溃/串改需按 §P0-1 的步骤复现确认。
- macOS 14/15 上的 TextKit 惰性降级、窗口合成、`CGWindowListCreateImage` 等行为未实测（本机 macOS 27.2）。
- 真实中文/日文输入法、iCloud、多显示器/混合 DPI 下的 gutter 对齐、WebKit 远程加载的实际网络包，均未测。
- `SourceEditing.shift` 的复杂多行选区边界、`ReadingSource` 的 wiki-link 与 front matter 边界只做了静态阅读，未逐例验证。
- `GutterSnapshot` 中与本任务无关的 UI 验收用例（explorer 点击、divider 拖动等）只看了入口与结构，未逐条核对。
