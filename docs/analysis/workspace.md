# XYZ Mac Workspace Layer Analysis (Read-Only)

Scope: `XYZ/Workspace/*.swift` (12,437 lines across 13 files), `XYZ/DocumentEditorView.swift`, `XYZ/XYZApp.swift`; references `XYZCore/Sources/XYZCore/*`, `XYZ/Preview/*`, `XYZ/Editor/*`, `docs/architecture.md`, `CHANGELOG.md`, `.github/workflows/ci.yml`.
Method: file-by-file read/grep plus line-number pinning; did not run `xcodebuild` (the Lead confirmed the Debug/Release/iOS Simulator builds pass). To validate two filesystem-level hypotheses, ran two one-off experiments in `/tmp` with `swift`/shell (see P0-1 and P1-5); the repository was not touched.
Version: 0.5.28 (build 44), HEAD `db12a62`; working tree clean.

---

## 0. Summary of Findings

- **The overall architecture is right**: `WorkspaceSession` owns the folder/tabs/current buffer; `WorkspaceFileBuffer` owns a single file's text and save state; pure policy (file classification, disk/editor conflicts, open-generation checks) already lives in `XYZCore` with unit-test coverage (`WorkspaceFilePolicy` / `WorkspaceTests`). AppKit appears only at the window/sidebar/panel layer.
- **But the read/write/lifecycle lines still have hard defects**: open-generation protection is a **global serial number** that collides with batch tab restoration and immediately persists an empty tab list after restore (P0-2); creating a file on a case-insensitive volume can **truncate an existing same-name file** (P0-1); window close/quit performs a single best-effort flush, with no blocking prompt on failure/conflict (P0-3).
- **State ownership has one structural break**: `WorkspaceFileBuffer` is an `ObservableObject` with 5 `@Published` properties, yet no view in the whole app subscribes to it (grep finds no `@ObservedObject var buffer` / `sink`). UI refresh for external disk changes, save-failure notices, and missing-file notices actually rides incidentally on unrelated `@Published` changes from `WorkspaceSession` (P1-1).
- **Full disk I/O on the main thread**: `save()` runs `NSFileCoordinator` + full-file read + full-file write synchronously on `@MainActor`, while the read path is `Task.detached` (P1-2, matching the Lead's clue a).
- **System-class swizzling** is concentrated in `FolderOpening.swift` (3 NSSavePanel selectors + 4 PlatformDocumentController selectors, with hand-written block signatures/`unsafeBitCast`); it is the project's largest upgrade fragility (P2-1, matching the Lead's clue b).
- Unit tests cover only `XYZCore` pure functions; the CI window screenshot/OCR job covers only one chain — "open a single file / switch mode / switch file". **Restoring tabs, saving/quit, disk conflicts, Replace All, case handling, symlinks, and bookmarks** all remain manual-only (section 6).

---

## 1. State Ownership and Data Flow

### 1.1 Ownership Boundaries

| Object | Location | State owned | Lifetime |
|---|---|---|---|
| `WorkspaceSession` (`@MainActor ObservableObject`) | `WorkspaceSession.swift:14` | `rootURL/bookmark`, tree `children/expanded/loadErrors`, `selectedPath`, `buffer`, `tabStrip`, `viewMode`, `caret/viewportLine`, search state, `indexedEntries/contentHits`, `previewBridge/previewHost/scrollLink`, monitor/tasks/generations | one per window; strongly held by `WorkspaceWindowController`; replaced wholesale on `switchFolder` |
| `WorkspaceFileBuffer` (`@MainActor ObservableObject`) | `WorkspaceSession.swift:1632-1935` | single-file `text/lastSaved/encoding/lineEnding/conflictText/isMissing/status/reloadToken`, `saveTask`, `observationEpoch` | held by the `session.buffers[path]` dictionary; removed on tab close/`release` |
| `WorkspaceWindowController` | `WorkspaceWindowController.swift:8` | `NSWindow`, `session`, global `static controllers` | strongly holds window+session; removes itself in `windowWillClose` |
| SwiftUI tree | `WorkspaceView.swift:838` / `WorkspaceDetail:1385` / `WorkspaceCommandBridge:1662` | local UI state such as layout/visibility (`columnVisibility`, `titlebarInset`, `outline`, `wordCount`, `caret` mirror) | held by `WorkspaceRootView`'s `NSHostingView` |
| AppKit side | `XYZSplitView`, `SidebarColumnView`, `WorkspaceChromeView`, find/palette/search panels | split-view frames, sidebar snapshot, titlebar accessories, panels | view lifetime; panels reused as controller singletons |

Data flow (opening a file):

```
Sidebar/⌘K/⌘P → session.openFile(node,...)                         WorkspaceSession.swift:515-565
  ├─ claimExistingFile? (cross-window dedupe, workspace windows only)  :523 / WorkspaceWindowController.swift:95-98
  ├─ revealAncestors / scrollMemory → pendingRevealLine            :530-538
  ├─ openSerial += 1; openRequest[path] += 1                       :539-546
  └─ Task { await readForEditing(detached IO) }                    :548
        └─ MainActor.run: install only if serial==openSerial and
           shouldInstallRead(request/latest/alreadyInstalled)      :551-557
             ├─ makeBuffer (installs onEditorState/onConflict, both weak self)  :936-957
             ├─ watchFile → DirectoryMonitor                       :980-993
             └─ present(): publish tabStrip+buffer together → show()        :568-578
```

Edit/save flow: `XYZMacEditor.updateNSView` (`XYZMacEditor.swift:1215-1226`, replaces the text wholesale only when `reloadToken` changes) → SwiftUI closure `session.buffer?.userEdited(...)` (`WorkspaceView.swift:1643-1652`) → `WorkspaceFileBuffer.userEdited` (`1750-1764`) → 500 ms `scheduleSave` (`1881-1888`) → `save()` (`1890-1934`) → `WorkspaceFileCoordination.updateText` (`WorkspaceFileAccess.swift:99-154`) → `onEditorState` writes only dirty back into `tabStrip` (`947-952`).

### 1.2 @Published Update Timing and Main Problems

1. **Session publishes on its own**: tree/tabs/viewMode/caret/viewport/search/`actionMessage` are all `@Published`; both SwiftUI and `WorkspaceSidebar.updateNSView` recompute from them (`WorkspaceSidebar.swift:70-74`).
2. **Buffer publishing is ineffective**: the `@Published` properties of `WorkspaceFileBuffer` (`1636-1640`: `kind/reloadToken/conflictText/isMissing/status`) have no observer. Views only read `session.buffer?.text` / `.editorToken` / `.status` (`WorkspaceView.swift:1439-1448, 1590-1617, 1628-1655`), and SwiftUI does not track properties of a nested `ObservableObject`. Actual refresh rides incidentally: `onEditorState` → only a change in `EditorTabStrip.setDirty` makes `session.tabStrip` (`@Published`) publish (`WorkspaceSession.swift:947-952`, `EditorTabs.swift:118-125`). Therefore:
   - A clean file modified externally: `noteExternalChange` → `apply(text:)` changes `text/lastSaved/reloadToken` (`1867-1879`), `setDirty(false)` returns false → **the session publishes nothing** → the editor's `reloadToken` does not update and the Reading preview does not refresh, until the user scrolls/clicks and produces a `viewportLine`/`caret` publication. CHANGELOG:281 "A clean file still reloads quietly" does not necessarily hold in the UI.
   - Save failure: the `catch` in `save` only sets `status` (`1929-1933`) and does not call `onEditorState` → the status-bar banner may never appear.
   - `noteMissing` (`1814-1816, 1843-1850`) likewise only modifies the buffer; only a later `indexedEntries` publication from `scheduleIndex` during a directory refresh can make the banner appear.
3. **Mirrored state**: `WorkspaceDetail` writes both its `@State caret` and `session.caret` (`1392, 1639-1643`); `WorkspaceView.openFilePath` uses `selectedPath ?? buffer` (`996-1001`), while `selectedPath` duplicates `buffer.relativePath` along most paths. See P1-7.
4. **Main-thread assumption**: session/buffer/views are all `@MainActor`; `DirectoryMonitor` runs `open/O_EVTONLY + DispatchSource` on a private queue, with events uniformly debounced via `DispatchQueue.main.asyncAfter` (`WorkspaceFileAccess.swift:21-68`); background reads are always `Task.detached` followed by a return to `MainActor.run`. Sole exception: the synchronous I/O of `save()` actually runs on the main thread (P1-2).

### 1.3 Task Lifecycle Inventory

- Tracked and cancellable: `reloadTasks` (directory debounce, `1502-1509`), `indexTask` (`1110-1127`), `contentTask` (`1129-1167`), `buffer.saveTask` (`1881-1888`), `find.searchTask` (`EditorChrome.swift:203-210`), `outline.task` (`EditorChrome.swift:1293-1304`), `GlobalSearchController.task` (`GlobalSearchPanel.swift:327-361`).
- **Not tracked**: opening files (`548-564`), creating files (`429-455`), folder replacement (`1259-1273`), disk sampling in `noteExternalChange` (`1787-1840`), `load(parent:)` (`1515-1545`), the `Task { @MainActor }` inside monitor callbacks (`204, 1069`). `shutdown()` (`211-223`) cancels only the first three groups; the rest exit on their own via `[weak self]` + generation guards, and detached reads still run to completion.
- Completion order of an individual Task is protected by guards, but **cancellation semantics** fail on detached tasks (P1-6).

---

## 2. Concurrency / Races

### 2.1 Inventory of Existing Generation Mechanisms

| Mechanism | Location | Decision | Assessment |
|---|---|---|---|
| Directory load `loadGeneration[parent]` | `1511-1545` | compare `loadGeneration[parent]` before results land | correct; but detached directory enumeration is not cancellable |
| Index `indexGeneration` | `1110-1127` | compare before results land | correct; the scan itself is not cancellable |
| Open file `openSerial` (global) + `openRequest[path]` | `126-127, 539-563` | only the last **user request** may publish a tab | fixes "tab appears before text", but **kills batch restore** (P0-2) |
| Install read `WorkspaceFilePolicy.shouldInstallRead` | `WorkspaceFilePolicy.swift:266-270` | `request==latest && !alreadyInstalled` | correct, unit-tested (`WorkspaceTests.swift:527-531`) |
| Disk sampling `observationEpoch` | `1651-1653, 1782-1841, 1894` | discard if edited after sampling started | correct, unit-tested (`533-537`) |
| Save decision `decideWrite` | `WorkspaceFileAccess.swift:131-146` | re-read disk inside the coordination block, then decide write/upToDate/conflict | correct; TOCTOU exists only for non-coordinated writers (git/shell) |
| Follow-up write `needsFollowUpSave` | `1917-1919` | text changed again after the write → save again | correct (unit test `538-541`) |
| Content search | `1129-1167` | `Task.cancel` + query/glob equality compare | outer layer correct; detached work is not cancellable |
| Find-panel Reading generation | `EditorChrome.swift:129-200` | `readingGeneration` | correct |
| Global search | `GlobalSearchPanel.swift:327-361` | `generation` + cancel | correct |

### 2.2 Remaining Races / Loss Paths

- **Batch restore is defeated by "latest open wins"** (P0-2): `restoreTabs` calls `openFile` in a synchronous loop; each call does `openSerial += 1` and then reads asynchronously; when a read completes, only the serial of the last request can pass the guard. `open()` then immediately calls `persistOpenWindows()`, while `tabStrip` is still empty. The result is "a restored window usually keeps only its last tab, and the saved tab list is overwritten". Unit tests only cover `WorkspaceWindowState.normalized` (`EditorShellTests.swift:256-284`); CI's `renderDocumentWindow` calls `session.openRelative("fixture.md")` directly and never goes through restore (`GutterSnapshot.swift:533-700`).
- **Per-tab viewMode is not persisted** (P1-3): `windowState()` hardcodes `.reading` for all tabs (`717-724`); `openRestored` also passes `.reading` (`749-761`); `restoreTabs` never calls `setMode` (`727-747`). `WorkspaceTabState.mode` is a dead field on the restore path, while `EditorTab.mode` does have unit tests (`EditorTabs.swift:72-75`, `EditorShellTests.swift:234`).
- **Two different files clicked in quick succession**: because `openSerial` is global, when A→B happens A's read is discarded and A never gets a tab at all (`539-563`). That is acceptable for "preview replacement" semantics, but it conflicts with the intuition that "every file you clicked should have a tab"; the suggestion is to let only requests for the same path compete, and to use an open-order queue across paths.
- **TOCTOU in Replace in Folder** (P1-4): `planFolderReplace` reads all file contents in the background (`1416-1478`); after the confirmation dialog, `applyFolderChange` (`1306-1375`) **writes unopened files directly from the old plan**, without re-reading or comparing; if a file was modified externally/iCloud-synced in the meantime, it is silently overwritten. Only the buffer that is "currently open and whose text equals the planned original" is checked (`1313-1315`).
- **Hidden-file overflow in Replace in Folder**: the file list at plan time excludes only `shouldSkipRelativePath` (`.git/node_modules/.build`) and **does not exclude `entry.isHidden`, nor consult `showsHiddenFiles`** (`1241-1243`; content search is the same, `1148-1150`). By contrast, `searchPanelContents` does filter (`1183, 1189-1194`). So with "hidden files" off, Replace All still rewrites text files the user cannot see, such as `.env` and `.obsidian/*`.
- **Window close/quit loses unsaved edits** (P0-3): `windowWillClose` calls `session.shutdown()` directly (`WorkspaceWindowController.swift:129-137`), `prepareForQuit` flushes only once and then `terminateNow` (`445-451, 652-657`); `shutdown` calls `flush()` on every buffer (`211-223`), while `flush` calls a single non-forced `save` (`1767-1770`). If that save is a conflict/encoding error/IO error (`1925-1933`), the edit survives only in memory and the window is destroyed right after; conflict notification via `offerExternalChange` additionally requires `buffer === self.buffer` (`961-963`), so conflicts in background tabs get no notification at all.
- **trash of dirty files**: `trash` first calls `closeTab(force: true)` (no flush) and then `trashItem` (`479-489`); the force-closed buffer's flush is deferred to `DispatchQueue.main.async` (`676-688`), and by the time it runs the file is already in the Trash → `save` takes the conflict branch and does not write → unsaved edits are lost.
- **Text changes again during save**: already handled (`needsFollowUpSave`), but only on the `.write` branch; on `.conflict`, new edits stay in memory only (`userEdited` cancels the save when it sees `conflictText != nil`, `1755-1758`). That is intended behavior, but the banner must be guaranteed visible (see P1-1).
- **Disk watching**: `DirectoryMonitor` uses one `DispatchSourceFileSystemObject` per key with a 250 ms debounce (`WorkspaceFileAccess.swift:8-74`); the file monitor is attached when the buffer is installed and detached on release (`980-993`), and directory monitors are added/removed with expand/collapse (`1067-1073, 1493-1500`). The problem is that **every directory event triggers a `load()`, which calls `scheduleIndex()`** (`1534`) — i.e. any file-tree change starts a full-root recursive index (P1-6).
- **Duplicate buffers**: cross-workspace-window deduplication exists via `claimExistingFile` (`523` + `WorkspaceWindowController.swift:259-272`), but `openInDocumentWindow` (`1021-1027`) and Reading preview links (`DocumentEditorView.swift:178-182`) hand the same file to `NSDocumentController`'s `DocumentGroup`, producing a second model; each side saves independently and only disk conflict catches it (P2-8).

---

## 3. Resources and Lifecycle

### 3.1 security-scoped bookmarks

- Creation: `WorkspaceBookmarks.make` (`WorkspaceFileAccess.swift:228-235`), `capture` (wraps the write in start/stop, `237-253`); panel paths call `make` directly (`WorkspaceWindowController.swift:54-60, 185-193`), CLI/drag paths use `capture` (`FolderOpening.swift:574`, `WorkspaceWindowController.swift:222`).
- Holding: `WorkspaceSession.bookmark` + a single `startAccessingSecurityScopedResource` inside `activate()` (`WorkspaceSession.swift:189`), with the paired stop in `shutdown()` (`219-222`). `accessStarted` prevents duplicates.
- CLI path: `startAccessing` → `openOne` → `stopAccessing` inside `application(_:open:)` (`FolderOpening.swift:516-524`); the session then starts access again on the resolved bookmark URL, avoiding loss of access after the outer stop (sound by design).
- **Problems**: (1) the `stale` flag is discarded, and restore never refreshes/rewrites the bookmark (`WorkspaceFileAccess.swift:255-270`; `WorkspaceWindowController.swift:224-232` only logs); restore degrades over time after the folder is moved/renamed. (2) Panel paths call `make` without start/stop, inconsistent with the `capture` convention. (3) `WorkspaceLibrary` synchronously writes all bookmarks/window state to UserDefaults on every `onTabsChanged` (`WorkspaceWindowController.swift:99-102, 461-468`), doing JSON+Data writes on the main thread. (4) Restored window tab paths are not validated before entering `url(for:)` (`1052-1056`) — a `".."` component can escape the root (if persisted data is tampered with).

### 3.2 NSWindow / SwiftUI Hybrid

- Not an `NSWindow` subclass, but a plain `NSWindow` + `NSWindowController` acting as delegate (`WorkspaceWindowController.swift:8-34`), with `isReleasedWhenClosed = false` (`:28`); the window is strongly held from `static controllers` and removed on close (`:129-137`).
- **Why `NSHostingController` is not used** (also documented in the architecture doc, `docs/architecture.md:7`): it is a constraint-driven content controller that feeds the editor's flexible height back into the window, and each layout pass makes the window taller until AppKit aborts. The current design wraps an `NSHostingView` in `WorkspaceRootView: NSView`, sets `sizingOptions = []`, and uses manual frames + `layout()` synchronization (`WorkspaceWindowController.swift:106-115, 472-498`). This is the right trade-off; just keep the comment.
- Window chrome mutates the AppKit titlebar directly: `WorkspaceChrome.apply` (`WorkspaceView.swift:1357-1383`) sets `titleVisibility=.hidden` and removes the toolbar; `TitlebarTitleInstaller` inserts labels/toggles into `standardWindowButton(.closeButton).superview` (`1100-1191`), and re-applies them repeatedly inside `layout()` (`WorkspaceChromeView:1068-1092`).
- Lifecycle gaps:
  - `windowWillClose` is not intercepted, so there is no "unsaved changes" gate (P0-3).
  - `installPhantomGuard` registers 3 notifications + 6 delayed passes (`308-348`) and never unregisters them (acceptable at app scope); `closeStrayWindows`/`closePhantomWindows` use 500×500/alpha heuristics to close windows that are "not ours" (`350-421`) — high-maintenance code that could kill future windows.
  - `WindowFill.fillOnce` uses `NSHashTable.weakObjects` + 3 `async` retries (`665-692`); acceptable.
  - `static controllers` is a strongly referenced array; if a window does not go through `windowWillClose` (abnormal path), the entire session is retained forever.
- AppKit machinery inside SwiftUI views: `XYZSplitView` at 600+ lines, `SidebarColumnView` at 300+ lines, `SidebarDivider`/`PaneSplitView`/`PaneHost` (`WorkspaceView.swift:24-549`), and `PaneHost.layout` reverse-locking the frame (`:552-567`); these are historical artifacts of "window instability" — they work but are hard to test.

### 3.3 NSTextView / WKWebView Ownership and Retain Cycles

- Editor: the `XYZMacEditor` UI is held by `EditorPane`/`XYZMacTextView`, `EditorFindModel.editorView` is `weak` (`EditorChrome.swift:36`), and `find.edit` captures `[weak textView]` (`XYZMacEditor.swift:1193-1194`). `Coordinator.deinit` removes scroll observations (`XYZMacEditor.swift:1323-1327`).
- Reading: one `PreviewWebHost` per session, lazily creating a `WKWebView` reused across files (`WorkspaceSession.swift:108-110`; `MarkdownWebView.swift:17-39`), with `PreviewWebCoordinator.openFile` capturing `[weak self]`. When `WorkspaceDetail` switches surfaces, `MarkdownPreview` reuses the same host and does not create another web view (as intended), but on session close it does not explicitly `stopLoading`/nil it out, relying on dealloc.
- Callback capture audit: `onEditorState`/`onConflict`/`scrollLink.onViewportLine`/`previewHost.openFile`/monitor callbacks/`onTabsChanged`/`claimExistingFile`/`onMoveTab` are all `[weak self]` (`947-955, 149-151, 190-194, 983-987, 1068-1072, WorkspaceWindowController.swift:95-105`); no strong session↔controller cycle was found.
- Remaining static/global holdings: `EditorCommands.shared` (weak `target`/`hostWindow`, `EditorCommands.swift:127-128`), `EditorMenuSupport.observers`/`FolderOpening.observers`/`EscapeKey.menuObservers`/`WorkspaceWindowController.phantomObservers` never unregister (app scope), `TabMiddleTarget.live` + the global `monitor` (`EditorChrome.swift:805-850`, weak view but `viewDidMoveToWindow` can append repeatedly), `AboutWindow.panel`, `GoToLinePanel.current` (cleared only on cancel/commit, not when a focus loss hides it, `EditorCommands.swift:1813-1918`). `EditorAnchorView` registers a `didBecomeKey` observation but **has no `deinit` to unregister** (`EditorCommands.swift:1159-1205`); although a second entry through `viewDidMoveToWindow` removes it first, adding a deinit is still recommended.
- Third-party surfaces: `PDFSurface.Coordinator` has a deinit that unregisters (`FileSurfaces.swift:328-330`); `QuickLookHost` never calls `preview?.close()` (`371-416`); `MediaSurface` pauses on dismantle (`351-355`); `ImageSurface` decodes the whole image on the main thread with `NSImage(contentsOf:)` in `makeNSView/updateNSView` (`143-168, 180-187`), so large images/HEIC visibly stutter and there is no downsampling.

---

## 4. Complexity Hotspots and Extraction Suggestions

Statistics (`grep` of declarations + line counts): `WorkspaceSession.swift` 1978 lines/6 types/110 func; `EditorCommands.swift` 1919/21/143; `WorkspaceView.swift` 1852/21/110; `WorkspaceSidebar.swift` 1839/18/112; `EditorChrome.swift` 1395/26/62; `GlobalSearchPanel.swift` 908/6/51; `WorkspaceWindowController.swift` 744/9/33; `FolderOpening.swift` 530/6/17; `FileSurfaces.swift` 430/11/24.

Concrete evidence of giant bodies / command dispatch:

- `EditorCommands.handleKeyEquivalent` matches 40+ sequential `if flags == ... && key == ...` checks (`159-265`), `run(_ id:)` is a 30-branch `switch` (`439-498`), plus 370 lines of imperative menu surgery (`EditorMenuSupport`, `776-1143`) and 3 panel classes.
- `WorkspaceSession` simultaneously does: tree/expand/persistence, open generations, disk monitoring, indexing and content search, global-search aggregation, folder replacement (plan + write + undo), tabs/scroll/view mode, and CLI open helpers (`openInDocumentWindow`).
- `WorkspaceView.swift` crams a full `NSSplitView` (`24-549`), titlebar AppKit injection (`1005-1383`), business detail (`1385-1658`), and the command bridge (`1660-1842`) into a SwiftUI file.
- `WorkspaceSidebar.swift` is a single file containing the representable + NSOutlineView data source/drag-and-drop/rename (`84-705`), column-width fitting (`708-1047`), root header (`1050-1276`), row cells/drawing (`1392-1838`), and the CI self-check (`724-847`).

The 8 extractions most worth doing (ordered by payoff):

1. **`WorkspaceSession` → 4 collaborating objects**: `WorkspaceSession` (tree/selection/tab presentation), `WorkspaceOpenCoordinator` (openFile/generations/restoreTabs, including the "batch restore" path), `WorkspaceIndexer` (`scheduleIndex` + `WorkspaceIndexScan` + search-result aggregation), `FolderReplaceEngine` (plan/apply/undo). A fifth: split `WorkspaceFileBuffer` into its own file with a dedicated save coordinator.
2. **Open/restore pure logic into XYZCore**: model the "apply order" of `restoreTabs` as a pure function (input `WorkspaceWindowState`, output tab sequence + per-tab mode/preview/pinned), which is the only way to write a regression unit test for P0-2.
3. **`EditorCommands` → shortcut table + command registry + menu installer + individual panels**. Make shortcuts/validation declarative `[Shortcut]`, map `run(id:)` to `PaletteCommand` (`XYZCore/CommandPalette.swift` already has id/title), and eliminate the two command tables.
4. **`WorkspaceView` → a separate file for the `XYZSplitView` machinery** (AppKit, ~730 lines), a separate file for window chrome/titlebar, a separate file for `WorkspaceDetail`, and a separate file for `WorkspaceCommandBridge`.
5. **`WorkspaceSidebar` → Coordinator (data source) + SidebarColumnView/Header + SidebarRowCell drawing + width fitting/self-check**. The CI-only `SidebarColumnFitCheck` should not remain in a production file.
6. **`GlobalSearchPanel` → panel construction/search cell + controller state machine**; move `QueryField`'s diagnostics overlay to DEBUG.
7. **`EditorChrome` → find model/bar, tab bar, breadcrumb/status bar, outline, tab-switch picker** (26 types are currently mixed into one file).
8. **`FolderOpening` → a standalone swizzling-hooks module + FileMenuSupport + AppDelegate**; split `FileSurfaces` by surface into separate files, and move the JSON/CSV views into their own files.

Logic that belongs in `XYZCore` (unit-testable) but currently stays in the App:

- **Path containment/normalization**: `openLinked` (`WorkspaceSession.swift:359-368`), CLI (`FolderOpening.swift:534-540`), drag-and-drop (`WorkspaceSidebar.swift:679-689`), and indexing (`WorkspaceSession.swift:1950-1964`) each hand-write `standardizedFileURL.path + hasPrefix(root + "/")`, with no shared function, no unit tests, and no coverage of symlinks/case/Unicode normalization.
- **Case-/normalization-aware unique naming**: `WorkspaceItemName.unique` (`XYZCore WorkspaceSearch.swift:297-309`) only does an exact-string set check, inconsistent with the current volume's case-insensitive semantics (P0-1).
- **Save state machine**: `WorkspaceFilePolicy` only has decision functions; the debounce/serial/epoch/conflict-notice **migration sequence** stays in `WorkspaceFileBuffer`, with no state-machine tests.
- **Pure-function Replace planning**: extract "entries + text → change set" into a core type (IO stays in the App) so encoding/line endings/case/hidden-file filtering can be tested.
- **Index-scan skip policy**: `WorkspaceIndexScan` is in the App (`1938-1976`); its skip/hidden/cap semantics should at least share core rules with `WorkspaceContentSearch` and be tested (currently the `.git/node_modules/.build` list lives only in core, while the scanner implements its own).

---

## 5. Security

Sandbox capabilities (`XYZ/XYZ-macOS.entitlements`): `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`, iCloud CloudDocuments. All disk access should stay within "user-selected folder root + bookmark".

1. **Path normalization**: see section 4; `standardizedFileURL` resolves only `..`/`//` and **does not resolve symlinks**; differing case (APFS is case-insensitive by default) and differing Unicode NFC/NFD are not handled. `WorkspaceSession.url(for:)` (`1052-1056`) appends each `/` segment of `relativePath` directly via `appendingPathComponent`; a persisted/restored path containing `..` or an absolute segment escapes the root, and `openRelative` itself does not validate either.
2. **Hidden files/skipped directories**: globally only `.git`, `node_modules`, and `.build` are skipped (`XYZCore/WorkspaceSearch.swift:339-347`); `Pods`, `DerivedData`, `vendor`, `.venv`, `target`, etc. are still indexed/content-searched/Replace-All'd. When "show hidden files" is off, hidden files are still hit by content search and Replace All (P1-4), which is the direct source of "search/replace out of bounds".
3. **Symlinks**: `WorkspaceDirectoryLoader` treats a symlink as a file (`WorkspaceDirectoryLoader.swift:10-27`, `isDirectory = isDirectory && !isLink`), and indexing does the same (`WorkspaceSession.swift:1957-1958`). After the user edits, saving goes through `Data.write(.atomic)` (`WorkspaceFileAccess.swift:139-142`), which **replaces the directory entry** instead of writing the target (P1-5). Indexing/content search follow links and read outside content (limited by the sandbox).
4. **Quick Look / external open**: `FileOpenRouting` hands Office and similar formats to Quick Look (`WorkspaceFilePolicy.swift:199-222`), and `QuickLookSurface` uses `QLPreviewItem` directly (`FileSurfaces.swift:357-416`); security depends on the system preview extension sandbox. `openLinked` calls `NSWorkspace.shared.open` directly for links outside the root (`WorkspaceSession.swift:363-365`); a relative link in Reading can be resolved by `<base href="xyz-asset://...">` into an arbitrary absolute path (`MarkdownWebView.swift:582-597` + `LocalAssets.swift:26-31`), so a malicious Markdown can use a link that "looks like a note" to make the user open an arbitrary app/document (explicit click, but no confirmation). `NSDocumentController.openDocument` (`DocumentEditorView.swift:178-182`, `WorkspaceSession.openInDocumentWindow`) is a second entry point.
5. **WebView content**: the custom scheme serves only image/audio/video (`LocalAssets.swift:33-39`), and the path may be any absolute path, caught by the sandbox as a backstop; `URLPolicy` allows http/https images (`HTMLRenderer.swift:481-499`), so opening untrusted Markdown **automatically loads remote images** (IP/tracking-pixel leak), with no "block remote content" switch; raw HTML is escaped (correct direction).
6. **NSSavePanel / NSDocumentController swizzling** (`FolderOpening.swift:64-111, 113-145, 160-236, 249-258`): in-process global rewriting of system/framework class methods, with hand-written `@convention(block)` signatures + `unsafeBitCast` forwarding; if AppKit/SwiftUI changes its implementation or a signature mismatches, the consequences are silently changed behavior for File→Open, "new document", etc., or even crashes; `userAskedForUntitled()` guesses "⌘N" from `NSApp.currentEvent` (`239-246`), so legitimate new-document requests from AppleScript/URL/menu validation get cancelled; `suppressDocumentOpenPanel` is a global one-shot switch (`16-35, 278-283`). This is a definite **upgrade-risk surface** and should not be expanded further.
7. **Diagnostics/logging**: `WorkspaceLog` uses `.private` for paths (`WorkspaceLog.swift:29-88`), which is correct; `XYZDiagnostics` should write unified logs + temp files only under an explicit switch (`XYZDiagnostics.swift:16-56`), where `note`'s high-frequency synchronous append (`192-204`) is debug-only by design and should not be enabled by default in production.

---

## 6. Verifiability (Against the Current CI)

Current CI (`.github/workflows/ci.yml`):

- `swift test --package-path XYZCore` (:59) → `XYZCoreTests`: `WorkspaceTests` (573 lines, covering the classifier/path/tree filtering/hidden/content search and all `WorkspaceFilePolicy` decisions: `WorkspaceTests.swift:508-573`), `EditorShellTests` (tab strip preview/pin/close/reorder/MRU/`WorkspaceWindowState.normalized`/decode compatibility: `:91-300`), `GlobalSearchTests`, `CommandPaletteTests`, etc. **Only pure functions are tested; no disk, no windows.**
- macOS Debug build (:66), iOS Simulator build (:200), both passing.
- `-XYZCheckGutter` (:77-101): offscreen rendering + real window screenshot + Vision OCR. Covers: editor line numbers (Edit/Reading, wrap on/off, light/dark), a real folder window opening a fixture and verifying the stored text, mode switching, **opening a second file sequentially** (`renderSwitchedFile`, `GutterSnapshot.swift:892-960`), Reading WebView snapshot, empty file, long-document scrolling.
- "Check original UI acceptance" (:103-122, `runAcceptanceGestures` inside `:XYZCheckGutter`, `GutterSnapshot.swift:1604-1636`): `create-file`, `create-folder`, `nested-file`, `refresh`, `collapse-header`, `dividers`, `mode-labels`, `empty-line-prefs` — 8 gesture/window checks in total; plus `SearchTypingCheck` (`GlobalSearchPanel.swift:841-895`, simulates character-by-character typing), `EscapeCrashCheck` (`GutterSnapshot.swift:2435-2470`, guards against the `NSWindowController.cancelOperation` crash), `SidebarColumnFitCheck` (`WorkspaceSidebar.swift:724-847`).
- `Launch macOS app` (:125-148) only verifies the app stays up for 8 seconds; `-XYZCheckFileMenu` (:150-199, including a Chinese-language environment) verifies that File menu items and the OpenPanel/DocumentController hooks are installed and that the Document Open panel can pick a folder; `FolderLaunchArgument` etc. are DEBUG-only.
- Window/pixel recognition limits: WebView pixels in the screenshot may not be captured (the script supplements them separately with a WebKit snapshot, `GutterSnapshot.swift:640-700`), OCR depends on language and pixels, and CI has an explicit recorded history of local screenshot failures/retries (CHANGELOG:11,16,17,38).

**Covered**: file classification/encoding and line endings/preview routing/content-search matching/tree filtering/hidden files/name uniqueness/tab model/window-state normalization/command-palette matching/line-number rendering/single-file open and switch/File menu/launch/Esc crash/sidebar width.
**Manual-only today (no automation)**:

1. Save/autosave/conflict/overwrite/missing-file behavior (`save`, `startFolderReplace`/`applyFolderChange`).
2. Handling of unsaved data on window close/quit/crash recovery (P0-3).
3. Window restore (multiple windows, multiple tabs, per-tab mode, preview/pinned) — the CI window check creates a new session and opens a single file directly; it does not go through `restoreTabs` (`GutterSnapshot.swift:573-700`).
4. External disk changes (clean-file reload, dirty-file conflict, iCloud sync) and whether banners/notices appear.
5. Replace in Folder: hidden files, opened/unopened files, concurrent modification, undo.
6. Case collisions, symlinks/hard links, Unicode normalization, read-only volumes, revoked permissions.
7. security-scoped bookmark invalidation/moved folder/restart restore.
8. Multiple windows on the same folder, dragging a tab out into a new window, duplicate opens across DocumentGroup/workspace.
9. Drag-and-drop moves, context-menu rename/move to Trash, hidden-file toggle.
10. Quick Look/PDF/video/large-image display and release.

Suggested test priorities (all doable in `XYZCore` or offscreen AppKit): first add unit tests for `WorkspaceWindowState → restore order`, for `unique` outside `FolderOpening` (case/normalization), for the path-containment helper, and for the pure Replace planning; then add a windowless integration test for `WorkspaceFileBuffer`'s save/epoch/conflict state machine (inject fake IO); finally add `restoreTabs` plus one real save/quit to the `-XYZCheckGutter` window checks.

---

## 7. Findings

> The parentheses after each id define severity: P0 = data loss/crash/security; P1 = clear defect/high risk; P2 = improvement.

### P0

**P0-1 Creating a file on a case-insensitive volume truncates an existing file**
- Evidence: `createItem` builds uniqueness from "listed names ∪ on-disk names" (`WorkspaceSession.swift:410-421`), `WorkspaceItemName.unique` compares **exact strings** (`XYZCore/WorkspaceSearch.swift:297-309`), and then `try Data().write(to: destination, options: .atomic)` runs (`WorkspaceSession.swift:429-435`). macOS's default APFS is case-insensitive: when `untitled.md` already exists on disk, `Untitled.md` is not in the set, and the `.atomic` write renames over the same directory entry.
- Local experiment (/tmp): after `printf 'IMPORTANT' > untitled.md`, `Data().write(to: "Untitled.md", options: .atomic)` → `untitled.md` becomes 0 bytes (the name stays lowercase); under the same behavior, `.atomic` also overwrites any same-name file that appears between "list directory" and "write".
- Impact: New File / context-menu New File silently empties the user's file (same for iCloud sync or another process creating the file concurrently); this is data loss.
- Recommendation: have `createItem` use `.withoutOverwriting` (or `O_CREAT|O_EXCL`) and handle the already-exists error; make uniqueness follow the volume's case/normalization semantics (probe with `FileManager`'s `isCaseSensitiveVolume`, or just try to create and retry); provide a testable `uniqueName(preferred:existing:caseInsensitive:)` in `XYZCore` with unit tests (including `Note.md`/`note.md` and NFC/NFD).

**P0-2 Restart tab restore is defeated by the "global open serial number" and overwrites the saved tab list with an empty/single tab**
- Evidence: `openFile` does `openSerial += 1` every time and requires `self.openSerial == serial` when the async read completes (`WorkspaceSession.swift:539-563`); `restoreTabs` calls `openRestored → openFile` for each tab inside the same synchronous loop (`727-747, 749-761`); all Tasks can only run after `restoreTabs` returns, so only the **last** request can install. Immediately afterwards, `WorkspaceWindowController.open(...)` calls `persistOpenWindows()` right after `restoreTabs` (`WorkspaceWindowController.swift:245-254`); at that moment `tabStrip` is still empty, `windowState()` (`717-724`) writes empty tabs, and `xyz.workspace.windows` in `UserDefaults` is overwritten (`461-468`, `WorkspaceFileAccess.swift:326-332`).
- Impact: on every launch a window's multiple tabs shrink to only the last one (or even zero), and the original tab state is destroyed — `CHANGELOG.md:261` "next launch restores each window, its folder, and its tabs" no longer holds. This is state-data loss; introduced by `d5c4f25` ("Publish a file's tab only when its text is ready"), and `restoreTabs` has no integration test.
- Recommendation: change `openSerial` from "global latest" to per-path (requests for the same path compete) plus an explicit "user-initiated open" cancellation policy; make `restoreTabs` an async/await serial restore (or give `openRestored` a dedicated install path not limited by serial); allow `persistOpenWindows` to overwrite only after restore completes (or after `restoreTabs` presents each tab); add a `WorkspaceWindowState → restore` regression test (a pure core function + one offscreen AppKit test).

**P0-3 Window close/quit does not guarantee unsaved edits reach disk, and failures have no blocking prompt**
- Evidence: `windowWillClose` calls `session.shutdown()` directly (`WorkspaceWindowController.swift:129-137`); `applicationShouldTerminate` always returns `.terminateNow` (`:652-657`), and `prepareForQuit` performs a single `session.shutdown()` (`:445-451`); `shutdown` calls `flush()` on every buffer (`WorkspaceSession.swift:211-223`), `flush` calls `save(force: false)` only once (`:1767-1770`), the `catch` in `save` only sets `status` (`:1929-1933`), and the conflict branch only calls `publishConflict` (`:1925-1927`) → `offerExternalChange` in turn requires `buffer === self.buffer` (`:961-963`); conflicts, encoding errors, and IO errors — for background tabs or the current tab — never block closing.
- Impact: when multiple tabs hold unsaved edits, closing the window/⌘Q can silently lose them (especially when the file was deleted/modified externally, iCloud is offline, or the volume is read-only); the `trash` case likewise loses edits (`:479-489` force-closes before trashing, and the async flush to the deleted path fails).
- Recommendation: add a `.terminateCancel` path to `windowShouldClose`/`applicationShouldTerminate`: first try to flush all buffers, and if any `isDirty || isMissing || status != nil` remains unresolved, show Save/Discard/Cancel; make `flush()` return a success/failure result; flush synchronously before `trash` and report failures; do not return `.terminateNow` unconditionally at quit.

### P1

**P1-1 `WorkspaceFileBuffer`'s `@Published` has no subscribers, so the UI for external changes/save failures/missing files may stay stale indefinitely**
- Evidence: the buffer declares `@Published kind/reloadToken/conflictText/isMissing/status` (`WorkspaceSession.swift:1636-1640`), yet the whole repository has no `@ObservedObject var buffer` / `.onReceive(buffer...)` / Combine `sink` (grep finds only `@ObservedObject session` in `WorkspaceSession/WorkspaceView`); views read `session.buffer?.text/editorToken/status` (`WorkspaceView.swift:1439-1448, 1590-1617, 1628-1653`). `onEditorState` only touches `tabStrip` when dirty changes (`WorkspaceSession.swift:947-952`, `EditorTabs.swift:118-125`). The clean-file external-modification path `noteExternalChange → apply` (`1782-1841, 1867-1879`) does not trigger a session publication, and `save` failures do not either (`1929-1933`).
- Impact: the editor/Reading may keep showing stale text ("clean file reloads quietly" does not hold), the save-failure banner never appears, and the user believes the save succeeded; combined with P0-3 this amplifies data-loss risk.
- Recommendation: have `WorkspaceSession` subscribe to each buffer's `objectWillChange` (`sink` into the session's `objectWillChange.send()`, minding cycles), or pass the buffer into `WorkspaceDetail` as an `@ObservedObject`; add UI tests for changes to `status/conflictText/isMissing/reloadToken`.

**P1-2 The save path does `NSFileCoordinator` + full-file read + full-file write synchronously on the main thread**
- Evidence: `save`, inside the `@MainActor WorkspaceFileBuffer`, calls `WorkspaceFileCoordination.updateText` synchronously (`WorkspaceSession.swift:1890-1934`), which inside the `NSFileCoordinator` block does `Data(contentsOf:)` full-file decode, then `TextBytes.encode` + `bytes.write(.atomic)` (`WorkspaceFileAccess.swift:112-150`, disk write `:139-146`); the read path by contrast is `readForEditing`'s `Task.detached` (`WorkspaceSession.swift:1564-1610`). The debounce is only 500 ms (`:1881-1888`), so during continuous typing the main thread does a full 0→5 MB read and write every 0.5 s; each save also triggers its own file monitor and reads the whole file once more (`watchFile` `:980-993` → `noteExternalChange` `:1802-1840`).
- Impact: dropped frames or even a beachball when typing on large files/iCloud/network volumes/external drives; this is the layer's most direct performance risk.
- Recommendation: move "read-disk validate — encode — write" to a dedicated serial actor (or a background `DispatchQueue`) and return to the MainActor to update the buffer afterward; `TextBytes.encode` and the "last saved text snapshot" can be prepared on the main thread; report save failures/conflicts back on the main thread uniformly. Also short-circuit monitor events caused by our own writes via mtime/content comparison (`observationEpoch` already handles loss, but a full-file read still happens).

**P1-3 Window restore does not save each tab's Reading/Editing mode**
- Evidence: `windowState()` hardcodes `mode: .reading` for every tab (`WorkspaceSession.swift:717-724`); `openRestored` fixes `mode: .reading` (`:749-761`); `restoreTabs` restores only preview/pinned/active and never calls `setMode` (`:727-747`); `WorkspaceTabState.mode` is only verified in `normalized`/encode-decode tests (`EditorTabs.swift:254-327`, `EditorShellTests.swift:234, 256`).
- Impact: tabs the user left in Editing all come back in Reading after restart (Markdown moves from source to rendered page, other text becomes read-only), conflicting with the model design that "each tab keeps its own mode".
- Recommendation: use `$0.mode` in `windowState`; pass `tab.mode` in `openRestored` and call `strip.setMode` in `restoreTabs`; add a "state→mode fidelity" test to core and an integration test to restore.

**P1-4 Replace in Folder modifies hidden files and does not re-validate unopened files on disk (TOCTOU coverage)**
- Evidence: the file list for content search filters only `!isDirectory && !shouldSkipRelativePath` (`WorkspaceSession.swift:1148-1150`); the Replace plan does the same (`:1241-1243`); while `searchPanelContents` filters by `showsHiddenFiles` (`:1183, 1189-1194`). The plan reads contents in the background (`:1416-1478`), and after user confirmation `applyFolderChange` calls `writeEncodedText/writeData` directly on unopened files (`:1326-1369`) without re-reading disk; only the "currently open buffer" is checked via `buffer.text == expected` (`:1313-1315`). `undoManager`'s undo also writes the old bytes back directly (`:1311-1324`).
- Impact: (1) with "show hidden files" off, Replace All silently rewrites invisible files such as `.env` and `.obsidian/…`; (2) files modified externally between plan and execution get overwritten by the stale plan (violating `WorkspaceFilePolicy`'s "no silent overwrite" principle), and undo may also overwrite newer content.
- Recommendation: use one shared "visibility + skipped directories" function for file lists and content search (put it in `XYZCore` with unit tests); carry each file's `expectedData`/mtime in the Replace plan, compare and skip conflicts inside `NSFileCoordinator` at execution time (or abort the whole batch), and let undo restore only files that "still equal the replacement result"; notify separately about hidden files.

**P1-5 Saving uses atomic replacement, which breaks symlinks and hard links**
- Evidence: directory loading treats a symlink as an ordinary file (`WorkspaceDirectoryLoader.swift:10-27`, `isDirectory = isDirectory && !isLink`; index scanning does the same, `WorkspaceSession.swift:1957-1958`); saving goes through `bytes.write(to:, options: .atomic)` (`WorkspaceFileAccess.swift:139-146`, `writeData` likewise `:170-186`).
- Local experiment (/tmp): with `link.md -> target.md`, after `Data.write(.atomic)` `link.md` becomes a regular file (3 bytes, no longer a symlink) and `target.md` is unchanged; hard-linked `hard.md` and `hard2.md` diverge after an atomic write (`hard2.md` still has the old content).
- Impact: the user edits "the note the link points to", but saving actually replaces the link with a new file and leaves the real target unupdated (the data looks "not saved"); the other end of a hard link/shared file sees stale content; Finder tags/xattrs and other metadata may also be lost under replace semantics.
- Recommendation: detect links with `.isSymbolicLinkKey` before opening/saving and resolve the target (or mark them read-only/warn in the UI); switch saving to `.forReplacing` coordination + writing back to the resolved target URL; if atomic replacement is mandatory, at least preserve link semantics (write the target for symlinks, write in place for hard links).

**P1-6 Cancellation is ineffective on `Task.detached`: indexing, content search, and Replace planning pile up, and every directory expansion rescans the whole root**
- Evidence: `scheduleIndex` cancels the old `indexTask` but still does `await Task.detached { WorkspaceIndexScan.entries(at: root) }.value` (`WorkspaceSession.swift:1110-1127`); the `Task.isCancelled` inside `WorkspaceIndexScan` (`:1953`) is usually always false in a detached task; `searchContents`/`planFolderReplace` likewise run their entire bodies in `Task.detached` (`:1386-1413, 1426-1477`), where the `Task.isCancelled` checks (`:1389, 1430`) are ineffective. `load(parent:)` calls `scheduleIndex()` unconditionally after success (`:1523-1534`), and `refreshFileTree` (`:268-275`) plus every expansion call `load`.
- Impact: on large repositories, every expand/refresh recursively enumerates the whole root (cap 20,000) and stats every URL; rapid typing in content search starts multiple full-directory scans and the old ones never stop, driving CPU/disk/power use and potentially starving the main thread (index results are `@Published` and trigger view recomputation, see P2-6).
- Recommendation: turn scanning into cancellable structured concurrency (`withTaskGroup` + `checkCancellation`, or pass an explicit `CancellationHandle` into `Task.detached`); update index results incrementally per "dirty directory" instead of rescanning the whole root; generation guards already protect result landing, but the work itself must also be stoppable.

**P1-7 After a folder is selected in the sidebar, the Header's New File/New Folder still lands "next to the open file"**
- Evidence: `creationParent()` uses `selectedPath ?? buffer?.relativePath` (`WorkspaceSession.swift:261-265`); but when NSOutlineView selects a directory, `outlineViewSelectionDidChange` only handles files (`WorkspaceSidebar.swift:289-299`), and `selectedPath` is written only in `present`/`selectTab`/`revealCrumb`/`revealActiveFile` (`WorkspaceSession.swift:576, 837, 860, 816`). The Header's `New File/New Folder` go through `session.createItem(..., session.creationParent())` (`WorkspaceSidebar.swift:170-185`), so the folder just clicked is not the parent directory; the "selected directory" branch of `newItem` (`WorkspaceSession.swift:580-590`) is nearly dead code. CI's `acceptCreateFile` (`GutterSnapshot.swift:1638-1675`) only tests the case where no folder is selected.
- Impact: files are created in the wrong directory (the user thinks they are in the selected folder), a clear functional defect; it also shows that "the selection" has two sources of truth (`selectedPath` vs `buffer`).
- Recommendation: when a directory is selected, also update a `sidebarSelection` (separate from `buffer`), and have `creationParent` read only that; or have the Header explicitly use the node at `outline.selectedRow`; add UI acceptance (select a subfolder first, then click New File).

**P1-8 Beyond tab restore/persistence, `openFile` drops tabs on "rapid consecutive opens"**
- Evidence: `openSerial` is global (`WorkspaceSession.swift:126-127, 539-563`); when the user quickly clicks A then B (or hits Enter repeatedly in ⌘P), A's read completes after B was started, so A is discarded and only B remains as a tab. The design comment only guarantees "older reads cannot publish a tab"; it has no semantics for "every file the user clicked is kept".
- Impact: tabs are lost during multi-select/rapid navigation, and A is not recorded in the ⌘⇧T history either; same root cause as P0-2, so fix them together.
- Recommendation: keep per-path request competition; allow out-of-order installs for "user-initiated opens" (newest becomes active, the rest install in background), or use a serial open queue that presents each item as soon as it completes.

### P2

**P2-1 System-class swizzling is the biggest upgrade fragility (the Lead's clue b)**
- Evidence: `FolderOpening.hookOpenPanelPresentation` applies `method_setImplementation` to `NSSavePanel`'s `beginWithCompletionHandler:`/`beginSheetModalForWindow:completionHandler:`/`runModal` (`FolderOpening.swift:64-111`); `hookOpenDocument` targets `PlatformDocumentController`'s `openDocumentWithContentsOfURL:display:completionHandler:` (`:113-145`); `hookAutomaticUntitled` targets `openUntitledDocumentAndDisplay:error:`, `reopenDocumentForURL:…`, `makeUntitledDocumentOfType:error:`, and `newDocument:` (`:160-236`); every forward is a hand-written `@convention(block)` + `unsafeBitCast` (`:66-108, 118-138, 164-234, 249-258`).
- Impact: a change in AppKit/SwiftUI implementation or signature is enough to cause silent File→Open misbehavior, cancelled new-document requests, panels that cannot be cancelled, etc.; `userAskedForUntitled()` depends on `NSApp.currentEvent` (`:239-246`), so legitimate non-keyboard new-document requests are killed by mistake; when swizzling fails, only `-XYZCheckFileMenu` detects it (CI :150-199).
- Recommendation: isolate the hooks into a standalone module with version probing/launch self-checks (already present); move paths that do not need swizzling back to `Commands`/`NSOpenSavePanelDelegate`; replace the `openUntitledDocument` interception with `applicationShouldOpenUntitledFile` or an `NSDocumentController` subclass (the project docs already explain the DocumentGroup limitation, but DocumentGroup alternatives can be evaluated); at minimum encapsulate the block signatures in one place and add assertions and failure logging.

**P2-2 Path containment is duplicated 4 times, with no core helper/unit tests, and symlink/case/normalization are unhandled**
- Evidence: `WorkspaceSession.openLinked` (`:359-368`), `CLIOpen.openOne` (`FolderOpening.swift:534-540`), sidebar drag-and-drop (`WorkspaceSidebar.swift:679-689`), and index scanning (`WorkspaceSession.swift:1950-1964`) each do their own `standardizedFileURL.path + root + "/"` prefix check; `WorkspaceSession.url(for:)` (`:1052-1056`) validates neither `..` nor absolute paths. When root is `/`, the prefix becomes `//` and indexing discards everything (`:1950-1964`).
- Impact: symlinked or differently-cased paths bypass or are misjudged; tampered/corrupt persisted tab paths escape the root; the four sites may behave inconsistently (trailing slash present or not, `/private` vs `/var`).
- Recommendation: add `WorkspacePathContainment` to `XYZCore` (`resolve(relativeTo:)`, `contains(root:url:)`, `normalizedRelativePath`) with explicit tests for `..`, absolute paths, case, NFC/NFD, and the symlink option; switch all 4 sites to it; validate restored tab paths before `url(for:)`.

**P2-3 Untrusted Markdown automatically loads remote images**
- Evidence: `URLPolicy.imageSchemes = ["http","https"]` (`HTMLRenderer.swift:481-489`); the WKWebView configuration allows JavaScript/network (`MarkdownWebView.swift:434-447`), and the entitlement includes `network.client`; Reading uses the `xyz-asset` base directly plus remote images.
- Impact: opening a `.md` downloaded from the web automatically requests remote images (IP, User-Agent, tracking pixels), with no "block remote content" option.
- Recommendation: add "block remote content / load only on demand" to Reading settings; or, in `URLPolicy`, strip http(s) images by default for untrusted files and open them in the default browser when clicked.

**P2-4 Main-thread decode and release for image/QuickLook/video surfaces**
- Evidence: `ImageSurface` calls `NSImage(contentsOf:)` in `makeNSView/updateNSView` and does a full-image `image.draw` (`FileSurfaces.swift:139-168, 180-205`); `QuickLookHost` has no `close` (`:371-416`); `JSONReadingView`/`CSVReadingView` re-run `JSONText.pretty`/`CSVText.parse` on every body (`:43-44, 83-84`), so large files are parsed repeatedly.
- Impact: main-thread stutter and memory spikes when opening large images/large CSVs; the QuickLook preview process may stay resident for a long time.
- Recommendation: downsample images in the background via `CGImageSourceCreateThumbnailAtIndex`; cache Reading's JSON/CSV parse results in `@State`/`task`; call `preview?.close()` in `QuickLookHost`'s `dismantleNSView`; add `dismantle` to the media surface (pause already exists).

**P2-5 Giant files/type concentration and extraction boundaries**
- Evidence and extraction list in section 4 (`WorkspaceSession.swift:14-1611` — one type with 110 methods; `WorkspaceView.swift:24-549` — 730 lines of NSSplitView stuffed into one file; `WorkspaceSidebar.swift` — 18 types/1839 lines; `EditorCommands.swift:159-265, 439-498` — giant shortcut/command switch; `FolderOpening.swift:64-497` — swizzling + menu surgery).
- Impact: unit tests cannot cover session behavior; changes easily regress each other (P0-2 was introduced by a local change to `openFile`).
- Recommendation: split files along the 8 boundaries in section 4; make commands/shortcuts table-driven; move pure logic such as `restore`/save sequence/paths/Replace planning down into `XYZCore`.

**P2-6 Main-thread O(n) computation and high-frequency `@Published` triggering whole-SwiftUI-tree recomputation**
- Evidence: `session.searchTree` re-filters on every access (`WorkspaceSession.swift:303-308` → `WorkspaceTreeQuery.filter`, up to 20k entries), while `WorkspaceSidebar.Snapshot(session)` (`WorkspaceSidebar.swift:1294-1345`) and `rebuild` (`:494-522`) call it on every update; `caret`/`viewportLine` are `@Published` (`WorkspaceSession.swift:93-95`), so every frame of editor scrolling/selection change triggers recomputation of `WorkspaceView`/`WorkspaceDetail`/`OutlineSidebar` and `updateNSView`.
- Impact: dropped frames in the sidebar/status bar/scrolling with large directories + large files.
- Recommendation: cache `searchTree` (invalidate by version number of query/indexedEntries/hidden); compare snapshots via a lightweight hash; debounce `caret/viewport` or put them in a separate Observable object subscribed to only by the status bar/outline.

**P2-7 Bookmark staleness is never refreshed, and panel paths are inconsistent with the `capture` convention**
- Evidence: `WorkspaceBookmarks.resolve`'s `isStale` is discarded (`WorkspaceFileAccess.swift:255-270`); `WorkspaceWindowController.open(bookmark:)` (`:200-209`) and `open(url:...)` (`:222-232`) only log `bookmarkRestored(stale:)` and never write back; panel paths call `WorkspaceBookmarks.make` directly (`WorkspaceWindowController.swift:54-60, 185-193`), while CLI/drag-and-drop use `capture` (`FolderOpening.swift:574`, `WorkspaceWindowController.swift:222`).
- Impact: after a folder is moved/renamed, restore may fail permanently with no fallback (`reopenLastFolder` only takes the first window/recent); bookmarks created by panels may fail on special paths (returning nil means that window is not persisted).
- Recommendation: when resolution finds `stale`, immediately `make` a new bookmark and write it back via `WorkspaceLibrary.syncWindows`; go through `capture` uniformly; on restore failure, degrade to "cancel that window and prompt for folder selection".

**P2-8 The same file can be open under both the workspace and DocumentGroup models**
- Evidence: `claimExistingFile` deduplicates only among `WorkspaceWindowController.controllers` (`WorkspaceWindowController.swift:95-98, 259-272`); `openInDocumentWindow` opens via `NSDocumentController` (`WorkspaceSession.swift:1021-1027`), and both `WorkspaceCommandBridge.paletteOpen(newWindow:)` and `DocumentEditorView`'s Reading link handler (`DocumentEditorView.swift:178-182`, `WorkspaceView.swift:1731-1738`) go through `NSDocumentController`.
- Impact: two edit models for the same path each autosave, with only disk-level `WorkspaceFilePolicy` conflict handling as a backstop; the user sees two different contents overwriting each other.
- Recommendation: make the DocumentGroup side claim through the same process-wide "file ownership table" (or forbid opening DocumentGroup windows from the workspace); at minimum align the checks/notices.

**P2-9 Mutating `@Published` inside `WorkspaceSidebar.updateNSView` (SwiftUI anti-pattern)**
- Evidence: `reloadIfNeeded` executes `session.actionMessage = nil` in the `updateNSView` call chain (`WorkspaceSidebar.swift:70-74, 113-135`); `WorkspaceChromeView.layout()` writes back SwiftUI `@State` via `onTitlebarInset` (`WorkspaceView.swift:1068-1092`), and `layout()` is an AppKit layout phase.
- Impact: possible undefined behavior ("Modifying state during view update / Publishing changes from within view updates"); changing state during layout for the titlebar inset may trigger extra layout rounds.
- Recommendation: move consumption of `actionMessage` to `MainActor.async`/`.onReceive`; coalesce `onTitlebarInset` with `DispatchQueue.main.async`; or pass state changes through explicit events instead of view update.

**P2-10 High-frequency diagnostics synchronously writing files**
- Evidence: `XYZDiagnostics.note` opens/writes a temp file on every `append` call (`XYZDiagnostics.swift:58-62, 192-204`), and `viewportLine`/sidebar fit/mode switches/window passes all call it (`WorkspaceSession.swift:154-159`, `WorkspaceSidebar.swift:1028-1031`, etc.).
- Impact: with diagnostics enabled, high-frequency synchronous IO during scrolling/layout slows the main thread (debug-only, but easy to turn on by mistake).
- Recommendation: move diagnostic writes to a background serial queue/buffered batch writes; downgrade hot paths (viewport) to os_log or sampling.

---

## Appendix: Verified Line-Number Index (for Review)

- Open serial/restore: `WorkspaceSession.swift:126-127, 539-563, 717-761`; `WorkspaceWindowController.swift:245-254, 461-468, 428-443`; `EditorShellTests.swift:256-284`.
- Create/replace: `WorkspaceSession.swift:410-455, 1241-1258, 1306-1375, 1416-1478`; `XYZCore/WorkspaceSearch.swift:281-318`.
- Buffer publish/save: `WorkspaceSession.swift:1632-1935` (`1636-1640, 1651-1658, 1767-1770, 1782-1841, 1867-1879, 1881-1934`); `WorkspaceFileAccess.swift:99-154`.
- Monitoring: `WorkspaceFileAccess.swift:8-74`; `WorkspaceSession.swift:980-993, 1067-1073, 1502-1509`.
- Index/search cancellation: `WorkspaceSession.swift:1110-1167, 1377-1414, 1938-1976`.
- Paths/security: `WorkspaceSession.swift:359-368, 1052-1056, 1950-1964`; `WorkspaceDirectoryLoader.swift:10-27`; `LocalAssets.swift:26-39`; `HTMLRenderer.swift:481-499`; `WorkspaceSearch.swift:339-347`; `XYZ/XYZ-macOS.entitlements`.
- Lifecycle: `WorkspaceWindowController.swift:8-34, 106-115, 129-137, 445-451, 472-498, 652-657`; `WorkspaceSession.swift:186-223`; `docs/architecture.md:7-9`.
- Swizzling: `FolderOpening.swift:64-111, 113-145, 160-236, 239-246, 249-258, 349-497, 499-527`.
- CI: `.github/workflows/ci.yml:59, 66, 77-101, 103-122, 125-148, 150-199, 200-208`; `GutterSnapshot.swift:533-700, 892-960, 1604-1636, 2435-2470`; `WorkspaceSidebar.swift:724-847`; `GlobalSearchPanel.swift:841-895`.
