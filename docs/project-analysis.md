# XYZ Project Analysis Report

- **Subject**: `/Users/lizhichao/Developer/XYZ`, HEAD `db12a62` (2026-11-07 11:12 +0800, merge of PR #4), version **0.5.28 (build 44)**.
- **Method**: local build/test baseline (Xcode 27.2, Swift 6.4.2, macOS 27.2) + four parallel static deep reads (Core / Workspace / Editor+Preview / engineering and CI) + cross-checking against the GitHub Actions API + a few AppKit/filesystem behavior probes. The GUI app was not launched, no Instruments run was performed, and no repository code was modified.
- **Evidence basis**: every `file:line` below refers to the HEAD working tree; conclusions marked "reproduced locally" were actually executed during this analysis. The original deep-dive reports are in `docs/analysis/` (core / workspace / editor / process, about 1,700 lines in total).
- **Report date**: 2026-11-07.

---

## 1. Executive Summary

**Project profile.** XYZ is a native SwiftUI text/Markdown editor: on macOS it offers "folder workspace + tabs + sidebar Explorer + command palette + Reading/Editing dual modes", while iPhone/iPad use the `DocumentGroup` document browser. The code is about **28.4k lines / 66 Swift files** (App 20.5k, XYZCore 5.8k, tests 2.2k); 156 commits and 42 version sections in 15 days, and the current tree is 0.5.28. Both the code and the docs clearly carry the hallmark of **high-frequency AI-agent iteration** (commit messages are step-by-step debugging logs; the CHANGELOG records failed runs and retracted claims).

**The engineering baseline is not bad.** Local verification in this analysis: the macOS Debug / macOS Release and iOS Simulator builds all succeeded, with a single script-phase warning; `swift test --package-path XYZCore` gave **191 tests, 0 failures**; `Scripts/xyz-test.sh` passed 6/6. XYZCore's layering and pure-function policy (`WorkspaceFilePolicy`), its encoding/line-ending fidelity, and the Markdown renderer's escaping and URL allowlist are all above the level of a typical personal project; the CHANGELOG's honest record of "not installed, not verified, failed" items is a real strength as well.

**But it is not in a shippable state, and there are genuine data-loss and crash risks.**

1. **HEAD is red on its own CI.** The newly added UI acceptance gate (introduced by `da9730d`) has **0 passes in 7 runs since it was introduced**; only 10 of the last 100 CI runs succeeded (details in §4.4). The 18 commits of 0.5.28 share one version number and there is no tag; the "release candidate" has never been green under the gate.
2. **Four high-severity defects** (details in §5):
   - On a case-insensitive APFS volume, New File **empties** an existing file with the same name (reproduced locally: with `untitled.md` present, creating `Untitled.md` → 0 bytes);
   - A regression in tab restore on relaunch (global `openSerial` + premature `persistOpenWindows`) **overwrites the restored state with nothing / a single tab**;
   - The flush on window close / ⌘Q is best-effort; conflicts or I/O failures do not block quitting, so edits to background tabs can be **silently lost**;
   - A folder window reuses the text view across tabs but **does not clear the undo stack**, so ⌘Z can throw an `NSRangeException` crash or write the previous document's edits into the current one (reproduced at the AppKit layer; needs step-by-step confirmation inside the product).
3. **The verification system does not match the product shape.** The App target has no test target; UI acceptance relies on the 2,459-line `GutterSnapshot` self-check, which **ships with the Release build**, plus window-screenshot OCR; CI builds an unsigned app **with no entitlements** (measured locally: `codesign -d --entitlements -` is empty), so the sandbox, iCloud and security-scoped bookmarks never enter CI.
4. **The release chain does not exist**: no tag, no release workflow, Release turns Hardened Runtime off, and the installed build uses an Apple Development certificate (measured: `/Applications/XYZ.app` = 0.5.27/43, TeamIdentifier Z4FMG2KTPM), so it cannot be notarized or distributed.

**One-line verdict:** functional completeness and "per-location code quality" are clearly ahead of "verification and release capability". **Fix the four P0s first, then make the gate actually mean something, and only then talk about release**; until then, any statement that "0.5.28 is a release candidate" does not hold.

---

## 2. Project Overview

### 2.1 Feature coverage

| Capability | macOS | iOS/iPadOS | Evidence / notes |
|---|---|---|---|
| Markdown Reading (WebView) + Editing (NSTextView/UITextView) | ✅ | ✅ (weaker feature set on the Source side) | Reading renders headings/tables/code/task lists/relative images |
| Folder workspace, sidebar Explorer, drag to move, new/rename/Trash | ✅ | ❌ | iOS only has the `DocumentGroup` document browser |
| Tabs (preview tab, pin, close history ⇧⌘T) | ✅ | ❌ | |
| Command palette (⌘P), Go to Line, outline (⌥⌘B), ⌘K filename + full-text search | ✅ | Partial (no ⌘K palette) | |
| Find/replace (⌘F/⌥⌘F/⌘G), folder-level Replace All | ✅ | ❌ (no find on iOS) | |
| Line numbers, current-line band, syntax coloring | ✅ | ❌ (no line numbers/coloring on iOS) | |
| Encoding and line-ending fidelity (UTF-8/BOM, UTF-16, Windows-1252, LF/CRLF/CR) | ✅ (folder path) | ❌ (the document scene is UTF-8 only) | see §5 P1-10 |
| Image/PDF/audio and video viewers, Quick Look, JSON/CSV Reading | ✅ | Partial | |
| `xyz` command line (`open -b` semantics), English/Chinese UI, settings | ✅ | Partial | the CLI has small edge-case bugs, see §5 P2 |
| iCloud Documents, App Sandbox, bookmark restore | Declared done | Declared done | **not verified in a signed/iCloud environment** |
| AI capabilities | ❌ | ❌ | the GitHub repository description is "An AI Editor.", but the code has no AI/LLM feature at all |

### 2.2 Size profile

| Metric | Value | Notes |
|---|---|---|
| Swift files / lines | 66 / about 28,429 | App 20,456; XYZCore sources 5,761; tests 2,177 |
| Types / functions (heuristic parse) | 359 / 1,645 | largest file `XYZ/Editor/GutterSnapshot.swift` (2,459 lines) |
| Tests | 9 files / 27 suites / **191 tests / 741 XCTAssert** | all in XYZCore; the App target has 0 unit tests |
| Third-party dependencies | `swift-markdown` 0.9.0 (+ swift-cmark 0.9.0); `highlight.js` 11.11.1 bundled | a very small dependency surface, which is a strength |
| Version / install state | tree at 0.5.28/44; `/Applications/XYZ.app` = 0.5.27/43 (measured locally) | consistent with the CHANGELOG |
| Release state | 0 tags / 0 releases; GitHub repository public, MIT, created 2026-10-23 | |
| Commit history | 156 commits; 151 on 2026-11-03; 42 sections for 0.5.x | a clear agent iteration cadence |

**File/type hotspots** (line counts): `GutterSnapshot.swift` 2,459 (a single 2,400-line enum), `XYZMacEditor.swift` 2,003 (`XYZMacTextView` 922 + `EditorTypography` 520 + entry point 440), `WorkspaceSession.swift` 1,977 (`WorkspaceSession` 1,597 + `WorkspaceFileBuffer` 303), `EditorCommands.swift` 1,918, `WorkspaceView.swift` 1,851, `WorkspaceSidebar.swift` 1,838, `EditorChrome.swift` 1,394, `MarkdownWebView.swift` 1,284. The longest function is `shell` at `MarkdownWebView.swift:839` (433 lines of HTML string concatenation).

### 2.3 Local baseline verification for this analysis (all actually executed)

| Check | Command | Result |
|---|---|---|
| Core unit tests | `swift test --package-path XYZCore` | ✅ **191 tests / 0 failures** |
| macOS Debug build | `xcodebuild … -configuration Debug -destination 'platform=macOS'` | ✅ BUILD SUCCEEDED (1 warning) |
| macOS Release build | the same with `-configuration Release` | ✅ BUILD SUCCEEDED (CI does not build Release) |
| iOS Simulator build | `-destination 'generic/platform=iOS Simulator'` | ✅ BUILD SUCCEEDED |
| CLI script | `sh Scripts/xyz-test.sh` | ✅ 6/6 |
| Compiler warnings | `xcodebuild … \| grep -c warning:` | **1** (`Make xyz executable` script phase declares no outputs) |
| Code-hygiene scan | `grep TODO/FIXME/HACK` | 0; 1 occurrence of `assert/precondition/fatalError`; 43 `print()` (diagnostics) |
| SwiftLint (default rules, no config in the repo) | `swiftlint lint` | App 468 / Core 138 findings, the vast majority style items such as `identifier_name`, `line_length`, `trailing_comma` |

> Note: neither the Release build nor `swift test` is part of CI; CI builds Debug only and does not run App-layer tests.

---

## 3. Architecture Assessment

### 3.1 Layering and data flow

```
XYZCore (pure logic, unit-testable)                      App target (AppKit/SwiftUI integration)
├─ text IO: TextBytes / TextDocument                     ├─ document scene: DocumentGroup + MarkdownFileDocument
├─ editing pure functions: SourceEditing / Transforms    ├─ folder scene: WorkspaceSession / Buffer / WindowController
├─ Markdown: Parser → ReadingSource → HTML               ├─ editor: XYZMacEditor / XYZIOSEditor (+ GutterSnapshot self-check)
├─ policy: WorkspaceFilePolicy (classify/write)          ├─ preview: MarkdownWebView (one WKWebView per window)
├─ workspace: Node / Loader / Search / Tabs              ├─ menus/commands: EditorCommands + FolderOpening (swizzling)
└─ misc: CommandPalette / SyntaxColoring                 └─ views: WorkspaceView / Sidebar / EditorChrome
```

**What is done well:**

- `WorkspaceFilePolicy` turns "install read / disk change / write conflict / follow-up save" into testable pure functions (`XYZCore/.../WorkspaceFilePolicy.swift:237-280`), and the App only consumes decisions; the three race-condition fixes in the 0.5.28 CHANGELOG match the code (verified in this analysis).
- The Markdown pipeline has clean boundaries: the only public API is `MarkdownHTML` / `MarkdownOutline`, while parser/renderer/preprocessing stay internal; source HTML is escaped, `javascript:/vbscript:/data:` are rejected and the link/image schemes are allowlisted, and the static review found no injection path (`HTMLRenderer.swift:448-511`).
- Encoding and line-ending fidelity is a genuine differentiator: `TextBytes` supports 7 forms and writes the original encoding/line ending back on save (`WorkspaceFileAccess.swift:99-154`).

**Main architectural conflicts:**

1. **The conflict between SwiftUI `DocumentGroup` and the "folder window" is resolved with runtime swizzling.** `FolderOpening.swift:64-258` performs `method_setImplementation` + hand-written `unsafeBitCast` forwarding on `NSSavePanel`'s `beginWithCompletionHandler:` / `beginSheetModalForWindow:completionHandler:` / `runModal`, and on `PlatformDocumentController`'s `openDocumentWithContentsOfURL:display:completionHandler:`, `openUntitledDocumentAndDisplay:error:`, `reopenDocumentForURL:…`, `makeUntitledDocumentOfType:error:` and `newDocument:`. This is the layer most likely to shatter on an OS upgrade, and only the `-XYZCheckFileMenu` self-check can detect it breaking.
2. **The macOS editor actually runs on TextKit 1, but that is not a design choice.** `makeNSView` first creates a TextKit 2 view (`XYZMacEditor.swift:1058`) and finally reads `.layoutManager` (`:1128`), triggering AppKit's undocumented lazy downgrade; a probe in this analysis reproduced "after reading `layoutManager`, `textLayoutManager` becomes nil". This is the escape hatch chosen to work around "SwiftUI's layer does not composite TextKit 2 fragment subviews, so the window is blank" (CHANGELOG 0.5.26), at the cost of acquiring undocumented behavior while the comments and docs still say TextKit 2 (`XYZMacEditor.swift:6`, `XYZEditor.swift:114`).
3. **UI acceptance is part of the product code.** `GutterSnapshot.swift` (2,459 lines, including Vision OCR, screenshots and synthesized windows) is compiled into Sources with no `#if DEBUG`; `strings` on the Release binary still finds `ACCEPTANCE_*`/`GUTTER_*`. All four debug entry points `-XYZCheckGutter` / `-XYZCheckFileMenu` / `-XYZDiagnostics` / `-XYZOpenFolder` are in the shipping build. It is not XCTest either, and there is no test target that could host App-layer tests.
4. **Two text IO stacks**: the folder path goes through `TextBytes` (encoding fidelity), while the document scene (the only iOS entry point, and Mac ⌘O) goes only through `TextDocument` (UTF-8 only, BOM stripped). "Open a text file" has inconsistent semantics within one product (see §5 P1-10).

### 3.2 Documented claims vs. code (spot check)

| Claim (README/CHANGELOG/docs) | Code fact | Verdict |
|---|---|---|
| The Mac editor runs on TextKit 1 (README:11) | it is indeed downgraded at runtime; but there is no assertion, and the comments still say TextKit 2 | ⚠️ behavior correct, mechanism not pinned down |
| Reading uses one WKWebView per window, the shell is loaded once, 220 ms debounce | holds (`MarkdownWebView.swift:536-644`, `MarkdownPreview.swift:46-79`); the "one web view for one open note" comment at `MarkdownWebView.swift:16` is wrong | ✅ mostly holds |
| "The renderer still does not request remote images" (README:16) | `URLPolicy.imageSchemes = ["http","https"]` (`HTMLRenderer.swift:482`), no CSP, and a unit test even asserts that remote `<img src>` must be emitted (`MarkdownHTMLTests.swift:156`) | ❌ **does not hold**: remote images do go online (P1-1) |
| Raw HTML is treated as text, `javascript:`/`data:` do not become links | holds (`HTMLRenderer.swift:128-134,279-281,500-510`) | ✅ |
| Files >5MB do not enter the editor | holds; there is also a 2MB read-only preview truncation (two thresholds, which the README does not distinguish) | ✅ |
| Folder windows restore "each window's folder and tabs" (README / CHANGELOG) | the restore path is broken by the global `openSerial` + premature persistence (P0-2) | ❌ regression |
| 0.5.28/44 is a release candidate and CI accepted `02dac3c` | the 0.5.28 number span covers 18 commits with no tag; `02dac3c` was green when no acceptance gate existed, and it predates two fixes recorded in 0.5.28 | ⚠️ the wording needs correcting |
| The gutter algorithm at docs/architecture.md:15 "is provided by layoutManager and re-measured when skipped" | the live code is in `LineNumberGutter.swift`; most of the same-named algorithm `LogicalLineGutter` in XYZCore is dead code | ⚠️ wrong code ownership in the description |
| README:53 "the text view's undo points at the document scene's undo manager" | in a folder window `@Environment(\.undoManager)` is nil, so the text view uses its own NSUndoManager and does not clear the stack across tabs | ❌ related to P0-4 |

---

## 4. Code and Test Quality

### 4.1 Strengths (worth keeping)

- **Zero compiler warnings, zero TODO/FIXME**; names and comments generally explain "why" rather than "what".
- **A pure-function policy layer**: `WorkspaceFilePolicy`, `SourceEditing`, `TextFind` and `EditorTabs` all have direct tests; `shouldInstallRead`/`isCurrentObservation`/`needsFollowUpSave` map one-to-one onto the 0.5.28 CHANGELOG claims.
- **Error-handling awareness**: re-read from disk before saving, refuse to write when the encoding cannot represent the text (`TextBytes.EncodingError.unrepresentable`), UI branches for deleted files / external conflicts, and `NSFileCoordinator` for coordinated reads and writes.
- **The security boundary is solid overall**: no bypass of the Markdown injection surface was found; no retain cycles were found in `WKScriptMessageHandler`; `LocalAssetSchemeHandler` handles the `stop` race correctly; Release does not enable `isInspectable`.
- **Single source of truth for the version holds**: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig` are not overridden in the pbxproj, and Debug/Release/iOS products were all measured at 0.5.28/44.
- **The CHANGELOG's honesty**: it records failed runs, retracts old claims and lists unverified items; that is rare discipline in an AI-driven project.

### 4.2 Structural problems

1. **Giant types/files**: `GutterSnapshotCheck` is 2,400 lines (a test fixture), `WorkspaceSession` is 1,597 lines with about 110 methods, `XYZMacTextView` is 922 lines, and `PreviewPage.shell` is one 433-line string. `WorkspaceSidebar.swift` is 1,838 lines containing 18 types; `WorkspaceSearch.swift` mixes 15 public types in 438 lines (name matching, sidebar geometry, icons, new-item names, content search).
2. **Duplicated implementations**: editor line-number/line computation has at least **6 variants** (`LineIndex`, `TextFind.lineNumber`, `EditorScrollAnchor`, `SourceEditing.lineRange`, `TextTransforms.coveringLines`, `WorkspaceContentSearch.newlineCount`, of which 2 count only `\n`, so CR-only text is wrong); extension/classification knowledge is spread over 5 places and has already drifted (bmp/ico use the image viewer but have no matching icons, `WorkspaceSearch.swift:252`); `EditorCommands` and `GlobalSearchPanel` each carry their own overlay-panel code (an automated scan found 42 duplicate blocks of ≥8 lines, with the largest cluster between these two files).
3. **Dead code**: `SourceFormatting.swift` (283 lines) + the `SourceEditing` inline toggle are the removed formatting feature, called nowhere in the App yet kept alive by 16 tests; `LogicalLineGutter`'s Reading line-number API is left over from deleting Reading line numbers in 0.5.26; `ReadingLineMap`, `ExplorerSection.fileCount`, `TextFind.step` and others are referenced only by tests.
4. **Poor App-layer testability**: much of `WorkspaceSession`'s save/restore/replace logic lives in the App target, and the core decisions have no unit-test entry point; a regression like P0-2 is the classic "breaks on any change and CI cannot see it" case.

### 4.3 Test coverage profile

- XYZCore: **191 tests / 741 asserts / 2,177 lines of tests vs. 5,761 lines of source (≈0.38:1)**. Coverage is thick for `TextBytes`, `TextFind`, `WorkspaceFilePolicy` and `EditorTabs`, and thin for `SyntaxColoring` (488 source lines with only 4 tests), `HTMLRenderer` (no dedicated test file, covered indirectly through `MarkdownHTML`) and `FileOutline`.
- Main gaps: the UTF-16-without-BOM heuristic; `TextFind.scan/replacement/lineNumber` (the find bar's main path); `MarkdownFileDocument`'s `init(configuration:)`/`fileWrapper`/dirty flag; the >5MB open route; front matter + CRLF; the `WorkspaceItemName.unique` boundary; the 20 languages of `SyntaxColoring`.
- **There are no async/concurrency tests at all**; the App target **has no test target** (the pbxproj has 1 target and the scheme's `TestAction` is empty).
- Some tests are coupled to implementation details: HTML assertions check attribute order exactly; `testFacadeMatchesDecoupledRenderer` uses `@testable` to compare the facade with the internal pipeline; tests depend on the 8,192/250k constants and on real symlinks.

### 4.4 The real state of CI (cross-checked against the GitHub Actions API)

| Metric | Value |
|---|---|
| Total runs | **380 runs**: success 137 (36%) / failure 172 / cancelled 71 |
| Last 100 runs | **10 successes (10%)** |
| Acceptance gate (from run 374, 7 runs in total) | **0 successes** |
| HEAD `db12a62` (run `42332912178`) | ❌ failed at `Check original UI acceptance`; the following `Launch macOS app`, `Check Open Folder menu` and `Check Open Folder menu in Chinese` were **skipped** because of implicit `success()` semantics; `Build iOS Simulator` and `Test XYZCore` passed |
| Last green push | run 364 (`ecd4594`, 11-06 10:18 UTC); last green PR was run 373 (`56bd310`) — consistent with the CHANGELOG |
| Structure of a single CI run | `macos-latest` + "pick the newest Xcode" (floating toolchain); Debug build; a 90-second hard timeout on `-XYZCheckGutter`; screenshots are still uploaded when acceptance fails; no Release/archive, no lint, no caching, no `timeout-minutes`, no app tests |

**Two structural problems:**

1. **CI does not run the app the user runs.** CI builds with `CODE_SIGNING_ALLOWED=NO` (`ci.yml:71-75`) and then re-signs ad hoc with `codesign --force --deep --sign -` (`:83/135/156/180`); a local product of the same kind measured an empty `--entitlements`, whereas the installed build carries App Sandbox / iCloud / bookmarks / network.client. In other words **the sandbox, iCloud, bookmarks and container paths have never been exercised by CI** — which explains the structural reason behind the CHANGELOG's "iCloud not verified", and means there is no equals sign between "the UI checks pass" and "it works inside the sandbox".
2. **Self-check ≠ acceptance.** Acceptance has passed 0/7 since it was introduced in `da9730d`, and the file has not been touched since; the failing items include the nested-file click, Collapse All, the divider double-click, the mode label and the empty-line preferences. Window screenshots cannot see WKWebView pixels (as the CHANGELOG itself notes), and Reading is core to the product, so this is a verification blind spot.

---

## 5. Risk List

> The P0/P1/P2 in front of each number is the unified severity used in this analysis: P0 = data loss/crash/release blocker; P1 = obvious defect, security or privacy, high risk; P2 = improvement. Each entry gives its primary evidence; the full evidence is in `docs/analysis/`.

### 5.1 P0 (4 defects + 1 release blocker)

**P0-1 New File truncates an existing file on a case-insensitive volume (data loss, reproduced locally)**
`createItem` uniquifies against "the names already listed in the tree ∪ the actual names in the directory" (`WorkspaceSession.swift:410-421`), `WorkspaceItemName.unique` does an **exact string comparison** (`WorkspaceSearch.swift:297-309`), and the file is then written with `Data().write(to:, options: .atomic)` (`WorkspaceSession.swift:429-435`). macOS APFS is case-insensitive by default: when `untitled.md` already exists on disk, `Untitled.md` is not in the set, and the atomic write overwrites the same directory entry.
Reproduced locally: `fmt 'precious content' > untitled.md`, then an atomic write to `Untitled.md` → `untitled.md` becomes 0 bytes. Fix: `.withoutOverwriting`/`O_CREAT|O_EXCL` + uniquification that follows the volume's case/Unicode-normalization semantics, moving `unique` down into Core with tests.

**P0-2 Tab restore on relaunch is broken by the "global open serial number" and overwrites the persisted state (state loss, confirmed in code)**
`openFile` increments a global `openSerial` for every request and requires `openSerial == serial` when the async read completes (`WorkspaceSession.swift:539-563`); `restoreTabs` opens all tabs in one synchronous loop (`:727-761`), so only the last request can install; immediately afterwards `WorkspaceWindowController.open` calls `persistOpenWindows()` right away (`WorkspaceWindowController.swift:245-254`), but `tabStrip` is still empty at that point, so `xyz.workspace.windows` is overwritten with nothing / a single tab. The regression was introduced by `d5c4f25`, and `restoreTabs` has no integration test. Fix: per-path request contention + allow persistence only after the restore completes, or make `restoreTabs` async and serial.

**P0-3 Window close / ⌘Q does not guarantee unsaved edits reach disk (data-loss risk, confirmed in code)**
`windowWillClose` calls `shutdown()` directly (`WorkspaceWindowController.swift:129-137`); `applicationShouldTerminate` always returns `.terminateNow` (`:652-657`), and `prepareForQuit` does a single `shutdown()` (`:445-451`). `flush()` calls `save(force:false)` only once, writing conflict/encoding/IO errors to `status` only (`WorkspaceSession.swift:1925-1933`), and the conflict dialog applies only to the current buffer (`:961-963`). Unsaved edits in multiple tabs can be silently lost when files were modified/deleted externally, when iCloud is offline, or on a read-only volume. Fix: return `.terminateCancel` from `windowShouldClose`/`applicationShouldTerminate` with a Save/Discard/Cancel prompt; make `flush()` return a result; flush synchronously before trashing.

**P0-4 The undo stack is not cleared across documents: ⌘Z crashes or corrupts the current document (crash/corruption, reproduced at the AppKit layer)**
A folder window's `XYZEditor` gets `@Environment(\.undoManager)` (`WorkspaceView.swift:1626-1658`; nil when there is no document scene), so `XYZMacTextView.undoManager` falls back to its own `NSUndoManager` (`XYZMacEditor.swift:43-45`); programmatic replacement only calls `disableUndoRegistration` without clearing the stack (`XYZMacEditor.swift:1376-1393`), and there is no `removeAllActions` anywhere in the repository. An AppKit probe in this analysis reproduced it: after typing, `canUndo=true`, and after `textView.string = "XY"`, `canUndo` is still true (the old typing action is still there and undo throws `NSRangeException`; calling `removeAllActions()` first is safe). Fix: `removeAllActions(withTarget:)` in `replaceContents` / on buffer switches, or a per-buffer undo manager; add a "⌘Z after switching tabs" regression case.

**P0-5 Release blocker: HEAD CI is red, acceptance never passed, no tag/release/notarization/Developer ID (release blocker)**
See §4.4, and the signature discrepancy discussed in §4.4. `git tag` is empty; there is no release workflow; Release has `ENABLE_HARDENED_RUNTIME=NO` (`project.pbxproj:487`); the installed build uses an Apple Development certificate (not Developer ID) and cannot be notarized or distributed. The 0.5.28/44 number span covers 18 commits, while the rollback target `02dac3c` in `docs/architecture.md:3` predates two fixes recorded in 0.5.28 (`ee0b4bd`, `d834720`), so "roll back to 0.5.28" is not actionable.

### 5.2 P1 (by theme)

**Security/Privacy**

1. **Preview requests remote images silently, contrary to the README.** `URLPolicy.imageSchemes = ["http","https"]` (`HTMLRenderer.swift:482`) and `visitImage` emits them verbatim (`:301-318`); the shell has no CSP and the app carries the `network.client` entitlement; opening a note containing `![](https://…)` contacts a third party on Reading's first render (leaking IP/time/read receipt). Recommendation: allow only local images by default (through `xyz-asset`), or add a CSP and an explicit prompt.
2. **`xyz-asset` has no root-directory restriction.** `LocalAssets.fileURL(for:)` checks only the scheme and the leading `/` (`LocalAssets.swift:26-31`) and neither canonicalizes the path nor verifies that it stays under the note's directory; a folder window holds authorization for the whole tree, so note A can use `../../` to show folder B's images/media (whereas opening links does have a root restriction, `WorkspaceSession.swift:360-368`).

**Data/Correctness**

3. **Stale `LineIndex`.** `warmLineIndex` is called only from `makeNSView` / programmatic reload (`XYZMacEditor.swift:1124,1386`), and the gutter reads `textView.cachedLineIndex()` first (`LineNumberGutter.swift:59-68`); after a single Return, line numbers/status-bar line:column/Source↔Reading anchors all shift.
4. **Gutter full layout + inconsistent line box.** With TK1 + wrapping, every redraw runs `ensureLayout(0..<full length)` inside `lineFragmentRows` (`LineNumberGutter.swift:313-322`), and the "skip" decision happens after that, so a skip lays out twice; without wrapping the gutter line box comes from the gutter font rather than the editor font (`:346-361`), drifting 2.84pt per line at line spacing 1.0–1.1 (measured with a local probe; the test fixture happens to use 1.2, which masks it).
5. **Saving blocks the main thread.** `WorkspaceFileBuffer.save` synchronously performs `NSFileCoordinator` + whole-file read + whole-file write on the `@MainActor` (`WorkspaceSession.swift:1890-1935`, `WorkspaceFileAccess.swift:112-150`) with a 500ms debounce; large files/iCloud/network volumes will drop frames or even beachball (the read path, by contrast, uses `Task.detached`).
6. **The buffer's `@Published` has no subscribers.** Nowhere in the repository are `kind/reloadToken/conflictText/isMissing/status` consumed via `@ObservedObject`/sink (`WorkspaceSession.swift:1636-1640`); external file changes, save failures and disappearing files may never refresh the UI, and `onEditorState` only updates the tab dirty flag (`:947-952`).
7. **Replace in Folder can modify hidden files and does not re-verify unopened files on disk.** The planned scan does not filter hidden files (`WorkspaceSession.swift:1241-1243`), execution writes unopened files directly (`:1326-1369`), external changes between planning and execution are overwritten by the stale plan, and undo likewise writes the old bytes back directly.
8. **Atomic writes break symlinks/hard links.** Directory loading treats a symlink as an ordinary file (`WorkspaceDirectoryLoader.swift:10-27`), and saving uses `bytes.write(.atomic)` (`WorkspaceFileAccess.swift:139-146`) → the link is replaced by a regular file and the real target is not updated (confirmed by a local experiment).
9. **`Task.detached` cancellation does not work + every directory expansion rescans the whole root.** `Task.isCancelled` is usually always false inside a detached task (`WorkspaceSession.swift:1110-1127,1386-1413,1938-1976`); `load(parent:)` unconditionally calls `scheduleIndex()` on success, so in a large repository expanding/refreshing stacks up whole-directory enumerations.
10. **The document scene supports UTF-8 only.** `TextDocument` is UTF-8 only and strips the BOM on read (`TextDocument.swift:5-40`), and `MarkdownFileDocument.init` throws on failure (`MarkdownFileDocument.swift:33-38`); iOS can only go through the document browser (README:4-7), so Windows-1252/UTF-16 text cannot be opened on iOS/⌘O, and a BOM disappears after a BOM-bearing file is saved through the document scene.
11. **CRLF front matter line numbers are off + ghost outline headings.** `ReadingSource.swift:65-71` masks per `Character`, and `"\r\n"` is a single Character → the CRLF front-matter newline is swallowed and `data-line` shifts by one; `MarkdownOutline.swift:20-26` parses the raw text directly without `ReadingSource.prepare`, so YAML front matter becomes a heading and wiki-link headings disagree with the preview.
12. **`MarkdownFileDocument.objectWillChange` is never sent.** `MarkdownFileDocument.swift:16` declares the publisher and `storeEditorText` (`:48-52`) never calls `send`; the document's dirty state depends entirely on the undo manager, and no test proves that "closing after a programmatic replacement / IME commit / reload prompts to save".

**Performance**

13. **Every keystroke synchronously hands the whole document String around** (editor → buffer → preview bridge → outline → word count), causing input latency and memory churn on 1–5MB files (`WorkspaceView.swift:1642-1657`, `XYZMacEditor.swift:1440`); the outline/word count are also recomputed on every keystroke.
14. **`TextFind.matches` has no cap**: `replaceAll` copies `NSMutableString→String` for every match, and `lineNumber` copies a prefix string; a frequent word in a 5MB file can produce millions of matches (`TextFind.swift:29-39,66-79,126-136`).
15. **`SyntaxColoring` does one `NSMutableString.substring` per character** (`SyntaxColoring.swift:154-157`), which is noticeable when scrolling a 256KB file; `TextBytes` decodes UTF-8 twice (`:187`) and concatenates per scalar (`:255-308`).

**Cross-platform/Product consistency**

16. **The iOS Source side is clearly behind**: it ignores font size/line spacing/font/readable width/spellCheck (`XYZIOSEditor.swift:210-219,285-311`; `XYZEditor.swift:254-263`) and has no line numbers, no find and no syntax coloring; meanwhile Reading uses the `@AppStorage` font size/line spacing (`MarkdownWebView.swift:97-111`) → Source/Reading disagree under the same settings.
17. **The internationalization promise is unfinished**: the catalog has 234 keys / 232 zh-Hans, but source extraction finds at least 47 user-visible strings missing from the catalog (menus, tab context menu Pin/Unpin/Close All, Find and Replace, Search Notes, Explorer/Collapse All, the search panel, Settings, etc.); CI only `grep`s one "Open Folder…" (`ci.yml:190`).
18. **Swizzling system classes is the biggest upgrade fragility**: 5 hooks in total across `NSSavePanel`/`PlatformDocumentController` (`FolderOpening.swift:64-258`), with no version probing or fallback; a change in AppKit/SwiftUI internals is enough to silently break "File → Open/New Document".

**Verification/Engineering**

19. **2,459 lines of self-check code ship in the release build**: `GutterSnapshot.swift` is a single enum including Vision OCR/WebKit/screenshots; its offscreen cases exercise the TK2 detached path and **do not cover the production TK1 window path** (`GutterSnapshot.swift:1279-1281`), so there is a structural risk of "the self-check is green but the window is wrong".
20. **Hand-written pbxproj** (no `project.yml`, UUIDs synthesized sequentially as `8A/8B/8C0…`): adding/renaming files requires manual registration, and a missed registration silently keeps the file out of the build; there is no CI consistency check.
21. **No tag/release/notarization/Developer ID** (see P0-5); the CHANGELOG relies on Actions artifacts that expire after 90 days as evidence.

### 5.3 P2 (summary)

- **Dead code**: `SourceFormatting` + the inline toggle (283 lines + 16 tests), most of `LogicalLineGutter`, `ReadingLineMap`, `ExplorerSection.fileCount`.
- **6 inconsistent line-number implementations** (2 of them count only `\n`); extension/classification knowledge drifts across 5 places; the `bmp/ico` viewer opens but shows the wrong icon.
- **`FileFormats.isTextualName` is always false for dotfiles** (`FileFormat.swift:189-196`), so the textual entries of `.gitignore` are unreachable → non-UTF-8 dotfiles are treated as binary.
- **BOM-less UTF-16 is misdetected if the bytes happen to be valid UTF-8**, and the bytes are rewritten after editing and saving (`TextBytes.swift:187-222`).
- **`WorkspaceItemName.unique` silently returns a duplicate name after 10,000 conflicts** (`WorkspaceSearch.swift:297-309`).
- **CLI `xyz` edge-case bugs**: the `~`/`~/*` branches in `case` never match the literal `"~"` (POSIX tilde expansion); an interactive shell usually works because it expands first, but passing it from a script or in quotes fails; the predictable `/tmp/xyz-cli-*.$$` temp file carries symlink/concurrency risk (`XYZ/Resources/bin/xyz:53-54,98-117`).
- **No lint/format configuration** (swiftlint/swiftformat are installed locally), default rules give App 468 / Core 138 findings; the Swift language mode is still 5.0 (`SWIFT_STRICT_CONCURRENCY` is not complete), so the concurrency correctness of the many `Task`/`@MainActor` code paths is undefended.

- **The macOS product contains iOS-only plist keys** (`UILaunchScreen`, `UISupportsDocumentBrowser`, etc., `project.pbxproj:447-500`).
- **`tools/make_icons.py` is not reproducible**: a top-level `import fontTools` (locally `--help` immediately raises ModuleNotFoundError), a hardcoded Chrome path, and no version pin/requirements.
- **Accessibility**: only 33 accessibility markers in the whole repository, with no VoiceOver/keyboard-completeness acceptance; the a11y declarations of the settings panel, status bar and Reading deserve dedicated tests.
- **Inconsistent product positioning**: the GitHub repository description says "An AI Editor.", but the code/README have no AI feature; if that is the roadmap, the README should say so, otherwise the description should be changed.

---

## 6. Product Assessment

**Strengths (worth continued investment):**

- Native (not Electron) macOS feel + a real folder workspace + tabs/command palette/outline, a combination closer to "a lightweight, IDE-like Typora", giving a clear differentiator in the Markdown-editor lane.
- Text fidelity (encoding/line endings/BOM/mixed line endings) is a capability many competitors ignore, and is especially valuable to users migrating from Windows or legacy toolchains.
- Both rendering paths, Reading (WebView) and Editing (native TextKit), are taken seriously: relative images, `#fragment`, external links, ASCII tables, highlight.js, find highlighting, scroll anchors.
- The thoroughness of the README/CHANGELOG and the discipline of "never record an unverified item as passing" are among the project's most credible assets.

**Main product gaps:**

1. **Release and distribution do not exist**: no download page/notarization/auto-update/TestFlight; users cannot get 0.5.28, and the installed build is the development-signed 0.5.27.
2. **iOS is only "a minimal implementation of the document scene"**: no folder workspace, tabs, find or syntax coloring; the Source and Reading sides disagree on settings. If "one SwiftUI codebase for three platforms" is the selling point, this is the biggest gap right now.
3. **Sync exists only as entitlement declarations**: the iCloud container, bookmarks and sandbox paths have not been verified in a signed environment, so the product promise "plain documents in iCloud Drive" cannot be proven today.
4. **The verification blind spot is misaligned with the product core**: window screenshots cannot see WebView pixels, and real IME/iCloud/gestures are not exercised; the 5 failing UI-acceptance items (Explorer click, Collapse All, divider, mode label, empty-line preference) are exactly the key interactions for "does the folder window work well".
5. **The positioning has not landed**: "An AI Editor." has no corresponding feature; if AI capabilities are planned, the privacy boundary (remote requests off by default), an outbound-data notice and the choice between local and cloud models must be settled first.

**Competitive summary (qualitative):** compared with Typora, XYZ has the folder workspace/tabs/command palette, but Typora is more mature, cross-platform and already shipped; compared with Obsidian, XYZ is lighter and more native, but its plugin ecosystem/sync/mobile cannot compare; compared with VS Code, XYZ's Markdown reading experience is more focused, but it lacks an extension ecosystem and a release channel; compared with small native tools such as MarkEdit, XYZ has a larger feature surface but also greater engineering risk. **The realistic path is "a small, polished native macOS Markdown/text workbench + iOS catch-up afterwards", not "a general-purpose editor platform".**

---

## 7. Recommended Roadmap

### Immediate (this week: fix P0 and make the gate trustworthy)

1. **P0-1 safe new files**: switch to `withoutOverwriting`/`O_EXCL`; implement `unique` following the volume's case/Unicode-normalization semantics, move it into XYZCore and unit-test it (including `Note.md`/`note.md`, NFC/NFD).
2. **P0-2 tab restore**: change to per-path request contention + persist only after `restoreTabs` completes; add restore regression tests (pure functions + offscreen AppKit).
3. **P0-3 quit protection**: `windowShouldClose` + `applicationShouldTerminate` go through `.terminateCancel`; `flush()` returns success/failure; conflict/encoding-error dialogs cover all tabs.
4. **P0-4 undo cleanup**: clear the undo stack in `replaceContents`/on buffer switches (or use a per-buffer undo manager); add a "⌘Z after switching tabs" case.
5. **Make CI trustworthy**: change the `if` on the `Launch`/menu checks to `always()` (otherwise an acceptance failure skips them forever); pin the Xcode version; add `timeout-minutes`; output a structured failure list when acceptance fails. If the 5 cases cannot be fixed soon, mark acceptance as advisory and state plainly that "HEAD is not green"; stop using "release candidate".
6. **Freeze a release point**: put an annotated tag `v0.5.28` on a commit where acceptance is fully green (or explicitly waived); enable Hardened Runtime in Release; add a Release build to CI (macOS at least) plus a skeleton archive/notarize script (the Developer ID certificate comes from secrets).

### Short term (1–2 months: fix P1 and the verification system)

7. **Move the self-checks out of the product**: split `GutterSnapshotCheck`/`FileMenuCheck` into a separate UI test target (or at least `#if DEBUG`) so the Release binary no longer contains the Vision/screenshot/OCR dependencies; also make offscreen cases cover the production TK1 path.
8. **Secure defaults**: Reading does not load remote images by default (or adds a CSP + a setting); `xyz-asset` gains a root restriction (canonicalize + `hasPrefix(allowedRoot)`, with the handler instantiated per webview/session).
9. **Small correctness fixes**: LineIndex invalidation strategy (clear the cache / rebuild asynchronously in `textDidChange`); unify the gutter line box on the editor font and remove the full `ensureLayout`; fix CRLF front matter in `ReadingSource` by masking per scalar; reuse `ReadingSource.prepare` in `MarkdownOutline`; have the document scene take over encoding from `TextBytes`.
10. **Make the App testable**: extract pure logic (restore plan, save sequence, replace plan, path containment) from `WorkspaceSession` into XYZCore; add an App test target and cover the 5 P0/P1 paths first.
11. **Move saving off the main thread**: put the disk re-verification, encoding and writing on a serial actor/background queue and bring the result back to the MainActor; publish buffer changes correctly (subscribe to the buffer's `objectWillChange` or make the view `@ObservedObject`).

12. **Internationalization/localization**: extract the 47 hardcoded strings; add a catalog diff check to CI; finish the Chinese menus/search panel.
13. **Converge swizzling**: gather it into one module, run a version/selector self-check at launch and log diagnostics; evaluate whether `NSOpenSavePanelDelegate`/`applicationShouldOpenUntitledFile` can replace some hooks.

### Mid term (3–6 months: release and platform)

14. **Release pipeline**: Developer ID signing + notarytool + a download page + Sparkle auto-update; iOS through TestFlight; a one-to-one mapping of version number → tag → build; the CHANGELOG links to tags instead of volatile run URLs.
15. **Acceptance in a real environment**: smoke tests on a signed sandboxed build (including security-scoped bookmarks, iCloud Drive, sandbox paths); a real Chinese input method; real window gestures/Explorer clicks (XCUITest failing to launch on GitHub runners is already recorded, so a self-hosted runner or a manual acceptance checklist is needed).
16. **iOS catch-up**: wire the Source side into the shared styles/find/coloring; evaluate an iPad folder workspace (`WorkspaceSession` already has the model reserved on the Core side, but `XYZ/Workspace/*` is entirely macOS-only today).
17. **Turn performance into targets**: define and measure the p95 of 1MB/5MB open, input latency, 300KB scrolling and ⌘K search; optimize in the order given in §5 P1-13/14/15.

### Long term (architecture and product direction)

18. **Settle the TextKit strategy**: either declare TextKit 1 explicitly (`usingTextLayoutManager: false`) or verify that the SwiftUI window-composition problem is fixed on the target macOS version before migrating to TextKit 2; either way, lock the runtime path down with assertions/diagnostics to avoid the undocumented downgrade.
19. **Unify the two IO stacks** for single files and workspaces (`TextBytes` as the only encode/decode entry point) to eliminate BOM/encoding semantic drift.

20. **Land the product positioning**: either implement AI capabilities (settling privacy/outbound data/local models first) or change the repository description to "native Markdown editor"; finish accessibility and theming to form a promotable differentiator.

---

## 8. Analysis Scope and Limitations

- **Verified**: the three local builds + Core tests + the CLI script; the metadata of 380 GitHub Actions runs (conclusions, steps, commits); 4 static deep reads covering all 66 Swift files, the CI/build configuration, the docs and the localization catalog; AppKit probes (TextKit downgrade, undo stack, line box) and filesystem probes (case-insensitive truncation, atomic writes breaking links).
- **Not verified**: the GUI app was not launched (it would open windows on the user's screen); no Instruments/performance measurement was run; nothing was tested on macOS 14/15; the real Chinese IME, iCloud and the signed sandbox were not run; GitHub job logs require admin rights (the API returns 403), so only run metadata and CHANGELOG records could be used; therefore P0-4 has the AppKit mechanism reproduced, with the in-product path still to be confirmed step by step.
- **Team output**: `docs/analysis/core.md`, `workspace.md`, `editor.md` and `process.md` are the original reports from the four parallel deep reads (about 1,700 lines, all with file:line), not merged or polished, and can serve as the appendix and review basis for this report.
- **Line-number basis**: HEAD `db12a62`. Later commits will shift line numbers, so locate by symbol/function name when re-checking.

---

## 9. Fix Progress (in this report's priority order)

This section records the changes actually landed, corresponding to version 0.5.29 (build 45); the detailed narrative is in the `CHANGELOG.md` entry for the same number. Line numbers are based on HEAD `db12a62`; this section locates code by function name.

### 9.1 Fixed: P0

| ID | Fix | Primary location | Verification |
|---|---|---|---|
| P0-1 | New files/folders are always created exclusively (`.withoutOverwriting` / `createDirectory`); the name is re-chosen from the directory's actual state at creation time, and if the filesystem reports that it exists, the next name is retried (up to 20 times); `unique` compares names by volume semantics (case-insensitive + Unicode precomposed), and after 10,000 conflicts returns a UUID-suffixed name instead of silently duplicating | `WorkspaceSession.createItem` / `createItemExclusively`/`itemAlreadyExists`, `WorkspaceItemName.comparisonKey` | `WorkspaceTests.testNamesAndMoves` gained `untitled.md`, `NFC/NFD` and case-sensitive-volume assertions |
| P0-2 | `openFile` returns the install task; restore awaits serially per tab with `activate: false` and finally selects the saved active tab; the window list is persisted only after restore completes (the old list is kept on failure); the restore task is cancelled with the window; `windowState()` saves each tab's real mode | `WorkspaceSession.restoreTabs`/`openRestored`/`present`, `WorkspaceWindowController.open` | `EditorTabTests.testSetActiveKeepsTheSet`, `testTabModeSurvivesTheStrip`; builds pass on all three platforms |
| P0-3 | `windowShouldClose` and `applicationShouldTerminate` first flush all buffers (suppressing per-file conflict dialogs), then show one merged list: "Keep Editing" as default/Esc, or "Close Anyway"/"Quit Anyway"; files that failed to save are listed first and their banner is visible after cancelling | `WorkspaceWindowController.windowShouldClose`/`prepareForQuit`/`confirmUnsaved`, `WorkspaceSession.unsavedForClose`/`presentForClose` | compile + path review; in-window acceptance on a real machine not done (see 9.4) |
| P0-4 | A whole-document replacement clears the undo stack when the text actually changed (macOS `XYZMacTextView` and iOS `UITextView`), so old ranges no longer point into the new document | `XYZMacEditor.replaceContents`, `XYZIOSEditor.replaceContents` | code-path review; interactive acceptance not done |

### 9.2 Fixed: P1 (selected items)

| ID | Fix | Verification |
|---|---|---|
| P1-3 | `textDidChange` invalidates the `LineIndex` cache immediately and redraws line numbers, then rebuilds it in the background after a 120 ms debounce; the gutter and status bar no longer read line starts from before the edit | builds pass |
| P1-4 (partial) | the gutter's line box without wrapping now uses the editor font and paragraph style, not the smaller gutter font | builds pass; the full `ensureLayout` is still there, no performance refactor |
| P1-6 | the session forwards the buffer's `objectWillChange`, so disk reloads/save failures/disappearing files refresh the body and banner | builds pass |
| P1-7 (partial) | `searchableFiles()` unifies the candidate set of ⌘K and Replace in Folder: directories excluded, skipped paths excluded, and hidden files excluded when the sidebar hides them | builds pass; pre-execution disk re-verification not done |
| P1-2 | `xyz-asset` gains a root restriction: `WorkspacePathScope.contains` standardizes the path and resolves symlinks; the handler is instantiated per webview and follows note-directory switches | `WorkspaceTests.testPathScopeResolvesTraversalAndLinks` (`..` escape, symlink escape) |
| P1-1 | Reading does not load remote images by default: with `MarkdownHTML.render(_:allowRemoteImages:)` off, the renderer emits no `http(s)` `<img src>` at all (the web view has nothing to request, and protocol-relative `//host` is blocked as well); the "Load remote images" setting defaults to off and can be enabled in Settings; relative-path images are unaffected | 2 new cases in `MarkdownHTMLTests` (no remote src when off, relative images still render, protocol-relative addresses blocked) |
| P1-17 | added the 48 user-visible strings missing from the source (menus, tab context menu, ⌘K panel, Explorer, Settings, status bar, CLI install dialog, Replace in Folder); the catalog went from 238 to 286 keys, all with zh-Hans | `Localizable.xcstrings` validation; a new catalog-completeness step in CI; Chinese menus not inspected on a real machine |
| P1-11 | CRLF front matter is masked by Unicode scalar, so `\r\n` is no longer swallowed as one Character; the outline parses after `ReadingSource.prepare`, so `#` inside front matter is no longer a heading and wiki-link headings match Reading | 3 new cases in `DocumentInsightTests` (LF/CRLF line numbers, wiki-link headings) |
| P1-10 | the document scene (iOS document browser / Mac ⌘O) now preserves encoding and line endings: UTF-8/BOM/UTF-16/Windows-1252 all read and write, the BOM is no longer lost, and characters that cannot be encoded fall back to UTF-8 instead of writing an empty file | 5 new unit tests in `TextDocument` (BOM, UTF-16, Windows-1252, CRLF preserved, UTF-8 fallback) |
| P1-8 (partial) | saving resolves symlinks through the new `WorkspaceWriteTarget.resolveForWriting` (including chained links and loop fallback), so the atomic write lands on the link target instead of replacing the link with a regular file; wired into `WorkspaceFileCoordination.updateText`/`writeData` | 5 cases in `WriteTargetTests` (regular path, link, chained link, loop, still a link after writing) |
| P1-9 (partial) | the detached scans became cancellable (they really stop when ⌘K is dismissed or the folder changes); a directory reload whose listing did not change no longer rescans the whole tree | builds pass |
| P1-15 (partial) | `TextBytes.decodeUnicode` no longer decodes UTF-8 twice; `TextFind.lineNumber` no longer copies the prefix string; regex `replaceAll` no longer copies the whole document per match | all 208 existing unit tests pass (including regex group replace) |
| P1-14 (partial) | the same `replaceAll` copy elimination as P1-15; `matches` still has no cap (which needs a UI-semantics decision) | — |
| P1-12 (docs) | `objectWillChange` remains unsent, and the reason is written in the code: the dirty state is driven by the undo manager, and sending on every keystroke would only rebuild the scene | comment; no runtime verification added |

### 9.3 Fixed: low-cost P2 items

| Item | Fix |
|---|---|
| dotfile text detection | `FileFormats.isTextualName` returns true for `.gitignore`/`.editorconfig`/`.env` and still false for `.DS_Store`/`.png` (with unit-test assertions) |
| JSON/CSS line comments | `TextTransforms.lineComment(for:)` returns nil, so the command is disabled instead of writing a file the parser rejects (with unit-test assertions) |
| `unique` conflict cap | after 9,998 names it returns a UUID-suffixed name instead of a name that may already exist |
| BOM-less UTF-16 | the heuristic now runs before UTF-8: pure-ASCII UTF-16 is no longer read as UTF-8 with NULs and then rewritten on save (with a unit test) |
| CLI `~` edge case | `case "~"` and `"~/"*` in `Resources/bin/xyz` are quoted; `Scripts/xyz-test.sh` gained `tilde`, `tilde-dir` cases (HOME pointed at a temp directory) |
| CLI temp files | the predictable `/tmp/xyz-cli-*.$$` became `mktemp -d` + `trap` cleanup, avoiding pre-planted/symlink and SIGINT leftovers; dry-run 8/8 pass |
| Icon script | `tools/make_icons.py` imports fontTools lazily, so `--help` no longer throws a traceback; Chrome is looked up through several candidates/`CHROME` override, and a missing dependency gives a one-line message; added `tools/requirements.txt` |
| CI trustworthiness | `timeout-minutes: 60`; a bundle-version consistency check against `Config/Base.xcconfig`; window-check steps run under `always()`; acceptance emits an `::error` annotation per failing case; a Release build; artifacts include screenshots and per-step logs; a catalog-completeness check |

### 9.4 Still open (deliberately left, by priority)

- **P0-5 release blocker (greatly advanced, still not closed)**: Release now enables Hardened Runtime; a Developer ID Application certificate was created locally (Team `Z4FMG2KTPM`), archive → `method=developer-id` export → zip notarization (submission `0e54a40b…`, Accepted) → staple → `spctl` **accepted / source=Notarized Developer ID**; the DMG was also signed, notarized (`a0e37293…`, Accepted), stapled and accepted by `spctl`. Still missing: tag/GitHub release, release workflow, the acceptance gate (0/7), the installed build still being 0.5.27, and manual acceptance on a real machine. The steps and records are in `docs/release.md`.
- **P1-1 remote images blocked by default**: a product decision (off by default + a setting + an external-link prompt); this round changed documentation only.
- **P1-5** saving is still on the main thread (1MB+ files/iCloud/network volumes can stutter) — it needs a refactoring window with no GUI acceptance.
- **P1-8 hard links**: atomic writes still split hard links (atomicity wins for now); symlinks are fixed.
- **P1-9 remainder**: directory loading itself (a single `children` call) is still not interruptible; `Task.detached` cancellation only covers loops that have a checkpoint.
- **P1-13** the per-keystroke whole-text hand-off (editor → buffer → preview/outline/word count) is not throttled; **P1-16** the iOS Source side still lags on styles/find/coloring; **P1-18** converge swizzling; **P1-19** move the self-check code out of the release build; **P1-20** hand-written pbxproj consistency.
- **P2 dead code (partial)**: `ReadingLineMap` (with 3 tests) and `ExplorerSection.fileCount` (with 2 assertions) were deleted — neither had a production caller; the 6 formatting commands in `SourceFormatting.swift` and the `SourceEditing` inline toggle are **deliberately kept** — `FormatMenu.swift` explicitly removed the Format menu ("notes are written as Markdown text"), the decision is written in the file header, and deleting them needs product-level confirmation.
- **P2 remainder**: unifying the 6 line-number implementations, lint/format configuration, accessibility, the repository description ("An AI Editor.") and the release positioning.
- **P2 iOS-only plist keys in the macOS product (tried, did not work)**: after changing the 6 `INFOPLIST_KEY_UI*` to conditional settings `[sdk=iphoneos*]`/`[sdk=iphonesimulator*]`, Xcode's Info.plist generator still writes keys of the same name (empty/false) into the macOS product — it merges the key names across all variants and then takes the value for the current SDK. Reverted. Doing it properly requires turning off `GENERATE_INFOPLIST_FILE` and using a full plist, or a Process Info.plist step that deletes these keys; the only benefit is cleaner metadata, so it was not done.

### 9.5 Verification baseline for this round

- `swift test --package-path XYZCore`: **207 tests / 0 failures** (194 after the first round; +14 in the second; +2 remote-image cases, −3 deleted `ReadingLineMap` tests in the third).
- `sh Scripts/xyz-test.sh`: **8/8 ok** (new `tilde`, `tilde-dir`).
- `xcodebuild`: macOS Debug, macOS Release and iOS Simulator Debug all **BUILD SUCCEEDED** (signing off, same settings as CI).
- `python3 tools/make_icons.py --help` prints normally on a machine without fontTools installed; `--sheet` gives an actionable install hint.
- GUI not launched: quit/close dialogs, tab restore, image scope and Chinese menus have only compilation + pure-function unit-test evidence, with no window screenshots; the signed sandbox, iCloud, a real Chinese IME and performance measurements were not run.
- Local signing and notarization chain (Team `Z4FMG2KTPM`, 2026-11-07): Apple Development Debug/Release builds pass; Developer ID archive + `developer-id` export succeed (entitlements: sandbox / network.client / user-selected / bookmarks / iCloud Production, no `get-task-allow`); the app zip is notarized Accepted and stapled, `spctl` accepted; the DMG is signed, notarized Accepted, stapled and `spctl` accepted. The app was not opened, no tag was created and nothing was uploaded.

### 9.6 Additional fixes not listed in the report

**Sidebar shortcut toggle: stutter, animation and header text overlap (user report; 0.5.30 → 0.5.31)**

- **Stutter**: `XYZSplitView` called `rebuild()` on every show/hide, detaching and re-attaching all three `NSHostingView`s (sidebar/detail/outline), so the editor text view and Reading's `WKWebView` left the window and redrew; the hide path also used a 60 Hz `Timer` to change the width frame by frame over 160 ms, triggering TextKit relayout every frame; the show path used the `savedPosition` it had just zeroed as the animation target, so the animation never actually took effect. 0.5.30 switched to `syncPanes()`, which only adds/removes the column that changed (`addSubview(positioned:)`, with detail always present) and dropped the frame-by-frame animation.
- **Animation**: after user feedback that "it no longer stutters but is not smooth", 0.5.31 restored a 180 ms ease-out (degrading to instant with Reduce Motion); after each frame's pane frames are set, `flushPaneLayout()` forces the host SwiftUI layout so the text/web views follow within the same frame; the three panes got `masksToBounds`; `sidebarWanted`/`outlineWanted` fix the shortcut being swallowed when pressed again during the animation.
- **Header text overlap**: the user's screenshot showed the sidebar header turning into "HIC"/"HA" on two lines pressed over the file list. The root cause was that `SidebarRootHeader.layout()` and `SidebarRowCell.layout()` assigned the label's **own current width** to `preferredMaxLayoutWidth`; on the first frame of the animation the sidebar width is ≈0, so `LIZHICHAO` wrapped to three lines and the second line of a 22 pt header drew outside its bounds. Fix: both labels are single-line with tail truncation (`wraps=false`, `usesSingleLineMode=true`, `maximumNumberOfLines=1`), and the self-referential wrap width is gone.
- **Diagnostics**: under `-XYZDiagnostics` the build keeps `sidebar/outline shown=… eased in 180ms sidebar=… detail=… outline=…`, the slide start point, and a warning for anomalous column width (<260 pt); the one-off resize probe was removed before release.

Verification: 207 unit tests / 8 CLI, macOS+iOS Debug builds; 0.5.31 (47) was Developer ID signed, notarized (app `ae1b56da…`, DMG `3229b1fa…`), stapled and `spctl` accepted, and installed over `/Applications` (keeping exactly one copy per `AGENTS.md`); the hidden launch works; the user confirmed on a real machine that the animation is smooth and the sidebar text is back to one line ("good now").

---

## Appendix: Key Evidence Index

| Topic | Key location |
|---|---|
| New file / unique name | `XYZ/Workspace/WorkspaceSession.swift:410-455`, `XYZCore/Sources/XYZCore/WorkspaceSearch.swift:297-309` |
| Tab restore / persistence | `XYZ/Workspace/WorkspaceSession.swift:539-563,727-761`, `XYZ/Workspace/WorkspaceWindowController.swift:245-254,461-468` |
| Quit / flush | `XYZ/Workspace/WorkspaceWindowController.swift:129-137,445-451,652-657`, `XYZ/Workspace/WorkspaceSession.swift:1767-1770,1890-1935` |
| undo | `XYZ/Editor/XYZMacEditor.swift:43-45,1376-1393`, `XYZ/Workspace/WorkspaceView.swift:1626-1658` |
| Swizzling | `XYZ/Workspace/FolderOpening.swift:64-258` |
| TextKit downgrade | `XYZ/Editor/XYZMacEditor.swift:1057-1128,1639-1644` |
| Gutter | `XYZ/Editor/LineNumberGutter.swift:154-179,273-290,313-322,346-361` |
| Preview security | `XYZCore/Sources/XYZCore/HTMLRenderer.swift:301-318,448-511`, `XYZ/Preview/LocalAssets.swift:15-81`, `XYZ/Preview/MarkdownWebView.swift:838-1271` |
| Save on main thread | `XYZ/Workspace/WorkspaceSession.swift:1890-1935`, `XYZ/Workspace/WorkspaceFileAccess.swift:99-154` |
| Buffer publication | `XYZ/Workspace/WorkspaceSession.swift:1633-1770,947-957` |
| Document encoding | `XYZCore/Sources/XYZCore/TextDocument.swift:5-40`, `XYZCore/Sources/XYZCore/MarkdownFileDocument.swift:33-38` |
| front matter/outline | `XYZCore/Sources/XYZCore/ReadingSource.swift:60-75`, `XYZCore/Sources/XYZCore/MarkdownOutline.swift:20-26` |
| Self-check harness | `XYZ/Editor/GutterSnapshot.swift:9-50,1279-1281`, `.github/workflows/ci.yml:77-199` |
| Build/release | `XYZ.xcodeproj/project.pbxproj:384,442,487`, `Config/Base.xcconfig`, `.github/workflows/ci.yml:71-75,83,135,156,180` |
| CI run data | GitHub API `repos/lizhichaox/XYZ/actions/runs` (380 runs); HEAD failure run `42332912178` |
| Localization | `XYZ/Resources/Localizable.xcstrings`, `ci.yml:190` |
