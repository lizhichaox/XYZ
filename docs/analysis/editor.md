# XYZ Editor and Preview Layer Analysis (editor-analyst)

- Repository: `/Users/lizhichao/Developer/XYZ`, version 0.5.28 (build 44) (`Config/Base.xcconfig`).
- Scope: `XYZ/Editor/` (7 files; the editor portion of 7,237 lines), `XYZ/Preview/` (3 files, 1,486 lines), `XYZ/Resources/Preview.css`, and the `XYZ/Resources/highlight.min.js` integration; `XYZCore` consulted as needed (HTMLRenderer / MarkdownHTML / MarkdownParser / ReadingSource / LogicalLineGutter / SourceEditing / SyntaxColoring / TextFind / TextStatistics / MarkdownFileDocument / WorkspaceFilePolicy / TextBytes / EditorViewMode), plus the read/write and window code in `XYZ/Workspace/`, the entitlements, and the CI scripts.
- Method: read the code with `read`/`grep`/`glob` only; all line numbers come from tool output. `xcodebuild` was not run and the repository was not modified. Two standalone AppKit probe scripts (`/tmp/xyz_probe.swift`, `/tmp/xyz_probe2.swift`) were also used to verify the TextKit implicit downgrade, the cross-document undo stack, and line-box computation; results are in §7.4 (the probes only verify AppKit behavior, not product runtime results).
- Host environment: macOS 27.2 (26B123), Xcode 27.2, SDK 27.2; the project deployment targets are macOS 14.0 / iOS 17.0 (`project.pbxproj:377-378`). Every "AppKit behavior" conclusion is therefore only empirically established on this host and the 27.x SDK; behavior on macOS 14/15 was not measured.

---

## 0. Summary of Findings: Claims in README/CHANGELOG/docs Checked Against the Code

| # | Claim (source) | Code facts | Verdict |
|---|---|---|---|
| 1 | The text view actually runs on TextKit 1, because reading `layoutManager` installs TextKit 1 (`README.md:11`, `CHANGELOG.md:12`, `docs/architecture.md:15`) | `makeNSView` creates it with `XYZMacTextView(usingTextLayoutManager: true)` (`XYZ/Editor/XYZMacEditor.swift:1058`), then reads `textView.layoutManager?.allowsNonContiguousLayout = true` (`XYZMacEditor.swift:1128`); `keepViewportLayout` reads it once more after resetting the attributes on every pass (`XYZMacEditor.swift:1639-1644`). The local probe confirms: a TK2 view's `layoutManager` is nil, and after the read `textLayoutManager` becomes nil (§7.4-A). | **Mostly holds, but relies on an undocumented AppKit implicit downgrade**; the code comments and the documentation contradict each other (see P1-5) |
| 2 | The line-number gutter is provided by that same layoutManager, doing skip detection and remeasurement for non-contiguous layout (`README.md:11`, `CHANGELOG.md:13`, `docs/architecture.md:15`) | The TK1 branch does use `textView.layoutManager` + `textContainer` (`XYZ/Editor/LineNumberGutter.swift:273-290`); but the same gutter also has a TK2 fragment branch (`:190-245`) and a uniform line-box branch (`:346-361`); skip detection only takes effect under "TK1 + wrap on", and before detecting it performs a whole-document `ensureLayout` (`:313-343`, `:320`). | **Partly holds**: three sets of measurement exist; the detection condition is narrow, the cost is high, and there is no regression case (§1.3) |
| 3 | Reading is one WKWebView per window, the shell loads only once, and a 220ms debounce replaces the body (`README.md:16`) | The host is owned per window: the folder window in `WorkspaceSession.swift:108-109`, the document window in `DocumentEditorView.swift:40,52`; the comment "One web view for one open note" at `MarkdownWebView.swift:16` does not match the implementation. Load-once is guaranteed by `didStartLoad/isReady` (`MarkdownWebView.swift:458-459,536-539,599-607`), with a reload only when the WebContent process terminates (`:569-578`). The 220/420ms is in `MarkdownPreview.swift:56`, rendering above 20KB runs in the background (`:41,67-74`), and version discarding uses a generation (`:44-63`). | **Holds** (one per window; the comment needs updating) |
| 4 | Raw HTML is displayed as text, and `javascript:`/`data:` do not become links (`README.md:16`) | Both block-level and inline raw HTML go through `HTMLText.escape` (`XYZCore/Sources/XYZCore/HTMLRenderer.swift:128-134,279-281`); the link scheme allowlist is `http/https/mailto` (`:481,492-510`), explicitly rejecting `javascript:/vbscript:/data:` (`:500-502`); the image scheme allowlist is `http/https` (`:482`). | **Holds** |
| 5 | "The renderer still does not request remote images" (`README.md:16`) | The image allowlist includes `http/https` (`HTMLRenderer.swift:482,488-490`), `visitImage` emits `<img src>` verbatim (`:301-318`), the shell has no CSP (`MarkdownWebView.swift:838-1271`), and page JS is fully enabled (`:435`); a unit test even asserts that a remote image must be emitted: `XCTAssertTrue(html.contains("<img alt=\"A &amp; B\" src=\"https://example.com/a.png\" title=\"Pic\">"))` (`XYZCore/Tests/XYZCoreTests/MarkdownHTMLTests.swift:156`). | **Does not hold**: the remote image is requested (P1-6) |
| 6 | Files above 5 MB do not enter the editor; there is a read-only path (`README.md:68`) | `WorkspaceFileClassifier.editLimit = 5_000_000` (`WorkspaceFilePolicy.swift:30`), `kind` returns `.tooLarge` (`:48-50`), the UI shows a placeholder (`WorkspaceView.swift:1467-1481`); the read-only preview limit is `TextBytes.previewByteLimit = 2_000_000` (`TextBytes.swift:103`, `WorkspaceSession.swift:1597-1607`); `.readOnly` files are not editable (`EditorViewMode.swift:45-54`). | **Holds** (note that the 2 MB truncation and the 5 MB limit are two different thresholds) |
| 7 | "Find and replace, and large-file updates, can still land on `textLayoutManager`" (`README.md:58`) | After the macOS view first reads `layoutManager`, `textLayoutManager` is nil; `visibleSpan` and the others all fall back through `guard let manager = textView.textLayoutManager` (`XYZMacEditor.swift:1676-1689`). | **Misleading**: on macOS that path is unavailable and the code actually falls back |
| 8 | "Both ends are TextKit 2" (`XYZEditor.swift:114`, `MarkdownFileDocument.swift:10`, `XYZMacEditor.swift:6`) | iOS stays on TK2 and asserts it (`XYZIOSEditor.swift:210,250`); at runtime macOS is downgraded to TK1 (proven by the probe). | **Does not hold (macOS)**: comment/documentation drift |
| 9 | highlight.js 11.11.1, common languages, distributed with the app (`README.md:169`) | The file header reads `Highlight.js v11.11.1 (git: 08cb242e7d)` (`XYZ/Resources/highlight.min.js:2`), 127,496 bytes; at runtime it is read once from the Bundle and inlined into the shell (`MarkdownWebView.swift:807-816,855-857`), `hljs.configure({ignoreUnescapedHTML:true})` (`:877`), and only `pre code[class*='language-']` is highlighted, capped at 400 blocks (`:1129-1133`). | **Holds** |
| 10 | iOS and macOS share `XYZEditor`/`XYZTextEditing`, with duplicate implementations (`README.md:58`) | The protocol has only three members, `text/textLayoutManager/perform` (`XYZEditor.swift:117-122`); the two Coordinators implement it separately (mac `XYZMacEditor.swift:1304-1481`, iOS `XYZIOSEditor.swift:326-369`); much of the logic exists as two copies (§5). | **Holds**, but with clear drift |

---

## 1. Text View Architecture

### 1.1 The TextKit version actually in use: macOS runs an "implicitly downgraded TextKit 1", iOS runs TextKit 2

- Creation order in macOS `makeNSView` (`XYZ/Editor/XYZMacEditor.swift:1057-1129`):
  1. `XYZMacTextView(usingTextLayoutManager: true)` (`:1058`) — TextKit 2 at creation time;
  2. set `isRichText/importsGraphics/allowsUndo/...` (`:1059-1087`);
  3. `pane.attach(textView)`, `applyChrome`, `textView.string = text`, `warmLineIndex()`, `restyle(edited: nil)`, `observeScroll`, `applyWrap` (`:1120-1127`);
  4. **The very last line** is `textView.layoutManager?.allowsNonContiguousLayout = true` (`:1128`) — this read makes AppKit lazily downgrade the view from TextKit 2 to TextKit 1.
- After that, `EditorTypography.keepViewportLayout` reads `layoutManager` again on every restyle and sets `allowsNonContiguousLayout` back to true (`:1639-1644`), which shows that the author observed in testing that `setAttributes` clears it — indirect evidence that the runtime really is TK1.
- Diagnostics path: `LineNumberGutter.swift:129` and `GutterSnapshot.swift:200` print the api name via `textView.textLayoutManager == nil ? "textkit1" : "textkit2"`, but they only actually write a log when `-XYZDiagnostics` is on (`XYZDiagnostics.swift:87-98`), and no assertion or CI verdict requires it to be `textkit1`.
- iOS differs: after `XYZIOSTextView(usingTextLayoutManager: true)` (`XYZIOSEditor.swift:210`) it never reads `layoutManager`, and it asserts `textLayoutManager != nil` (`:250`), so iOS really is on TextKit 2.
- The probe (§7.4-A) confirmed the downgrade on this host: `A tk2 before: textLayoutManager != nil: true layoutManager == nil: false` → `B after read .layoutManager: textLayoutManager != nil: false`. This matches the repository documentation's conclusion, but it is an **AppKit side effect that is not documented anywhere**: external projects have also recorded that "a default-initialized view is TextKit 2, the first access to `.layoutManager` lazily downgrades it, possibly leaving the layoutManager/textContainer pair inconsistent, and then `glyphRangeForTextContainer:` throws `NSInvalidArgumentException`" ([osaurus regression test](https://github.com/osaurus-ai/osaurus/blob/b4f10dfd86b94d7a00848b0ec941d0fe0b205328/Packages/OsaurusCore/Tests/Chat/TextViewTextKitModeTests.swift)). This risk is P1-5.

### 1.2 Why this path was chosen (judging from the CHANGELOG)

Historically this was not "designed as TextKit 1"; it was forced back by a window screenshot:

- 0.5.23: wrapping no longer treats visual lines as source lines (`CHANGELOG.md:75-77`).
- 0.5.24: it insisted on TextKit 2 for a while, but "Reading `layoutManager` was installing TextKit 1, and a wrapped gutter then had no fragments to number" (`CHANGELOG.md:69`).
- 0.5.25: back to the TextKit 2 viewport (`CHANGELOG.md:64`).
- 0.5.26: the real problem was recorded — "TextKit 2 puts the body in fragment subviews. A layer-backed SwiftUI window was compositing the text view's layer without those subviews, so the gutter showed and the page stayed white. `cacheDisplay` still called `draw` and counted that ink." (`CHANGELOG.md:52`); the same version also states that Reading's line numbers were removed (`:55`).
- 0.5.27: the editor file reverted to the version where "the window can show the body" (`CHANGELOG.md:48`).
- 0.5.28: accepts TextKit 1, keeps the patch that "remeasures contiguously once when visible line numbers are skipped", and explicitly rejects a TextKit 2 rewrite (`CHANGELOG.md:11-13,21-23`, `docs/architecture.md:15,25`).

Conclusion: this is an escape hatch chosen to work around the AppKit problem of "a layer-backed SwiftUI window + TK2 fragment subviews not participating in compositing"; the cost is giving up TK2's viewport layout and on-demand typesetting, and betting line-number correctness on TK1's `allowsNonContiguousLayout` estimation behavior.

### 1.3 Correctness of the gutter and the non-contiguous layout/remeasurement strategy

The live gutter is `LineNumberGutter` (368 lines), with the drawing entry point `draw(_:)` (`XYZ/Editor/LineNumberGutter.swift:70-142`). On every draw it calls `placedRows` (`:154-179`), which tries, in order:

1. **TK2 fragment branch**: `fragmentRows` (`:190-245`);
2. **TK1 + wrap**: `layoutManagerRows` (`:273-290`);
3. **fragments after one more viewport layout attempt** (`:167-172`);
4. **empty document**: `emptyRow` (`:292-304`);
5. **no wrap**: `lineBoxRows` (`:346-361`), estimated from a uniform line box.

The skip detection/remeasurement logic in `layoutManagerRows` (`:273-290`):

```swift
let first = lineFragmentRows(...)            // already performs a whole-document ensureLayout internally (:320)
let numbered = first.filter(\.showsNumber).count
if Self.isSourceRun(first), first.count > numbered { return first }   // numbers contiguous and there are wrapped continuation rows → considered normal
guard layout.allowsNonContiguousLayout else { return first }
layout.allowsNonContiguousLayout = false
layout.ensureLayout(forCharacterRange: 0..<length)                    // second whole-document typesetting
let second = lineFragmentRows(...)
layout.allowsNonContiguousLayout = true                               // restored, but not in a defer
return second
```

Correctness problems (by severity):

1. **The detection happens after two whole-document typesetting passes**: `lineFragmentRows` begins with `layout.ensureLayout(forCharacterRange: 0..<length)` (`:320`), and `layoutManagerRows` has already called it before deciding "whether to remeasure". So this "remeasure only when skipped" optimization does not save the full typeset: **with TK1 + wrap, every gutter redraw has at least one whole-document `ensureLayout`, and two when the run is skipped** (P1-4).
2. **The detection only recognizes "non-contiguous numbers + wrapped continuation rows"**: `isSourceRun` (`:306-311`) requires the visible numbers to be consecutive integers starting from the first. If the estimate collapses whole lines (numbers still contiguous, but the y coordinates wrong) it does not trigger a remeasure; conversely, if the first estimate happens to be contiguous, the second may still give wrong y values.
3. **With wrap off it does not take the TK1 fragment branch** but goes straight to `lineBoxRows` with a uniform line box (`:346-361`); and `lineBoxRows`'s line box comes from the **gutter font** (`Self.font`: `max(10, 0.75*fontSize)`, `:23-25,347-349`), not the editor font. Below a line spacing of about 1.2 the two disagree, and line numbers drift row by row (P1-3, measured 2.84pt/row @ 1.0).
4. **Flag restoration has no `defer`**: `:282` sets it false and `:288` sets it true; if `lineFragmentRows` or `ensureLayout` in between raises an Objective-C exception (not unlikely in the implicit-downgrade scenario), that layoutManager stays in contiguous layout mode for the rest of the process, and every subsequent typeset/scroll gets more expensive. The current code has no Swift `throw` path, so this is not a certain bug, but it is a textbook case of "incomplete flag restoration".
5. **No regression coverage**: `GutterSnapshot.swift`'s `layoutGutter` carries the explicit comment "Detached `EditorPane`. It never calls `XYZMacEditor.makeNSView` and never reads `layoutManager`, so a pass here does not mean the window drew numbers." (`:1279-1281`); that is, `checkEditing` (`:1240-1265`, which asserts `api == "textLineFragments"`) verifies the TK2 path, **not the TK1 path that production uses**. The production path only has `renderProductionEditors`'s 28-row small sample (`:68-81,183-232`), with no narrow-window wrapped skipped-number scenario and no "line numbers after editing" check. The concrete failures `1,2,3,13,22,23` in CHANGELOG therefore have no corresponding automated case (P2-14).

In addition, `GutterSnapshot.swift` and `LineNumberGutter.swift` each maintain their own line-number source; `XYZCore/LogicalLineGutter.swift` holds a third set, `labels/editingLabels/readingLabels` (`:11-41`), but the live code uses only `highlighted` (`LineNumberGutter.swift:88-92`), and the rest appears only in unit tests (`XYZCore/Tests/XYZCoreTests/TextFindTests.swift:73-128`).

### 1.4 The per-draw performance cost

The redraw trigger paths of `LineNumberGutter`:

- selection change → `textViewDidChangeSelection` (`XYZMacEditor.swift:1405-1409`) → `caretMoved` (`:632-643`) → `editorPane?.gutter.needsDisplay = true`;
- text change → `lineNumbersChanged` (`:625-629`) → `invalidateLines()` + pane `needsLayout`;
- scrolling → `EditorPane.attach` registers the clip-bounds notification (`:961-980`) → `gutter.noteGeometryChanged()` (`LineNumberGutter.swift:41-52`);
- the text view's own `layout()` also calls `editorPane?.noteTextLayout()` (`XYZMacEditor.swift:584-598`) → `gutter.noteGeometryChanged()`.

The geometry key is de-duplicated (`:42-52`), but the row count/current row in the key come from a possibly stale `LineIndex` (P1-2). **As long as "TK1 + wrap on" holds (the default setting is wrap on), every redraw reaches the whole-document `ensureLayout` at `:320`**; typing/scrolling in a large document therefore costs main-thread O(n) work (§6-H2).

---

## 2. Editing Correctness

### 2.1 Markdown list continuation/indentation (`XYZCore/SourceEditing.swift`)

- Continuation: `newline(in:selection:)` (`:57-83`). The logic: it handles only a zero-length selection, outside a code fence (`:61`), where the current line has a list marker (`:64`), and the caret must already be past the marker region (`:66`); an empty list item calls `closeEmptyItem` (`:68-69,109-132`), deleting the marker (or one level of indentation) to implement "press Return on an empty item to leave the list".
- Indent/outdent: `indent/outdent` → `shift` (`:134-183`), rebuilding the text line by line for a multi-line selection; it changes anything only if at least one line carries a list marker (`:175`), otherwise it returns nil and the platform view falls back to a native Tab (mac `XYZMacEditor.swift:96-108`; iOS Tab goes through an `insertText` override, `XYZIOSEditor.swift:80-85`).
- Ordered lists: `orderedMarker` parses the number and adds 1 on continuation (`:321-348`); task-list continuation always emits `" [ ] "` (`:297-313`).
- Fence detection: `insideFence` (`:377-391`) scans from the start of the document to the caret line — **an O(position) scan on every Return/indent**; pressing Return repeatedly in a long document costs more the later it is (part of §6-H1).
- Continuation detail: `:73-75` swallows one space only when the character to the right of the caret is a space (`replaced = 1`), so that `- |item` does not become two spaces; this is deliberate.

Potential defect: `shift`'s `locationShift/lengthShift` computation (`:142-178`) for a "multi-line selection" versus a "zero-length selection" compares line starts only. If the selection start is mid-line and that line gets indented, the offsets after the caret's line do get +2 correctly, but when *the selection start is inside the same line* the condition `line.location <= selection.location` holds and +2 is applied too, which matches expectations; an edge case (selection end exactly at a line start) counts one extra lengthShift, a P2-level detail that this static check does not settle (needs XCTest coverage). `SourceEditing` itself already has tests (`XYZCore/Tests/XYZCoreTests/TextFindTests.swift:73` — the SourceEditing test file beyond that vicinity was not checked within this task's scope, marked as to be confirmed).

### 2.2 Undo and the document scene's undo manager

- Document scene: `DocumentEditorView` takes `@Environment(\.undoManager)` from the SwiftUI environment (`DocumentEditorView.swift:34`) and passes it to `XYZEditor(undoManager:)` (`:124-141,143-158`) → `XYZMacEditor/XYZIOSEditor` → the platform view.
- macOS: `XYZMacTextView` overrides `undoManager` to return `documentUndoManager ?? super.undoManager` (`XYZMacEditor.swift:43-45`); `allowsUndo = true` (`:1065`). The SwiftUI scene tracks dirty via undo registration (comment at `MarkdownFileDocument.swift:10-12`; `MarkdownFileDocument` only stores text in `storeEditorText` and never calls `updateChangeCount`, `:47-58`).
- On a programmatic replacement (disk reload/switching files) only `disableUndoRegistration` wraps `textView.string = replacement` (`XYZMacEditor.swift:1376-1393`), and the undo stack is **not cleared**.
- The repository contains no `removeAllActions` call at all (grep result is empty); the folder window reuses the same `XYZMacTextView` across several tabs (the `editor` branch at `WorkspaceView.swift:1626-1658` is not rebuilt per tab; a change of `session.buffer?.editorToken` only triggers `perform(.replaceContents)`). A probe on this machine confirms: after `textView.string = "XY"`, `canUndo` is still true, and performing undo throws `NSRangeException` outright (§7.4-B). This is **P0-1 (crash + potential data corruption)**.

### 2.3 Marked text / input methods

- mac: `restyle` is skipped while `hasMarkedText()` (`XYZMacEditor.swift:1425-1439,1445,1468`); `applyMarkupEdit/applySourceEdit` guard as well (`:117,132`). iOS: `applyMarkupEdit` guards `markedTextRange == nil` (`XYZIOSEditor.swift:98`).
- But during composition `textDidChange` still pushes `textView.string` (including marked text) to `onTextChange` (`XYZMacEditor.swift:1440`), and the workspace buffer treats it as a user edit and queues an autosave (`WorkspaceSession.swift:1750-1766,1881-1895`); it pushes once more when composition is cancelled. The final text is usually correct, but **disk/autosave may briefly write the pinyin under composition**.
- `perform(.replaceContents)` has no `hasMarkedText()` check (`XYZMacEditor.swift:1376-1393`); if a reload triggered by an external disk change arrives mid-composition, it replaces the string and loses the composition. `docs/architecture.md:29` and `CHANGELOG.md:44` say of themselves "Real IME composition is not covered here / A real Chinese input method was not run", and the code agrees with that: only shallow protection was done. Ranked P2-9.

### 2.4 Selection and find & replace (including regex / whole word)

- Editor side: `FindQuery` (`TextFind.swift:4-16`); `matches` uses `NSRegularExpression`, applying `escapedPattern` first when not regex; whole word uses the lookaround `(?<![\p{L}\p{N}_])…(?![\p{L}\p{N}_])` (`:138-148`); an invalid regex becomes nil through `try?` → `isValid` is false (`:91-93`), and the UI shows `regexInvalid` (`EditorChrome.swift:28`; `XYZMacEditor.swift:360-374`).
- The whole find flow runs in the background: `scheduleReveal` runs `FindScan.make` in a `Task.detached` (`XYZMacEditor.swift:333-350,451-510`), with a generation to reject stale results (`:339,346`).
- **replaceCurrent / replaceAll / selectNextOccurrence scan the whole text synchronously on the main thread**: `TextFind.matches(in: string, ...)` (`XYZMacEditor.swift:514,540,569`; `TextFind.swift:29-39`), and `replaceAll` additionally runs `NSRegularExpression.matches` over the whole text + reverse replacement (`TextFind.swift:66-79`). In a large document (≤5 MB) this visibly stutters (§6-H7).
- replace's undo: `applySourceEdit` uses `beginUndoGrouping/endUndoGrouping` + `defer` (`XYZMacEditor.swift:130-144`), one undo group per replace; `replaceEvery` replaces the whole text with a new string (`:538-549`), undo restores the old full text, so the behavior is correct.
- Find on the Reading side goes through WebKit's `WKFindConfiguration` (`ReadingSurface.swift`, inside `MarkdownWebView.swift:364-382`) or its own JS highlight (`xyzHighlightFind`, `MarkdownWebView.swift:901-962`); both differ from the editor implementation (P2-10). Replace within Reading just beeps (`EditorChrome.swift:144-145`), consistent with the README's note that this row is only used for Editing.
- Selection: mac supports inserting into multiple selections (`XYZMacEditor.swift:234-245`), `selectNextOccurrence` (`:551-582`); `applySelectionChrome` updates the selection color when the appearance changes (`:55-64,1276-1282`). `paste` is forced to plain text (`:47-49`), and `changeFont/changeColor` are disabled (`:51-53`), so rich text cannot pollute the buffer.

### 2.5 Line-number logic: indeed two (in fact three) implementations

1. live mac gutter: `LineNumberGutter.placedRows` (`LineNumberGutter.swift:154-179`) computes `showsNumber` itself (number on the first fragment, empty on wrapped continuations), and `draw` uses only `XYZCore.LogicalLineGutter.highlighted` to choose the current-line band (`:88-102`).
2. `XYZCore/LogicalLineGutter`: `labels/editingLabels/readingLabels/placedReading` (`LogicalLineGutter.swift:11-121`) implement the complete "visual row → source line" mapping, but the live code uses only `highlighted` (`:23-25`), and the rest only in unit tests (`TextFindTests.swift:73-128`).
3. Reading's JS line numbers: `xyzLayoutGutter` (`MarkdownWebView.swift:1041-1108`) exists in full, but `PreviewPrefs.script` always calls `setLineNumbers(false)` (`:51,55-63`), `data-lines` is never `"true"` (`:1048-1054`), and the `xyzGutter` message handler (`:473-494`) never receives a count. Since 0.5.26 Reading explicitly has no line numbers (`CHANGELOG.md:55`), so this is dead code.

### 2.6 Wrapping and the current-line band

- band: `drawBackground` → `drawCurrentLineBand` (`XYZMacEditor.swift:682-705`). With wrap on it uses `currentLineBand()` to take the TK2 fragment's `layoutFragmentFrame` (`:667-680`); with wrap off it degrades to "the (line-1)-th uniform line box" (`:699-701`), consistent with `lineBoxHeight()` (`:744-748`, which uses the editor font); but the gutter's `lineBoxRows` uses the gutter font (P1-3), so with wrap off and low line spacing the band and the numbers are misaligned (the band follows the editor box, the numbers the gutter box).
- When the selection changes the band is refreshed by `caretMoved`'s `setNeedsDisplay(previous/next)` (`:632-643`); the band is drawn only when `isEditable` (`:685`).
- Indent guides: `drawIndentGuides` (`:708-742`) likewise positions by "uniform line box" (`:712-715`), and uses `lineIndexCache ?? LineIndex(string)` (`:711`) → reusing a possibly stale index (P1-2).
- The TK2 branch's band depends on `textLayoutManager` (`:667-680`), but at runtime on macOS that value is nil, so with "wrap on" the band in fact always fails `currentLineBand()` → falls into the uniform box branch? Note that `drawCurrentLineBand`'s test is `if style.wraps, let laid = currentLineBand()` (`:694`): under TK1 `currentLineBand()` returns nil, so it enters the `else` uniform line box branch (`:696-701`). Therefore on the real macOS production path (TK1), **with wrapping the current-line band is also a uniform line box and does not cover the several visual rows of a wrapped line**; this contradicts the comment at `:690-691`, "Wrapping uses the laid-out fragment, which covers every visual row of that line" (P2-11; degraded behavior, but no crash).

### 2.7 The 5 MB large-file and read-only paths

- Opening: `WorkspaceSession.readForEditing` (`:1564-1607`) first reads an 8 KiB sample (`WorkspaceFileClassifier.sampleLimit = 8_192`, `WorkspaceFilePolicy.swift:28`) to classify; >5 MB → `.tooLarge`, `FileOpenRouting` → `.readOnlyPreview` (`WorkspaceFilePolicy.swift:196-213`), and the editor branch shows "File Too Large / Open with Default App" (`WorkspaceView.swift:1467-1481`).
- Read-only preview: 2 MB truncation (`TextBytes.previewByteLimit`, `TextBytes.swift:103`; `WorkspaceSession.swift:1597-1607`), marked by `WorkspaceFileBuffer.previewTruncated` (`:1660-1663`), with the status bar showing "Preview truncated" (`WorkspaceView.swift:1488-1490`); for `.readOnly`, `isDirty` is always false and `userEdited` returns immediately (`WorkspaceSession.swift:1657-1658,1750-1752`), so it is never saved.
- The >5 MB case cannot arise inside the editor; but a 3–5 MB file is still read in full as a Swift String into `NSTextStorage`, and every keystroke goes through `onTextChange(String)` → buffer → preview bridge → outline as a full-document propagation (§6-H4); this is the cost that still needs attention beyond "the 5 MB limit".
- Read-only (Reading) path: non-Markdown Reading reuses the same text view with `isEditable=false` (`EditorViewMode.swift:66-77`; `WorkspaceView.swift:1559-1573`), and the band/indent guides/find-and-replace are all disabled by `isEditable` or `EditorModeChoice`; Markdown Reading is a WKWebView (`WorkspaceView.swift:1574-1576,1619-1625`).

---

## 3. The Preview Side

### 3.1 Creating, reusing and destroying the WKWebView

- `PreviewWebHost` lazily creates the `WKWebView` and `PreviewWebCoordinator` (`MarkdownWebView.swift:17-41`): on the first access to the `webView` getter it calls `PreviewWebViewFactory.make()` (`:24-34`), and reuses it afterwards.
- Owners: the folder window uses `WorkspaceSession.previewHost` (one per window, `WorkspaceSession.swift:108-109`); the document window uses `DocumentEditorView`'s `@State webHost` (one per document window, `DocumentEditorView.swift:39-40,51-52`). So the fact is "one per window, reused across notes"; "One web view for one open note" at `MarkdownWebView.swift:16` is wrong (P2-12).
- Destruction: there is no explicit `dismantle`/teardown; when leaving Reading, `ReadingSurface` removes the webview from its superview (`MarkdownWebView.swift:246-260`, iOS `:405-413` + `claim()` `:425-430`), but the host still holds the webview until the window/session is released. This is the intentional design described in the README ("The view stays with the window").
- Note: the document window unconditionally does `commands.readingWeb = webHost.webView` in `macBody.onAppear` (`DocumentEditorView.swift:209-212`), so **even if the current file is not Markdown, or the window stays in Editing forever, a WebContent process is created for every document window** (P2-13).

### 3.2 How the shell is loaded only once

- State machine: `didStartLoad`, `isReady`, `pendingHTML/appliedHTML`, `pendingTheme/appliedTheme`, `pendingPrefs/appliedPrefs` (`MarkdownWebView.swift:458-471`).
- First `update` → `loadShell` (`:536-539`), `webView.loadHTMLString(PreviewPage.shell(...), baseURL: nil)` (`:599-607`) — `baseURL: nil` means the page origin is opaque/about:blank.
- Afterwards `update` only stores the latest state in pending, and `push` uses `evaluateJavaScript` for incremental updates: `setTheme/setBase/setPrefs/setContent/xyzRevealLine/xyzReport` (`:609-644`). If `appliedHTML` is equal it is skipped (`:626-630`), so the same HTML is never injected twice.
- Script errors are logged only once (`:466,667-676`) and never reload the shell.
- Process crash: `webViewWebContentProcessDidTerminate` resets all state and calls `loadShell` again (`:569-578`).
- Defect: `didFail/didFailProvisionalNavigation` only write a log (`:557-567`) — they neither retry nor reset `isReady`; if the first shell load fails (a rare case), Reading stays blank until the next `didStartLoad` resets it (P2-15).

### 3.3 Discarding stale renders (PreviewBridge / PreviewModel)

- `PreviewBridge` keeps only `latestText` and a single listener (`MarkdownPreview.swift:10-34`), and the editor `send`s on every change (`WorkspaceView.swift:1645`, `DocumentEditorView.swift:163`, `WorkspaceSession.swift:893`).
- `PreviewModel.schedule` (`MarkdownPreview.swift:46-65`): first `task?.cancel()`, `generation += 1`; render after 220ms (420ms when >120KB), then publish only if `generation == token` (`:62`); `publish` also de-duplicates with `html != rendered` (`:76-79`). When `immediate` and ≤20KB it publishes synchronously (`:50-53`); renders above 20KB go to `Task.detached` (`:67-74`). This is what the docs call "PreviewModel drops a render when a newer one has been scheduled". **Holds**.
- Detail: `adopt` does nothing for files >20KB (`:82-85`), so a large document's first shell has an empty `<article>`, and content is injected only afterwards (`:626-630`) — the user sees Reading blank first and then the content appear.

### 3.4 Message passing and WKScriptMessageHandler

- Registration: `add(coordinator, name: "xyzAnchor"/"xyzGutter")` (`MarkdownWebView.swift:29-30`), with no matching `removeScriptMessageHandler`.
- Reference graph: `WKUserContentController` strongly holds the coordinator; `PreviewWebHost` strongly holds the webview and the coordinator; the coordinator holds neither the host nor the webview (`scrollLink.capture` and the reveal closures are both `[weak self, weak webView]`, `:525-534`). So **no retain cycle/leak was found**; but the lifetime is tied to the window — while the window lives, neither the coordinator nor the page is released, and the `setInterval`-style `xyzScheduleGutter` in the page keeps running. If frequent multi-window open/close is needed later, `removeScriptMessageHandler` should be added (P2-12).
- Performance: the page calls `xyzReport()` on every frame of the `scroll` event (`:1257`); the coordinator's `didReceive` runs on the main thread (`:473-518`), and every message also calls `scrollLink.onViewportLine` under `MainActor.assumeIsolated` (`:504-506`) → SwiftUI state updates. Scrolling a long document is therefore high-frequency WebContent→UI-process IPC (§6-H9).

### 3.5 The 220ms debounce and typing latency

- 220ms / 420ms (`MarkdownPreview.swift:56`), consistent with the README's "about 220ms (a little longer for a large note)"; `syncLimit` is 20,000 (`:41`).
- Typing latency chain: `textDidChange` → `onTextChange` (synchronous, full text) → `PreviewBridge.send` → `schedule` (cancels the old task) → render 220ms later. For large documents (>20KB) rendering happens on a background thread, and the main thread only handles the final `publish` and the SwiftUI update; but the `innerHTML` replacement after `setContent` and the `hljs` highlight (at most 400 code blocks, `MarkdownWebView.swift:1129-1133`) both run on the WebContent process's main thread (§6-H5).

### 3.6 The sandbox exception (network client) and the attack surface

- The macOS entitlements include `com.apple.security.network.client` (`XYZ/XYZ-macOS.entitlements:7`); the iOS entitlements do not have that key (`XYZ/XYZ-iOS.entitlements`, full file).
- The README's wording is "so the web content process can start" (`:16,134`). From the static code one can only confirm: this is an **app-level network permission**, not preview-specific; the current renderer does allow http/https images (`HTMLRenderer.swift:482`), so the permission does have real uses. It also genuinely enlarges the attack surface: page JS is fully enabled (`MarkdownWebView.swift:435`), the shell is built by string concatenation, and once the WebContent process is compromised it can reach the network directly.
- Suggestion: if the product goal is "Reading does not go online", tighten `URLPolicy.imageSchemes` to relative paths only (or `xyz-asset`), add a CSP to the shell (`img-src xyz-asset: data:; script-src 'unsafe-inline' …`), and then test in practice whether the network client can be dropped (if WebContent cannot start without it, keep it and document the real reason). See P1-6.

---

## 4. Security

### 4.1 Escaping and URL allowlisting in Markdown → HTML

- Raw HTML: `visitHTMLBlock` emits `<pre class="raw-html">` + `HTMLText.escape` (`HTMLRenderer.swift:128-134`); `visitInlineHTML` is escaped directly (`:279-281`). The escaping covers `& < > " '` (`:448-477`), and attribute values additionally collapse newlines into spaces (`:474-477`).
- Links: `URLPolicy.linkDestination` allows only `http/https/mailto` and "relative paths with no scheme" (`:484-486,492-510`); `sanitize` first rejects control characters (`:496-498`), then explicitly rejects `javascript:/vbscript:/data:` (`:500-502`), and rejects any unknown scheme (`:503-508`).
- Images: `imageSource` allows only `http/https` and relative paths (`:482,488-490`); an absolute `xyz-asset` URL is rejected as an unknown scheme, but **a relative path is resolved through `<base>` into `xyz-asset://…`**.
- Code-block language: `languageToken` keeps only letters/digits/`-`/`_` (`:349-354`), then it goes through attribute escaping; heading ids go through `HeadingAnchor.slug` + `HTMLText.attribute` (`:26-38`, `389-420`); `data-line/data-end` are pure digits (`:326-334`).
- style values such as table alignment come from an enum (`:336-347`) and cannot be injected.
- Injection-surface conclusion: **within this static check no path was found from Markdown content to HTML attribute/tag injection**. `setContent` uses `innerHTML` (`MarkdownWebView.swift:861-872`), but its input is the renderer's output, with the escaping/allowlisting above; the shell's first inlining of `html` (`:854`) is the same. `hljs` uses `ignoreUnescapedHTML: true` (`:877`), avoiding the "re-parse unescaped HTML" risk of older highlight.js versions.

### 4.2 Remote images / the network (contradicts the README)

`imageSchemes` includes `http/https` (`HTMLRenderer.swift:482`), `visitImage` emits them unchanged (`:301-318`), a unit test pins "remote images must be emitted" (`XYZCore/Tests/XYZCoreTests/MarkdownHTMLTests.swift:156` asserts `src="https://example.com/a.png"`), the shell has no CSP, the WKWebView allows content JS (`MarkdownWebView.swift:435`), and the app carries network.client (entitlements:7). So opening a note that contains `![](https://attacker/x.png?note=…)` **silently issues a network request** on the first Reading render: it leaks the IP, the time of opening, and the association between document and user (if the URL carries a unique parameter), and can serve as a read receipt. This directly conflicts with `README.md:16`'s "The renderer still does not request remote images". Ranked P1-6.

(The same mechanism is only of limited use in reverse: content cannot execute JS, so it cannot carry the document body; but see the `xyz-asset` relative-path read below.)

### 4.3 Relative image path resolution and the `xyz-asset` custom scheme

- `<base id="xyz-base" href="…">` is produced by `LocalAssets.baseHref(for: baseDirectory)`: `xyz-asset://local` + the absolute path of the note's directory (`LocalAssets.swift:15-23`), the directory coming from `session.buffer?.url.deletingLastPathComponent()` (`WorkspaceView.swift:1620-1625`) or from `DocumentEditorView`'s `fileURL` (`DocumentEditorView.swift:169-175`).
- Read: `LocalAssets.fileURL(for:)` only looks at the scheme and at whether `url.path` starts with `/` (`LocalAssets.swift:26-31`), with **no canonicalization, no symlink resolution, and no check that the file must lie under baseDirectory**; the handler filters only by the extension `image`/`audiovisual` (`:33-37`), then does `Data(contentsOf:)` (`:58`).
- Consequences:
  1. `![](../../../../<any absolute path>/x.png)` is normalized by the URL into `xyz-asset://local/<absolute path>`, so as long as the target is an image/media file and the sandbox allows reading it, it is displayed. A single document window's sandbox grants only that file, which usually blocks it; **a folder window grants the whole tree, and with several folder windows open the app holds several folders' sandbox extensions at once (`WorkspaceWindowController.swift:41,517`, bookmarks in `WorkspaceFileAccess.swift:228-271`), so note A can display images/media from folder B**.
  2. `LocalAssets.fileURL` ignores the host, so `xyz-asset://anything/…` likewise reads by absolute path; there is no validation that the request came from the current note's directory.
  3. `Data(contentsOf:)` reads the whole file on a background thread (`:57-58`), with no size cap and no Range support for very large videos.
- Contrast: the **link** opening path does enforce a directory constraint — `WorkspaceSession.openLinked` requires `path.hasPrefix(root + "/")` (`WorkspaceSession.swift:360-368`), and hands anything outside the root to `NSWorkspace.shared.open`; the document window's `openFile` instead goes straight to `NSDocumentController.openDocument` (`DocumentEditorView.swift:179-182`). So "images/media unconstrained, links constrained" is asymmetric.
- Ranked P1-7 (security / unauthorized read; the sandbox is the backstop, so this is not arbitrary file reading, but it violates the "note directory only" model and reaches across folder windows).

### 4.4 Other preview security details

- `openIfSafe` calls `NSWorkspace.shared.open`/`UIApplication.shared.open` only for `http/https/mailto` (`MarkdownWebView.swift:686-699`); `file:` and the like are dropped.
- `decidePolicyFor` special-cases only `.linkActivated` and `.allow`s every other navigation (`:580-597`); the content HTML has no executable tags, and `#fragment` is `preventDefault`ed by the page JS (`:1144-1156`), so no input was found that can make the WebView navigate to an arbitrary page.
- Debug builds set `webView.isInspectable = true` (`:449`); Release does not.
- `LocalAssetSchemeHandler.shared` is a singleton, and the `active` set is read/written only on the main thread (`LocalAssets.swift:42-81`); the race handling between `stop` and the completion callback is correct (`:60`).
- `highlight.js` 11.11.1's common bundle is inlined into the shell as a string (`MarkdownWebView.swift:807-816,855-857`); the file contains no `</script` (grep count 0), and that version has no known high-severity XSS advisory (the pre-10.4.1 ReDoS is fixed; 11.11.1 is not in the affected range).

### 4.5 Degradation (when content is blocked)

- An image that fails to load is replaced with `.missing-image` text by the page's `error` event handler (`MarkdownWebView.swift:1120-1142`).
- A code-highlighting failure is swallowed by `try/catch` (`:1132`) and degrades to a plain `<code>`.
- Render failure / script failure: log only (`:557-567,667-676`), and Reading may stay blank (P2-15).
- There is no `WKContentRuleList`/CSP/`WKNavigationDelegate` concept of a "content blocked" degradation; the current implementation has no content filter either.

---

## 5. iOS / macOS Shared-Layer Drift

### 5.1 What is shared

- `XYZEditor` (`XYZ/Editor/XYZEditor.swift`, 411 lines) dispatches by platform to `XYZMacEditor` / `XYZIOSEditor` (`:228-265`); the `XYZTextEditing` protocol (`:117-122`) has only three members — `text`, `textLayoutManager`, `perform(.replaceContents)`; the two Coordinators implement it separately (mac `XYZMacEditor.swift:1304-1481`, iOS `XYZIOSEditor.swift:326-369`).
- Platform-branch density: `XYZ/Editor` + `XYZ/Preview` contain 24 `#if os(` occurrences (23 macOS, 1 iOS; `XYZIOSEditor.swift` is entirely iOS-only). `MarkdownWebView.swift` alone has 11.
- Duplicated code (not a shared implementation):
  - Scroll anchor/restore: mac `scrollAnchor/jump/reveal/alignIfReady/scrollLineToTop/lineOffset/viewportTopLine` (`XYZMacEditor.swift:772-927`) vs the same-named iOS implementation (`XYZIOSEditor.swift:48-196`) — two highly similar ~150-line blocks;
  - `applyMarkupEdit`: mac edits `textStorage` directly (`XYZMacEditor.swift:116-127`), iOS goes through `UITextInput.replace/textRange` (`XYZIOSEditor.swift:97-111`);
  - `perform(.replaceContents)`: mac turns undo off + clears chrome + restyles asynchronously (`XYZMacEditor.swift:1376-1393`), iOS just does `textView.text = replacement` (`XYZIOSEditor.swift:342-351`);
  - styling: mac has ~519 lines of `EditorTypography` (`XYZMacEditor.swift:1483-2001`, heading/marker/code/syntax), iOS has only a 27-line `applyTypingStyle` (`XYZIOSEditor.swift:285-311`, setting font/paragraph only).

### 5.2 iOS feature gaps / inconsistencies (with code evidence)

| Capability | macOS | iOS | Evidence |
|---|---|---|---|
| Line-number gutter | Yes | None | `LineNumberGutter.swift:1` is macOS-only; `lineNumbersVisible` is a macOS-only parameter (`XYZEditor.swift:211-215`) |
| Find/replace | Yes (editor + Reading) | None | The `find` parameter is macOS-only (`XYZEditor.swift:214-215`); `EditorChrome.swift:1`/`EditorFindModel` are macOS-only; `XYZIOSEditor.swift:6` has the comment "future … find/replace" |
| Syntax/Markdown coloring | Yes | None | `syntax` is never passed to iOS (`XYZEditor.swift:254-263`); `applyTypingStyle` sets only font/paragraph (`XYZIOSEditor.swift:285-311`) |
| Font size / line spacing / font / readable-width settings | Applied to the editor | Ignored by the editor | iOS uses the `XYZEditorStyle.markdown` default of 16pt (`XYZIOSEditor.swift:211`) and the `XYZEditorStyle(monospaced:)` defaults (`:286`); the Reading side does use `@AppStorage` (`MarkdownWebView.swift:97-111`) → Source and Reading font sizes disagree |
| Spell-check toggle | Follows the file type | Always on | mac uses `spellCheck` (`XYZMacEditor.swift:1072,1149-1151`); iOS hard-codes `.yes` (`XYZIOSEditor.swift:219`), and `XYZEditor.swift:254-263` never passes `spellCheck` at all |
| Word-wrap toggle | Yes (`wordWrapKey`) | None | `XYZEditor.swift:224-226` is macOS-only |
| Status-bar line/column | Yes (`onSelection`) | None | `onSelection` is macOS-only (`XYZEditor.swift:209`); the iOS call never passes it (`:254-263`) |
| Folder mode / tabs / outline / Go to Line | Yes | None | `WorkspaceView.swift:1` is `#if os(macOS)`; iOS registers only `DocumentGroup` + `ViewModeCommands` (`XYZApp.swift:10-40`) |
| Find within Reading | Yes (ReadingSurface/JS) | None | `ReadingSurface` lives under `#if os(macOS)` (`MarkdownWebView.swift:121-396`); the iOS branch `:398-422` has no find |

Conclusion: the README's "shared `XYZEditor`/`XYZTextEditing`" holds at the protocol level, but the two platforms' implementations share only a skeleton; on iOS the Source side is clearly behind the Reading side (the settings inconsistency is the drift that is easiest to reproduce). Ranked P1-8.

---

## 6. Performance: 8 Concrete Hotspots and How to Verify Them

> The timings below are "should-measure" targets, not values measured in this pass; no app/Instruments run was performed here.

**H1 Full-document attribute rewrite on every keystroke (≤80k characters)**
- Evidence: `textDidChange` → `restyle` (`XYZMacEditor.swift:1422-1441,1467-1479`) → `EditorTypography.apply`: below `immediateLimit = 80_000` it takes `span = full` (`:1484-1486,1579-1585`) and calls `storage.setAttributes([...], range: span)` over the whole text (`:1586-1602`); `styleMarkup` then works line by line (`:1736-1760`), where `fenceIsOpen` scans from the start of the document to the start of the span (`:1762-1776`) and `applyInlineCode` scans character by character (`:1939-1985`).
- Verification: wrap `apply` and `styleMarkup` in `os_signpost`/`SignpostInterval` and record 30 seconds of continuous typing with Instruments Time Profiler + os_signpost; compare 60KB/79KB/81KB Markdown and code files.
- Expected: at ≤80k, main-thread O(n) per keystroke (including per-line string substr); above 80k it jumps to processing only the edited line plus a full pass 280ms later via `laterRestyle` (`:1431-1438`).

**H2 The TK1 gutter's whole-document `ensureLayout` on every redraw**
- Evidence: `draw` (`LineNumberGutter.swift:70`) → `placedRows` (`:154`) → `layoutManagerRows` (`:273`) → `lineFragmentRows`'s `layout.ensureLayout(forCharacterRange: 0..<length)` (`:320`); when the run is skipped, once more (`:282-288`). Triggers: selection change (`XYZMacEditor.swift:632-643`), text change (`:625-629`), scrolling (`EditorPane` notification `:970-978`), view layout (`:596`).
- Verification: add signposts to `LineNumberGutter.draw` and `lineFragmentRows`; open a 300KB/1MB Markdown file (wrap on) and scroll continuously/in a held arrow-key direction; compare whether `layoutManagerRows` is called, and the call count and duration of `ensureLayout`; an environment variable can temporarily toggle `allowsNonContiguousLayout` for A/B.
- Expected: main-thread spikes that grow linearly with document length; this is the primary reason "line numbers are expensive in large documents".

**H3 Every keystroke copies the whole text out of the text view**
- Evidence: `textDidChange` calls `onTextChange(textView.string)` directly (`XYZMacEditor.swift:1440`); `WorkspaceView`'s closure runs `session.buffer?.userEdited(newText)` (a whole-text String comparison, `WorkspaceSession.swift:1750-1766`), `previewBridge.send(newText)`, `wordCount.update`, `outline.update(text:language:)` on every keystroke (`WorkspaceView.swift:1642-1657`).
- Verification: Instruments Allocations + Time Profiler, continuous typing into a 1MB Markdown file; see whether the `String` bridging and the `MarkdownOutline` parse appear in the main-thread flame graph; compare with Show Word Count off / no outline.
- Expected: O(n) copy + one outline parse per keystroke; typing into a 1MB file has perceptible latency.

**H4 Preview re-render + whole-`innerHTML` replacement**
- Evidence: after 220/420ms, `MarkdownHTML.render` (`MarkdownPreview.swift:46-74`; `MarkdownHTML.swift:6-16`), then the coordinator runs `setContent(html)` (`MarkdownWebView.swift:626-630`) → `node.innerHTML = html` (`:861-872`) → `xyzDecorate` re-runs `hljs.highlightElement` on up to 400 code blocks (`:1128-1133`) and `xyzScheduleGutter` (`:1120-1141`).
- Verification: Web Inspector (`isInspectable` is on in Debug) + Timeline; or inject `performance.mark` into the page to time `setContent` to the next frame. Type continuously into a 200KB/1MB note and measure keystroke→paint P95.

**H5 O(blocks) JS scan on every frame while Reading scrolls**
- Evidence: `window.addEventListener("scroll", …xyzReport(); xyzMarkCurrentLine())` (`MarkdownWebView.swift:1257`); in `xyzReport → xyzTop`, `document.querySelectorAll("[data-line]")` and a `getBoundingClientRect()` on each (`:1185-1207`); `xyzMarkCurrentLine` runs `querySelectorAll(".xyz-ln")` again (`:1109-1119`; even though Reading line numbers are off, the function is still called).
- Verification: record a long-document scroll in the Web Inspector Timeline; or temporarily print `nodes.length` and the duration in `xyzTop`; measure scroll FPS with a document of 5000 blocks.

**H6 Find/replace scans the whole text on the main thread**
- Evidence: `replaceCurrent` first runs `TextFind.matches(in: string, …)` (`XYZMacEditor.swift:514`), `replaceEvery` goes through `TextFind.replaceAll` (`:538-548`), `selectNextOccurrence` runs `matches` once more (`:569`); `TextFind.matches` runs `NSRegularExpression` over the whole text (`TextFind.swift:29-39`), and `lineNumber` also takes a `substring` of the prefix (`:126-136`).
- Verification: perform a ⌘⌥F replacement in a 1MB/3MB document; watch main-thread `NSRegularExpression` samples in Instruments Time Profiler; also measure `paintFindMarks` (up to 2000 `.backgroundColor`s, `XYZMacEditor.swift:299-321,1610`).

**H7 Visible flicker during first coloring / scroll catch-up in large documents**
- Evidence: when `full.length > immediateLimit`, `apply` uses `lineSpan(around: edited ?? visibleSpan(in: textView))` (`XYZMacEditor.swift:1579-1585`); `visibleSpan` falls back to `0..<min(len,4000)` while the viewport is not yet established (`:1676-1689`); above 250k Markdown gets no markup coloring at all (`:1594-1600`), and code is colored only when the span is ≤64k. Only the `scheduleVisibleRecolor` 40 ms after scrolling catches up (`:1357-1366`).
- Verification: open a 200KB Markdown/code file, screenshot immediately + `sample`/Instruments; watch the catch-up delay after scrolling; use `-XYZDiagnostics` logs to confirm the `visibleSpan` fallback branch.

**H8 Memory and string copies within the 5 MB limit**
- Evidence: `editLimit = 5_000_000` (`WorkspaceFilePolicy.swift:30`), `.tooLarge` is not read (`WorkspaceSession.swift:1564-1607`); but a 3–5MB file goes fully into `NSTextStorage`, and every keystroke still goes through H3's whole-text propagation; the read-only preview is truncated to 2MB (`TextBytes.swift:103`).
- Verification: open a 4MB `.txt`/`.log` (not Markdown, to avoid markup cost) and measure memory and input latency; use Instruments VM Tracker for `NSTextStorage`/`NSString` peaks; then check whether 5MB+ hits the `.tooLarge` placeholder immediately.

**H9 Round-trip scroll anchoring from Reading → Editor**
- Evidence: Reading posts a message every scroll frame (`MarkdownWebView.swift:1180-1184,1257`) → coordinator `onViewportLine` (`:495-518`); on the Editor side `viewportTopLine` uses `lineIndexCache` (possibly stale, P1-2), and `scrollLineToTop` needs an `ensureLayout` up to the target line (`XYZMacEditor.swift:846-877`).
- Verification: in a long document, scroll in Reading then press ⌘/ to switch to Editing (10 times in a row), recording the requested/landed difference from ViewAnchorLog (`XYZEditor.swift:6-16`) and the switch duration; compare whether `warmLineIndex` runs in time.

---

## 7. Findings List (P0 / P1 / P2)

> Each entry has: conclusion, evidence (file:line), impact, recommendation (including minimum verification steps).
> All line numbers come from this report's own reads; the probes are AppKit-level demonstrations, not results from running the product.

### P0 (crashes / data corruption)

**P0-1 Undo stack is not cleared after switching file/tab: ⌘Z throws `NSRangeException` and crashes, or applies the previous note's edit to the current note (data corruption)**
- Evidence:
  - On programmatic replacement `XYZMacTextView` only disables undo registration; it does not clear the stack: `XYZMacEditor.swift:1376-1393` (`disableUndoRegistration` → `textView.string = replacement` → `enableUndoRegistration`).
  - There is no `removeAllActions` anywhere in the repo (grep: 0 hits); `clearDocumentChrome()` clears only find and selection (`XYZMacEditor.swift:291-296`).
  - In a folder window the same `XYZMacTextView` is reused across tabs: the `editor` branch changes only with `viewMode` (`WorkspaceView.swift:1559-1573,1614-1658`), `onChange(of: session.buffer?.editorToken)` notifies only when the text changes (`WorkspaceView.swift:1440-1455`), and the view is not rebuilt; the tab-switch flow is `WorkspaceSession.swift:888-918`.
  - Local AppKit probe (§7.4-B): after typing `B`, `canUndo=true`; after `textView.string = "XY"` `canUndo` is still true; `undo()` throws `NSRangeException` outright (`NSBigMutableString substringWithRange:` out of bounds, stack `NSTextStorage(NSUndo) _undoRedoAttributedSubstringFromRange:`).
  - CI's undo check only undoes immediately on the same view (`GutterSnapshot.swift:768-788`), so it cannot cover "undo after switching documents".
- Impact: ⌘Z crashes (the first time it enters an old undo group); if the old range happens to fall inside the new text's length, it silently modifies the wrong text, and the following `WorkspaceFileBuffer` autosave writes the error to disk (`WorkspaceSession.swift:1881-1895`) — data corruption.
- Recommendation: call `documentUndoManager?.removeAllActions(withTarget: textView)` (or clear all actions of the current undo manager) in `perform(.replaceContents)` and at the folder window's buffer switch, then replace the string; the more thorough fix is one `NSUndoManager` per buffer (or a per-buffer text storage). The probe has already verified that "`removeAllActions()` first, then `string=` → `canUndo=false`, undo is safe" (second part of §7.4-B).
- Minimum verification: ① reproduce with the probe script; ② in the product: open `a.md` / `b.md` (both short), type in a → switch to b → ⌘Z, and observe the crash or b's content being modified; ③ after the fix the same steps should leave nothing to undo.

### P1 (clear defects / high cost / security)

**P1-2 Stale `LineIndex` cache: after an edit, line numbers, status-bar line/column and Source/Reading anchors are all shifted**
- Evidence: `warmLineIndex` is called only in `makeNSView` (`XYZMacEditor.swift:1124`) and on programmatic reload (`:1386`); `lineIndexCache` is a static snapshot (`LineIndex` stores only the line-start array, `XYZCore/TextStatistics.swift:75-115`). Consumers: `LineNumberGutter.lineIndex()` prefers `textView!.cachedLineIndex()` (`LineNumberGutter.swift:59-68`), `viewportTopLine` (`XYZMacEditor.swift:913`), `viewportLine` (`:920-927`), `drawIndentGuides` (`:711`), `reportSelection → EditorCaret.measure(..., index:)` (`:1411-1420`; `XYZCore/EditorCaret.swift:25-40`). On a text change the gutter clears only its own cache (`LineNumberGutter.swift:35-39`, invoked by `lineNumbersChanged` at `XYZMacEditor.swift:625-629`), and then puts the stale `cachedLineIndex()` straight back into its own cache.
- Impact: after one Return in the middle, every line number below it, the status-bar line number, the outline's tracking line and the Source↔Reading restore line are off by one, and the error accumulates with editing; it may also be confused with the old "line numbers jumped 1,2,3,13,22,23" symptom in the CHANGELOG (that one is more likely a non-contiguous estimate, but the two are hard to tell apart when they stack).
- Recommendation: set `lineIndexCache = nil` in `textDidChange` (or rebuild it asynchronously behind a generation); have the gutter prefer building from the current string; `LineIndex` construction is O(n) and can run in the background, and after `invalidate` the visible segment can be built on demand first.
- Minimum verification: open a 100-line file, put the caret on line 10, press Return 3 times; check whether line numbers below line 20 are 3 lower than reality (gutter + status bar). After the fix, repeat: line numbers should match the text.

**P1-3 With wrap off, the gutter line box comes from the gutter font, so line numbers drift when line spacing is low**
- Evidence: `lineBoxRows` and `emptyRow` use `Self.font(textView.style.fontSize)` (gutter font = 0.75× the font size, minimum 10) to compute `natural` and then take `max(natural, fontSize*lineHeight)` (`LineNumberGutter.swift:23-25,292-304,346-361`); the editor's own `lineBoxHeight()` uses the editor font (`XYZMacEditor.swift:744-748`). Local probe (§7.4-C): 16pt system font natural=18.84, gutter 12pt natural=14.13; at line spacing 1.0 the editor box is 18.84 and the gutter box 16.0 → 2.84pt drift per line; at 1.1 it is 0.84pt; only at ≥1.2 are they equal. The default 1.7 and the tests' 1.2 are both equal, so the existing tests (`GutterSnapshot.swift:1311-1314` sets `lineHeight = 1.2`) and the default path both mask the problem.
- Impact: with line spacing set to 1.0–1.15 and wrap off, line numbers diverge from the text further the further down you go (about 284pt, roughly 10 lines, over 100 lines), and the current-line highlight band is also misplaced (the band uses the editor box, the numbers use the gutter box).
- Recommendation: derive the line box uniformly from `textView.font`/typingAttributes (or extract it into a shared function); add `lineHeight=1.0` + `wraps=false` to the test matrix.
- Minimum verification: set line spacing to 1.0, turn wrap off, open a 200-line file, and check whether line 100's number is several lines away from its text.

**P1-4 Under TK1 + wrap the gutter runs a whole-document `ensureLayout` on every redraw (main thread O(n))**
- Evidence: `LineNumberGutter.draw` (`:70`) → `placedRows` (`:154`) → `layoutManagerRows` (`:273`) → the unconditional `layout.ensureLayout(forCharacterRange: 0..<length)` inside `lineFragmentRows` (`:313-320`); the "skip" decision comes after that full layout pass, and when it does skip it lays everything out once more (`:282-288`). Callers include every selection change (`XYZMacEditor.swift:632-643`), every text change (`:625-629`), every clip scroll (`XYZMacEditor.swift:961-980`) and view layout (`:596`).
- Impact: on the default macOS editing path ("wrap on + line numbers on"), scrolling, typing or moving the caret can each trigger a whole-document layout; the effect grows with file size and runs counter to the intent of `allowsNonContiguousLayout` (which should lay out only the visible area).
- Recommendation: do not `ensureLayout` the whole document; take only the visible range (`glyphRange(forBoundingRect:)`/fragment enumeration); move the "skip detection" after a single visible-range measurement; restore the flag with `defer`.
- Minimum verification: add signposts around the `ensureLayout` in `lineFragmentRows`, then scroll/type continuously in a 300KB wrapped Markdown file and read the per-draw duration and call count in Instruments; remove that line for A/B.

**P1-5 The macOS editor depends on TextKit 1's undocumented "lazy downgrade", and its comments/docs/assertions contradict each other**
- Evidence: TK2 creation (`XYZMacEditor.swift:1058`) → reading `layoutManager` triggers the downgrade (`:1128,1641`); `XYZMacEditor.swift:6`, `XYZEditor.swift:114` and `MarkdownFileDocument.swift:10` still say "TextKit 2"; `XYZIOSEditor.swift:250` has a TK2 assertion but macOS has no corresponding "must be TK1" assertion; the line-number path only branches on `textLayoutManager == nil` at runtime (`LineNumberGutter.swift:129,161`; `GutterSnapshot.swift:200`), and CI does not verify that value; the local probe confirms the downgrade (§7.4-A), and an external project recorded an `NSInvalidArgumentException` (`glyphRangeForTextContainer:`) caused by the lazy downgrade (see the link in §1.1).
- Impact: ① if a future AppKit changes the downgrade behaviour, the code silently switches to TK2 and the `allowsNonContiguousLayout`/`ensureLayout` logic stops applying or becomes meaningless, without any error; ② the lazy downgrade itself carries a stale-pairing crash risk; ③ readers will believe from the comments that they are working on TK2 (README:58 already misleads in this way).
- Recommendation: create the view explicitly with `XYZMacTextView(usingTextLayoutManager: false)` (or keep the implicit path but assert `textLayoutManager == nil` at launch and write a diagnostic log); align the comments and README; write one `-XYZCheckGutter` case for each of the TK1/TK2 branches.
- Minimum verification: append `XYZDiagnostics.note("path=\(textView.textLayoutManager == nil ? "textkit1" : "textkit2")")` at the end of `makeNSView` and check the running log; switch to an explicit `usingTextLayoutManager: false`, run the existing gutter checks, and compare line numbers/scrolling/window screenshots.

**P1-6 The preview allows remote image loading (silent network access), contrary to the README's explicit statement**
- Evidence: `URLPolicy.imageSchemes = ["http","https"]` (`HTMLRenderer.swift:482`), `sanitize` lets them through (`:492-510`), `visitImage` emits `<img src>` (`:301-318`); the shell has no CSP (`MarkdownWebView.swift:838-1271`); network permission sits in the app-level entitlements (`XYZ-macOS.entitlements:7`); README:16 claims "The renderer still does not request remote images".
- Impact: opening a note that contains remote images silently contacts third parties (IP/time/document-fingerprint leak, read receipts), which may trigger alerts outright in enterprise environments; it also gives the network client permission a real use, and that permission itself widens the attack surface if WebContent is compromised.
- Recommendation: tighten the image schemes to relative paths only (local resources loaded via `xyz-asset`); if remote images must be supported, add a CSP `img-src xyz-asset: https:` and state in the UI that "remote images will use the network"; fix the README; then test whether `network.client` can be dropped.
- Minimum verification: write a note containing `![](https://example.com/pixel.png)`, open it in Reading, and watch for requests with `log stream`/Charles/`nettop`; or log img `load/error` in the page's `xyzDecorate`.

**P1-7 The `xyz-asset` scheme has no directory containment: images/media outside the note's directory (including other authorized folder windows) can be read**
- Evidence: `baseHref` uses the absolute path of the note's directory (`LocalAssets.swift:15-23`); `fileURL` checks only the scheme and the `/` prefix, with no canonicalization and no base check (`:26-31`); the handler filters only by extension (`:33-37,48-54`) and then calls `Data(contentsOf:)` (`:58`). Contrast: opening a link does check the root directory (`WorkspaceSession.swift:360-368`); multiple folder windows each call `startAccessingSecurityScopedResource` (`WorkspaceWindowController.swift:41,517`).
- Impact: a malicious or tainted Markdown file can use `![](../../<other authorized dir>/x.png)` to make Reading display images/video that do not belong to this note's folder; across folder windows this is at least unauthorized reading across note trees (paths outside the sandbox are still refused by the system, so it is not arbitrary file reading). Large media also has no size cap and no Range support (`:57-73`).
- Recommendation: after `fileURL`, apply `standardizedFileURL.resolvingSymlinksInPath()` and verify `path.hasPrefix(allowedRoot)`; keep allowedRoot in `LocalAssetSchemeHandler` (one handler instance per webview/session instead of a singleton, or a root maintained per webview); add a file size/type allowlist.
- Minimum verification: put two notes in different folders, write `![](../../B/x.png)` in A, open both folder windows, and check whether A's Reading shows B's image.

**P1-8 The iOS editor ignores settings, lacks rendering and find capabilities, and is inconsistent with the Reading side**
- Evidence: iOS uses the default 16pt/1.7/13pt inset (`XYZIOSEditor.swift:211,285-311`), and `XYZEditor`'s iOS branch passes no font size/font/line spacing/readable width/syntax/spellCheck (`XYZEditor.swift:254-263`); Reading, in contrast, uses the `@AppStorage` font size/line spacing/font/readable width (`MarkdownWebView.swift:97-111`); iOS has no line numbers/find/Reading find (`LineNumberGutter.swift:1`; `XYZEditor.swift:211-215`; `MarkdownWebView.swift:121-396`).
- Impact: after the user raises the font size in settings, iOS Reading grows but Source does not (in fact Source is always 16pt); code files get no syntax coloring on iOS; users cannot find "find" on iPad; the promise of a "shared layer" does not hold.
- Recommendation: extract `XYZEditorStyle` and `EditorTypography` into a cross-platform module (iOS should at least reuse baseFont/paragraphStyle/syntax coloring); move `@AppStorage` up into `XYZEditor` and pass it to iOS; add iOS find (editor + Reading).
- Minimum verification: set 24pt on iOS and screenshot Source/Reading in turn for comparison; open a `.swift` file on iPad and see whether it is colored; check whether ⌘F works.

**P1-9 (performance) Whole-text propagation on every keystroke + full recompute of outline/word count/preview**
- Evidence: see §6-H3; `WorkspaceView.swift:1642-1657`; `XYZMacEditor.swift:1440`. Also `WorkspaceSession.userEdited`'s whole-text `text != lastSaved` comparison (`WorkspaceSession.swift:1750-1766`).
- Impact: typing into a 1–5MB file fills the main thread with string copying/comparison/parsing, producing input latency and memory churn; the preview's 220ms debounce only defers the render — the text itself is copied on every keystroke.
- Recommendation: change `onTextChange` to "dirty ranges + pull" (the protocol comment at `XYZEditor.swift:114-116` already reserves this direction); raise the debounce for outline/word count on large documents, or compute only the visible range; make `isDirty` use a dirty flag instead of a whole-text comparison.
- Minimum verification: type continuously into a 1MB file for 10 seconds and read the `String`/`MarkdownOutline`/`TextStatistics` share in Instruments Time Profiler; compare after switching to dirty-range pushing.

### P2 (improvements)

**P2-10 With wrap off + TK1, the current-line band/indent guides do not cover real wrapped visual rows**
- Evidence: `drawCurrentLineBand` first tries `currentLineBand()` when `style.wraps` (`XYZMacEditor.swift:692-705`), but `currentLineBand` depends on `textLayoutManager` (`:667-680`), which is always nil after the TK1 downgrade, so it falls into the uniform line box branch (`:696-701`); `drawIndentGuides` likewise uses the uniform box (`:708-742`). This disagrees with the comment at `:690-691` and with CHANGELOG:75's "the band uses the same fragment".
- Impact: with wrap + TK1 the band highlights one line's height only, so a wrapped line spanning several visual rows looks incompletely highlighted; indent guides are positioned by estimation in wrapped documents.
- Recommendation: use TK1's `layoutManager.enumerateLineFragments` or `boundingRect(forGlyphRange:)` to get the current line's real range; or change the band's `if style.wraps` to "fall back and accept when no fragment is available".

**P2-11 Text is still reported during IME composition (which may trigger autosave), and reload does not check marked text**
- Evidence: `XYZMacEditor.swift:1425-1440` (restyle is skipped but `onTextChange` is not), `:1376-1393` (replaceContents has no `hasMarkedText` check); `docs/architecture.md:29` and `CHANGELOG.md:44` state themselves that a real IME was not tested.
- Impact: within the autosave window, pinyin that has not been committed may be written to disk (usually overwritten by the correct text afterwards); a reload from disk swallows the composition.
- Recommendation: have `onTextChange` not fire while `hasMarkedText()` (or route it through a separate composition channel), and have `replaceContents` call `unmarkText()` / wait for composition to end first; add a UI case with real PingFang input.

**P2-12 WKWebView lifecycle/message handler is never torn down explicitly, and the document window creates the WebView eagerly**
- Evidence: `add(coordinator, name:)` (`MarkdownWebView.swift:29-30`) has no remove; `DocumentEditorView.swift:209-212` unconditionally touches `webHost.webView` in `onAppear`; `MacMarkdownWebView` has no `dismantleNSView`.
- Impact: each document window keeps a WebContent process and render tree resident, so memory is high; the coordinator/page live as long as the window; even a plain `.txt` document gets a WebView.
- Recommendation: create the webview only when Reading appears; call `removeScriptMessageHandler` + `stopLoading` when the window/document is destroyed; give `DocumentEditorView`'s `readingWeb` a lazy wrapper.

**P2-13 No retry for a failed first preview load, and `isReady` is never reset**
- Evidence: `didFail`/`didFailProvisionalNavigation` only call `logNavigationFailure` (`MarkdownWebView.swift:557-567`); `update` returns immediately when `didStartLoad && !isReady` (`:540-541`).
- Impact: in the rare case of a shell load failure, Reading stays blank permanently until the file switches or the process crashes and resets.
- Recommendation: on failure set `didStartLoad=false` and retry once after a backoff; log to the unified log.

**P2-14 Dead Reading line-number code and two find implementations**
- Evidence: `PreviewPrefs.script` always calls `setLineNumbers(false)` (`MarkdownWebView.swift:51,55-63`), yet the `xyzLayoutGutter/xyzScheduleGutter/xyzGutter` handlers remain (`:473-494,983-1119`); Reading find's JS regex (`:901-962`) and the editor's `NSRegularExpression` (`TextFind.swift:138-148`) are two different semantics (ICU vs JS), and whole-word in JS relies on lookbehind.
- Impact: dead code adds maintenance surface and shell size (it is parsed on every page); read-only users get find behaviour that differs from Editing (e.g. `\p{L}` classes, case folding, zero-width matches).
- Recommendation: delete the Reading line-number JS and handlers; consolidate find semantics into a shared description with each side executing it (or document the differences explicitly).

**P2-15 The 2459-line `GutterSnapshot` CI harness is compiled into the app target and does not cover the production TK1 path**
- Evidence: `GutterSnapshot.swift` is a single 2459-line `enum GutterSnapshotCheck` (`:9`), `GutterSnapshot.swift:4` imports Vision, `:9-51` (`exit()` under `-XYZCheckGutter`), `:409-425`/`:1205-1220` (`cacheDisplay`), `:1003-1016` (`takeSnapshot`), `:1028-1034` (`CGWindowListCreateImage`), `:1156` (Vision OCR); `project.pbxproj:38,328` shows it in Sources (not a separate Check target; the Lead also confirmed it separately with `strings` on the Release binary); CI runs it with `-XYZCheckGutter` (`.github/workflows/ci.yml:87`, verifying window screenshots with Vision OCR). `:1279-1281` states explicitly that the detached harness does not go through `makeNSView` and does not read `layoutManager`.
- Impact: test-only dependencies such as Vision/WebKit/AVKit go into the production binary; the OCR code paths depend on the OS version; the tests cover a detached TK2 pane instead of the actual TK1 window path, so "all tests green but the window is wrong" is easy (CHANGELOG:11 described a similar situation).
- Recommendation: split it into a separate UI test target/helper app and keep it out of the main app; or at least change `layoutGutter` to take the window path through `makeNSView`, and add assertions for both the TK1 and TK2 paths.

**P2-16 Several flag and undo-group restores are written without defer**
- Evidence: `LineNumberGutter.swift:282-288` (`allowsNonContiguousLayout` false→true, no defer); `XYZMacEditor.swift:299-321` (`paintFindMarks`'s `disableUndoRegistration`, no defer); `:234-245` (multi-selection `insertText`'s `beginUndoGrouping`/`endUndoGrouping`, no defer); `EditorPane.layout`'s `clamping` (`:987-1009`), no defer.
- Impact: there is no Swift `throw` path today, but any ObjC exception or future early return would leave the flag permanently wrong (especially undo registration disabled for good → the user's edits become non-undoable).
- Recommendation: replace them all with `defer`; use `defer { enableUndoRegistration() }` wherever undo is disabled.

**P2-17 Syntax colors use the global `NSApp.effectiveAppearance` instead of the view's own appearance**
- Evidence: `EditorTypography.syntaxColor` uses `NSApp.effectiveAppearance` (`XYZMacEditor.swift:1646-1648`), while the editor's other colors use `NSColor.xyzDynamic` resolved by the view (`XYZEditor.swift:296-377`), and the preview follows the window's `colorScheme` (`MarkdownWebView.swift:113-117`).
- Impact: in mixed-appearance windows (e.g. a sheet forced to dark, or windows with a different appearance) the code token colors do not match the background.
- Recommendation: resolve them from `textView.effectiveAppearance`/`textView.layer?.contentsScale`, or make the colors dynamic NSColors.

**P2-18 `TextFind.lineNumber` builds a prefix substring for large documents every time**
- Evidence: `TextFind.swift:126-136` (`ns.substring(with: 0..<utf16)` followed by iterating over unicodeScalars), called in the background by `FindScan.make` (`XYZMacEditor.swift:460-471`) and also used by `matches`' callers to locate results; `replaceCurrent` also recomputes the range on the main thread after `matches`.
- Impact: O(n) allocation per find-result location in large documents; not fatal, but optimizable.
- Recommendation: use `LineIndex` (cacheable) instead of a prefix substring; or reuse the match index already produced by `TextFind.stepDetail` inside `FindScan`.

---

## 7.4 Probes and reproduction evidence

### A. TextKit implicit downgrade (section 1 of `/tmp/xyz_probe.swift`)

```swift
let tv = NSTextView(usingTextLayoutManager: true)
print(tv.textLayoutManager != nil, tv.layoutManager == nil) // true false
_ = tv.layoutManager
print(tv.textLayoutManager != nil, tv.layoutManager == nil) // false false
```

Output:

```
A tk2 before: textLayoutManager != nil: true layoutManager == nil: false
B tk2 after read .layoutManager: textLayoutManager != nil: false layoutManager == nil: false
```

Conclusion: on this machine (macOS 27.2 / Xcode 27.2), reading `.layoutManager` downgrades an `usingTextLayoutManager: true` NSTextView to TextKit 1 and `textLayoutManager` becomes nil — consistent with `docs/architecture.md:15` and `CHANGELOG.md:12`, and contradicting the "TextKit 2" comments at `XYZMacEditor.swift:6` and `XYZEditor.swift:114`.

### B. Cross-document undo stack (section 2 of `/tmp/xyz_probe.swift` / `/tmp/xyz_probe2.swift`)

```swift
let win = NSWindow(...); let tv = NSTextView(usingTextLayoutManager: true)
win.contentView = tv; tv.isEditable = true; tv.allowsUndo = true
tv.string = "AAAA"; tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.insertText("B", replacementRange: NSRange(location: 4, length: 0)) // "AAAAB", canUndo=true
tv.string = "XY"
print(tv.undoManager?.canUndo)      // true  ← the old document's undo action is still there
tv.undoManager?.undo()              // NSRangeException: Range {4, 1} out of bounds; string length 2
```

Output:

```
C after typing: AAAAB undoable: true undoManager class: NSUndoManager
D after set string: XY undoable: true
*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** -[NSBigMutableString substringWithRange:]: Range {4, 1} out of bounds; string length 2'
...
A tk2 after read .layoutManager: ... (elided)
after clear+set string canUndo=false text=XY
```

(The last line is `xyz_probe2.swift`: `removeAllActions()` first, then swap the string → `canUndo=false`, undo is safe.)

Conclusion: `textView.string = …` does not clear the undo stack; the old document's `NSUndoTyping` still points at the same `NSTextStorage`, so undoing on the new document either crashes with an out-of-range error or corrupts the text. The app happens not to clear the stack (P0-1).

### C. Inconsistent line box (`/tmp/xyz_probe2.swift`)

```
editor natural=18.84375 gutter natural=14.1328125
spacing=1.0 editorBox=18.84375 gutterBox=16.0 -> drift/line=2.84375
spacing=1.1 editorBox=18.84375 gutterBox=18.0 -> drift/line=0.84375
spacing=1.2 editorBox=20.0 gutterBox=20.0 -> drift/line=0.0
spacing=1.7 editorBox=28.0 gutterBox=28.0 -> drift/line=0.0
```

Conclusion: with line spacing 1.0–1.1 and wrap off, `LineNumberGutter.lineBoxRows`'s line box is smaller than the editor's, so line numbers drift upward line by line (P1-3); the test harness uses 1.2 (`GutterSnapshot.swift:1311-1314`) and happens to avoid it.

---

## 8. Coverage and Non-coverage Statement

Checked:
- All 7 files in `XYZ/Editor/`; all 3 files in `XYZ/Preview/`; the key rules of `XYZ/Resources/Preview.css` (`:288-290` images, `:319` raw-html, `:350` dark mode) and the version/inlining of `highlight.min.js`; the entitlements; how the CI script runs `-XYZCheckGutter`; resource and source membership in `project.pbxproj`.
- `XYZCore`: the whole of HTMLRenderer, MarkdownHTML, ReadingSource, SourceEditing, LogicalLineGutter, TextFind, SyntaxColoring (first 160 lines + the scan entry point), TextStatistics (LineIndex), EditorCaret, MarkdownFileDocument, EditorViewMode, WorkspaceFilePolicy, TextBytes (preview limit).
- `XYZ/Workspace`: WorkspaceView's fileBody/editor/preview sections, WorkspaceSession's preview/undo/readForEditing/openLinked sections, WorkspaceFileAccess's bookmarks/watching, WorkspaceWindowController's multi-window/security-scope sections, EditorChrome's EditorFindModel/Reading find, XYZDiagnostics, EditorCommands' undo menu trail; the whole of `DocumentEditorView`; the whole of `XYZApp`.
- AppKit behaviour was proven empirically with two probe scripts (TextKit downgrade, undo stack, line box).

Not covered / cannot be verified:
- No `xcodebuild`/app/Instruments run; all performance numbers are targets to be measured; P0-1's AppKit mechanism is proven, but the **in-app** crash/cross-write needs reproducing and confirming per the steps in §P0-1.
- TextKit's lazy downgrade, window compositing, `CGWindowListCreateImage` and similar behaviour on macOS 14/15 were not tested (this machine runs macOS 27.2).
- Real Chinese/Japanese input methods, iCloud, gutter alignment on multi-display/mixed-DPI setups, and the actual network packets of WebKit remote loading were all untested.
- The complex multi-line selection boundaries of `SourceEditing.shift` and the wiki-link/front-matter boundaries of `ReadingSource` were only read statically, not verified case by case.
- The UI acceptance cases in `GutterSnapshot` that are unrelated to this task (explorer clicks, divider drags, etc.) were checked only at their entry points and structure, not item by item.
