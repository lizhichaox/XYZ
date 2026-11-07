# XYZCore 分析报告

> 分析者：core-analyst（只读分析；未修改仓库任何文件）
> 产出：/tmp/xyz-analysis/core.md
> 基线：Lead 已验证 `swift test --package-path XYZCore` = 191 tests / 0 failures（本机 Xcode 27.2 + Swift 6.4.2），源码无 TODO/FIXME/HACK。本报告的全部结论来自源码阅读 + grep 引用核对，未重复运行测试。

## 0. 范围、方法与一个事实更正

- 源码目录：`XYZCore/Sources/XYZCore/`，**实际 29 个 .swift 文件，5,761 行**（不是任务书写的 21 个）。
- 测试目录：`XYZCore/Tests/XYZCoreTests/`，**实际 9 个 .swift 文件，2,177 行，191 个 `func test`，741 处 XCTAssert**（不是 8 个）。
- 包配置：`Package.swift`（swift-tools-version 5.9，macOS 14 / iOS 17，单一 target + 单一 testTarget，唯一外部依赖 swift-markdown）；`Package.resolved` 锁 swift-markdown 0.9.0（`25cb61d…`）与 swift-cmark 0.9.0（`08ddb52…`）。
- 全仓库 66 个 Swift 文件 / 28.4k 行的口径可以复现：27 个 App target 文件（20,456 行）+ 29 个 Core 源文件（5,761 行）+ 9 个测试文件（2,177 行）+ `XYZCore/Package.swift` = 66 个文件、约 28.4k 行。也就是说“21 个源文件 / 8 个测试文件”是任务书笔误。
- 方法：`read` 通读全部 29 个源文件与 9 个测试文件；用 `grep -rn` 在 `XYZ/`（App target）与 `XYZCore/Sources` 中核对每个 public 符号的真实调用方；用 `wc`/`grep -c` 统计行数与测试数；用 git log 追溯关键 API 的引入提交。行号均由 read 的 offset/limit 或 grep -n 定位，可直接回溯。

## 1. 模块地图

### 1.1 逐文件职责（29 个）

| 分组 | 文件（行数） | 职责 |
|---|---|---|
| 文本 IO | TextBytes.swift (309) | 编码探测（UTF-8/BOM/UTF-16/Windows-1252）、行尾归一化与回写、read-only preview |
| | TextDocument.swift (42) | 仅 UTF-8 的极简文档值类型；BOM 在读取时剥掉、写回时不再添加 |
| | FileFormat.swift (242) | 扩展名 → 语言/Reading/字体/查看器；shebang 探测；isTextualName |
| | ContentTypes.swift (12) | 自定义 `UTType.markdown`（`net.daringfireball.markdown`） |
| | MarkdownFileDocument.swift (64) | SwiftUI `ReferenceFileDocument` 适配器（文档场景），NSLock + String |
| 编辑逻辑 | SourceEditing.swift (462) | Markdown 列表续行/缩进/行内标记（**/~~/`），SourceRange/SourceReplacement，fence/lineRange/split 工具 |
| | SourceFormatting.swift (283) | `extension SourceEditing`：标题/引用/列表/代码块/表格/链接 6 个块级命令 |
| | TextTransforms.swift (280) | 行编辑：复制/移动/删除行、注释开关、缩进、合并/排序/去尾空格/大小写 |
| | TextFind.swift (182) | 查找替换（literal/regex/wholeWord/case）、scan 单次查找、`PathGlob` 路径 glob |
| | TextStatistics.swift (114) | 字数/字符数/阅读时间；`LineIndex` UTF-16 行索引 |
| | EditorCaret.swift (101) | 光标行列/选区统计；`GoToPosition` 解析与行内字符列 → UTF-16 偏移 |
| 行号/几何 | LogicalLineGutter.swift (148) | 逻辑行号标签、Reading 块行号、`FindScroll` 滚动落点 |
| Markdown/Reading | MarkdownParser.swift (16) | swift-markdown 解析（internal，`disableSmartOpts`） |
| | HTMLRenderer.swift (512) | AST → HTML（internal walker）、标题锚点、callout、`HTMLText` 转义、`URLPolicy` URL 白名单 |
| | MarkdownHTML.swift (16) | 唯一公开的 Markdown → HTML 门面 |
| | ReadingSource.swift (198) | 渲染前预处理：front matter → properties、`[[wiki link]]` 重写（internal） |
| | MarkdownOutline.swift (37) | 标题大纲（public） |
| | FileOutline.swift (237) | 大纲门面：Markdown 标题 / JSON key / 声明扫描；跟随行策略 |
| | SyntaxColoring.swift (488) | 24 种语言的轻量着色 span 计算（250k 扫描上限 + 可视窗口） |
| | StructuredText.swift (110) | JSON pretty print、CSV/TSV 表格解析（500 行上限） |
| 工作区/树 | WorkspaceNode.swift (130) | 树节点/面包屑/路径工具/自然排序/可见性过滤 |
| | WorkspaceDirectoryLoader.swift (34) | 单层目录列举（符号链接当文件、隐藏项包含） |
| | WorkspaceSearch.swift (438) | 名字匹配（子串/模糊）、树过滤、文件图标、新建名、内容搜索、侧栏几何（SidebarFit/OutlineDisclosure/ExplorerSection） |
| | GlobalSearch.swift (63) | ⌘K 文件名/路径模糊匹配与排序 |
| 标签/模式 | EditorTabs.swift (384) | tab strip（preview/pin/dirty/close）、关闭历史、窗口状态 Codable、TabMRU、跨窗口定位 |
| | EditorViewMode.swift (255) | Source/Reading 模式、文件访问级别、`EditorScrollAnchor`、`ReadingLineMap` |
| 策略/杂项 | WorkspaceFilePolicy.swift (281) | 文件分类/大小/UTF-8 采样、打开路由、磁盘变更与写入决策、读安装与保存跟随判定 |
| | CommandPalette.swift (312) | 模糊匹配器、palette 命令表/注册表、`>` `@` `:` 三种模式的行生成 |
| | PhantomWindowPolicy.swift (11) | 幽灵窗口（TUINSWindow）清理白名单 |

### 1.2 真实引用关系（grep 核实，不是自述）

- 文本 IO：`TextDocument` 只被 `MarkdownFileDocument` 使用（MarkdownFileDocument.swift:37, 62）→ 文档场景路径 = TextDocument/UTF-8；工作区路径 = `TextBytes`（App `XYZ/Workspace/WorkspaceFileAccess.swift:122,139,163`、`WorkspaceSession.swift:1326…`）。**两条 IO 栈并存**。
- 编辑层：`TextTransforms`/`TextFind` 依赖 `SourceRange`（定义在 SourceEditing.swift:28-38）；`SourceFormatting` 通过 `extension SourceEditing` 复用内部工具（contains/coveringLines/insideFence/collectLines/lineRange/split，SourceFormatting.swift:175-180, 90-93, 109-111）。
- 行号/光标：`LineIndex`（TextStatistics.swift:75-114）被 `EditorCaret.swift:22,30,31`、`LogicalLineGutter.swift:13,39`、App `XYZMacEditor.swift:655,711` 使用；`TextFind.lineNumber:126-136`、`EditorScrollAnchor.lineNumber/utf16Location:144-184`、`WorkspaceContentSearch.newlineCount:408-416` 则各自重算（见 §4.1）。
- Markdown：`MarkdownHTML`（MarkdownHTML.swift:9-11）→ `ReadingSource.prepare` → `MarkdownParser.parse` → `HTMLRenderer.render`；`ReadingSource` 依赖 `HTMLText`/`HeadingAnchor`（ReadingSource.swift:16-18, 183）；`MarkdownOutline` 直接调 `MarkdownParser.parse`（MarkdownOutline.swift:23）；`FileOutline` → `MarkdownOutline`（FileOutline.swift:38）。public 面只有 `MarkdownHTML`/`MarkdownOutline`，parser/renderer/ReadingSource 都是 internal——**这是本包分得最干净的一层**。
- 工作区：`WorkspaceFilePolicy` → `TextBytes`/`FileFormats`（WorkspaceFilePolicy.swift:89, 105）；`WorkspaceSearch` → `WorkspaceNode`/`WorkspacePaths`/`WorkspaceTreeSort`/`WorkspaceFileClassifier`/`FileFormats`/`TextFind`（WorkspaceSearch.swift:136, 188-212, 204, 351-356, 369, 390）；`WorkspaceDirectoryLoader` → `WorkspaceNode`/`WorkspaceTreeSort`（WorkspaceDirectoryLoader.swift:24-32）；`GlobalSearch` → `WorkspacePathEntry` + `FuzzyMatcher`（GlobalSearch.swift:44-45）；`EditorTabs` → `EditorViewMode` + `WorkspacePaths`（EditorTabs.swift:16, 200-203）；`CommandPalette` → `FuzzyMatcher`/`OutlineHeading`/`GoToPosition`（CommandPalette.swift:161, 195, 208）。
- App target 对 Core 的公开依赖（19 个文件 `import XYZCore`）：预览 MarkdownHTML（`XYZ/Preview/MarkdownPreview.swift:51,69,72,84`、`GutterSnapshot.swift:1330`）、编码菜单（`EditorChrome.swift:1022,1041`）、保存（`WorkspaceFileAccess.swift:122-164`）、查找（`XYZMacEditor.swift:461,492,506,514-569`）、大纲（`EditorChrome.swift:1232,1298`）、工作区策略（`WorkspaceSession.swift:553,1791,1813,1828,1917`）、tab（`WorkspaceSession.swift:31,630,702,718`）、palette/search。

### 1.3 分层是否合理

合理的部分：
- Markdown 解析/渲染/预处理/大纲是清晰的小流水线，门面（MarkdownHTML/MarkdownOutline）与实现（internal MarkdownParser/HTMLRenderer/ReadingSource）边界正确。
- 策略层（WorkspaceFilePolicy）与 UI/IO 分离，纯函数可单测，App 只拿决策枚举——这是全包最值得保留的设计。

不合理/混杂的部分：
- 一个 5.7k 行的单 target 包混了 5 种层：纯文本算法、文件 IO 策略、窗口策略（PhantomWindowPolicy）、侧栏几何（SidebarFit）、SwiftUI 文档适配器（MarkdownFileDocument 直接 `import SwiftUI/Combine`，MarkdownFileDocument.swift:1-4）。后三者不是“core text”，放进来让 `swift test` 依赖 UI 框架、也阻止未来 CLI/服务端复用。
- `SourceEditing`（enum）既是命名空间、又被 SourceFormatting 以 extension 拆分，文件边界 = 历史提交边界而不是模块边界；`SourceEditing` 的四个行内 toggle 与 SourceFormatting 的六个块级命令在 App 中已全部没有调用方（见 §2.2）。
- `WorkspaceSearch.swift`（438 行、15 个 public 类型）名不副实：里面同时有名字匹配、树过滤、文件图标、新建名、move 校验、内容搜索、侧栏 fit 数学、disclosure 位置。`EditorViewMode.swift` 同理（模式 + 访问级别 + 滚动锚点 + Reading 行映射）。
- 行号/行索引没有单一事实来源：`LineIndex` 存在的同时还有 5 份独立实现（§4.1），这是分层缺失的直接后果。

## 2. 公开 API 面

### 2.1 规模

`grep -c "^\s*public "` 在 29 个源文件上合计 **446 行 public 声明**（含 public 属性/init），范围远超 App 实际使用量：一个仅服务本仓库单一 App 的本地包，public 基本等于“防 App 用不到”，没有 internal 收口。

### 2.2 public 但 App target 完全不引用（grep `XYZ/` 零命中；部分仅测试/仅模块内部使用）

| 符号 | 证据 | 现状 |
|---|---|---|
| SourceFormatting 全部 6 个命令 `setHeading/toggleQuote/toggleList/insertCodeBlock/insertTable/insertLink` | SourceFormatting.swift:17-144；`grep -rn "setHeading\|toggleQuote\|toggleList\|insertCodeBlock\|insertTable\|insertLink" XYZ/` = 0 | 产品已移除格式化菜单（`XYZ/Editor/FormatMenu.swift:4-16` 明确移除 bold/italic/link/heading 等），Core 仍保留 + 16 个测试 |
| SourceEditing 行内 toggle `toggleBold/toggleItalic/toggleStrikethrough/toggleInlineCode` | SourceEditing.swift:93-107；`grep` App = 0 | 同上，死代码 |
| LogicalLineGutter 的 `labels/editingLabels/placedReading/readingLabels/blockLabels/ReadingLabel/Block` | LogicalLineGutter.swift:11-121；App 只调用 `highlighted`（`XYZ/Editor/LineNumberGutter.swift:89`） | 0.5.26 移除 Reading 行号后成为孤儿（CHANGELOG.md:55；commit e98f3e5） |
| `ReadingLineMap` | EditorViewMode.swift:234-255；`grep -rn ReadingLineMap XYZ/ XYZCore/Sources` 只有定义；测试 WorkspaceTests.swift:332-359 | 测试专用死代码 |
| `TextFind.step(from:matches:forward:)` | TextFind.swift:42-44；App 用 `stepDetail`（XYZMacEditor.swift:492） | 测试专用 |
| `WorkspacePaths.breadcrumb(rootName:relativePath:limit:)` | WorkspaceNode.swift:81-88；App 用 `crumbs`（EditorChrome.swift:869） | 测试专用 |
| `ExplorerSection.fileCount` | WorkspaceSearch.swift:87-93；App 0 引用；commit 97c2212 用 header actions 替换了文件数（CHANGELOG.md:57） | 测试专用 |
| `HeadingAnchor` | HTMLRenderer.swift:389-421；App 0；模块内部由 HTMLRenderer/ReadingSource 使用 | 可为 internal |
| `FuzzyMatcher` | CommandPalette.swift:14-62；App 0（模块内 CommandPalette/GlobalFileSearch 使用） | 可为 internal；`FuzzyMatch` 因出现在 PaletteRow/GlobalFileHit 中需 public |
| `WorkspaceNameMatching` | WorkspaceSearch.swift:130-164；App 0（WorkspaceTreeQuery 内部用） | 可为 internal |
| `FileFormats.shebangLanguage` | FileFormat.swift:116-123；App 0（resolved 内部用） | 可为 internal |
| `CommandPalette.parse` / `PaletteMode` | CommandPalette.swift:213-227、307-312；App 只用 `rows`（0 处 parse） | 可为 internal |
| `TextBytes.looksLikeUTF16` | TextBytes.swift:157-165；App 0（WorkspaceFileClassifier 内部用） | 可为 internal |
| `SyntaxColoring.spans(in: NSString…)` | SyntaxColoring.swift:40-44；App 用 String 重载（XYZMacEditor.swift:1722） | 可为 internal |
| `WorkspaceContentSearch.excerpt` | WorkspaceSearch.swift:419-437；App 0（hits 内部用） | 可为 internal |
| `EditorModeChoice.showsLineNumbers` | EditorViewMode.swift:75-77，与 `isEditing`（70-72）条件完全相同；App 两处分别调用（WorkspaceView.swift:1566,1570） | 重复语义 API |
| `PaletteCommandRegistry` 的“插件”叙事 | CommandPalette.swift:79, 149-155；`grep -ri plugin` 仅测试 CommandPaletteTests.swift:99-122，无插件加载路径 | 过早抽象 |

另外 `EditorModeChoice.access(kind:markdown:)` 的 `markdown` 参数是死参数：唯一 App 调用传入 `markdown: buffer.kind == .markdown`（WorkspaceSession.swift:352），`.plainText + markdown:true → .preview` 分支（EditorViewMode.swift:48-50）在 App 中不可达，只有测试 WorkspaceTests.swift:257-258 覆盖这个组合。

### 2.3 App target 自己重复实现、Core 已有等价逻辑

1. **fence 扫描**：`XYZ/Editor/XYZMacEditor.swift:1762-1783`（`fenceIsOpen`）、`:1915-1930`（`isFence`）、`:1987`（`contentRange`）与 Core `SourceEditing.insideFence/isFence/split`（SourceEditing.swift:377-414, 439-455）逐行同构。因为 Core 这两个函数是 internal（SourceEditing.swift:377, 393）App 只能复制 → 改 fence 语义（如 4 个反引号、缩进 4 空格、`~~~` 规则）时两处会漂移。建议把 fence/行切分提为 public（或拆 `SourceTextLines` 小模块）供 App 复用。
2. **链接协议白名单**：`URLPolicy.linkSchemes = ["http","https","mailto"]`（HTMLRenderer.swift:481）与 App `MarkdownWebView.swift:686-696` 的 `openIfSafe` switch 是同一集合的两份硬编码，任一侧加协议（如 `x-apple.systempreferences`）就会不一致。
3. **格式化**：App 删除菜单（FormatMenu.swift:12-14 还在剥离 `xyzBold:` 等 selector，但仓库里已无这些 selector 的定义），Core 却保留完整实现——不是“App 重复实现”，而是“Core 保留、App 放弃”的半迁移状态；两侧测试仍在给不可达代码兜底。

## 3. 测试覆盖

### 3.1 可量化的粗印象（不伪造百分比）

- 191 tests / 741 assertions；测试代码 2,177 行 vs 源码 5,761 行 ≈ **0.38:1**。
- 29 个源文件里，约 **25 个有直接测试、4 个只有间接覆盖**（MarkdownParser、HTMLRenderer、ReadingSource 经 MarkdownHTML 间接覆盖；ContentTypes 经 MarkdownFileDocument 测试间接覆盖）。没有“完全零测试”的源文件，但深度差异很大：TextFind/TextBytes/WorkspaceFilePolicy 很厚，SyntaxColoring/HTMLRenderer/FileOutline 很薄。
- 测试分布不均：`EditorShellTests.swift` 一个文件塞了 9 个无关 suite（TextBytes/EditorTab/WindowRestore/ReadOnlyPreview/OutlineFollow/PhantomWindowPolicy/EditorCaret/FileFormat/FileOutline，518 行、47 个 test），而 `SyntaxColoring`(488 行)只有 4 个测试、`HTMLRenderer`(512 行)没有独立测试文件。

### 3.2 模块 → 测试映射

| 源模块 | 测试位置 | 评价 |
|---|---|---|
| TextBytes | EditorShellTests.swift:4-88, 309-339 | BOM/CRLF/CR/混合/UTF-16LE BOM/1252/preview 都有；**BOM 缺失 UTF-16 的启发式解码、UTF-16BE、UTF-32 拒绝无测试** |
| TextDocument / MarkdownFileDocument | TextDocumentTests.swift:5-50；MarkdownHTMLTests.swift:232-258 | 只测值语义；`init(configuration:)`/`fileWrapper`/并发/`objectWillChange` 无测试 |
| FileFormat | EditorShellTests.swift:404-486 | 只覆盖少部分扩展；`isTextualName` 零测试（dotfile 逻辑 bug 因此漏网） |
| FileOutline / MarkdownOutline | EditorShellTests.swift:488-510；SourceFormattingTests.swift:127-134 | Markdown/JSON/Swift 基本盘；front matter、wiki-link 标题、250k/4k 上限无测试 |
| HTMLRenderer / MarkdownHTML | MarkdownHTMLTests.swift:6-230 | 转义/不安全 URL/task list/table/callout/锚点覆盖不错；**CRLF front matter、inline HTML、多段 callout、relative image 无测试** |
| SyntaxColoring | EditorShellTests.swift:451-485 | 只有 swift/ini/json + 大文件窗口；其余 20 种语言、块注释续接、三引号、转义无测试 |
| TextFind | TextFindTests.swift:4-71 | matches/stepDetail/replaceAll/PathGlob 有；**真正给查找条用的 `scan`、`replacement(in:)`、`lineNumber`、零长 regex、wholeWord+regex 组合零测试** |
| TextTransforms | TextFindTests.swift:134-197 | 主路径有；**moveLine 上移、deleteLine 末尾、注释 suffix 边界、sortLines 稳定性无测试** |
| SourceEditing / SourceFormatting | SourceEditingTests.swift:4-129；SourceFormattingTests.swift:4-124 | 列表续行/缩进/行内标记/6 个块命令都有；**“光标在开 fence 行上执行格式化”这一破坏路径无测试** |
| WorkspaceFilePolicy | WorkspaceTests.swift:361-573 | 分类/歧义截断/冲突/安装/污点版本/跟随保存全部有测试，质量最高的一组 |
| WorkspaceSearch / WorkspaceNode / GlobalSearch | WorkspaceTests.swift:4-237；GlobalSearchTests.swift:4-118 | 路径/排序/过滤/内容搜索/excerpt 有；**matchLimit=400 truncated、hitLimit=40 截断、more>0 无测试** |
| EditorTabs / EditorViewMode / EditorScrollAnchor | EditorShellTests.swift:90-307；WorkspaceTests.swift:239-330 | preview/pin/close/MRU/窗口恢复覆盖好；**setPreview 制造多 preview、retarget 冲突、未知 mode 解码无测试** |
| LogicalLineGutter | TextFindTests.swift:73-131 | 函数级测试其实不差，但**被测函数在 App 里已无调用方**（§2.2），属于“给死代码维持测试” |
| CommandPalette / FuzzyMatcher | CommandPaletteTests.swift:4-152 | 模式解析/最近文件/命令匹配/registry 有；heading limit 的奇怪逻辑（CommandPalette.swift:206）无测试 |
| PhantomWindowPolicy | EditorShellTests.swift:350-357 | 11 行 # 全覆盖 |

### 3.3 任务点名的关键分支：有/无测试

| 分支 | 结论 | 证据 |
|---|---|---|
| 编码/BOM | 有（UTF-8 BOM、UTF-16LE BOM、1252 round-trip） | EditorShellTests.swift:14-64 |
| UTF-16 启发式（无 BOM） | **无** | `heuristicEndian`/`decodeUnicode` 的 :190-195、:204-222 没有任何测试入口；测试只经 BOM 路径 |
| Windows-1252 | 有（decode/encode/canStore） | EditorShellTests.swift:57-64, 512-517 |
| 行尾（LF/CRLF/CR/混合） | 有（TextBytes 与 LineIndex 都有） | EditorShellTests.swift:22-45；SourceFormattingTests.swift:147-158；WorkspaceTests.swift:318-323 |
| 5MB 上限 | 只测分类边界 | WorkspaceTests.swift:391-394（`editLimit+1 → .tooLarge`）；**previewByteLimit 2MB 截断路径、>5MB 文件打开路由无 Core 测试**（逻辑主要在 App） |
| 搜索取消 | **Core 没有取消逻辑**（取消/代际在 App `WorkspaceSession`），`TextFind.scan` 本身无测试 | TextFind.swift:96-124；`grep "scan("` 测试 = 0 |
| Markdown 列表续行 | 有（bullet/ordered/task/fence/空项缩进） | SourceEditingTests.swift:24-73 |
| HTML 转义 | 有（raw HTML、文本、属性、javascript:/data:、image alt） | MarkdownHTMLTests.swift:58-66, 137-171 |
| 查找替换 | 部分（literal `$`、CRLF、regex group、wholeWord、wrap） | TextFindTests.swift:4-48；**scan/replacement/lineNumber 无** |
| 命令面板 | 有（9 个测试） | CommandPaletteTests.swift |
| 标签预览/pin | 有（14 个测试） | EditorShellTests.swift:90-253 |
| 大纲 | 部分（Markdown/JSON/Swift） | EditorShellTests.swift:488-510；**front matter 与 Reading 不一致的 bug 无测试** |

### 3.4 与实现细节耦合 / flaky 风险

- **精确 HTML 字符串断言**：MarkdownHTMLTests.swift:13（`<h1 id="hello" data-line="1"`）、:20、:55、:156 要求属性名与顺序完全一致；属性顺序/多一个空格就红。对渲染契约可接受，但一旦允许改属性顺序就是无意义红。
- **门面 = 内部管线的等价测试**：MarkdownHTMLTests.swift:194-202 `testFacadeMatchesDecoupledRenderer` 用 `@testable` 把 `MarkdownHTML.render` 与 `HTMLRenderer().render(MarkdownParser.parse(...))` 比较；任何预处理改动（front matter/wiki link 顺序）都会让这个测试表达“内部实现必须保持现状”，而不是“输出正确”。
- **常量耦合**：EditorShellTests.swift:467-478 用 130,000 行构造 >250k 字符断言 `scanLimit` 行为；:512-517 的 `sampleCutting` 依赖 8,192 常量；一旦调上限测试红得没有信息量。
- **真实文件系统/符号链接**：WorkspaceTests.swift:72-104 建临时目录 + `createSymbolicLink`；在受限 CI/沙箱或 APFS 大小写敏感配置下可能 flaky（低概率，但这是唯一碰磁盘的测试）。
- **依赖 `lines(in:)` 的尾随空行语义**：WorkspaceTests.swift:283-296、:291-296 的期望值依赖 EditorScrollAnchor.swift:202-226 不把结尾空行算进去；与 `LineIndex`（会算）不一致，改任一侧就红。
- **locale 排序**：WorkspaceTreeSort（WorkspaceNode.swift:107-121）、TextTransforms.sortLines（TextTransforms.swift:140）、CommandPalette/GlobalFileSearch 的 tie-break 用 `localizedStandardCompare`，在非 en/zh locale 下顺序可能不同；现有断言基本只含 ASCII，风险低。
- 没有 time-based / 网络 / 并发测试，也**没有任何 async/并发测试**（MarkdownFileDocument 的锁、App 的取消逻辑都不在测试范围）——这不算 flaky 源，但是覆盖缺口。

## 4. 代码质量

### 4.1 重复代码

1. **6 份行/换行计算**：`LineIndex`（TextStatistics.swift:75-114，正确处理 \r\n 与孤立 \r）、`TextFind.lineNumber`（TextFind.swift:126-136，**只数 `\n`**）、`EditorScrollAnchor.lineNumber/utf16Location`（EditorViewMode.swift:144-184）、`SourceEditing.lineRange`（SourceEditing.swift:426-437）、`TextTransforms.coveringLines`（TextTransforms.swift:209-220）、`WorkspaceContentSearch.newlineCount`（WorkspaceSearch.swift:408-416，**只数 `\n`**）。对 CR-only 文本（旧 Mac 行尾，经文档场景可进入）后两者会给出错误行号。建议统一到 `LineIndex`。
2. **扩展名/文本分类知识至少 5 处**：FileFormat.swift:105-241（format/viewer/textualExtensions）、WorkspaceFilePolicy.swift:32-33（markdown/plain 集合）、WorkspaceSearch.swift:239-279（图标映射）、SourceEditing.swift:4-24（TextMarkup prose/markup）、EditorViewMode.swift:42-54（访问级别）。加一个格式要改 4-5 处，且已经出现漂移：`FileFormats` 的图片查看器包含 bmp/ico/tif（FileFormat.swift:200），`WorkspaceFileSymbolChoice` 的图片图标列表不含 bmp/ico（WorkspaceSearch.swift:252）→ 同一文件在查看器能开、图标却是通用文档。
3. **两条文本 IO 栈**：TextBytes（工作区，7 种编码/行尾保真）vs TextDocument+MarkdownFileDocument（文档场景，仅 UTF-8、剥 BOM）。同一产品的“打开文本”有两条语义不同的路径（§5/P1-1）。
4. **fence 扫描 App 复制 Core**（§2.3-1）；**链接协议白名单两份**（§2.3-2）。
5. 小项：`EditorModeChoice.isEditing` 与 `showsLineNumbers` 条件逐字相同（EditorViewMode.swift:70-77）；`FileFormat.init` 的三元表达式两个分支相同（FileFormat.swift:95）；`TextTransforms.lineCommentSuffix` 与 `lineComment` 分散两处（TextTransforms.swift:184-207）。

### 4.2 Dead code（public 但无产品调用方 / 被移除特性遗留）

| 项 | 证据 | 说明 |
|---|---|---|
| SourceFormatting 全文件 + SourceEditing 行内 toggle | SourceFormatting.swift:17-144；SourceEditing.swift:93-107；App grep 0；FormatMenu.swift:4-16 明示移除 | 不可达功能，283 行实现 + 16 个测试 |
| LogicalLineGutter Reading/labels 相关 7 个 API | LogicalLineGutter.swift:11-121；App 只用 :23-25 | 0.5.26 删 Reading 行号（CHANGELOG.md:55）后遗留 |
| `ReadingLineMap` 整个类型 | EditorViewMode.swift:234-255；全仓库仅测试引用 | 旧阅读滚动映射，现由 JS 侧负责 |
| `TextFind.step` | TextFind.swift:42-44 | 只有测试用，App 用 stepDetail |
| `WorkspacePaths.breadcrumb` | WorkspaceNode.swift:81-88 | App 用 crumbs |
| `ExplorerSection.fileCount` | WorkspaceSearch.swift:87-93 | 0.5.26 移除 Explorer 文件数（CHANGELOG.md:57，commit 97c2212）后遗留 |
| `MarkdownFileDocument.objectWillChange` | MarkdownFileDocument.swift:16；:48-52 的 storeEditorText 从不 send | 只为满足 ObservableObject 协议存在的死发布者（见 P1-4） |
| `FileFormat.viewer` 在 init 的 label 三元无效分支 | FileFormat.swift:95 | 死表达式 |
| `EditorModeChoice.access(markdown:)` 参数 | EditorViewMode.swift:45-54 + WorkspaceSession.swift:352 | 死参数 |
| `ContentTypes.UTType.markdown` 注释与实现 | ContentTypes.swift:5-11 | 注释称“SDK 没有 UTType.markdown”，但本机 MacOSX27.2 SDK 已声明 `UTTypeMarkdown`（`UTCoreTypes.h:488`，API_AVAILABLE(macos(27.0))，Swift 侧 `UTType.markdown`）；本包自定义成员目前在模块内遮蔽它，注释已过期。低风险但误导。 |

### 4.3 命名 / 分层问题

- `EditorShellTests.swift` 里没有“EditorShell”这个类型（源文件也无）——测试文件名是历史遗物；9 个无关 suite 塞进一个文件，定位失败成本高。
- `WorkspaceSearch.swift` 名不副实（名字匹配 + 侧栏几何 + 图标 + 新建名 + 内容搜索）。
- `EditorViewMode.swift` 名不副实（模式 + 访问级别 + 滚动锚点 + 阅读行映射）。
- `SourceEditing` 与 `SourceFormatting` 的拆分只对应提交历史；`SourceEditing` 作为 enum 承担工具函数命名空间（contains/lineRange/split/insideFence）并且被 SourceFormatting 扩展，名字读起来像“整个源编辑”，实际是一组 Markdown 编辑函数。
- `TextFind.swift` 同时放 `TextFind` 与 `PathGlob`（182 行内两个不相关 public API）。
- `MarkdownFileDocument` 注释仍写 “Typing undo is owned by the TextKit 2 view”（MarkdownFileDocument.swift:10-12），而 README/docs 明确 Mac 路径读 `layoutManager` 会装 TextKit 1（README.md:11；docs/architecture.md:15）——注释与当前架构相反。
- 没有 `@available`/`Sendable` 标注问题：绝大多数纯值类型标了 `Sendable`，与 App 的 `@MainActor` 混用没问题；但 `MarkdownFileDocument` 是可变 class + NSLock、未隔离，测试也没有并发覆盖。

### 4.4 错误处理（throws vs 静默）

- 全包只有 3 个 throwing API：`WorkspaceDirectoryLoader.children`（:9）、`TextDocument.init(data:)`（:15）、`MarkdownFileDocument.init(configuration:)`（:33）。其余一律 `nil`/空数组/默认值。
- 设计上有意为之（编辑器命令返回 nil = 不修改），但代价是**错误不可观察**：`TextBytes.decode` 的 nil（TextBytes.swift:77-100）要靠调用方区分“不是文本/编码不支持”；`TextFind.matches` 对非法 regex 直接返回空数组（TextFind.swift:32-38），只有单独调用 `isValid` 才区分“没匹配”与“正则写错”；`FileFormats.isTextualName` 返回 false 会让 legacy 解码与 UTF-16 启发式静默关闭（见 P2-9）；`WorkspaceDirectoryLoader` 的 `try? resourceValues`（:21）把元数据失败降级为普通文件。
- `TextBytes.EncodingError.unrepresentable`（:70-73）是唯一的业务错误类型，App 的保存路径有处理（WorkspaceSession.swift:1929），但“Windows-1252 文件里输入中文 → 保存失败”的用户可见文案/回退没有 Core 侧测试。
- 未发现 `try!`/强制解包崩溃风险（仅 `ReadingLineMap`/`SidebarFit` 等少数 `!` 在测试/安全上下文中）。

### 4.5 性能隐患（大文件 / 正则 / 逐字符循环）

1. **TextBytes.decodeUnicode 对 UTF-8 解码两次**：`if String(data: data, encoding: .utf8) != nil, let text = String(data: data, encoding: .utf8)`（TextBytes.swift:187）。5MB 文件打开/磁盘变更采样时 = 2 次全量解码。
2. **TextBytes 逐 scalar 拼字符串**：`splitEndings` 每个 scalar 一次 `result.append`（:261-282）、`restore` 同样（:300-306）、`utf16()` 每个 UTF-16 unit 两次 `Data.append`（:233-243）。5MB 文本 = 数百万次小 append，保存/打开路径明显偏慢；可用 `String.UnicodeScalarView` 批量 + `reserveCapacity`/`Data.reserveCapacity` 改善。
3. **SyntaxColoring 每个字符分配一个 NSString substring**：主循环每次都调 `lineCommentEnd`，其中 `ns.substring(with: NSRange(location: index, length: min(4, limit - index)))`（SyntaxColoring.swift:154-157）。可视窗口重着色（App 每次滚动/击键，XYZMacEditor.swift:1722）在 250k 字符窗口上 = 25 万次短字符串分配；块注释匹配也逐字节 substring（:182-188、:320-326）。这是 Core 最明显的热点。
4. **TextFind.matches 无上限**：返回全部 match 数组（:29-39），`scan` 每次 ⌘G 都重建（:96-124），5MB 文件里高频词（如 "a"）会产生数百万个 `FindMatch`（每个 24B+ 数组开销）→ 百 MB 级瞬时内存/主线程卡顿风险。配合 `replaceAll` 每个 match 都把 `NSMutableString` bridge 成 `String` 副本（:74，`result as String`），以及 `lineNumber` 为每个 match 复制前缀字符串（:126-136），替换全部是 O(n·m) 级。
5. **EditorCaret.characterCount 每次移动光标复制子串**（EditorCaret.swift:54-57）：单行 5MB 的 JSON 文件里每次左右移动 = 一次 5MB `substring`。
6. **FileOutline 每次刷新复制 250k scalar**（FileOutline.swift:50-54）；`SyntaxColoring` 对 ≤250k 文件的可视窗口总是从 0 扫到窗口尾（:47-51），不是 O(窗口)。
7. `PathGlob.matches` 对每个 path×pattern 走 `range(of:options:.regularExpression)`（TextFind.swift:167-181）→ 文件夹替换对每个文件现场编译一次正则；建议缓存编译结果。
8. `WorkspaceContentSearch.hits(FindQuery)` 先全量 matches，再每个 hit 用 `newlineCount` 复制前缀串（WorkspaceSearch.swift:385-416）→ O(hits · n)。
9. `CSVText.parse` 达到 500 行上限后仍继续解析全文以数 `rowCount`（StructuredText.swift:41-101）——5MB CSV 在 Reading 路径上会白扫全文；若在主线程调用会卡（调用点在 App）。

## 5. 一致性检查（docs/architecture.md、CHANGELOG 0.5.28、README 中关于 XYZCore 的声明）

| # | 声明 | 代码事实 | 结论 |
|---|---|---|---|
| 1 | CHANGELOG.md:21 “A slow open installs only when it is still the latest request and the path has no buffer yet (`WorkspaceFilePolicy.shouldInstallRead`)” | `shouldInstallRead(request:latest:alreadyInstalled:) = request==latest && !alreadyInstalled`（WorkspaceFilePolicy.swift:266-270）；由 commit `ee0b4bd`（0.5.28）新增 | ✅ 一致；注：“path 无 buffer”条件在 App 的 `alreadyInstalled` 参数里，Core 只表达“最新 + 未安装” |
| 2 | CHANGELOG.md:21 “A disk sample applies only if the buffer has not been edited or saved since the sample started” | `isCurrentObservation(started:current:) = started == current`（:272-275），App 在观测 epoch 上递增（`WorkspaceSession.swift:1652-1653,1791,1813`） | ✅ 一致（纯比较器；时序在 App） |
| 3 | CHANGELOG.md:21 “A save that finishes after the text has moved schedules another save” | `needsFollowUpSave(written:current:) = written != current`（:277-280）；App WorkspaceSession.swift:1917 使用 | ✅ 一致；同理是谓词而非调度器 |
| 4 | CHANGELOG.md:14 “because 'editor equals last saved' means 'take the disk'” | `interpretChange`：`editor == lastSaved → .reload`（:239-247） | ✅ 一致 |
| 5 | CHANGELOG.md:23 “Not done: … a new dependency” | Package.swift:14-19 唯一依赖 swift-markdown（自 0.0.3 起，git log `06fa239`）；Package.resolved 0.9.0 | ✅ 一致 |
| 6 | docs/architecture.md:9 “A debounced save writes through `WorkspaceFilePolicy`, which refuses to replace a newer disk copy unless the user chooses Keep Mine” | `decideWrite`：disk 与 lastSaved 不同且非 force → `.conflict`（:250-264）；App 用 `.write/.conflict/.upToDate` 分支处理 | ✅ 一致（Core 侧；防覆盖语义成立） |
| 7 | docs/architecture.md:19 “Directory loads already ignore a stale generation. Opening a file did not. … The sample is now dropped when the buffer's observation has moved.” | Core 有 `shouldInstallRead`/`isCurrentObservation` 谓词（:266-275）；目录/文件代际本身在 App | ✅ Core 提供的原语与声明一致；整句行为无法只凭 Core 证明 |
| 8 | docs/architecture.md:15 “The gutter therefore numbers lines from the layout manager… a contiguous remeasure is used only when the visible numbers skip” | Core `LogicalLineGutter` 的 gutter 计算已不在 App 路径上（App 用 GutterSnapshot 自己的扫描，`XYZ/Editor/GutterSnapshot.swift`；App 只调用 `LogicalLineGutter.highlighted`，LineNumberGutter.swift:89） | ⚠️ 声明的实现位置与 Core 的残留代码不一致：文档描述的算法不在 XYZCore 里，Core 里的同名算法是死代码 |
| 9 | README.md:52 “`TextDocument` reads and writes UTF-8.” | TextDocument.swift:5-7,19-21,29-40：UTF-8，读取剥 BOM、写回不加 | ✅ 字面一致；但与 README.md:7 “Workspace files keep … UTF-8 with a byte-order mark” 对照：只有工作区路径保 BOM，文档场景路径不保 |
| 10 | README.md:53 “`MarkdownFileDocument` is the `ReferenceFileDocument` the document scene saves. The text view keeps the buffer; SwiftUI is not given a new string on every keystroke.” | MarkdownFileDocument.swift:13-63 + XYZApp.swift:33 `DocumentGroup`；`storeEditorText` 只写 storage，不 send objectWillChange（:16, :48-52） | ✅ 结构一致；但“系统知道文档脏了”完全依赖 undo manager，见 P1-4 |
| 11 | README.md:54 “`HTMLRenderer` only walks a tree, and gives headings GitHub-style ids.” | HTMLRenderer.render 只遍历传入的 Document（:9-17），不做解析 ✅；`HeadingAnchor` 却 public（:389）且 App 未用 | ✅ 一致（“only walks a tree”成立；public 面偏大） |
| 12 | README.md:55 “`SourceEditing` holds list continuation and indent as pure functions” | SourceEditing.swift:57-91 纯函数 ✅；但同一 enum 还有 4 个行内 toggle（:93-107）与整个 SourceFormatting extension，App 已全部不用 | ✅ 字面一致，实际内容大于声明 |
| 13 | README.md:68 “Text over 5 MB stays out of the editor” / 8 KiB 采样 / 协调保存保留编码行尾 | editLimit=5_000_000（WorkspaceFilePolicy.swift:30）、sampleLimit=8_192（:28）、TextBytes 编解码 + App 协调写（WorkspaceFileAccess.swift:98-165） | ✅ 一致 |
| 14 | README.md:16 “The renderer still does not request remote images.” | `URLPolicy.imageSchemes = ["http","https"]`（HTMLRenderer.swift:482）并输出 `<img src="https://…">`（:301-318）→ 渲染器本身不 fetch，但产出的页面会让 WKWebView 去请求；是否拦截取决于 App（`MarkdownWebView` 未发现内容拦截规则） | ⚠️ 语义模糊/不可仅凭代码证实：Core 明确允许远程图片 URL，“不请求”只能理解为“renderer 不主动下载” |
| 15 | README.md:16 “Raw HTML … shown as text, javascript:/data: not links” | HTMLBlock/InlineHTML escape（:128-134, :279-281）、URLPolicy 拒绝三协议（:500-502） | ✅ 一致 |
| 16 | README.md:72 “tree model lives in `XYZCore` so a later iOS folder view can reuse it” | WorkspaceNode/DirectoryLoader/WorkspaceSearch 在 Core 且平台无关 ✅；当前仅 macOS App 使用（`XYZ/Workspace/*` 是 macOS 路径） | ✅ 一致（“later”是未来承诺） |
| 17 | CHANGELOG.md:55 “Reading has no line numbers… saved 'on' value does not bring them back.” | `showsLineNumbers` 只在 `.source` 返回 true（EditorViewMode.swift:75-77）；`restored` 只认 "reading"（:22-24） | ✅ 一致；但 LogicalLineGutter 的 Reading 标签代码未删（死代码） |
| 18 | CHANGELOG.md:57 “The Explorer header no longer shows a file count.” | App 不再调用 `ExplorerSection.fileCount`（grep 0），但 Core 保留该 public API + 测试（WorkspaceSearch.swift:87-93；WorkspaceTests 未直接测，GlobalSearchTests.swift:98-113 测的是 fileCount） | ⚠️ 功能已删、API 未删（死代码/文档未同步） |
| 19 | docs/architecture.md:9 “`WorkspaceFileBuffer` owns … the dirty flag (`text != lastSaved`)” | App 实现是 `text != lastSaved || encoding != savedEncoding || lineEnding != savedLineEnding`（WorkspaceSession.swift:1655-1658） | ⚠️ 声明是简化版（非 XYZCore，但属同一文档的核对项；编码/行尾改动也算脏） |

## 6. 发现清单

### P0（正确性/数据丢失/安全）

在 XYZCore 内**未发现可证实的 P0**：HTML 注入面（raw HTML 转义 + 属性转义 + URL 协议白名单，HTMLRenderer.swift:448-511）经代码审查与现有测试（MarkdownHTMLTests.swift:58-66,137-171）未发现绕过；文本编解码的 lossy 分支要么拒绝打开、要么有 App 侧冲突保护。以下 P1-1/P1-4 存在数据丢失**可能性**，需要 App 侧联调确认，故不升级为 P0。

### P1（明显缺陷 / 维护性高风险）

**P1-1 文档场景文本 IO 只支持 UTF-8，iOS/⌘O 打开非 UTF-8 文本失败；BOM 被静默移除**
- 证据：TextDocument.swift:5-7,15-40（仅 `.utf8`，读时剥 BOM、写回不加）；MarkdownFileDocument.swift:33-38（`TextDocument(data:)` 失败即抛 `fileReadCorruptFile`）；对比工作区路径 TextBytes.swift:77-100,133-153（7 种编码）。
- 影响：README.md:4-7 说 iOS 只能走文档浏览器；Windows-1252/UTF-16 的 `.txt`/`.md` 在 iOS 上打不开（Mac 上 ⌘O 同样失败，只有“打开文件夹”路径能开）。带 BOM 的 UTF-8 文件经文档场景保存后 BOM 消失，与 README.md:7 “BOM 属于会被保留的编码形态”在两条路径上语义不一致。
- 建议：`MarkdownFileDocument` 内部改用 `TextBytes.decode/encode` 并把 encoding/lineEnding 存进 ReadConfiguration/WriteConfiguration 的派生状态（或明确在文档场景拒绝非 UTF-8 并在 UI 提示），补 `init(configuration:)`/`fileWrapper` 的编码测试。

**P1-2 front matter 在 CRLF 文档上会把换行“吃掉”，Reading 行号整体错位**
- 证据：ReadingSource.swift:65-71 `for character in head` 逐 `Character` 处理，`character == "\n" || character == "\r"` 才保留；Swift 中 `"\r\n"` 是**一个** Character，会走 else 分支被替换成空格。因此 CRLF 的 front matter 换行全部丢失，后面的 `data-line`/大纲行号整体前移。
- 影响：文档场景打开的 CRLF Markdown（TextDocument 保留 CRLF，MarkdownHTML 直接吃这份文本）中，Reading 的块行号、Go to Heading、大纲行号全部错；LF 文档无此问题（现有测试 MarkdownHTMLTests.swift:90-97 只测 LF）。
- 建议：改为按 unicodeScalars 扫描（或复用 TextBytes.splitEndings 的标量思路），并为 CRLF front matter 增加回归测试（先测 `MarkdownHTML.render` 的 data-line，再测 outline）。

**P1-3 大纲不经过 Reading 的预处理，front matter 会变成幽灵标题、wiki-link 标题不一致**
- 证据：MarkdownOutline.swift:20-26 直接 `MarkdownParser.parse(markdown)`；而 MarkdownHTML.swift:8-11 先 `ReadingSource.prepare`（front matter 掩码 + wiki link 重写）。App 两处都走各自的入口：FileOutline.swift:38（侧栏大纲）、`XYZ/DocumentEditorView.swift` 的 `paletteHeadings()` → `MarkdownOutline.headings(in: currentText())`（原始文本）。
- 影响：任何带 YAML front matter 的笔记，预览会显示 properties 块（无标题），侧栏/⌘R 却会多出由 `---`/setext 规则解析出的标题（如 `title: …` 那一行），且标题文本/锚点与预览不同；`[[wiki link]]` 出现在标题里时两侧文本也不同。
- 建议：让 MarkdownOutline 或 FileOutline 复用 `ReadingSource.prepare`（只掩码、不渲染 properties），并加 front matter 大纲测试。

**P1-4 `MarkdownFileDocument` 的 `objectWillChange` 从不发送，脏标记/自动保存只剩 undo manager 一条路**
- 证据：MarkdownFileDocument.swift:16 `public let objectWillChange = ObservableObjectPublisher()`；全文无 `.send()`（:48-52 的 `storeEditorText` 只改 storage）；也没有任何测试覆盖脏标记/保存触发。
- 影响：README.md:53 与注释（:8-12）都称系统通过 undo manager 感知脏状态；但只要有任何编辑路径不经过 undo（程序化替换、IME 提交边界、reload/格式化、外部写入），SwiftUI/NSDocument 就可能认为文档未修改 → 关闭/退出时不提示、自动保存不触发 → 丢编辑的风险。当前无测试能证明这条链路成立。
- 建议：要么显式在 `storeEditorText` 时发 `objectWillChange`（并让 SwiftUI 正确追踪），要么补一个文档场景集成测试（编辑 → 不手动保存 → 关闭时 hasUnsavedChanges 为 true），把“只靠 undo”写成注释约束。

**P1-5 `SourceFormatting` + 行内 toggle 是已移除功能的完整实现，283 行 + 16 个测试都在给不可达代码兜底**
- 证据：SourceFormatting.swift:17-144、SourceEditing.swift:93-107；App 全仓库零调用（grep）；`XYZ/Editor/FormatMenu.swift:4-16` 明确“settles 移除 Markdown 格式化命令”；测试 SourceFormattingTests.swift:4-124、SourceEditingTests.swift:94-114 覆盖它们。
- 影响：维护者会以为产品有格式化能力（测试全绿），实际菜单已删；将来有人“修复”或扩展这些代码是纯浪费；也增加 public 面与心智负担。
- 建议：删除（连同测试）或在 README/CHANGELOG 记录“保留 API 但产品不暴露”的决策；更推荐删掉，需要时从 git 恢复。

**P1-6 在开 fence 行上执行块级格式化会破坏代码块边界**
- 证据：`SourceFormatting.rewriteLines` 只检查 `insideFence(ns, before: span.location)`（SourceFormatting.swift:177；insideFence 定义 SourceEditing.swift:377-391）。若光标/选区起点正好落在**开 fence 行**，`before:` 状态是“未在 fence 内”→ 放行；随后 `setHeading/toggleQuote/toggleList` 会把 ``` 改成 `# ```/`> ```/`- ```。现有测试 SourceFormattingTests.swift:101-106 只测 fence 内部 caret(5)，没测 fence 行本身。
- 影响：一条命令就把文档里的代码块变成普通文本，后续内容渲染错误；撤销可恢复，但属于明显正确性缺陷。
- 建议：`rewriteLines/insertCodeBlock/insertTable` 增加“选区首行本身是 fence 行 → nil”，并补充测试（开 fence 行、闭 fence 行、只有 fence 行三种）。

**P1-7 `WorkspaceItemName.unique` 在 10,000 次冲突后静默返回重复名字**
- 证据：WorkspaceSearch.swift:297-309，`while number < 10_000`，循环结束 `return preferred`（不保证 unique）。
- 影响：调用方（New File/New Folder，WorkspaceSession.swift:418,494）把它当唯一名，极端目录下会命中已存在名字 → 后续创建/覆盖路径可能写错文件。虽极端，但函数契约是“unique”，静默破坏契约是数据风险。
- 建议：返回 `String?`/`Result`，或不再兜底而用 UUID 后缀；补测试。

**P1-8 查找/替换主路径（`scan`、`replacement`、`lineNumber`）没有任何测试，且 `matches` 无上限**
- 证据：TextFind.swift:96-124（scan）、:81-89（replacement）、:126-136（lineNumber）在 TextFindTests.swift 中零引用；`matches`（:29-39）一次性返回全量 match；App 每次 ⌘G 都调用 `TextFind.scan`（XYZMacEditor.swift:461）再对高亮调用 `matches`（:514）。
- 影响：查找条是高频功能，但“current match/line/wrapped/invalid”四元组的组合逻辑没有回归保护；5MB 文件高频词会产生百万级 match 数组（每项 struct + Array 开销），有卡顿/内存峰值风险。
- 建议：为 scan 补行为测试（前进/后退/wrap/stay/invalid pattern/空匹配），`matches` 增加 `limit` 或基于 `NSRegularExpression.enumerateMatches` 的流式接口；`lineNumber` 改用 `LineIndex`。

### P2（改进）

**P2-1 6 套行号/换行实现，其中 2 套只认 `\n`，与 `LineIndex` 的 CR 支持不一致**
- 证据：TextStatistics.swift:75-114 vs TextFind.swift:126-136（:132 只数 "\n"）vs WorkspaceSearch.swift:408-416（只数 "\n"）vs EditorViewMode.swift:144-184 vs SourceEditing.swift:426-437 vs TextTransforms.swift:209-220；另 EditorScrollAnchor.lines（EditorViewMode.swift:202-226）不把结尾空行计入，而 LineIndex 计入。
- 影响：CR-only 文本的行号在查找/内容搜索/大纲里可能错 1 行以上；两套“行数”语义会让滚动锚点与行号显示不一致。
- 建议：统一 `LineIndex`（放到独立文件），其余实现改为调用；`EditorScrollAnchor.lines` 明确复用同一模型。

**P2-2 扩展名/分类知识分散 5 处并已漂移**
- 证据：FileFormat.swift:105-241、WorkspaceFilePolicy.swift:32-33、WorkspaceSearch.swift:239-279、SourceEditing.swift:4-24、EditorViewMode.swift:42-54；具体漂移：bmp/ico 在 FileFormat.swift:200 是 image viewer，在 WorkspaceSearch.swift:252 的图标表里没有 → 显示为 document 图标。
- 影响：新增/调整格式要改多处，容易产生“能打开但图标不对/不能打开但图标对”的不一致。
- 建议：以 `FileFormats` 为唯一事实来源，`WorkspaceFileSymbolChoice` 按 `FileViewerKind` 派生图标。

**P2-3 TextBytes 热路径的两次 UTF-8 解码与逐 scalar 拼接**
- 证据：TextBytes.swift:187（同一 data 解码两次）、:255-293（splitEndings 每 scalar append）、:295-308（restore 每 scalar append）、:228-245（UTF-16 每 unit 两次 Data.append）。
- 影响：5MB 文件的打开/保存/磁盘采样明显多花 CPU/内存；与“大文件不卡”的产品叙事冲突。
- 建议：decode 只调用一次并用 `if let`；splitEndings 用 `String.UnicodeScalarView` 的 `replaceSubrange` 或一次性 `components` 扫描；utf16 用 `withUnsafeBytes`/`reserveCapacity` 预分配。

**P2-4 SyntaxColoring 每字符短 substring 分配 + 大文件窗口从 0 扫描**
- 证据：SyntaxColoring.swift:154-157（每字符 `substring`）、:182-188/:320-326（块注释逐字节 substring）、:47-51（≤scanLimit 时 `scan(from: 0, limit: windowEnd)`，不是 O(窗口)）、:341-364（>scanLimit 的块注释回看上限 16,000 字节，可能误着色）。
- 影响：编辑长文件时每次可视区重着色（XYZMacEditor.swift:1722）是 Core 最重的 CPU 路径；256KB 文件滚动可感。
- 建议：用 `ns.character(at:)`/`range(of:)` 做前缀比较；窗口扫描从 `origin` 开始（已有 `lineStart` 逻辑，只需把 ≤limit 分支也切到 origin 并从 origin 回溯块注释）；为 16KB 回看上限写注释/测试。

**P2-5 `PathGlob` 每个 path×pattern 现场编译正则；`WorkspaceContentSearch` 每个 hit 复制前缀**
- 证据：TextFind.swift:167-181（`range(of:options:.regularExpression)`）；WorkspaceSearch.swift:385-416（`newlineCount` :408-416 复制前缀）。
- 影响：文件夹级替换/内容搜索在几千文件、40 hit 时多出可观耗时。
- 建议：编译并缓存 regex（或手写 `*`/`?` matcher）；行号用 `LineIndex` 或增量扫描。

**P2-6 `TextTransforms.lineComment` 对无行注释的语言回退到 `// `
- 证据：TextTransforms.swift:194-207，`default: return "// "`（:204-205）。JSON（.json）与 CSS（.css）没有 `//` 行注释（JSONC/CSS 仅 `/* */`），但 App 的 Toggle Comment（⌘;）对这些文件仍会插入 `// `（EditorCommands.swift:390-399, 858-878）。
- 影响：对 JSON/CSS 执行注释命令直接产生无效文件（保存后下游解析失败），是用户可见的正确性缺陷（严重度低于 P1 因需主动操作、可撤销）。
- 建议：为 `.json`（非 jsonc）返回 nil、`.css` 返回 nil 或改用块注释；补按语言的表驱动测试。

**P2-7 `FileFormats.isTextualName` 对 dotfile 永远返回 false，`textualExtensions` 里的 gitignore/editorconfig 条目实际不可达**
- 证据：FileFormat.swift:189-196：`let ext = pathExtension(of: name); if ext.isEmpty { return false }`；而 `.gitignore`/`.editorconfig` 的 `pathExtension` 是空串（隐藏文件无扩展名），`textualExtensions` 却包含 "gitignore"/"gitattributes"/"editorconfig"（:239）。该函数决定 legacy 解码与 UTF-16 启发式（WorkspaceFilePolicy.swift:89,105；App WorkspaceSession.swift:1403,1461）。
- 影响：Windows-1252 或 UTF-16 的 dotfile（凭证/配置）不会被当作文本解码 → 只读预览或二进制；与 README.md:68“dotfiles 也按文本打开”冲突（UTF-8 dotfile 不受影响，因为走 UTF-8 分支）。
- 建议：对以 "." 开头的 basename 先查 textualBasenames/整名小写是否在 textualExtensions，再退回扩展名；补 `.gitignore` 的 1252/UTF-16 测试。

**P2-8 BOM-less UTF-16 若字节恰好是合法 UTF-8，会被当 UTF-8 解码（保存即改字节）**
- 证据：TextBytes.swift:187-195 先试 UTF-8 再试启发式 UTF-16；:204-222 的启发式要求存在成对的 0 字节。某些 UTF-16（无 BOM）内容（例如全部由低频 CJK 组成、字节都 <0x80）会先通过 UTF-8 校验 → 以乱码文本打开，编辑保存后原字节被改成 UTF-8 乱码。
- 影响：边缘但真实的数据改写路径；文档只说“UTF-16 支持”，未说明仅启发式。
- 建议：在 README/TextBytes 注释明确“无 BOM 的 UTF-16 仅在含 0 字节时识别”；或对可疑双字节交错模式增加更严格启发式并加测试。

**P2-9 `EditorModeChoice.access(kind:markdown:)` 死参数；`showsLineNumbers` 与 `isEditing` 重复**
- 证据：EditorViewMode.swift:45-54、:70-77；唯一 App 调用 WorkspaceSession.swift:352 传 `markdown: kind == .markdown`；测试 WorkspaceTests.swift:257-258 覆盖不可达组合。
- 影响：API 让人以为存在“plainText 但 markdown 语义”的第三种状态；增加误用面。
- 建议：去掉参数或改成 `FileFormat` 驱动；`showsLineNumbers` 直接复用 `isEditing`。

**P2-10 `MarkdownFileDocument` 的注释与当前架构相反（TextKit 2 vs TextKit 1）**
- 证据：MarkdownFileDocument.swift:8-12 “Typing undo is owned by the TextKit 2 view”；README.md:11 与 docs/architecture.md:15 均说明 Mac 读 `layoutManager` 会切回 TextKit 1，且 0.5.28 明确不重写 TextKit 2（CHANGELOG.md:21-25）。
- 影响：误导后续开发者。
- 建议：改成“text view 的 undo manager 指向文档场景的 undo manager”，不要写具体 TextKit 版本。

**P2-11 `ContentTypes.swift` 的“SDK 没有 UTType.markdown”已过期，且自定义成员在新 SDK 下遮蔽系统成员**
- 证据：ContentTypes.swift:5-11；本机 MacOSX27.2 SDK `UTCoreTypes.h:488` 声明 `UTTypeMarkdown`（`API_AVAILABLE(macos(27.0))`，Swift 侧 `UTType.markdown`）。当前模块内 `static let markdown` 与系统成员同名，模块内编译可通过（已用 `swiftc -typecheck` 验证本项目写法可编译），但跨模块调用者可能同时看到两个候选。
- 影响：低（App 目前不跨模块引用 `.markdown` 的系统版本），但注释误导、未来 SDK 下可能出现歧义/弃用警告。
- 建议：改为 `if #available(macOS 27, iOS 27, *) { return .markdown } else { return UTType(importedAs:…) }` 或把注释改为“为部署目标 macOS 14/iOS 17 提供常量（系统版本 macOS 27 起才有）”。

**P2-12 测试组织与少量 brittle 断言**
- 证据：EditorShellTests.swift（518 行、9 个无关 suite、文件名对应的类型不存在）；MarkdownHTMLTests.swift:13/:20/:55/:156 精确属性串；:194-202 门面=内部管线等价；EditorShellTests.swift:467-478 依赖 250k 常量；WorkspaceTests.swift:72-104 真实符号链接。
- 影响：失败定位成本高、改实现即红、CI 偶发（符号链接）。
- 建议：按被测模块拆测试文件；HTML 断言用包含式（已有部分）或 `data-line` 解析；把“管线等价”改成输出快照；把文件系统测试标 `XCTSkip` 条件或改用内存抽象。

**P2-13 错误语义不可观察、以及 `throws` 面过窄**
- 证据：全包仅 3 个 throwing API（WorkspaceDirectoryLoader.swift:9、TextDocument.swift:15、MarkdownFileDocument.swift:33）；`TextBytes.decode` 返回 nil、`TextFind.matches` 对非法 regex 静默空数组（TextFind.swift:32-38，需另调 isValid）；
- 影响：调用方容易把“解码失败/正则错误/没有匹配”混为一谈；App 侧已用 `isValid` 兜底，但 Core 层没有统一错误枚举。
- 建议：为 decode 增加可区分原因的结果类型（或在文档中固定契约并补测试）；`matches` 增加 throwing 变体或明确注释“非法正则 = 空结果，调用前先 isValid”。

## 7. 建议的处置顺序（给 Lead 的收口建议）

1. 先做 P1-2、P1-3（front matter/大纲），改动小、用户可见、回归测试容易写。
2. P1-4（文档脏标记）需要 App 侧联合验证，优先级取决于产品是否依赖自动保存；建议直接加一个文档场景测试。
3. P1-5 删除死格式化代码（或至少标注），同步清理 16 个测试与 README 措辞。
4. P1-1（文档场景编码）与 P1-8（查找引擎）作为中期改造：前者影响 iOS 兼容性叙事，后者影响 5MB 文件交互体验。
5. P2 中优先 TextBytes 双解码（P2-3）与 SyntaxColoring 分配（P2-4），两者都是热点路径且改动局部。

---

### 附：本报告行号来源
所有 `file:line` 均由 read 工具（offset/limit）或 `grep -n` 定位；测试/源码行号以当前工作树（HEAD `db12a62`）为准。未运行 `swift test`/`xcodebuild`（Lead 已给出 191 tests / 0 failures 基线）；`swiftc -typecheck` 仅用于验证 ContentTypes.swift:5-11 的 UTType 遮蔽说法（临时文件 /tmp/uttype_probe.swift，未进仓库）。
