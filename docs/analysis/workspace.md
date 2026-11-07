# XYZ Mac 工作区层分析（只读）

范围：`XYZ/Workspace/*.swift`（12,437 行，13 个文件）、`XYZ/DocumentEditorView.swift`、`XYZ/XYZApp.swift`；参考 `XYZCore/Sources/XYZCore/*`、`XYZ/Preview/*`、`XYZ/Editor/*`、`docs/architecture.md`、`CHANGELOG.md`、`.github/workflows/ci.yml`。
方法：read/grep 逐文件阅读 + 行号定位；未运行 `xcodebuild`（Lead 已确认 Debug/Release/iOS Simulator 构建通过）。为验证两个文件系统级假设，在 `/tmp` 用 `swift`/shell 做了两个一次性实验（详见 P0-1、P1-5），未触碰仓库。
版本：0.5.28 (build 44)，HEAD `db12a62`；工作树干净。

---

## 0. 结论摘要

- **架构总体方向是对的**：`WorkspaceSession` 持有文件夹/标签/当前 buffer；`WorkspaceFileBuffer` 持有单文件文本与保存状态；纯策略（文件分类、盘/编辑器冲突、打开代际判定）已经在 `XYZCore` 且单测覆盖（`WorkspaceFilePolicy` / `WorkspaceTests`）。AppKit 只出现在窗口/侧栏/面板层。
- **但“读/写/生命周期”三条线仍有硬伤**：打开文件的代际保护是**全局串行号**，与批量恢复标签冲突，且恢复后立即持久化空标签列表（P0-2）；新建文件在大小写不敏感卷上会**截断同名文件**（P0-1）；关窗/退出只做一次 best-effort flush，失败/冲突时无阻塞提示（P0-3）。
- **状态所有权有一处结构性断层**：`WorkspaceFileBuffer` 是 `ObservableObject`、有 5 个 `@Published`，但整个 App 没有任何视图订阅它（grep 无 `@ObservedObject var buffer` / `sink`）。外部磁盘变更、保存失败提示、缺文件提示的 UI 刷新实际依赖 `WorkspaceSession` 的其它无关 `@Published` 顺带触发（P1-1）。
- **主线程上做全量磁盘 IO**：`save()` 在 `@MainActor` 同步执行 `NSFileCoordinator` + 整文件读 + 整文件写，而读路径却是 `Task.detached`（P1-2，与 Lead 线索 a 一致）。
- **系统类 swizzling** 集中在 `FolderOpening.swift`（NSSavePanel 3 个 selector + PlatformDocumentController 4 个 selector，含手写 block 签名/`unsafeBitCast`），是本项目最大的升级脆弱点（P2-1，与 Lead 线索 b 一致）。
- 单位测试只覆盖 `XYZCore` 的纯函数；CI 的窗口截图/OCR 只覆盖“单文件打开/模式切换/切换文件”一条链路，**恢复标签、保存/退出、磁盘冲突、Replace All、大小写、符号链接、书签**全部只能人工验证（第 6 节）。

---

## 1. 状态所有权与数据流

### 1.1 所有权边界

| 对象 | 位置 | 拥有的状态 | 生命周期 |
|---|---|---|---|
| `WorkspaceSession` (`@MainActor ObservableObject`) | `WorkspaceSession.swift:14` | `rootURL/bookmark`、树 `children/expanded/loadErrors`、`selectedPath`、`buffer`、`tabStrip`、`viewMode`、`caret/viewportLine`、搜索状态、`indexedEntries/contentHits`、`previewBridge/previewHost/scrollLink`、monitor/tasks/generations | 每个窗口 1 个；`WorkspaceWindowController` 强持有；`switchFolder` 时整体替换 |
| `WorkspaceFileBuffer` (`@MainActor ObservableObject`) | `WorkspaceSession.swift:1632-1935` | 单文件 `text/lastSaved/encoding/lineEnding/conflictText/isMissing/status/reloadToken`、`saveTask`、`observationEpoch` | 由 `session.buffers[path]` 字典持有；关标签/`release` 时移除 |
| `WorkspaceWindowController` | `WorkspaceWindowController.swift:8` | `NSWindow`、`session`、全局 `static controllers` | 强持窗口+session；`windowWillClose` 移除自己 |
| SwiftUI 树 | `WorkspaceView.swift:838` / `WorkspaceDetail:1385` / `WorkspaceCommandBridge:1662` | 布局/可见性等局部 UI 状态（`columnVisibility`、`titlebarInset`、`outline`、`wordCount`、`caret` 镜像） | `WorkspaceRootView` 的 `NSHostingView` 持有 |
| AppKit 侧 | `XYZSplitView`、`SidebarColumnView`、`WorkspaceChromeView`、find/palette/search 面板 | 分栏帧、侧栏快照、标题栏附件、面板 | 视图生命周期；面板为 controller 单例复用 |

数据流（打开一个文件）：

```
Sidebar/⌘K/⌘P → session.openFile(node,...)                     WorkspaceSession.swift:515-565
  ├─ claimExistingFile?（跨窗口去重，仅工作区窗口）                :523 / WorkspaceWindowController.swift:95-98
  ├─ revealAncestors / scrollMemory → pendingRevealLine          :530-538
  ├─ openSerial += 1; openRequest[path] += 1                     :539-546
  └─ Task { await readForEditing(detached IO) }                  :548
        └─ MainActor.run: 只有 serial==openSerial 且
           shouldInstallRead(request/latest/alreadyInstalled) 才安装   :551-557
             ├─ makeBuffer（挂 onEditorState/onConflict，均为 weak self）:936-957
             ├─ watchFile → DirectoryMonitor                      :980-993
             └─ present(): tabStrip+buffer 同时发布 → show()       :568-578
```

编辑/保存流：`XYZMacEditor.updateNSView`（`XYZMacEditor.swift:1215-1226`，`reloadToken` 变化才整体替换文本）→ SwiftUI 闭包 `session.buffer?.userEdited(...)`（`WorkspaceView.swift:1643-1652`）→ `WorkspaceFileBuffer.userEdited`（`1750-1764`）→ 500ms `scheduleSave`（`1881-1888`）→ `save()`（`1890-1934`）→ `WorkspaceFileCoordination.updateText`（`WorkspaceFileAccess.swift:99-154`）→ `onEditorState` 只把 dirty 写回 `tabStrip`（`947-952`）。

### 1.2 @Published 更新时机与主要问题

1. **Session 自身发布**：树/标签/viewMode/caret/viewport/搜索/`actionMessage` 都是 `@Published`，SwiftUI 与 `WorkspaceSidebar.updateNSView` 都靠它们重算（`WorkspaceSidebar.swift:70-74`）。
2. **Buffer 发布无效**：`WorkspaceFileBuffer` 的 `@Published`（`1636-1640`：`kind/reloadToken/conflictText/isMissing/status`）没有任何观察者。视图只读 `session.buffer?.text` / `.editorToken` / `.status`（`WorkspaceView.swift:1439-1448, 1590-1617, 1628-1655`），而 SwiftUI 不会跟踪嵌套 Observatory 对象的属性。实际刷新靠“顺带”：`onEditorState` → `EditorTabStrip.setDirty` 变化才让 `session.tabStrip`（`@Published`）发布（`WorkspaceSession.swift:947-952`，`EditorTabs.swift:118-125`）。因此：
   - 干净文件被外部修改：`noteExternalChange` → `apply(text:)` 改 `text/lastSaved/reloadToken`（`1867-1879`），`setDirty(false)` 返回 false → **session 不发布** → 编辑器 `reloadToken` 不更新、Reading 预览不刷新，直到用户滚动/点击产生 `viewportLine`/`caret` 发布。CHANGELOG:281 “A clean file still reloads quietly”在 UI 上不一定成立。
   - 保存失败：`save` 的 `catch` 只设 `status`（`1929-1933`），不调用 `onEditorState` → 状态栏横幅可能永远不出现。
   - `noteMissing`（`1814-1816, 1843-1850`）同样只改 buffer；只有目录刷新里 `scheduleIndex` 稍后发布 `indexedEntries` 才可能让横幅出现。
3. **镜像状态**：`WorkspaceDetail` 用 `@State caret` 与 `session.caret` 双写（`1392, 1639-1643`）；`WorkspaceView.openFilePath` 用 `selectedPath ?? buffer`（`996-1001`），而 `selectedPath` 在多数路径与 `buffer.relativePath` 重复。见 P1-7。
4. **主线程假设**：session/buffer/视图全部 `@MainActor`；`DirectoryMonitor` 在私有队列上 `open/O_EVTONLY + DispatchSource`，事件统一 `DispatchQueue.main.asyncAfter` 去抖（`WorkspaceFileAccess.swift:21-68`）；后台读一律 `Task.detached` 后回 `MainActor.run`。唯一例外：`save()` 的同步 IO 实际在主线程（P1-2）。

### 1.3 Task 生命周期清单

- 受追踪可取消：`reloadTasks`（目录去抖，`1502-1509`）、`indexTask`（`1110-1127`）、`contentTask`（`1129-1167`）、`buffer.saveTask`（`1881-1888`）、`find.searchTask`（`EditorChrome.swift:203-210`）、`outline.task`（`EditorChrome.swift:1293-1304`）、`GlobalSearchController.task`（`GlobalSearchPanel.swift:327-361`）。
- **不受追踪**：打开文件（`548-564`）、新建文件（`429-455`）、文件夹替换（`1259-1273`）、`noteExternalChange` 的磁盘采样（`1787-1840`）、`load(parent:)`（`1515-1545`）、monitor 回调里的 `Task { @MainActor }`（`204, 1069`）。`shutdown()`（`211-223`）只取消前三类，其余靠 `[weak self]` + generation guard 自行退出；detached 读仍会跑完。
- 单个 Task 的完成顺序有 guard 保护，但**取消语义**在 detached 上失效（P1-6）。

---

## 2. 并发 / 竞态

### 2.1 已有代际机制盘点

| 机制 | 位置 | 判定 | 评价 |
|---|---|---|---|
| 目录加载 `loadGeneration[parent]` | `1511-1545` | 结果落地前比对 `loadGeneration[parent]` | 正确；但 detached 目录枚举不可取消 |
| 索引 `indexGeneration` | `1110-1127` | 结果落地前比对 | 正确；扫描本身不可取消 |
| 打开文件 `openSerial`（全局）+ `openRequest[path]` | `126-127, 539-563` | 仅最后一个**用户请求**能发布 tab | 修好了“tab 先于文本出现”，但**把批量恢复打死**（P0-2） |
| 安装读 `WorkspaceFilePolicy.shouldInstallRead` | `WorkspaceFilePolicy.swift:266-270` | `request==latest && !alreadyInstalled` | 正确，单测覆盖（`WorkspaceTests.swift:527-531`） |
| 磁盘采样 `observationEpoch` | `1651-1653, 1782-1841, 1894` | 采样开始后编辑过就丢弃 | 正确，单测覆盖（`533-537`） |
| 保存决策 `decideWrite` | `WorkspaceFileAccess.swift:131-146` | 在协调块内重读盘后决定 write/upToDate/conflict | 正确；TOCTOU 只在非协调写入者（git/shell）存在 |
| 保存后追写 `needsFollowUpSave` | `1917-1919` | 写完发现文本又变了 → 再存 | 正确（单测 `538-541`） |
| 内容搜索 | `1129-1167` | `Task.cancel` + 查询/glob 相等比较 | 外层正确，detached 工作不可取消 |
| find 面板 Reading 代际 | `EditorChrome.swift:129-200` | `readingGeneration` | 正确 |
| 全局搜索 | `GlobalSearchPanel.swift:327-361` | `generation` + cancel | 正确 |

### 2.2 仍存在的竞态 / 丢失路径

- **批量恢复被“最新打开获胜”击穿**（P0-2）：`restoreTabs` 同步循环调用 `openFile`，每次 `openSerial += 1` 并异步读；读完成时只有最后一次请求的 serial 能通过 guard。随后 `open()` 立即 `persistOpenWindows()`，而 `tabStrip` 还空。结果是“恢复的窗口通常只剩最后 1 个标签，并把保存的标签列表覆盖掉”。单测只测 `WorkspaceWindowState.normalized`（`EditorShellTests.swift:256-284`），CI 的 `renderDocumentWindow` 直接 `session.openRelative("fixture.md")`，不经过 restore（`GutterSnapshot.swift:533-700`）。
- **每 tab 的 viewMode 不持久化**（P1-3）：`windowState()` 对所有 tab 硬编码 `.reading`（`717-724`）；`openRestored` 也传 `.reading`（`749-761`）；`restoreTabs` 从不 `setMode`（`727-747`）。`WorkspaceTabState.mode` 在恢复路径上等于死字段，而 `EditorTab.mode` 有单测（`EditorTabs.swift:72-75`, `EditorShellTests.swift:234`）。
- **快速连续点两个不同文件**：由于 `openSerial` 是全局的，A→B 时 A 的读被丢弃，A 根本不出标签（`539-563`）。对“预览替换”语义可接受，但和“点过的文件都应有标签”的直觉冲突；建议只让同一 path 的 request 竞争，跨 path 用打开顺序队列。
- **Replace in Folder 的 TOCTOU**（P1-4）：`planFolderReplace` 在后台读取全部文件内容（`1416-1478`），确认框后 `applyFolderChange`（`1306-1375`）对**未打开的文件直接按旧计划写入**，不重读、不比对；若期间文件被外部修改/iCloud 同步，会被静默覆盖。只对“当前打开且 text 等于计划原文”的 buffer 做了检查（`1313-1315`）。
- **Replace in Folder 的隐藏文件越界**：计划阶段的文件列表只排除 `shouldSkipRelativePath`（`.git/node_modules/.build`），**不排除 `entry.isHidden`、也不看 `showsHiddenFiles`**（`1241-1243`；内容搜索同样 `1148-1150`）。对比 `searchPanelContents` 是过滤的（`1183, 1189-1194`）。所以“隐藏文件”关闭时，Replace All 仍会改 `.env`、`.obsidian/*` 等用户看不见的文本文件。
- **关窗/退出丢失未保存编辑**（P0-3）：`windowWillClose` 直接 `session.shutdown()`（`WorkspaceWindowController.swift:129-137`），`prepareForQuit` 只 flush 一次并 `terminateNow`（`445-451, 652-657`）；`shutdown` 对每个 buffer `flush()`（`211-223`），而 `flush` 只调用一次非强制 `save`（`1767-1770`）。若该次保存是 conflict/编码错误/IO 错误（`1925-1933`），编辑只留在内存，窗口随即销毁；冲突提示 `offerExternalChange` 还要求 `buffer === self.buffer`（`961-963`），后台标签的冲突连提示都没有。
- **trash 脏文件**：`trash` 先 `closeTab(force: true)`（不 flush），再 `trashItem`（`479-489`）；被 force 关闭的 buffer 的 flush 被排到 `DispatchQueue.main.async`（`676-688`），执行时文件已在废纸篓 → `save` 走 conflict 分支不写盘 → 未保存编辑丢失。
- **保存中文本再变**：已处理（`needsFollowUpSave`），但只在 `.write` 分支；`.conflict` 时新编辑继续只留在内存（`userEdited` 见 `conflictText != nil` 就 cancel save，`1755-1758`），直到用户处理横幅，属预期但需保证横幅可见（见 P1-1）。
- **磁盘监听**：`DirectoryMonitor` 每 key 一个 `DispatchSourceFileSystemObject`，250ms 去抖（`WorkspaceFileAccess.swift:8-74`）；文件监听在 buffer 安装时挂、释放时摘（`980-993`），目录监听随展开/折叠增删（`1067-1073, 1493-1500`）。问题在于**每次目录事件 `load()` 都调用 `scheduleIndex()`**（`1534`），即任何一次文件树变化都触发全根递归索引（P1-6）。
- **重复 buffer**：跨工作区窗口有 `claimExistingFile`（`523` + `WorkspaceWindowController.swift:259-272`），但 `openInDocumentWindow`（`1021-1027`）与 Reading 预览链接（`DocumentEditorView.swift:178-182`）会把同一文件交给 `NSDocumentController` 的 `DocumentGroup`，产生第二个模型；两边各自保存，只靠磁盘冲突兜底（P2-8）。

---

## 3. 资源与生命周期

### 3.1 security-scoped bookmark

- 创建：`WorkspaceBookmarks.make`（`WorkspaceFileAccess.swift:228-235`）、`capture`（start/stop 包住写入，`237-253`）；面板路径直接 `make`（`WorkspaceWindowController.swift:54-60, 185-193`），CLI/拖放路径用 `capture`（`FolderOpening.swift:574`, `WorkspaceWindowController.swift:222`）。
- 持有：`WorkspaceSession.bookmark` + `activate()` 里 `startAccessingSecurityScopedResource` 一次（`WorkspaceSession.swift:189`），`shutdown()` 成对 stop（`219-222`）。`accessStarted` 防重复。
- CLI 路径：`application(_:open:)` 里 `startAccessing` → `openOne` → `stopAccessing`（`FolderOpening.swift:516-524`）；session 内部用解析后的 bookmark URL 再 start，避免外层 stop 后失权（设计上成立）。
- **问题**：① `stale` 标志被丢弃，恢复时从不刷新/重写 bookmark（`WorkspaceFileAccess.swift:255-270`；`WorkspaceWindowController.swift:224-232` 只记日志）；文件夹被移动/重命名后恢复会逐渐失效。② 面板路径不 start/stop 而直接 `make`，与 `capture` 的约定不一致；③ `WorkspaceLibrary` 每次 `onTabsChanged` 都把全部 bookmark/窗口状态同步写 UserDefaults（`WorkspaceWindowController.swift:99-102, 461-468`），主线程做 JSON+Data 写入；④ 恢复窗口的 tab 路径未校验，直接进 `url(for:)`（`1052-1056`）——`".."` 组件可越出 root（持久化数据被篡改时）。

### 3.2 NSWindow / SwiftUI 混合

- 不是 `NSWindow` 子类，而是普通 `NSWindow` + `NSWindowController` 作为 delegate（`WorkspaceWindowController.swift:8-34`），`isReleasedWhenClosed = false`（`:28`），窗口从 `static controllers` 强持，关闭时移除（`:129-137`）。
- **不用 `NSHostingController` 的原因**（架构文档也写了，`docs/architecture.md:7`）：它是约束驱动的 content controller，会把编辑器 flexible height 反写窗口，每轮布局窗口越来越高直到 AppKit abort。现在用 `WorkspaceRootView: NSView` 包 `NSHostingView`、`sizingOptions = []`、手动 frame + `layout()` 同步（`WorkspaceWindowController.swift:106-115, 472-498`）。这是正确取舍，保留注释即可。
- 窗口 chrome 直接改 AppKit 标题栏：`WorkspaceChrome.apply`（`WorkspaceView.swift:1357-1383`）把 `titleVisibility=.hidden`、去掉 toolbar；`TitlebarTitleInstaller` 往 `standardWindowButton(.closeButton).superview` 里插 label/toggles（`1100-1191`），并在 `layout()` 里反复 re-apply（`WorkspaceChromeView:1068-1092`）。
- 生命周期缺口：
  - `windowWillClose` 不拦截，没有“未保存更改”闸门（P0-3）。
  - `installPhantomGuard` 注册 3 个通知 + 6 段延时 pass（`308-348`），永不注销（app 级可接受）；`closeStrayWindows`/`closePhantomWindows` 用 500×500/alpha 启发式关闭“不是我们的”窗口（`350-421`），属于高维护成本、可能误杀未来窗口的代码。
  - `WindowFill.fillOnce` 用 `NSHashTable.weakObjects` + 3 次 `async` 重试（`665-692`），可接受。
  - `static controllers` 是强引用数组，若窗口未走 `windowWillClose`（异常路径）会永久保留整个 session。
- SwiftUI 视图内的 AppKit 机器：`XYZSplitView` 600+ 行、`SidebarColumnView` 300+ 行、`SidebarDivider`/`PaneSplitView`/`PaneHost`（`WorkspaceView.swift:24-549`），`PaneHost.layout` 反向锁 frame（`:552-567`）；这些是“窗口不稳定”的历史产物，能工作但难测。

### 3.3 NSTextView / WKWebView 持有与 retain cycle

- 编辑器：`XYZMacEditor` UI 由 `EditorPane`/`XYZMacTextView` 持有，`EditorFindModel.editorView` 是 `weak`（`EditorChrome.swift:36`），`find.edit` 捕获 `[weak textView]`（`XYZMacEditor.swift:1193-1194`）。`Coordinator.deinit` 移除滚动观察（`XYZMacEditor.swift:1323-1327`）。
- Reading：`PreviewWebHost` 每个 session 一个、惰性建 `WKWebView` 并跨文件复用（`WorkspaceSession.swift:108-110`；`MarkdownWebView.swift:17-39`），`PreviewWebCoordinator.openFile` 捕获 `[weak self]`。`WorkspaceDetail` 切换 surface 时 `MarkdownPreview` 复用同一 host，不会重复建 web view（符合意图），但 session 关闭时不显式 `stopLoading`/置空，依赖 dealloc。
- 回调捕获审计：`onEditorState`/`onConflict`/`scrollLink.onViewportLine`/`previewHost.openFile`/monitor 回调/`onTabsChanged`/`claimExistingFile`/`onMoveTab` 全部 `[weak self]`（`947-955, 149-151, 190-194, 983-987, 1068-1072, WorkspaceWindowController.swift:95-105`），未发现 session↔controller 的强环。
- 剩余静态/全局持有：`EditorCommands.shared`（弱 `target`/`hostWindow`，`EditorCommands.swift:127-128`）、`EditorMenuSupport.observers`/`FolderOpening.observers`/`EscapeKey.menuObservers`/`WorkspaceWindowController.phantomObservers` 永不注销（app 级）、`TabMiddleTarget.live` + 全局 `monitor`（`EditorChrome.swift:805-850`，weak 视图但 `viewDidMoveToWindow` 可重复 append）、`AboutWindow.panel`、`GoToLinePanel.current`（仅 cancel/commit 时清空，失焦 hides 时不清，`EditorCommands.swift:1813-1918`）。`EditorAnchorView` 注册 `didBecomeKey` 观察但**没有 `deinit` 注销**（`EditorCommands.swift:1159-1205`），虽然 `viewDidMoveToWindow` 二次进入会先移除，仍建议补 deinit。
- 第三方表面：`PDFSurface.Coordinator` 有 deinit 注销（`FileSurfaces.swift:328-330`）；`QuickLookHost` 从不 `preview?.close()`（`371-416`）；`MediaSurface` dismantle 会 pause（`351-355`）；`ImageSurface` 在 `makeNSView/updateNSView` 主线程 `NSImage(contentsOf:)` 整图解码（`143-168, 180-187`），大图/HEIC 会明显卡顿且无降采样。

---

## 4. 复杂度热点与拆分建议

统计（`grep` 声明 + 行数）：`WorkspaceSession.swift` 1978 行/6 类型/110 func；`EditorCommands.swift` 1919/21/143；`WorkspaceView.swift` 1852/21/110；`WorkspaceSidebar.swift` 1839/18/112；`EditorChrome.swift` 1395/26/62；`GlobalSearchPanel.swift` 908/6/51；`WorkspaceWindowController.swift` 744/9/33；`FolderOpening.swift` 530/6/17；`FileSurfaces.swift` 430/11/24。

巨型 body / 命令分发的具体证据：

- `EditorCommands.handleKeyEquivalent` 用 40+ 个 `if flags == ... && key == ...` 顺序匹配（`159-265`），`run(_ id:)` 是 30 分支 `switch`（`439-498`），另有 370 行命令式菜单手术（`EditorMenuSupport`，`776-1143`）和 3 个面板类。
- `WorkspaceSession` 同时干了：树/展开/持久化、打开代际、磁盘监听、索引与内容搜索、全局搜索聚合、文件夹替换（计划+写盘+undo）、tab/滚动/视图模式、CLI 打开辅助（`openInDocumentWindow`）。
- `WorkspaceView.swift` 里 SwiftUI 文件塞进了 `NSSplitView` 全套（`24-549`）、标题栏 AppKit 注入（`1005-1383`）、业务 detail（`1385-1658`）、命令桥（`1660-1842`）。
- `WorkspaceSidebar.swift` 一个文件包含 representable + NSOutlineView 数据源/拖放/重命名（`84-705`）、列宽拟合（`708-1047`）、root header（`1050-1276`）、行 cell/绘制（`1392-1838`）、CI 自检（`724-847`）。

最该拆的 8 处（按收益排序）：

1. **`WorkspaceSession` → 4 个协作对象**：`WorkspaceSession`（树/选中/tab 呈现）、`WorkspaceOpenCoordinator`（openFile/代际/restoreTabs，含“批量恢复”路径）、`WorkspaceIndexer`（`scheduleIndex` + `WorkspaceIndexScan` + 搜索结果聚合）、`FolderReplaceEngine`（plan/apply/undo）。第 5 个：把 `WorkspaceFileBuffer` 拆到独立文件与独立保存协调器。
2. **打开/恢复的纯逻辑进 XYZCore**：把 `restoreTabs` 的“应用顺序”建模成纯函数（输入 `WorkspaceWindowState`，输出 tab 序列 + 每 tab mode/preview/pinned），才能对 P0-2 写回归单测。
3. **`EditorCommands` → 快捷键表 + 命令注册表 + 菜单安装器 + 各面板**。快捷键/校验改成声明式 `[Shortcut]`，`run(id:)` 映射到 `PaletteCommand`（`XYZCore/CommandPalette.swift` 已有 id/title），消灭两套命令表。
4. **`WorkspaceView` → `XYZSplitView` 机器单独文件**（AppKit，~730 行）、窗口 chrome/标题栏单独文件、`WorkspaceDetail` 单独文件、`WorkspaceCommandBridge` 单独文件。
5. **`WorkspaceSidebar` → Coordinator（数据源）+ SidebarColumnView/Header + SidebarRowCell 绘制 + 宽度拟合/自检**。CI 专用 `SidebarColumnFitCheck` 不应留在生产文件里。
6. **`GlobalSearchPanel` → 面板构建/搜索 cell + 控制器状态机**；`QueryField` 的 diagnostics 覆盖应移到 DEBUG。
7. **`EditorChrome` → find model/bar、tab bar、breadcrumb/status bar、outline、tab switch picker**（现 26 个类型混在一个文件）。
8. **`FolderOpening` → swizzling hooks 独立模块 + FileMenuSupport + AppDelegate**；`FileSurfaces` 按 surface 拆文件，JSON/CSV 视图可移到独立文件。

本应在 `XYZCore`（可单测）但目前留在 App 的逻辑：

- **路径包含/规范化**：`openLinked`（`WorkspaceSession.swift:359-368`）、CLI（`FolderOpening.swift:534-540`）、拖放（`WorkspaceSidebar.swift:679-689`）、索引（`WorkspaceSession.swift:1950-1964`）各自手写 `standardizedFileURL.path + hasPrefix(root + "/")`，没有共享函数、没有单测，也没覆盖符号链接/大小写/Unicode 归一化。
- **大小写/归一化感知的唯一命名**：`WorkspaceItemName.unique`（`XYZCore WorkspaceSearch.swift:297-309`）只做精确字符串集合判断，与当前卷的 case-insensitive 语义不一致（P0-1）。
- **保存状态机**：`WorkspaceFilePolicy` 只有判定函数；debounce/serial/epoch/冲突提示的**迁移序列**留在 `WorkspaceFileBuffer`，没有状态机测试。
- **Replace 计划的纯函数化**：把“条目+文本→变更集”抽成 core 类型（IO 留在 App），可测编码/换行/大小写/隐藏文件过滤。
- **索引扫描的跳过策略**：`WorkspaceIndexScan` 在 App（`1938-1976`），其 skip/隐藏/上限语义至少应与 `WorkspaceContentSearch` 共用 core 规则并测试（当前 `.git/node_modules/.build` 名单只在 core，扫描器却自己实现）。

---

## 5. 安全

沙箱能力（`XYZ/XYZ-macOS.entitlements`）：`app-sandbox`、`files.user-selected.read-write`、`files.bookmarks.app-scope`、`network.client`、iCloud CloudDocuments。所有磁盘访问都应落在“用户选择的文件夹 root + bookmark”内。

1. **路径规范化**：见第 4 节；`standardizedFileURL` 只解 `..`/`//`，**不解符号链接**；大小写不同（APFS 默认不区分大小写）与 Unicode NFC/NFD 不同都没有处理。`WorkspaceSession.url(for:)`（`1052-1056`）对 `relativePath` 的每个 `/` 分段直接 `appendingPathComponent`，持久化/恢复的路径若含 `..` 或绝对分段会越出 root；`openRelative` 本身也不校验。
2. **隐藏文件/跳过目录**：全局只有 `.git`、`node_modules`、`.build` 三个目录被跳过（`XYZCore/WorkspaceSearch.swift:339-347`）；`Pods`、`DerivedData`、`vendor`、`.venv`、`target` 等仍会被索引/内容搜索/Replace All。隐藏文件在“显示隐藏文件”关闭时仍会被内容搜索与 Replace All 命中（P1-4），这是“搜索/替换越界”的直接来源。
3. **符号链接**：`WorkspaceDirectoryLoader` 把 symlink 当文件（`WorkspaceDirectoryLoader.swift:10-27`，`isDirectory = isDirectory && !isLink`），索引同样（`WorkspaceSession.swift:1957-1958`）。用户编辑后保存走 `Data.write(.atomic)`（`WorkspaceFileAccess.swift:139-142`），会**替换目录项**而不是写目标（P1-5）。索引/内容搜索会跟随链接读外内容（受沙箱限制）。
4. **Quick Look / 外部打开**：`FileOpenRouting` 把 Office 等交给 Quick Look（`WorkspaceFilePolicy.swift:199-222`），`QuickLookSurface` 直接 `QLPreviewItem`（`FileSurfaces.swift:357-416`），安全性依赖系统预览扩展沙箱。`openLinked` 对 root 外链接直接 `NSWorkspace.shared.open`（`WorkspaceSession.swift:363-365`），Reading 里的相对链接可被 `<base href="xyz-asset://...">` 解析成任意绝对路径（`MarkdownWebView.swift:582-597` + `LocalAssets.swift:26-31`），恶意 Markdown 可以用“看起来像笔记”的链接让用户点开任意 app/文档（显式点击，但无确认）。`NSDocumentController.openDocument`（`DocumentEditorView.swift:178-182`, `WorkspaceSession.openInDocumentWindow`）是第二个入口。
5. **WebView 内容**：自定义 scheme 只服务 image/audio/video（`LocalAssets.swift:33-39`），路径可以是任意绝对路径，靠沙箱兜底；`URLPolicy` 允许 http/https 图片（`HTMLRenderer.swift:481-499`），未受信 Markdown 打开时会**自动加载远程图片**（IP/跟踪像素泄露），无“阻止远程内容”开关；raw HTML 被转义（安全方向正确）。
6. **NSSavePanel / NSDocumentController swizzling**（`FolderOpening.swift:64-111, 113-145, 160-236, 249-258`）：进程内全局改写系统/框架类方法，手写 `@convention(block)` 签名 + `unsafeBitCast` 转发，一旦 AppKit/SwiftUI 改实现或签名不匹配，后果是 File→Open、“新建文档”等行为静默改变甚至崩溃；`userAskedForUntitled()` 用 `NSApp.currentEvent` 猜“⌘N”（`239-246`），AppleScript/URL/菜单校验触发的合法新建会被取消；`suppressDocumentOpenPanel` 是全局一次性开关（`16-35, 278-283`）。这是明确的**升级风险面**，不应再扩大。
7. **诊断/日志**：`WorkspaceLog` 对路径用 `.private`（`WorkspaceLog.swift:29-88`）正确；`XYZDiagnostics` 只应在显式开关下写统一日志+临时文件（`XYZDiagnostics.swift:16-56`），其中 `note` 高频同步 append（`192-204`）在设计上仅调试用，不要在生产默认开启。

---

## 6. 可验证性（结合现有 CI）

现有 CI（`.github/workflows/ci.yml`）：

- `swift test --package-path XYZCore`（:59）→ `XYZCoreTests`：`WorkspaceTests`（573 行，覆盖分类器/路径/树过滤/隐藏/内容搜索/`WorkspaceFilePolicy` 全部判定：`WorkspaceTests.swift:508-573`）、`EditorShellTests`（tab strip 预览/固定/关闭/重排/MRU/`WorkspaceWindowState.normalized`/解码兼容：`:91-300`）、`GlobalSearchTests`、`CommandPaletteTests` 等。**只测纯函数，不触磁盘、不建窗口。**
- macOS Debug 构建（:66）、iOS Simulator 构建（:200，均通过）。
- `-XYZCheckGutter`（:77-101）：离屏渲染 + 真窗口截图 + Vision OCR。覆盖：编辑器行号（Edit/Reading、wrap on/off、light/dark）、真实文件夹窗口打开 fixture 并校验存储文本、模式切换、**顺序打开第二个文件**（`renderSwitchedFile`，`GutterSnapshot.swift:892-960`）、Reading WebView 快照、空文件、长文档滚动。
- “Check original UI acceptance”（:103-122，`:XYZCheckGutter` 内 `runAcceptanceGestures`，`GutterSnapshot.swift:1604-1636`）：`create-file`、`create-folder`、`nested-file`、`refresh`、`collapse-header`、`dividers`、`mode-labels`、`empty-line-prefs` 共 8 个手势/窗口检查；另有 `SearchTypingCheck`（`GlobalSearchPanel.swift:841-895`，模拟逐字键入）、`EscapeCrashCheck`（`GutterSnapshot.swift:2435-2470`，防 `NSWindowController.cancelOperation` 崩溃）、`SidebarColumnFitCheck`（`WorkspaceSidebar.swift:724-847`）。
- `Launch macOS app`（:125-148）只验证启动 8 秒不退；`-XYZCheckFileMenu`（:150-199，含中文环境）验证 File 菜单项与 OpenPanel/DocumentController hook 已装、Document Open 面板能选文件夹；`FolderLaunchArgument` 等只在 DEBUG。
- 窗口/pixel 识别上限：截图里 WebView 像素可能拍不到（脚本用 WebKit snapshot 单独补，`GutterSnapshot.swift:640-700`），OCR 依赖语言与像素，且 CI 明确记录过本机截图失败/重试历史（CHANGELOG:11,16,17,38）。

**有覆盖**：文件分类/编码换行/预览路由/内容搜索匹配/树过滤/隐藏/名称唯一/tab 模型/窗口状态归一化/命令面板匹配/行号渲染/单文件打开与切换/File 菜单/启动/Esc 崩溃/侧栏宽度。
**只能人工验证（当前无自动化）**：

1. 保存/自动保存/冲突/覆盖/缺失文件的行为（`save`、`startFolderReplace`/`applyFolderChange`）。
2. 关窗口/退出/崩溃恢复时的未保存数据处理（P0-3）。
3. 窗口恢复（多窗口、多标签、每 tab mode、preview/pinned）——CI 窗口检查是直接 new session 打开单文件，不走 `restoreTabs`（`GutterSnapshot.swift:573-700`）。
4. 外部磁盘变更（干净文件重载、脏文件冲突、iCloud 同步）与横幅/提示是否出现。
5. Replace in Folder：隐藏文件、打开/未打开文件、并发修改、undo。
6. 大小写冲突、符号链接/硬链接、Unicode 归一化、只读卷、权限被撤销。
7. security-scoped bookmark 失效/移动文件夹/重启恢复。
8. 多窗口同文件夹、tab 拖出成新窗口、跨 DocumentGroup/工作区重复打开。
9. 拖放移动、右键重命名/移到废纸篓、隐藏文件开关。
10. Quick Look/PDF/视频/大图显示与释放。

建议的补测优先级（都可在 `XYZCore` 或离屏 AppKit 里做）：先给 `WorkspaceWindowState → restore 顺序`、`FolderOpening` 之外的 `unique`（大小写/归一化）、路径包含 helper、Replace 计划纯函数补单测；再给 `WorkspaceFileBuffer` 的保存/epoch/conflict 状态机做无窗口集成测试（注入 fake IO）；最后把 `restoreTabs` + 一次真实保存/退出加进 `-XYZCheckGutter` 的窗口检查。

---

## 7. 发现清单

> 编号后括号为严重度定义：P0 = 数据丢失/崩溃/安全；P1 = 明显缺陷/高风险；P2 = 改进。

### P0

**P0-1 新建文件在大小写不敏感卷上会截断已有文件**
- 证据：`createItem` 用“已列名字 ∪ 磁盘名字”做唯一化（`WorkspaceSession.swift:410-421`），`WorkspaceItemName.unique` 是**精确字符串**比较（`XYZCore/WorkspaceSearch.swift:297-309`），随后 `try Data().write(to: destination, options: .atomic)`（`WorkspaceSession.swift:429-435`）。macOS 默认 APFS 不区分大小写：磁盘已有 `untitled.md` 时，`Untitled.md` 不在集合里，`.atomic` 写会用 rename 覆盖同一个目录项。
- 本机实验（/tmp）：`printf 'IMPORTANT' > untitled.md` 后 `Data().write(to: "Untitled.md", options: .atomic)` → `untitled.md` 变为 0 字节（名称保持小写）；同样特性下 `.atomic` 也会覆盖任何在“列目录”与“写入”之间刚出现的同名文件。
- 影响：New File / 右键 New File 静默清空用户文件（iCloud 同步、其他进程刚创建文件同理），属于数据丢失。
- 建议：`createItem` 使用 `.withoutOverwriting`（或 `O_CREAT|O_EXCL`）并处理已存在错误；唯一化按卷的 case/normalization 语义做（`FileManager` 用 `isCaseSensitiveVolume` 探测，或直接尝试创建后重试）；`XYZCore` 里提供可测的 `uniqueName(preferred:existing:caseInsensitive:)`，并补单测（含 `Note.md`/`note.md`、NFC/NFD）。

**P0-2 重启恢复标签被“全局打开串行号”击穿，并把保存的标签列表覆盖成空/单标签**
- 证据：`openFile` 每次 `openSerial += 1` 并在异步读完成时要求 `self.openSerial == serial`（`WorkspaceSession.swift:539-563`）；`restoreTabs` 在同一同步循环里对每个 tab 调 `openRestored → openFile`（`727-747, 749-761`）；所有 Task 都在 `restoreTabs` 返回后才可能运行，因此只有**最后一次**请求能安装。紧接着 `WorkspaceWindowController.open(...)` 在 `restoreTabs` 后立即 `persistOpenWindows()`（`WorkspaceWindowController.swift:245-254`），此刻 `tabStrip` 仍为空，`windowState()`（`717-724`）写出空 tabs，覆盖 `UserDefaults` 里的 `xyz.workspace.windows`（`461-468`, `WorkspaceFileAccess.swift:326-332`）。
- 影响：每次启动，窗口的多个标签只剩最后 1 个（甚至 0 个），且原始 tab 状态被修掉——`CHANGELOG.md:261`“next launch restores each window, its folder, and its tabs”失效。属状态数据丢失；由 `d5c4f25`（“Publish a file's tab only when its text is ready”）引入，`restoreTabs` 无集成测试。
- 建议：把 `openSerial` 从“全局最新”改为 per-path（同 path 的 request 竞争）+ 显式的“用户主动打开”取消策略；`restoreTabs` 改成 async/await 串行恢复（或 `openRestored` 走不受 serial 限制的专用安装路径）；`persistOpenWindows` 仅在恢复完成后（或 `restoreTabs` 内部逐个 `present` 后）才允许覆盖；补 `WorkspaceWindowState → restore` 的回归测试（core 纯函数 + 一个离屏 AppKit 测试）。

**P0-3 关窗/退出不保证未保存编辑落盘，失败无阻塞提示**
- 证据：`windowWillClose` 直接 `session.shutdown()`（`WorkspaceWindowController.swift:129-137`）；`applicationShouldTerminate` 永远返回 `.terminateNow`（`:652-657`），`prepareForQuit` 只做一次 `session.shutdown()`（`:445-451`）；`shutdown` 对每个 buffer `flush()`（`WorkspaceSession.swift:211-223`），`flush` 只调用一次 `save(force: false)`（`:1767-1770`），`save` 在 catch 里只设置 `status`（`:1929-1933`），conflict 分支只调 `publishConflict`（`:1925-1927`）→ `offerExternalChange` 又要求 `buffer === self.buffer`（`:961-963`），后台标签/当前标签的冲突、编码错误、IO 错误都不会阻止关闭。
- 影响：多标签里有未保存编辑时，用户关窗/⌘Q 可能静默丢失（特别是文件被外部删除/修改、iCloud 断网、只读卷）；`trash` 场景同理会丢编辑（`:479-489` 先 force close 再 trash，异步 flush 到已删除路径失败）。
- 建议：增加 `windowShouldClose` / `applicationShouldTerminate` 的 `.terminateCancel` 路径：先尝试 flush 所有 buffer，若有 `isDirty || isMissing || status != nil` 未解决，弹“保存/放弃/取消”；让 `flush()` 返回成功/失败结果；`trash` 前同步 flush 并对失败提示；退出时不要无条件 `.terminateNow`。

### P1

**P1-1 `WorkspaceFileBuffer` 的 `@Published` 没有订阅者，外部变更/保存失败/文件消失的 UI 可能长期不刷新**
- 证据：buffer 声明了 `@Published kind/reloadToken/conflictText/isMissing/status`（`WorkspaceSession.swift:1636-1640`），但全仓库没有 `@ObservedObject var buffer` / `.onReceive(buffer...)` / Combine `sink`（grep 仅 `WorkspaceSession/WorkspaceView` 的 `@ObservedObject session`）；视图读 `session.buffer?.text/editorToken/status`（`WorkspaceView.swift:1439-1448, 1590-1617, 1628-1653`）。`onEditorState` 只在 dirty 变化时改 `tabStrip`（`WorkspaceSession.swift:947-952`，`EditorTabs.swift:118-125`）。干净文件外部修改路径 `noteExternalChange → apply`（`1782-1841, 1867-1879`）不会触发 session 发布；`save` 失败也不触发（`1929-1933`）。
- 影响：编辑器/Reading 可能持续显示旧文本（“clean file reloads quietly”不成立），保存失败横幅不出现，用户误以为已保存；与 P0-3 叠加会放大数据丢失风险。
- 建议：让 `WorkspaceSession` 订阅每个 buffer 的 `objectWillChange`（`sink` 到 session 的 `objectWillChange.send()`，注意避免循环），或把 buffer 变成 `@ObservedObject` 传入 `WorkspaceDetail`；为 `status/conflictText/isMissing/reloadToken` 的变化补 UI 测试。

**P1-2 保存路径在主线程同步做 `NSFileCoordinator` + 整文件读 + 整文件写**
- 证据：`save` 在 `@MainActor WorkspaceFileBuffer` 内同步调用 `WorkspaceFileCoordination.updateText`（`WorkspaceSession.swift:1890-1934`），后者在 `NSFileCoordinator` 块里 `Data(contentsOf:)` 整文件解码、再 `TextBytes.encode` + `bytes.write(.atomic)`（`WorkspaceFileAccess.swift:112-150`，写盘 `:139-146`）；而读路径是 `readForEditing` 的 `Task.detached`（`WorkspaceSession.swift:1564-1610`）。debounce 只有 500ms（`:1881-1888`），即连续输入时每 0.5s 主线程做一次 0→5MB 的全量读写；每次保存还会触发自身文件监听再整文件读一次（`watchFile` `:980-993` → `noteExternalChange` `:1802-1840`）。
- 影响：大文件/iCloud/网络卷/外接盘上输入掉帧甚至 beachball；这是本层最直接的性能风险。
- 建议：把“读盘校验—编码—写入”移到专用串行 actor（或 `DispatchQueue` background）并在完成后回 MainActor 更新 buffer；`TextBytes.encode` 与“上次保存文本快照”可在主线程准备；保存失败/conflict 结果回主线程统一提示。顺带把“自己写入触发的监听事件”用 mtime/内容比较短路（`observationEpoch` 已能处理丢失，但仍会整文件读）。

**P1-3 窗口恢复不保存每标签的 Reading/Editing 模式**
- 证据：`windowState()` 对所有 tab 写死 `mode: .reading`（`WorkspaceSession.swift:717-724`）；`openRestored` 固定 `mode: .reading`（`:749-761`）；`restoreTabs` 只恢复 preview/pinned/active，不 `setMode`（`:727-747`）；`WorkspaceTabState.mode` 只在 `normalized`/编解码测试里被验证（`EditorTabs.swift:254-327`，`EditorShellTests.swift:234, 256`）。
- 影响：用户在 Editing 里留下的标签重启后全部回到 Reading（Markdown 从源码变渲染页，其他文本变只读），与“每个 tab 保留自己的 mode”的模型设计冲突。
- 建议：`windowState` 用 `$0.mode`；`openRestored` 传 `tab.mode` 并在 `restoreTabs` 里 `strip.setMode`；给 core 补“state→mode 保真”测试，给 restore 加集成测试。

**P1-4 Replace in Folder 会改隐藏文件，且对未打开文件不做磁盘再校验（TOCTOU 覆盖）**
- 证据：内容搜索的同名文件列表只过滤 `!isDirectory && !shouldSkipRelativePath`（`WorkspaceSession.swift:1148-1150`）；Replace 计划同样（`:1241-1243`）；而 `searchPanelContents` 会按 `showsHiddenFiles` 过滤（`:1183, 1189-1194`）。计划在后台读取内容（`:1416-1478`），用户确认后 `applyFolderChange` 对未打开文件直接 `writeEncodedText/writeData`（`:1326-1369`），不复读磁盘；只有“当前打开 buffer”检查 `buffer.text == expected`（`:1313-1315`）。`undoManager` 的 undo 也是直接写回旧字节（`:1311-1324`）。
- 影响：① 用户关掉“显示隐藏文件”时，Replace All 静默改写 `.env`、`.obsidian/…` 等不可见文件；② 计划与执行之间被外部修改的文件会被旧计划覆盖（违反 `WorkspaceFilePolicy` 的“不静默覆盖”原则），undo 也可能覆盖更新的内容。
- 建议：文件列表与内容搜索统一使用“可见性 + 跳过目录”函数（放进 `XYZCore` 并单测）；Replace 计划带上每个文件的 `expectedData`/mtime，执行时在 `NSFileCoordinator` 内比对并跳过冲突（或整批 abort），undo 只恢复“仍然等于替换后内容”的文件；对隐藏文件单独提示。

**P1-5 保存用原子替换，会破坏符号链接与硬链接**
- 证据：目录加载把 symlink 当普通文件（`WorkspaceDirectoryLoader.swift:10-27`，`isDirectory = isDirectory && !isLink`；索引扫描同 `WorkspaceSession.swift:1957-1958`）；保存走 `bytes.write(to:, options: .atomic)`（`WorkspaceFileAccess.swift:139-146`，`writeData` 同 `:170-186`）。
- 本机实验（/tmp）：`link.md -> target.md`，`Data.write(.atomic)` 后 `link.md` 变成普通文件（3 字节，不再是 symlink），`target.md` 内容未改；`hard.md` 与 `hard2.md` 硬链接经原子写后内容分叉（`hard2.md` 仍是旧内容）。
- 影响：用户编辑的是“链接指向的笔记”但实际保存把链接替换成新文件、真实目标未更新（数据看起来“没保存”）；硬链接/共享文件的另一端看到旧内容；Finder 标签/xattr 等元数据在 replace 语义下也可能丢失。
- 建议：打开/保存前用 `.isSymbolicLinkKey` 识别链接并解析目标（或在 UI 上标为只读/警告）；保存改为 `.forReplacing` 协调 + 写回解析后的目标 URL；若必须原子替换，至少保留链接语义（对 symlink 写目标、对 hard link 走 in-place 写）。

**P1-6 取消对 `Task.detached` 无效：索引与内容搜索/替换计划会叠加执行，每次展开目录都全根重扫**
- 证据：`scheduleIndex` 取消旧 `indexTask` 后仍 `await Task.detached { WorkspaceIndexScan.entries(at: root) }.value`（`WorkspaceSession.swift:1110-1127`），`WorkspaceIndexScan` 内的 `Task.isCancelled`（`:1953`）在 detached 任务里通常恒为 false；`searchContents`/`planFolderReplace` 同样整段在 `Task.detached` 里（`:1386-1413, 1426-1477`），其中的 `Task.isCancelled`（`:1389, 1430`）无效。`load(parent:)` 成功后无条件 `scheduleIndex()`（`:1523-1534`），而 `refreshFileTree`（`:268-275`）和每次展开都会 `load`。
- 影响：大仓库下每次展开/刷新都递归枚举全根（cap 20,000）+ stat 每个 URL；快速键入内容搜索会启动多个全目录扫描且旧扫描不会停，CPU/磁盘/耗电高，还可能挤压主线程（索引结果 `@Published` 触发视图重算，见 P2-9）。
- 建议：把扫描改成可取消的 structured concurrency（`withTaskGroup` + `checkCancellation`，或 `Task.detached` 内显式传递 `CancellationHandle`）；索引结果按“脏目录”增量更新而不是全根重扫；对 `Task.detached` 结果落地前已有 generation 保护，但工作本身也要能停。

**P1-7 侧栏选中文件夹后，Header 的 New File/New Folder 仍落在“打开文件旁边”**
- 证据：`creationParent()` 用 `selectedPath ?? buffer?.relativePath`（`WorkspaceSession.swift:261-265`）；但 NSOutlineView 选中目录时 `outlineViewSelectionDidChange` 只处理文件（`WorkspaceSidebar.swift:289-299`），`selectedPath` 只在 `present`/`selectTab`/`revealCrumb`/`revealActiveFile` 写（`WorkspaceSession.swift:576, 837, 860, 816`）。Header 的 `New File/New Folder` 走 `session.createItem(..., session.creationParent())`（`WorkspaceSidebar.swift:170-185`），因此刚点过的文件夹不是父目录；`newItem` 的“选中目录”分支（`WorkspaceSession.swift:580-590`）近乎死代码。CI 的 `acceptCreateFile`（`GutterSnapshot.swift:1638-1675`）只测未选中文件夹的情况。
- 影响：文件被创建到错误目录（用户以为在选中文件夹里），属于明显功能缺陷；也说明“选中项”有两个事实来源（`selectedPath` vs `buffer`）。
- 建议：目录选中时也更新一个 `sidebarSelection`（与 `buffer` 分离），`creationParent` 只读它；或让 Header 显式使用 `outline.selectedRow` 的节点；补 UI acceptance（先选中子文件夹再点 New File）。

**P1-8 标签恢复/持久化之外，`openFile` 对“快速连续打开”会丢标签**
- 证据：`openSerial` 是全局的（`WorkspaceSession.swift:126-127, 539-563`）；用户快速点 A、B（或 ⌘P 连续回车）时 A 的读完成晚于 B 的发起，A 被丢弃，只剩 B 一个标签。设计注释只保证“较旧的读不能发布 tab”，但没有“用户点过的文件都保留”的语义。
- 影响：多选/快速导航时标签丢失、⌘⇧T 历史也记录不到 A；与 P0-2 同源，建议一并修。
- 建议：保留 per-path request 竞争；对“用户主动打开”允许乱序安装（最新 active，其余 tab 后台安装），或用串行打开队列 + 每项完成即呈现。

### P2

**P2-1 系统类 swizzling 是最大升级脆弱面（Lead 线索 b）**
- 证据：`FolderOpening.hookOpenPanelPresentation` 对 `NSSavePanel` 的 `beginWithCompletionHandler:`/`beginSheetModalForWindow:completionHandler:`/`runModal` 做 `method_setImplementation`（`FolderOpening.swift:64-111`）；`hookOpenDocument` 对 `PlatformDocumentController` 的 `openDocumentWithContentsOfURL:display:completionHandler:`（`:113-145`）；`hookAutomaticUntitled` 对 `openUntitledDocumentAndDisplay:error:`、`reopenDocumentForURL:…`、`makeUntitledDocumentOfType:error:`、`newDocument:`（`:160-236`）；所有转发都是手写 `@convention(block)` + `unsafeBitCast`（`:66-108, 118-138, 164-234, 249-258`）。
- 影响：AppKit/SwiftUI 实现或签名变化即可造成 File→Open 静默异常、新建文档被取消、面板无法取消等；`userAskedForUntitled()` 依赖 `NSApp.currentEvent`（`:239-246`），非键盘来源的合法新建会被误杀；swizzling 失败时只有 `-XYZCheckFileMenu` 能发现（CI :150-199）。
- 建议：把 hooks 隔离成独立模块并加版本探测/启动自检（已有）；能不用 swizzling 的路径改回 `Commands`/`NSOpenSavePanelDelegate`；对 `openUntitledDocument` 的拦截改为 `applicationShouldOpenUntitledFile` 或 `NSDocumentController` 子类（项目文档已解释 DocumentGroup 限制，但可评估 `DocumentGroup` 替代方案）；至少把 block 签名集中封装、加断言与失败日志。

**P2-2 路径包含判断重复 4 处、无 core helper / 单测，且 symlink/大小写/归一化未处理**
- 证据：`WorkspaceSession.openLinked`（`:359-368`）、`CLIOpen.openOne`（`FolderOpening.swift:534-540`）、侧栏拖放（`WorkspaceSidebar.swift:679-689`）、索引扫描（`WorkspaceSession.swift:1950-1964`）各自 `standardizedFileURL.path + root + "/"` 前缀判断；`WorkspaceSession.url(for:)`（`:1052-1056`）不做 `..`/绝对路径校验。root 为 `/` 时前缀变成 `//`，索引会全部丢弃（`:1950-1964`）。
- 影响：符号链接/大小写不同的路径绕过或误判；持久化 tab 路径被篡改/损坏时越出 root；四处行为可能不一致（有无 trailing slash、`/private` vs `/var`）。
- 建议：`XYZCore` 新增 `WorkspacePathContainment`（`resolve(relativeTo:)`、`contains(root:url:)`、`normalizedRelativePath`），对 `..`、绝对路径、大小写、NFC/NFD、symlink 选项显式测试；所有 4 处改用它；恢复的 tab 路径先校验再 `url(for:)`。

**P2-3 未受信 Markdown 会自动加载远程图片**
- 证据：`URLPolicy.imageSchemes = ["http","https"]`（`HTMLRenderer.swift:481-489`）；WKWebView 配置允许 JavaScript/网络（`MarkdownWebView.swift:434-447`），entitlement 含 `network.client`；Reading 直接用 `xyz-asset` base + 远程图片。
- 影响：打开从网上下载的 .md 时自动请求远程图片（IP、User-Agent、跟踪像素），无“阻止远程内容”选项。
- 建议：Reading 设置里加“阻止远程内容/仅按需加载”；或在 `URLPolicy` 里对未受信文件默认剥离 http(s) image，点击后在默认浏览器打开。

**P2-4 图片/QuickLook/视频表面的主线程解码与释放**
- 证据：`ImageSurface` 在 `makeNSView/updateNSView` 中 `NSImage(contentsOf:)` 并整图 `image.draw`（`FileSurfaces.swift:139-168, 180-205`）；`QuickLookHost` 无 `close`（`:371-416`）；`JSONReadingView`/`CSVReadingView` 每次 body 重新 `JSONText.pretty`/`CSVText.parse`（`:43-44, 83-84`），大文件会重复解析。
- 影响：打开大图/大 CSV 时主线程卡顿与内存峰值；QuickLook 预览进程可能长期驻留。
- 建议：图片走 `CGImageSourceCreateThumbnailAtIndex` 后台降采样；Reading 的 JSON/CSV 解析结果缓存到 `@State`/`task`；`QuickLookHost` 在 `dismantleNSView` 里 `preview?.close()`；媒体 surface 加 `dismantle`（已有 pause）。

**P2-5 巨型文件/类型集中与拆分边界**
- 证据与拆分清单见第 4 节（`WorkspaceSession.swift:14-1611` 一个类型 110 个方法；`WorkspaceView.swift:24-549` 一个文件塞 730 行 NSSplitView；`WorkspaceSidebar.swift` 18 个类型/1839 行；`EditorCommands.swift:159-265, 439-498` 巨型快捷键/命令 switch；`FolderOpening.swift:64-497` swizzling + 菜单手术）。
- 影响：单测无法覆盖 session 行为；改动易互相回归（P0-2 即由 `openFile` 局部改动引入）。
- 建议：按第 4 节 8 个边界拆文件；命令/快捷键表驱动化；把 `restore`/保存序列/路径/替换计划等纯逻辑下沉 `XYZCore`。

**P2-6 主线程 O(n) 计算与高频 `@Published` 触发整棵 SwiftUI 重算**
- 证据：`session.searchTree` 每次访问都重新过滤（`WorkspaceSession.swift:303-308` → `WorkspaceTreeQuery.filter`，最多 20k entries），而 `WorkspaceSidebar.Snapshot(session)`（`WorkspaceSidebar.swift:1294-1345`）和 `rebuild`（`:494-522`）每次 update 都调用；`caret`/`viewportLine` 是 `@Published`（`WorkspaceSession.swift:93-95`），编辑器滚动/选区变化每帧触发 `WorkspaceView`/`WorkspaceDetail`/`OutlineSidebar` 重算与 `updateNSView`。
- 影响：大目录 + 大文件下侧栏/状态栏/滚动掉帧。
- 建议：缓存 `searchTree`（按 query/indexedEntries/hidden 的版本号失效）；`Snapshot` 用轻量哈希比较；`caret/viewport` 用去抖或独立 Observable 对象只让状态栏/outline 订阅。

**P2-7 书签 stale 从不刷新，面板路径与 `capture` 约定不一致**
- 证据：`WorkspaceBookmarks.resolve` 的 `isStale` 被丢弃（`WorkspaceFileAccess.swift:255-270`）；`WorkspaceWindowController.open(bookmark:)`（`:200-209`）与 `open(url:...)`（`:222-232`）只记 `bookmarkRestored(stale:)` 日志，不回写；面板路径直接 `WorkspaceBookmarks.make`（`WorkspaceWindowController.swift:54-60, 185-193`），CLI/拖放用 `capture`（`FolderOpening.swift:574`, `WorkspaceWindowController.swift:222`）。
- 影响：文件夹移动/重命名后，restore 可能永久失败且没有 fallback（`reopenLastFolder` 只取第一个 window/recent）；面板创建的 bookmark 在特殊路径下可能失败（返回 nil 后该窗口不持久化）。
- 建议：解析时若 `stale`，立即 `make` 新 bookmark 并 `WorkspaceLibrary.syncWindows` 回写；统一走 `capture`；restore 失败时降级到“取消该窗口并提示选择文件夹”。

**P2-8 同一文件可能同时被工作区与 DocumentGroup 两套模型打开**
- 证据：`claimExistingFile` 只在 `WorkspaceWindowController.controllers` 之间去重（`WorkspaceWindowController.swift:95-98, 259-272`）；`openInDocumentWindow` 用 `NSDocumentController` 打开（`WorkspaceSession.swift:1021-1027`），`WorkspaceCommandBridge.paletteOpen(newWindow:)` 与 `DocumentEditorView` 的 Reading 链接处理器（`DocumentEditorView.swift:178-182`, `WorkspaceView.swift:1731-1738`）都走 `NSDocumentController`。
- 影响：同一路径两个编辑模型各自自动保存，只在磁盘层靠 `WorkspaceFilePolicy` 冲突兜底；用户看到两份不同内容、互相覆盖。
- 建议：DocumentGroup 侧也通过一个进程级“文件占用表”做 claim（或禁止从工作区打开 DocumentGroup 窗口）；至少在检查/提示上对齐。

**P2-9 `WorkspaceSidebar.updateNSView` 内修改 `@Published`（SwiftUI 反模式）**
- 证据：`reloadIfNeeded` 在 `updateNSView` 调用链里执行 `session.actionMessage = nil`（`WorkspaceSidebar.swift:70-74, 113-135`）；`WorkspaceChromeView.layout()` 里 `onTitlebarInset` 回写 SwiftUI `@State`（`WorkspaceView.swift:1068-1092`），`layout()` 为 AppKit 布局阶段。
- 影响：可能出现 “Modifying state during view update / Publishing changes from within view updates” 的未定义行为；标题栏 inset 在布局中改状态可能触发额外布局轮次。
- 建议：把 `actionMessage` 消费挪到 `MainActor.async`/`.onReceive`；`onTitlebarInset` 用 `DispatchQueue.main.async` 合并；或把状态变化通过显式事件而非视图 update 传递。

**P2-10 高频诊断同步写文件**
- 证据：`XYZDiagnostics.note` 每次调用 `append` 打开/写入临时文件（`XYZDiagnostics.swift:58-62, 192-204`），而 `viewportLine`/侧栏 fit/模式切换/窗口 pass 都会调用它（`WorkspaceSession.swift:154-159`、`WorkspaceSidebar.swift:1028-1031` 等）。
- 影响：诊断开关打开时，滚动/布局高频同步 IO 拖慢主线程（仅调试场景，但容易误开）。
- 建议：诊断写入移到后台串行队列/缓冲批量写；热路径（viewport）降级为 os_log 或采样。

---

## 附：本次核实过的关键行号索引（便于复核）

- 打开串行号/恢复：`WorkspaceSession.swift:126-127, 539-563, 717-761`；`WorkspaceWindowController.swift:245-254, 461-468, 428-443`；`EditorShellTests.swift:256-284`。
- 新建/替换：`WorkspaceSession.swift:410-455, 1241-1258, 1306-1375, 1416-1478`；`XYZCore/WorkspaceSearch.swift:281-318`。
- buffer 发布/保存：`WorkspaceSession.swift:1632-1935`（`1636-1640, 1651-1658, 1767-1770, 1782-1841, 1867-1879, 1881-1934`）；`WorkspaceFileAccess.swift:99-154`。
- 监听：`WorkspaceFileAccess.swift:8-74`；`WorkspaceSession.swift:980-993, 1067-1073, 1502-1509`。
- 索引/搜索取消：`WorkspaceSession.swift:1110-1167, 1377-1414, 1938-1976`。
- 路径/安全：`WorkspaceSession.swift:359-368, 1052-1056, 1950-1964`；`WorkspaceDirectoryLoader.swift:10-27`；`LocalAssets.swift:26-39`；`HTMLRenderer.swift:481-499`；`WorkspaceSearch.swift:339-347`；`XYZ/XYZ-macOS.entitlements`。
- 生命周期：`WorkspaceWindowController.swift:8-34, 106-115, 129-137, 445-451, 472-498, 652-657`；`WorkspaceSession.swift:186-223`；`docs/architecture.md:7-9`。
- swizzling：`FolderOpening.swift:64-111, 113-145, 160-236, 239-246, 249-258, 349-497, 499-527`。
- CI：`.github/workflows/ci.yml:59, 66, 77-101, 103-122, 125-148, 150-199, 200-208`；`GutterSnapshot.swift:533-700, 892-960, 1604-1636, 2435-2470`；`WorkspaceSidebar.swift:724-847`；`GlobalSearchPanel.swift:841-895`。
