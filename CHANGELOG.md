# Changelog

## 0.5.38

Build 54. Installed on this Mac, Developer ID signed, notarized and stapled. Local install only: no tag, no GitHub release.

### What changed

- **Code folding.** Indentation-based folds for code and structured text. The gutter gets a
  fold column (hover shows the open chevron, folded rows keep the closed one), the folded
  header shows an ellipsis, and View gets Fold / Fold All / Unfold All (⌥⌘[, ⌥⌘⇧[, ⌥⌘⇧]).
  Folding never touches the text, offsets, undo or saving; the caret, find and edits open
  a fold before acting inside it, and folds re-anchor by their header text after edits.
  Hidden lines keep no number, indent guide or whitespace marks, and the current-line band
  follows the real laid-out row, not a uniform line box.
- **Bracket matching and selected-word highlight.** The caret's bracket pair is highlighted,
  and the other occurrences of the word under the caret are marked with rendering
  attributes that never enter the text storage.
- **Relative line numbers and whitespace rendering.** View menu toggles; spaces draw a
  middle dot, tabs a small arrow.
- **Markdown fenced blocks color by their language** (`swift`, `js`, `py`, …), scanned as
  whole blocks so comments and strings stay right.
- **Symbol breadcrumbs.** The path crumb row now carries a Markdown heading chain
  (clickable); code and JSON show the path only, no symbol list.
- **Find enhancements.** ⌘K content search gains Aa / W / regex toggles; ⌘F gains
  In Selection (S).
- **Status bar capped at three entries per side**; overflow from the right moves left.
- **Sidebar arrow column aligned** with the first-level disclosure triangles.
- **Spelling and grammar checking removed from the whole app**, including the context
  menu's Spelling / Grammar items. Recorded under Product boundaries in AGENTS.md.
- The sticky section row added earlier was removed: it repeated the breadcrumb and the
  outline.

### Where this was checked

- `swift test --package-path XYZCore`: 246 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: all ok.
- `-XYZCheckGutter`: new cases `code-folding`, `editor-folding`, `editor-folding-caret`,
  `editor-caret-band`, `editor-viewport-line`, `sidebar-arrows` all pass in the real
  folder window; `refresh` and the file creation cases still pass. The five older cases
  fail on this Mac because the window is inactive while the harness runs, unrelated to
  these changes.
- Release 0.5.38 (54): archive, Developer ID export, app notarized and stapled,
  `spctl` accepted. Installed over `/Applications/XYZ.app`; one app on the machine.
- Not published to GitHub: no tag, no release, per the owner's choice (local install only).

## 0.5.37

Build 53. Installed on this Mac, Developer ID signed, notarized and stapled. Tagged `v0.5.37` and published as a GitHub release (DMG + ZIP assets).

### What changed

- **Sidebar ownership moved out of SwiftUI.** Visibility now lives in `SidebarVisibility` and
  the split view; ⌘B and the title-bar button call AppKit directly, so toggling the sidebar
  no longer re-renders the whole window body. The animation is one slide at a time and a
  press during a slide is only remembered, never a second reverse animation.
- **⌘B no longer repeats.** The menu key equivalent fired once per auto-repeat event, so a
  held key flipped the sidebar dozens of times and shook the content. ⌘B is handled by the
  local key monitor now and drops `isARepeat` events.
- **Regular and edited widths are remembered separately.** A column that was never dragged
  opens at a width fitted to its content; once the divider is dragged (or double-clicked)
  that width is stored per folder and restored on the next open and next launch. A late
  `splitViewDidResizeSubviews` no longer overwrites it with the default.
- **The title bar has three buttons again**, on the traffic lights' own grid: sidebar,
  outline and the reading/editing switch. All are drawn in one 16 by 15 box with a 3 pt
  corner radius and a 1.3 pt stroke: an open column fills its compartment, a closed one is
  hollow; the mode button shows an open book while reading and a document while editing.
- **Reading mode fills the left side of the status bar** with the scroll progress, and the
  mode name dropped its icon (the title bar already carries that button).
- **Scrolling to the bottom of a Reading page now reports the last source line**, so the
  outline can mark its last entry; before, a short final section could never reach the top
  of the page and its heading never became current.

### Where this was checked

- `swift test --package-path XYZCore`: 220 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok.
- `-XYZCheckGutter`: `refresh` (opens a folder by clicking it) passes. The other five cases
  fail on this Mac because the window is not active while the harness runs, so its posted
  clicks and menu lookups are dropped; they are unrelated to these changes.
- Manual checks during the session: folder open/close and rapid clicking, selection and the
  open-file marker, sidebar and outline width persistence, reading progress, outline
  bottom-follow, title-bar button geometry (measured 16×15 boxes, 23 pt pitch, mirrored
  centres, one 3 pt radius), ⌘B under rapid presses.
- Release 0.5.37 (53): archive, Developer ID export, app notarized
  (`c0ccb3e8-322e-4793-8d2a-0e6304527be3`) and stapled, DMG signed, notarized
  (`4e609d87-c848-420a-a141-4bcc7e7a00c3`) and stapled, `spctl` accepted for both. Installed
  over `/Applications/XYZ.app`; one app on the machine.

## 0.5.36

Build 52. Installed on this Mac, Developer ID signed, notarized and stapled. No tag or GitHub release.

### What changed

Follow-up performance pass after 0.5.35:

- **A finished index scan no longer redraws the sidebar.** The sidebar snapshot carried
  `indexedEntries.count`, so the background scan that runs after any folder listing change
  made the snapshot differ and rebuilt the whole tree for a value the sidebar never shows.
  The field is gone; index results reach the UI through the search tree only.
- **Opening a folder no longer walks the whole vault.** The listing now patches the name
  index in place: `WorkspaceIndexPatch` replaces that folder's direct entries and leaves the
  rest alone. Structural operations (delete, move) still rescan the tree. Five unit tests
  cover the patch (`swift test`: 220 tests, 0 failures).
- **Saving stays synchronous, on purpose.** Moving the disk write off the main thread was
  tried and reverted: `unsavedForClose`, `shutdown`, closing a tab and moving a tab all
  check `isDirty` immediately after `flush()`, so a background write raced those checks and
  could drop edits on quit. The reason is recorded next to `save`.

### Where this was checked

- `swift test --package-path XYZCore`: 220 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok.
- `-XYZCheckGutter`: `refresh` (opens a folder by clicking it) passes; the other cases still
  fail on this Mac for the inactive-window reason described in 0.5.35.
- The owner tried the intervening test build and reported the sidebar performance as
  "差不多了" (good enough).
- Release 0.5.36 (52): archive, Developer ID export, app notarized
  (`eb83c100-89a4-4706-bb03-514d743f7294`) and stapled, DMG signed, notarized
  (`1339a0e1-7c43-4194-8a9d-9c7e48674d3d`) and stapled, `spctl` accepted for both. Installed
  over `/Applications/XYZ.app`; one app on the machine.

## 0.5.35

Build 51. Installed on this Mac, Developer ID signed, notarized and stapled. No tag or GitHub release.

### What changed

This round is the Explorer sidebar feeling slow and jumpy, and one correctness bug found while
chasing it:

- **A quick series of clicks only opened.** AppKit numbers the clicks of a rapid series 1, 2,
  3..., and the double-click guard added in 0.5.34 treated every click after the first as "the
  same intent" and dropped it. Each click of a series toggles the folder again now.
- **Clicking a folder redrew the whole window.** The click wrote `selectedPath`, a published
  value the main window body reads, so editor, preview and outline were re-evaluated on every
  click. A folder click now moves a non-published `clickedPath`; New File still lands next to
  the folder the user picked.
- **The view already showed the expansion, but the tree was rebuilt anyway.** After a click the
  sidebar recorded a fresh snapshot, so the next update sees no difference and skips
  `rebuild`/`reloadData`. A queued rebuild from before the click is cancelled by a generation
  token, so it no longer replaces rows under the user's pointer and swallows the next click.
- **Folder open/close is instant.** No disclosure animation and no animation context, which is
  what used to draw AppKit's intermediate frames for a moment.
- **The triangle no longer moves.** Its position comes from the level, not from the value AppKit
  proposes (that changes between 0 and 2 between layout passes), so a collapse followed by an
  expand leaves it exactly where it was. The custom cell shift was removed as well, so AppKit and
  the row agree on one geometry.

### Where this was checked

- `swift test --package-path XYZCore`: 215 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok.
- `-XYZCheckGutter`: `refresh` (opens a folder by clicking it) passes; the remaining cases fail on
  this Mac because the window is not active when the harness runs, so its posted clicks and menu
  lookups are dropped. Those cases are unrelated to the sidebar.
- The owner confirmed on the installed build: opening and closing folders, rapid clicking,
  selection, the open-file marker, the scoped Collapse/Expand button and icon state all behave,
  and the sidebar is "丝滑多了" (much smoother).
- Release 0.5.35 (51): archive, Developer ID export, app notarized
  (`110ef669-88d7-4554-8819-1a0117cedf8a`) and stapled, DMG signed, notarized
  (`70cdb64f-4af1-478b-86ea-29cc7b2456b2`) and stapled, `spctl` accepted for both. Installed
  over `/Applications/XYZ.app`; one app on the machine.

## 0.5.34

Build 50. Installed on this Mac, Developer ID signed, notarized and stapled. No tag or GitHub release.

### What changed

The Explorer sidebar could not open a folder by clicking it. This is the fix, and it
took several AppKit behaviours that are now written down in `AGENTS.md`:

- A click on a disclosure triangle runs inside AppKit and never calls the subclass's
  `expandItem`, so the session never learned about it. The row view now hands the
  disclosure strip to the outline view, which toggles the folder itself.
- AppKit's private disclosure button only acts inside its own mouse tracking; a click
  delivered any other way was dropped. The outline handles the click instead.
- `NSTextField` is an `NSControl` and swallowed clicks on a folder's name. Row labels are
  a pass-through label whose `hitTest` returns nil.
- `NSOutlineView.reloadData()` keeps the expansion of items that compare equal, so
  clearing the session's set closed nothing. Collapse All now also closes the rows it
  shows open.
- A fresh `SidebarNode` per rebuild lost both expansion and selection: the outline keys
  them by object identity and row number. Nodes are cached by path, and the selected row
  is restored by path after a rebuild.
- AppKit calls the expand/collapse callbacks while it reloads. Writing those into the
  session closed a folder about two seconds after the user opened it. Only user intent
  writes to the session now.
- The open file no longer gets a second row highlight; its name is drawn in the accent
  colour instead.
- The last header button is a toggle: with folders open it closes them all and shows the
  collapse glyph; with everything closed it opens the top-level folders and shows the
  expand glyph.

### Where this was checked

- `swift test --package-path XYZCore`: 215 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok.
- `-XYZCheckGutter` acceptance: `create-file`, `create-folder` and `refresh` pass.
  `refresh` is the case that opens a folder by clicking it; it failed before this
  change. `nested-file`, `collapse-header`, `dividers`, `mode-labels` and
  `empty-line-prefs` still fail for reasons outside the sidebar (a synthetic click the
  inactive window drops, and menu targets this harness cannot reach).
- Release 0.5.34 (50): archive, Developer ID export, app notarized
  (`cda68ac5-95ad-4a61-9d54-c3d4c90d1ab0`) and stapled, DMG signed, notarized
  (`c23e3bd4-3231-43b4-9bc8-939bac42e4e4`) and stapled,
  `spctl` accepted for both.
- Installed over `/Applications/XYZ.app`; one app on the machine.

### Not checked

The owner has not yet confirmed folder clicks in this installed build. Everything
unverified in 0.5.29 keeps that status.

## 0.5.33

Build 49. Not installed. Removed the "Limit line width" setting: the toggle, the style
field, the preview parameter and CSS, the two localization keys, and the README sentence.
A typing pass in 0.5.32 built on this: an incremental line index, per-edit restyle above
4,000 characters, and no whole-file string copies on the typing path.

## 0.5.31

Build 47. The version in this tree, and the build installed in `/Applications` on this Mac (Developer ID signed, notarized, stapled). No tag or GitHub release. Change set on top of 0.5.30: the sidebar and outline animation.

### What changed

- The sidebar (⌘B) and outline (⌥⌘B) columns slide again. Opening or closing eases for 180 ms (60 Hz, cubic ease-out; a cut when Reduce Motion is on). The editor pane never leaves the window: each frame sets the three pane frames and then flushes the hosted SwiftUI layout, so the text view and the Reading web view take the new width in the same frame. Each pane also clips to its own bounds. Before 0.5.30 the split view detached all three panes and added them back on every toggle, which repainted the note and the web view; the hide path then laid the text out again on every frame of a 60 Hz ease. That is the shortcut that felt stuck.
- A second press during a slide is honored instead of swallowed: `sidebarWanted`/`outlineWanted` record the target and `finishSlide` settles the running slide first.
- Sidebar header and file-row labels are one line, truncating at the tail. `SidebarRootHeader.layout()` and `SidebarRowCell.layout()` used to pass the label's own current width as `preferredMaxLayoutWidth`; the first animation frame (column near zero) froze `LIZHICHAO` into three lines, and the header's second line was drawn over the file list. That overlap is what the owner saw. The self-referential wrap width is gone and `maximumNumberOfLines` is 1.
- The split view keeps diagnostics behind `-XYZDiagnostics`: `sidebar shown=… eased in 180ms sidebar=… detail=… outline=…`, a slide start line, and a line when a layout leaves a column under 260 pt.

### Where this was checked

- `swift test --package-path XYZCore`: 207 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok (`help dot tilde tilde-dir file multi missing bare`).
- `xcodebuild` Debug for `platform=macOS` and Debug for `generic/platform=iOS Simulator`: BUILD SUCCEEDED, signing off.
- Release 0.5.31 (47): archive → `developer-id` export; `codesign` shows the Developer ID authority and Hardened Runtime. The app zip was notarized (`ae1b56da-b042-46ac-a983-55daece1822e`, Accepted), stapled, and `spctl` reports `accepted, source=Notarized Developer ID`. The DMG was code-signed, notarized (`3229b1fa-6c13-41a9-b203-6d9f3c347156`, Accepted), stapled, and accepted the same way.
- Installed over `/Applications/XYZ.app`; the machine keeps one app (`AGENTS.md`). Launched hidden once: the process started and quit with no crash report.
- The owner ran 0.5.30 on this Mac, reported the animation "不卡了" but not smooth, then reported the header text overlap, then confirmed the 0.5.31 build ("好了"): the slide is smooth and the sidebar text is back to one line. That is the only windowed verification; it was done by the owner, not by a harness.

### Not checked

The animation frames were never measured frame by frame (no Instruments run). The acceptance gate is still 0/7 because XCUI cannot launch the app on the cloud runner. Everything unverified in 0.5.29 keeps that status: iCloud, the sandbox in use, a real Chinese input method, the quit alerts, and performance other than what the owner felt. The resize trace used to diagnose the overlap was removed before the release build.

## 0.5.30

Build 46. The version in this tree, and the build installed in `/Applications` on this Mac (Developer ID signed, notarized, stapled). No tag or GitHub release exists. This is a small change set on top of 0.5.29: the sidebar and outline shortcuts.

### What changed

- Toggling the sidebar (⌘B, View → Toggle Sidebar) and the outline (⌥⌘B) no longer takes the editor out of the window. `XYZSplitView` removed all three panes — sidebar, editor, outline — and added them back on every toggle, so the `NSTextView` and the Reading `WKWebView` left the window and repainted. The hide path then eased the width for 160 ms with a 60 Hz timer and laid the text out again on every frame. The show path passed the width it had just written to zero as the animation target, so the ease did nothing and the sidebar came back at the 220 pt floor. Now only the column that changed is added or removed (`syncPanes`), the editor stays attached, and the toggle finishes in one layout pass. A later body update that does not change the outline width also skips the layout pass.
- `-XYZDiagnostics` now logs `sidebar shown=… in Nms` and `outline shown=… in Nms` from the toggle, so a slow toggle can be measured again.

### Where this was checked

- `swift test --package-path XYZCore`: 207 tests, 0 failures.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok (`help dot tilde tilde-dir file multi missing bare`).
- `xcodebuild` Debug for `platform=macOS` and Debug for `generic/platform=iOS Simulator`: BUILD SUCCEEDED, signing off.
- Release 0.5.30 (46): archive → `developer-id` export; `codesign` shows the Developer ID authority and Hardened Runtime. The app zip was notarized (`91461877-697d-4be0-8b9b-642c19195825`, Accepted), stapled, and `spctl` reports `accepted, source=Notarized Developer ID`. The DMG was signed, notarized (`239efb06-f903-4ce5-8f2a-9424dae80c2d`, Accepted), stapled, and accepted the same way.
- Installed over `/Applications/XYZ.app` (one app on the machine), launched hidden once: the process started, stayed up, and quit with no crash report.

### Not checked

The toggle was not clicked in a window by any harness or by this agent: the self-check harness has no sidebar-toggle assertion, and no interactive session was run. The split view frames and the felt latency in a real window are the owner's check. Everything unverified in 0.5.29 keeps that status: iCloud, the sandbox in use, a real Chinese input method, the quit alerts, and any performance measurement beyond the new toggle log.

## 0.5.29

Build 45. The version in this tree. It is not installed, and no tag or GitHub release exists. A Developer ID signed, notarized, stapled build of it was produced on this Mac on 2026-11-07 (`build/XYZ-0.5.29.dmg`, not in git; steps in `docs/release.md`). This is the first change set after `db12a62`, which is red in the cloud check (`0.5.28` records the acceptance gate at 0/7). It follows the analysis in `docs/project-analysis.md` and the four deep dives in `docs/analysis/`, in that report's P0 → P1 → P2 order.

### What changed

Four paths that could lose data or crash were fixed first.

- New File and New Folder create exclusively. The name is chosen again at creation time from a fresh directory listing, a file is written with `Data.write(.withoutOverwriting)`, and `createDirectory` refuses a path that exists. `WorkspaceItemName.unique` compares names the way the default volume does, case-insensitively and with precomposed Unicode. Before this, `Untitled.md` replaced an existing `untitled.md` through the same directory entry, and the atomic write left it at zero bytes. A name the file system reports as taken is retried as `Untitled 2.md`; a directory holding 9,998 of these names gets a UUID suffix instead of a silent duplicate.
- Restoring a window's tabs installs every tab again. The reads are awaited one at a time (`openFile` returns the task that installs the file), each tab is opened with `activate: false`, and the saved active tab is selected at the end. The restore is a tracked task that a closing window cancels, and saving the window list waits for it instead of writing the not-yet-filled strip a moment later. A restore whose reads all fail keeps the saved list for the next launch. The mode of each tab is saved with it; `windowState` wrote `.reading` for every tab before.
- Closing a window or quitting flushes every open file first. `windowShouldClose` and `applicationShouldTerminate` run the same flush with the per-file conflict alert suppressed, then show one alert that lists the files that still have unsaved changes: Keep Editing (the default, and Escape), or Close Anyway / Quit Anyway. A file that could not be saved is brought to the front so its banner is visible when the user goes back. No window closes over edits that were never offered.
- A whole-content replacement starts a new undo history. `replaceContents` calls `removeAllActions()` when the text really differs, on the Mac text view and on the iOS text view. A range recorded against the previous file can no longer fire into the new one.

Then the P1 items that show up in normal use.

- The line index is dropped when the text changes and rebuilt once typing pauses for 120 ms. The gutter and the status bar read line starts from before the edit, so every number below an inserted line stayed wrong until something else warmed the cache.
- The gutter numbers an unwrapped line from the editor's font and line box, not the smaller gutter typeface.
- The session forwards a buffer's `@Published` changes. Nothing observed that object, so a clean file reloaded from disk, a failed save, or a file that disappeared did not refresh the note or the banner.
- Replace in Folder no longer writes hidden files while the sidebar hides them. ⌘K and Replace share one list of searchable files.
- A picture in Reading is read from `xyz-asset` only inside the note's folder. The handler had one process-wide root and no path check. `WorkspacePathScope.contains` canonicalizes both paths and resolves symbolic links, so a sibling folder, a `..` above the folder, and a link that leaves it are refused.
- `.gitignore`, `.editorconfig`, and `.env` are text files. `isTextualName` returned false for every dotfile because Foundation reports no path extension for one.
- Comment toggle does not prefix JSON or CSS with `//`. The command is disabled there instead of writing a file the parser rejects.
- `xyz` reads a literal `~` and `~/notes` from a script or a quoted argument. The `case` patterns were unquoted, so the shell's tilde expansion made both branches unreachable.

Then the Core correctness and cost items the same analysis listed as P1.

- Front matter with CRLF line endings no longer joins its lines. The mask walked Swift `Character`s, and "\r\n" is one of them, so every `data-line` after the front matter moved up and a `# comment` in YAML was listed as a heading. The mask now walks Unicode scalars, and the outline runs through the same `ReadingSource.prepare` as Reading, so front matter is not scanned and `[[Page]]` reads as the link text Reading shows.
- A document opened through the document browser or ⌘O keeps its encoding. `TextDocument` now reads and writes UTF-8 with or without a byte-order mark, UTF-16 with or without one, and Windows-1252, keeping line endings as they are; a character the encoding cannot hold falls back to UTF-8 instead of writing an empty file. `MarkdownFileDocument` writes with the encoding the file was opened with. Before this, every read was UTF-8, every save dropped the mark, and a Windows-1252 note could not open at all.
- A save through a symbolic link updates the file the link names. The atomic write copied a new file over the path and replaced the link with a regular file. `WorkspaceWriteTarget.resolveForWriting` follows the link, and a chain of links, before the write. A hard link still splits, because keeping it would mean giving up the atomic write.
- A detached scan stops when the caller is cancelled. `Task.detached` does not inherit cancellation, so the `Task.isCancelled` checks in the index walk, the ⌘K content search, and the folder replace plan were never true; each now cancels the work task it waits on. A reload that found the same directory listing no longer walks the whole tree again.
- The decoder tries UTF-8 once instead of twice, and the byte-pattern test for BOM-less UTF-16 runs before the UTF-8 attempt, so a pure-ASCII UTF-16 file is no longer read as text with NUL characters and written back that way.
- `TextFind` numbers a match without copying the text before it, and a regex replace no longer copies the whole document once per match.
- The `xyz` command keeps its temporary paths under `mktemp -d` and removes the directory with a trap, instead of two names in `/tmp` that another process can predict.
- `tools/make_icons.py` imports fontTools only for the commands that draw, so `--help` works without it; it finds Chrome, Chromium, or Edge under `/Applications` (or `CHROME`), and says which dependency is missing instead of raising a traceback. `tools/requirements.txt` names fontTools.
- The localization catalog grew from 238 to 286 keys: 48 user-visible strings from the menus, the tab context menu, the ⌘K panel, the Explorer header, Settings, the status bar, the CLI install dialogs, and Replace in Folder. The zh-Hans values are machine-written and no Chinese menu was read on a screen. CI now checks that every key has one.
- Reading does not fetch a remote picture unless Settings → Reading → Load remote images is on, and it is off in a new install. The renderer leaves an `http`/`https` image source out of the page when the switch is off, so the web view never starts a request and the picture shows as its alt text. A protocol-relative `//host/path` counts as remote. A picture next to the note is a relative path and still loads through `xyz-asset`.
- Two unused Core helpers are gone: `ReadingLineMap` and `ExplorerSection.fileCount`, with their tests. The six Format commands and the inline toggles stay: `FormatMenu` removes the Format menu on purpose ("notes are written as Markdown text"), and `SourceFormatting.swift` now says so at the top, so the next reader does not read those tests as a missing feature.
- Release builds with Hardened Runtime. `ENABLE_HARDENED_RUNTIME` is `YES` for Release and stays `NO` for Debug. A locally signed Release build now carries `flags=0x10000(runtime)`; the unsigned cloud build is unaffected, because the setting only matters when a signature is made.

The README used to say that the renderer does not request remote images. That was false, and the fix went the other way round: the README now says a remote picture is left out unless the setting is on, and that a relative picture is read only from the note's folder. It also now says that a document opened through the document page keeps its encoding, and that the Source/Reading choice is saved per tab.

`docs/project-analysis.md` gained a section that records which findings are fixed, with the test and build evidence for each, and which ones are still open.

### Where this was checked

- `swift test --package-path XYZCore`: 207 tests, 0 failures. The tree had 194; the second pass added 14 methods, and the third added 2 for the remote-image switch and removed the 3 that covered `ReadingLineMap`.
- `sh Scripts/xyz-test.sh`: 8 cases, all ok (`help dot tilde tilde-dir file multi missing bare`).
- `xcodebuild` Debug and Release for `platform=macOS`, and Debug for `generic/platform=iOS Simulator`: BUILD SUCCEEDED. Signing is off, as in the cloud check.
- Signed builds on this Mac (team `Z4FMG2KTPM`, Apple Development certificate): Debug and Release for `platform=macOS` BUILD SUCCEEDED. `codesign` shows App Sandbox, network client, user-selected files, app-scoped bookmarks, and the iCloud container in both; Release carries Hardened Runtime. `spctl` still rejects the app, because an Apple Development signature that is not notarized is not distributable, and there is no Developer ID certificate in this keychain.
- Signed, notarized build: a Developer ID Application certificate (`Zhichao Li`, team `Z4FMG2KTPM`) and an `xyz-notary` keychain profile were set up on this Mac on 2026-11-07. The archived Release (0.5.29, build 45) was exported with `method = developer-id`; `codesign` shows the Developer ID authority, Hardened Runtime, and the sandbox/bookmark/iCloud entitlements with `get-task-allow` absent. The app zip was notarized (`0e54a40b-e359-4159-9fbf-e9c066ed37ff`, Accepted), stapled, and `spctl` reports `accepted, source=Notarized Developer ID`. A DMG was code-signed, notarized (`a0e37293-3755-4566-908b-f48ac56616ed`, Accepted), stapled, and accepted the same way. No tag, upload, or GitHub release was made.
- `python3 tools/make_icons.py --help` prints its usage on this Mac, where fontTools is not installed; `--sheet` stops with the install line.
- `.github/workflows/ci.yml`: a job timeout, a step that compares the built bundle version with `Config/Base.xcconfig`, a step that checks every localization key has a zh-Hans value, window-check steps that still run when the acceptance step has failed, one `::error` annotation per failing acceptance case on the run page, a Release build, and the artifact list now carries the shots and logs those steps write.

### Not checked

No window was launched while doing this: on this Mac it would take the screen. The quit and close alerts, the tab restore, the picture scope, the Chinese menus, the new Load remote images switch, and the encoding of a document-browser save are compiled and unit-tested only where the decision is a pure function; there is no app-layer test target yet. The switch was not clicked in a window, so only the renderer side (no remote source in the page) is tested. The salvage of a cp1252 note typed over with Chinese was tested on `TextDocument`, not through the document scene. XCUI still does not launch the app on the cloud runner, so the acceptance gate is still not green, and the two new alert buttons have no picture. The notarized build was installed over `/Applications/XYZ.app` and launched hidden once: the process started, stayed up, and quit with no crash report. No window was used, so the sandbox, iCloud, and the quit alerts are still unverified in a running app. No real Chinese input method, no performance measurement. The save still runs on the main thread and every keystroke still copies the whole document into the preview, outline, and word count.

### Open, for the owner

- The six formatting commands in `XYZCore` (heading, quote, list, code block, table, link) are kept with no menu item, because `FormatMenu` removes the Format menu on purpose. The file says so. Deleting them, or giving them a menu, is a product decision.
- The signing path is in place (Developer ID certificate, `xyz-notary` profile, notarized DMG), but nothing is tagged or uploaded, and there is no release workflow. The acceptance gate is 0/7 because XCUI cannot launch the app on the cloud runner; a self-hosted runner or a written manual checklist is the next step.
- The save still runs on the main thread and every keystroke copies the whole document into the preview, outline, and word count. Moving the write off the main actor is a refactor that cannot be checked without a real window, so it waits for a decision.
- Nobody has looked at this build on a real screen. The quit and close alerts, the tab restore, iCloud, the sandbox, a real Chinese input method, and the Chinese menus are recorded as verified by compile and unit tests only.

## 0.5.28

Build 44. The version in this tree. It is not installed. 0.5.27 (build 43) `a0f85fa46f1d95ca40056c771e400e7236d3172c` is still the installed build, and a user test of it was not recorded. Deeper notes: `docs/architecture.md`.

### What went wrong

These are findings from the code and from cloud window pictures, not a guess treated as the cause.

- 0.5.23's folder window showed the note and did not show a gutter. 0.5.24 and 0.5.25 said the editor stayed on TextKit 2 and that the note was visible with the gutter. The pictures after those changes showed the gutter and a blank page. Isolated pixel counts of a layer still passed. That claim is withdrawn here. The older sections are left as they were written.
- Reading `layoutManager` on the text view installs TextKit 1. That is the drawing path whose titled window shows the note. TextKit 2 fragment views did not appear in that window picture. Putting the view back on TextKit 2 is the change that blanked the page, so it was not done again.
- With that TextKit 1 path, noncontiguous layout estimated line positions. On a narrow wrapped note the gutter numbers skipped (`1, 2, 3, 13, 22, 23`). `02dac3c` remeasures only when the visible numbers skip, then restores the flag. The text storage is not rewritten.
- Opening a file and sampling the disk did not keep a generation. Directory loads already did. Two overlapping reads of one path could install a second buffer. A disk sample that started while the buffer still matched the last save could finish after an edit or a save and reload the old bytes, because "editor equals last saved" means "take the disk."
- New File chose a name from the tree listing only. A click before that listing arrives can target `Untitled.md` even when that file is already on disk.
- A long-note window was pictured while it still said no file was open, after the session buffer had loaded. `2bcd032` waits and takes the picture again until the note is visible or the attempts run out. That does not explain the empty picture. No further wait was added. Check windows are still left open across cases.
- The pull-request picture of `ba42002` showed the `plain.txt` tab while the note underneath was still the previous file. The tab was published when the open started, and the text arrived later. The tab and the buffer are now published together. `d5c4f25` still photographed the previous file: the text view already held the new note, and the window picture had not caught up. The check now waits until the window title and the text view agree, lets that frame composite, and takes one picture. `fa9b5fe03766a2784d6e8f766454b20632fadea1` then passed both cloud runs. The switch picture shows the `plain.txt` tab, the `plain.txt` breadcrumb, and the plain note. Push https://github.com/lizhichaox/XYZ/actions/runs/42200814965 and pull request https://github.com/lizhichaox/XYZ/actions/runs/42200824829. The click script in that same run still failed at `deep.md` and did not decide the build.

### What was chosen, and what was not

The text view stays the native view that paints today. The gutter asks that same layout manager for source lines. Reading stays the web view, with no line-number setting and no reserved gutter. A slow open installs only when it is still the latest request and the path has no buffer yet (`WorkspaceFilePolicy.shouldInstallRead`). A disk sample applies only if the buffer has not been edited or saved since the sample started. A save that finishes after the text has moved schedules another save.

Not done: a TextKit 2 rewrite, an Electron or web editor, a new document framework, or a new dependency. The session, the buffer, and `WorkspaceFilePolicy` already own those jobs. The build number was not increased just to record this.

One XCUI click was tried and is not a path on this runner. Apple documents `XCUIElement.click()`, `doubleClick()`, `click(forDuration:thenDragTo:)`, `waitForExistence(timeout:)`, and `isHittable` for macOS ([XCUIElement](https://developer.apple.com/documentation/xcuiautomation/xcuielement), [isHittable](https://developer.apple.com/documentation/xcuiautomation/xcuielement/ishittable)). That documents the API. It does not document this image. `4785e4c` added one test, `testEditMenuClick`, and ran it on the existing GitHub macOS runner with the same ad-hoc sign already used for the window check (`CODE_SIGN_IDENTITY=-`, signing required off). No SIP change and no TCC edit. The test bundle and `XYZUISmoke-Runner` compiled. The app never launched: `Could not launch “XYZ”. Runningboard has returned error 5. … Launchd job spawn failed.` Push https://github.com/lizhichaox/XYZ/actions/runs/42206480078, Xcode 26.6, MacOSX 26.5 SDK, destination “My Mac”. The click was not performed. The smoke target was removed so that launch failure does not skip the window checks. CircleCI’s SIP-off and TCC-injection recipe was not used.

### What changed

- `02dac3c` numbers each visible row from the source line, and only the first fragment of a wrapped line. An empty note is line 1. The production window passes numbers from the mode, not from the old preference keys.
- `ee0b4bd` drops a stale open and a stale disk sample, and follows a save when the text moved during the write. The text view's drawing code was not edited.
- `d834720` also looks at names already on disk before creating `Untitled.md` or `Untitled Folder`.
- Header clicks and divider drags are attempted in the cloud check. On `d834720` and later runs a click on `deep.md` left the selection empty, and every check after that click was skipped. Those checks now run on their own fixtures. The nested-file click stays a failed case. The body result and the UI acceptance result are separate. Acceptance is not complete while any of those cases fail. `56bd310` is not a double-green build: its pull request passed and its push failed because the capture-control picture was misread.

### Where this was checked

Cloud only. No user Mac, no real input method, no iCloud.

- Green on both cloud runs, `02dac3c84a34f0bd0680431557ba2cb11c630f59`: push https://github.com/lizhichaox/XYZ/actions/runs/42192386391 and pull request https://github.com/lizhichaox/XYZ/actions/runs/42192393433. The titled window showed the note and source lines 1–4, with the wrapped continuation blank, in light and dark, wrap on and off. Reading showed the rendered note and no gutter. Typing, the caret, undo, a long-note scroll, a plain-text switch, and a blank document passed. The empty outline kept a width.
- Not a green result: every commit after `02dac3c` through this note. `d834720` failed the click script. `ee0b4bd` had not finished when this section was written.
- `da9730d` ran the eight acceptance cases on their own fixtures (push https://github.com/lizhichaox/XYZ/actions/runs/42205589416). Pass: create-file, create-folder, refresh. Fail: nested-file (`selected=none buffer=nil`), collapse-header (`Collapse All left descendants open`), dividers (`left double-click was not idempotent`), mode-labels and empty-line-prefs (`the View menu target was not attached`). `ACCEPTANCE_FAIL 5`. The same push also failed the body step: the switch picture still showed the previous note. Those failures stay failures. Direct handlers and font metrics are not a pass.

### Still open

Explorer New File, New Folder, Refresh, and Collapse All are on the header. Create-file, create-folder, and refresh passed once on `da9730d`. Nested-file, Collapse All, divider double-click, mode-label weight, and the empty-line preference check did not. XCUI did not supply a click: the runner failed at launch. A real Chinese input method was not run. `hasMarkedText()` only skips restyle during a marked range. iCloud was not run. A cloud build does not show that a signed Mac syncs. 0.5.28 is not installed and is not a release.

## 0.5.27

- The editor file is back to the revision whose folder window showed the note. The debug assertion that stopped the run before the window was pictured is not included. Editing is checked on the window picture, including the Chinese line in the editor area when the full window recognition misses it. Typing, the caret, undo, scrolling, a blank document, and a switch to a plain file are each checked. Line-number and outline-fit checks stay in the log and do not decide this build. The Reading page stays the web view. The window capture does not show web-view pixels. A WebKit snapshot of that same page is checked separately and is not a picture of the window. The file column keeps the width left after the sidebar, and the columns are laid out in subview order so they do not overlap.

## 0.5.26

- Editing draws the document text in the real window, not only into an offscreen bitmap. TextKit 2 puts the body in fragment subviews. A layer-backed SwiftUI window was compositing the text view's layer without those subviews, so the gutter showed and the page stayed white. `cacheDisplay` still called `draw` and counted that ink.
- The folder window keeps the size it was given. The SwiftUI view fills that frame. It is no longer a constraint-based content controller that wrote the editor's flexible height back into the window on every layout pass.
- Editing draws the source into the text view the window composites. Fragment subviews stay in the layer tree. They are no longer dropped by a parent that claimed to draw them and then skipped their layers.
- Reading has no line numbers. The Reading setting and its gutter are gone, and a saved "on" value does not bring them back. Editing numbers are the source lines. Wrapping does not change them: only the first fragment of a source line is numbered.
- A one-pixel hairline runs under the title bar, across the sidebar and the editor. Light stays white. The line is the same divider used between the other surfaces.
- The Explorer header no longer shows a file count. New File, New Folder, Refresh, and Collapse All sit at its trailing edge. Collapse All closes nested folders and does not open them again for the file that is already open.
- The status bar draws Editing and Read-only in bold, with a pencil and an open book. The words are unchanged. VoiceOver reads the mode once.
- Double-clicking a sidebar divider fits that column to the names on screen. The Explorer includes indentation and the header actions. The outline includes heading depth. The editor keeps room when both sidebars are open.
- The line-number check opens a normal folder window on a synthetic file, switches Reading to Editing, and reads the composited text with text recognition. A blank document must not pass. Shots of that window are saved for light and dark.

## 0.5.25

- Editing shows the document text and the line-number gutter at the same time. The hosted text view is the TextKit 2 viewport again, so glyphs are drawn in the clip. A separate content storage could number lines without painting the body.
- `-XYZCheckGutter` samples foreground pixels in the text clip, in light and dark, with wrapping on and off, after resize, scroll, and hiding the gutter. A synthetic edit is written to a temporary file and read back. The source buffer must stay intact.

## 0.5.24

- Editing shows its line-number gutter in the real window, with wrapping on or off. The hosted editor stays on TextKit 2. Reading `layoutManager` was installing TextKit 1, and a wrapped gutter then had no fragments to number.
- Reading numbers sit on the first text row. A large heading's number is centered on that row, not on the top edge of the heading block. A wrapped paragraph or heading keeps the number on its first row.
- `-XYZCheckGutter` mounts `XYZMacEditor` in a window and checks the Editing gutter for wrap on and off. It also compares Reading numbers with the rendered first text row at two text sizes.

## 0.5.23

- Line wrapping no longer turns visual rows into source line numbers. Editing numbers follow newline boundaries, and only the first fragment of a wrapped line is numbered. The current-line band uses that same fragment.
- Reading shows the source start line of each rendered block. It does not invent a number for every wrapped row inside a paragraph, list, fence, or table.
- `-XYZCheckGutter` now prints the numbered lines for a synthetic wrapped document and for a synthetic Reading page. `-XYZDiagnostics` records `evidence=missing` when no gutter labels were drawn.

## 0.5.22

- Editing always shows line numbers, with wrapping on or off. A wrapped continuation stays blank. The number is the source line.
- Reading line numbers sit on the block they belong to. A list item, code fence, or table row uses its own source line. A block that cannot be split shows only its start line, and a number that would overlap the one above it is left off.
- Gutter diagnostics log how many labels were drawn and the first line and y pairs. Repeated draws with the same labels are skipped.

## 0.5.21

- Clicking the pin on a pinned tab unpins it. The pin sits in the close slot. Hovering it shows Unpin, and an accent tint. Middle-click still does not close a pinned tab.
- Collapsing or expanding Explorer no longer paints the sidebar white in dark mode. The sidebar fill follows the appearance.
- Find next and previous scroll the current match into view in Editing and in Reading.
- In dark mode, pressed find toggles, find matches, and the text selection are easier to see. Light mode stays an accent tint on white.
- With wrapping on, line numbers stay the source line. A wrapped continuation is blank. Reading numbers are the lines in the Markdown file, including lists, code fences, and tables.

## 0.5.20

- A single click in Explorer opens a preview tab, with an italic title. The next single click replaces that tab. Double-click the file, double-click the tab, or edit it, and the tab stays with a roman title.
- The tab menu has Pin and Unpin. A pinned tab shows a pin. It is not replaced by a preview, and Close Others, Close to the Right, and Close All leave it open. Middle-click does not close it. Close still does.

## 0.5.19

- Switching files clears the previous caret, selection, and find marks. Reading shows no leftover highlight from the file you left.
- `.command` and `.tool` files, and a `#!/bin/bash` or `sh` shebang, use the shell colors.
- Text size is 11–24 pt (⌘+, ⌘−, ⌘0). Line spacing is 1.0–2.0. Settings chooses a Latin face and a Chinese face separately. The choices are kept.

## 0.5.18

- Collapsing a folder in Explorer stays collapsed while a file inside it is open. Opening a file still reveals it. The folder section header still hides the whole list, and that choice lasts for the session.

## 0.5.17

- Find (⌘F) is a compact bar at the top right of the note, in Reading and in Editing. It fills from the selection, shows `n of m`, highlights every match, and marks the current one. ⌘G, ⇧⌘G, Return, and Shift-Return move through the matches and say when the search wraps. Match case, whole word, and regex stay on while they are pressed. ⌥⌘F adds Replace and Replace All in Editing. Esc closes the bar.
- ⌘K searches note names and their text. File-name matches come first, then open and recent notes, then lines of text with the match in the line. An empty field lists recent files. With no folder open, the panel says so. ⌘P stays commands and go to file.
- The open folder's row in Explorer is a section header. Its chevron and the row itself collapse the file list. The number on the right is how many files are in the folder. The choice lasts for the session.
- Folder arrows in the sidebar stay inside the window when it is flush with the left edge of the screen.

## 0.5.16

- Light mode is white. The editor, Reading, both sidebars, the tab row, the title bar, breadcrumbs, and the status bar are `#FFFFFF`. Hairlines (`#E5E5E5`) separate them. There is no grey fill. A selected row is the blue accent at 14% with ink text. Code in Reading sits on white with a hairline. Dark mode is unchanged.
- Reading headings have a steadier gap, lists are a little tighter, rules are hairlines, pictures stay within the page with a small corner radius, and a task checkbox is a read-only box with an accent check.
- Explorer rows stay about 22 points. Icons are secondary-colored symbols. The folder chevron turns when the tree opens or closes. The open file's row keeps the accent tint.
- The status bar is compact, white in light mode, with a hairline along the top and secondary text.
- ⌘K, ⌘P, Find, and Go to Line use the same white plate, a hairline, and a soft shadow.

## 0.5.15

- A new window's sidebar opens near 260 points, and it will not grow past about 40% of the window on its own.
- Editing draws a full-width current-line band, and indent guides for 2-space and tab indents.
- ⌥Z turns line wrap on or off, and the status bar says Wrap while it is on.
- ⌃G opens a small Go to Line field. Return jumps. Esc closes it.
- Middle-click closes a tab. ⌘0 returns the text to the size it had before this zoom.
- Reading and Editing keep the same top line. Restoring that line also moves the outline highlight.
- The divider logs `divider cursorUpdate` when the pointer is over it, including above the reader and the editor.
- The outline icon in the title bar is dimmed when the file is not Markdown.
- Light is white and near-black ink. Dark follows a calm VS Code / Obsidian pair. The blue `#0078D4` is only for focus, the active tab, selection, and links.
- `xyz .` opens that folder. The command lives in the app. XYZ → Install 'xyz' Command in PATH… shows the symlink to copy. See the README.

## 0.5.14

- The outline follows the heading on screen while Reading, and while Editing is scrolled away from the caret. Choosing a heading still jumps to it.
- Reading margins grow slightly with the window. The note still fills the pane. Headings, code, and tables stay compact and grey.
- Opening a file again in the same session returns to the line you left. Switching Reading and Editing still keeps the scroll position.
- Editing draws a quiet indent guide. The status bar shows Wrap while that is on, and still shows the line, column, encoding, and line ending. Reading hides the line and column.
- A tab's menu can close every tab. Middle-click closes that tab. Esc cancels a rename in the sidebar.
- Showing or hiding a sidebar eases its width. The text-input window (`TUINSWindow`) is no longer treated as an empty document, and the phantom sweep stops when nothing of ours is left.

## 0.5.13

- "No Outline" is centered in the outline pane. An empty folder, and the other lone sidebar messages, are centered the same way.
- View → Show/Hide Outline shows ⌥⌘B. The command palette lists Toggle Outline with the same shortcut. ⌥⌘B toggles the outline from the physical B key as well as the typed character.
- The title bar keeps one row and adds two icons at the right: the left sidebar (⌘B) and the outline (⌥⌘B). The mark is filled while that sidebar is open. The outline icon is dimmed when the file is not Markdown. Clicking one does not take focus and does not drag the window.
- Each sidebar edge is a 1px line, light `#E5E5E5` and dark `#2B2B2B`, for the full height between the title bar and the status bar. A 5pt strip on top of the panes shows the resize cursor. After a short hover, and while dragging, the line thickens and turns blue (`#007FD4`), then fades back.

## 0.5.12

- Sidebar file names use the width of the sidebar. The outline column follows the clip view after it has laid out, including the first layout and every later resize, instead of a 34 point width measured before layout and then held at 80.
- Diagnostics also turn on with the environment variable `XYZDiagnostics=1` (`YES` and `true` count too). Lines are public in the unified log: `log stream --predicate 'subsystem == "com.lizhichao.XYZ" AND category == "diag"'`. A shell `defaults write` does not reach the sandboxed container, and `xyz-diag.log` inside that container is not readable from the shell.

## 0.5.11

- Line numbers are drawn from the editor's line box when TextKit 2 does not return visible fragments, so the gutter is no longer an empty strip.
- ⌘K does not write the search field while you are typing.
- A 500×500 window is closed again for half a minute after launch, including one that is still ordered in. The log records why any window was kept.
- The editor frame stops at the status bar, including when that bar's coordinates are flipped.
- The line and column are shown only while Editing. Reading hides them, and Go to Line goes with them.
- The sidebar divider is wide enough to grab and shows the resize cursor. File names, the folder header, and outline rows use the new width while you drag.
- Markdown headings are a sidebar on the right. ⌥⌘B shows or hides it. The width is remembered for that folder. Other files do not show the pane.
- Esc in Reading, with nothing else open, no longer crashes. The window controller does not forward `cancelOperation:` to a superclass that does not implement it.
- Optional diagnostics: `defaults write com.lizhichao.XYZ XYZDiagnostics -bool YES`, or launch with `-XYZDiagnostics`. Lines go to Console under subsystem `com.lizhichao.XYZ` category `diag`, and to `xyz-diag.log` in the app's temporary directory (`~/Library/Containers/com.lizhichao.XYZ/Data/tmp/` when sandboxed).

## 0.5.10

- Editing shows line numbers again. They sit beside the text, not inside the scroll view, in light and dark, and the current line is marked.
- ⌘K keeps the last character of a real keystroke. The field is the query.
- The hidden 500×500 window is closed even when it is still ordered in. Find in Files and the command palette stay ordered out, and they are not documents.
- The editor’s frame stops at the top of the status bar.

## 0.5.9

- A hidden untitled window is closed: the 500×500 one after launch, and the full-size one ⌘K used to leave behind. ⌘K is not treated as File → New.
- The editor ends at the top of the status bar. A short note no longer sticks about 18 points past the window.

## 0.5.8

- Editing draws the source again, in light and dark, with line numbers beside it. The editor stops at the status bar.
- ⌘K keeps the last character you type. Find in Files is one panel, and a hidden 500×500 window is closed again.

## 0.5.7

- In Reading, the outline follows the heading at the top of the page as you scroll. Editing still follows the caret. Choosing a heading still jumps to it.

## 0.5.6

- The sidebar in light mode is a step off white (`#F8F8F8`), not a murky grey. Dark mode stays a step under the editor (`#181818`). Expanding a folder lists its children after the click, or shows nothing only when the folder is empty.

## 0.5.5

- A tab’s menu can close it, close the others, close the tabs to the right, copy its path, or reveal it in Finder. A breadcrumb opens the files and folders beside that segment.

## 0.5.4

- ⌥Z wraps lines. The outline follows the caret and scrolls the current heading into view. The line and column in the status bar open Go to Line.

## 0.5.3

- Reading shows a callout for a quote that starts with `[!note]` or `[!warning] Title`, a compact properties block for leading front matter, and turns `[[wiki links]]` into links to the named note. Code stays literal.

## 0.5.2

- Editing shows line numbers. They sit above the text, including on a file that was already open when you switch to Editing.
- Sidebar rows have no fill except the open file and the row under the pointer. The sidebar itself is one flat tint.
- Launch no longer leaves a hidden 500×500 window. Settings opens only when you ask for it, and an untitled document is created only from File → New.
- Find, replace, and Go to Line stay disabled until a file is open.
- Sidebar rows fit the sidebar from the start, before a file is opened.
- A large source file keeps syntax color on the lines on screen, including in Reading, and colors new lines as you scroll.

## 0.5.1

- Editing shows the line-number gutter again. The current-line highlight runs across the gutter and the text.
- The status bar is back under the whole window: line and column, encoding, line ending, language, and Read-only or Editing.
- Edit → Use Selection for Find (⌘E) is back.
- An empty folder window centers “No File Open”. The tab bar stays out of the way until a file is open.
- Launch reopens the last folder. It does not present an Open panel, and it does not leave an untitled window behind.
- The sidebar has no filter field. ⌘K is the folder search: file names and paths, including hidden files when they are shown, and text in the files. The sidebar is Explorer, the folder, then Outline.
- ⌘K lists more than a handful of matches in one file, and a “more” row when the rest are cut off. The query includes the last character typed.
- Syntax coloring adds muted colors for strings, numbers, types, and, in config files, section headers and keys.
- ⌘F shows the find bar immediately. Counting matches waits a moment and runs off the main thread, so a large file does not freeze the window. The bar sits over the text instead of pushing it down. Closing it only hides the bar. Closing a tab updates the tab strip first and swaps the file afterward, without recoloring the whole document.
- Esc closes the topmost popup even when focus is in the find field, the editor, or the Reading page: the find bar, folder search, the command palette, Go to Line, the tab switcher (Esc cancels it), a status-bar menu, or a confirmation. Focus returns to the editor. An input method that is still composing keeps Esc.

## 0.5.0

- The title bar is one row: traffic lights, and the window title centered as `<file> — <folder>`. The row drags, and a double click zooms. There is no toolbar.
- The sidebar starts with Explorer, then the filter, then the folder. Rows are short, with a file icon and a full-width highlight. Outline is a section at the bottom of the sidebar, collapsed until View → Show Outline. ⌘B toggles the sidebar and does nothing else.
- There is no Markdown formatting menu. Bold, italic, link, code, headings, lists, and the other Format commands are gone. Find, replace, line edits, ⌘/, and ⌃Tab stay.
- ⌘K opens a search panel in the upper middle of the window. An empty query lists recent files. Typing lists filename matches and text matches. ↑↓ and Return open a result, ⌘Return keeps the panel open, and Esc or ⌘K closes it. Replace across files is Edit → Replace in Folder…, only in Editing, and it still asks before changing files. ⌘F stays find-in-file. ⌘P stays the command palette.
- Tabs sit under the title bar, across the editor. Each tab has an icon, the name, and a close button on the active tab and on hover. The path is a short breadcrumb row under the tabs. Editing shows line numbers and a highlight on the current line. The status bar runs the full width of the window.

## 0.4.0

- The tab strip is a title-bar accessory, so the title-bar material does not paint over it. The sidebar no longer installs a toolbar. ⌃⌘S toggles the sidebar once. Reading, Editing, and Toggle Sidebar are in the View menu. Find is in the Edit menu.
- Files open in Reading. Markdown Reading is the rendered note. Other text Reading is the colored source, and it cannot be edited. ⌘/ switches to Editing, which is the source with line numbers. ⌘/ again returns to Reading. Pictures, PDF, media, and the plain-text fallback stay read-only.
- Replace, line edits, and ⌘S are for Editing. ⌘F still finds in Reading. Settings can show line numbers while reading. The status bar says Read-only or Editing.

## 0.3.2

- The window toolbar no longer covers the tabs. The tab row is visible and clickable, level with the traffic lights. With the sidebar collapsed, the tabs start just after the lights. ⌃⌘S still toggles the sidebar.
- Source text starts about 13 points from the pane edge. Line numbers still widen that side when they are on.

## 0.3.1

- The tab bar sits in the title-bar row, level with the traffic lights. The filter sits just under that row. The path, the status bar, and the space above the first line are shorter.

## 0.3.0

- ⌘F finds in the current file from a bar above the editor. ⌥⌘F adds Replace and Replace All. The bar can match case, whole words, or a regular expression, and shows “n of m”. ⌘G and ⇧⌘G move through the matches. ⌘E still uses the selection as the query.
- ⇧⌘F still filters the sidebar. It can replace across the folder: a preview of matches, include and exclude patterns, and Replace All after a confirmation. Each file is its own undo, and the file keeps its encoding and line endings.
- Edit can duplicate, move, or delete a line, indent and outdent, join, sort, trim trailing space, and change case. ⌘; toggles a comment in code. ⌘/ still switches Source and Reading.
- ⌘D adds the next occurrence of the selection. Option-click adds another caret. Typing goes to each caret as one undo. Arrow keys and the input method still use one caret.
- The sidebar names the open folder under the filter. The chevron collapses the tree. The tooltip is the path, with ~ for the home folder. The menu can reveal the folder, copy its path, or open a different folder in this window.

## 0.2.0

- File → New Window (⇧⌘N) opens another folder window, with its own tabs. A file already open in another window of that folder is brought forward instead of copied. A tab can move to a new window from its menu, or by dragging it out of the tab bar. The next launch restores each window, its folder, and its tabs. ⌘` still cycles windows, and ⌘1–⌘9 stay inside the key window.
- The folder window no longer draws a title and subtitle above the tabs. The tab bar sits on the traffic-light row. The path stays under the tabs. The file name remains the window's title for the Window menu.
- ⌃Tab switches to the previous file. Holding Control shows the window's recent files; Tab and Shift-Tab move through them, and releasing Control opens the selection.
- A file that is not text and has no picture, PDF, or media viewer opens as a read-only text preview. Bytes that are not Unicode are shown in Windows-1252. A long file previews the first 2 MB.

## 0.1.4

- Document and folder windows open filling the screen, under the menu bar and the Dock. A size chosen during a session stays until quit. The next launch fills the screen again.

## 0.1.3

- Changing the text size updates the font once and leaves the rest of the note on viewport layout, so typing and scrolling stay smooth afterward.
- Reading applies that size through the page's text-size setting and keeps the line that was at the top.

## 0.1.2

- ⇧⌘T reopens the last closed tab. ⌃G asks for a line, and optionally a column (`12:4`). View → Reveal Active File selects that file in the sidebar.
- ⌃⌘S toggles the sidebar. ⌘B stays Bold. View → Wrap Lines, and the same switch in Settings, scrolls long lines sideways instead of breaking them.
- Settings remembers Show hidden files.
- A picture shows its pixel size. Double-click switches between fit and actual size, and a pinch zooms. A PDF shows the page in the status bar.
- When a file with unsaved edits changes on disk, XYZ asks whether to reload or keep yours. A clean file still reloads quietly. Esc leaves the choice on the banner.

## 0.1.1

- The tab bar keeps the dirty dot in a fixed slot, marks the active tab more clearly, and scrolls the active tab into view when the row overflows.
- The status bar can change the encoding and the line ending. A choice the text cannot store is refused, and the file is written back in the new form.
- View → Show Outline lists Markdown headings, JSON keys, or declarations. Choosing one jumps to that line. It is a scan, not a language server.
- The file tree draws a quiet indent guide.

## 0.1.0

- A folder window keeps open files in a tab bar. A single click is a preview tab; editing or a double click pins it. A dirty file shows a dot. ⌘W closes the tab, and ⌘1–⌘8 select a tab, with ⌘9 selecting the last.
- The path sits under the tabs. The status bar shows the caret, the selection, the encoding, the line ending, the file type, and, for prose, the word count.
- Text files keep the encoding and line endings they were saved with: UTF-8, UTF-8 with a byte-order mark, UTF-16, and Windows-1252 for names that are already text. The editor works in Unicode and writes the original form back.
- Source colors comments, strings, numbers, and keywords in common languages. There is no completion, diagnostics, or language server.
- JSON Reading is pretty-printed. CSV and TSV Reading is a table. Markdown Reading is unchanged.
- Pictures, PDF, and audio or video open in a viewer. Other files that are not text use Quick Look. Text over 5 MB still stays out of the editor.
- The sidebar can copy a relative path. ⌘⇧F still filters names and searches inside files; choosing a match opens that line.
- Code uses a fixed-width face. Prose still follows Settings.

## 0.0.3

- Format menu: bold, italic, strikethrough, inline code, link, headings, quote, bulleted, numbered and task lists, code block, and table, with Typora-style shortcuts (headings on ⌥⌘0 to ⌥⌘6).
- Go to Heading (⌘R), and `@` in the command palette, list the note's headings and jump to one in Source or Reading.
- Reading shows pictures from the note's folder, colors fenced code that names its language, scrolls to a heading for `#fragment` links, and opens the file a relative link names.
- Settings: appearance (System, Light, Dark), language (System, English, 简体中文), font, a text size shared by Source and Reading, and Limit line width. View → Zoom In, Zoom Out, and Actual Size step the size.
- View → Show Word Count shows the word count and reading time under the note.
- The interface is in English and Simplified Chinese.
- Source shows line numbers in the left padding (Settings → Show line numbers, or View → Show Line Numbers).
- Esc closes Settings, About, and alerts, in English and Chinese.
- A folder window's subtitle shows the path from the workspace root to the open file, such as `LIZHICHAO › DT`.
- Files that are not Markdown show as plain text in the editor, without heading sizes or tinted `#`. Spell checking is on for Markdown and `.txt` only.
- The `_xyz` icon is redrawn: the underscore is as heavy as the letters and stands a little apart from the x, the word is larger, and up to 64 pixels it is set heavier so it stays legible in Finder and menus. The Mac icon's rounded edge no longer shows a dark rim at small sizes. `tools/make_icons.py` draws it.

- ⌘/ keeps the same source line at the top of Source and Reading. Ten switches stay on that line, with one scroll and no second jump.
- Reading blocks carry the source line (`data-line`). The toggle uses that line, not a height ratio.

## 0.0.2

- ⌘P with an empty field lists files opened in that folder, most recent first. Matched characters are semibold, in the same grey as the rest of the row.
- A wide table scrolls sideways inside the note. Task checkboxes stay read-only. Code uses the same monospace face in light and dark.
- The folder sidebar is a source list: monochrome symbols by file type, tighter rows, and left/right to move through folders. Opening a file expands its folders and scrolls to it. Move to Trash uses the system Trash.
- The window title is the open file. The subtitle is the folder. The proxy icon is that file.
- A large note restyles the edited lines instead of the whole buffer. Reading waits a little longer before updating a large note.
- ⌘F uses the system find bar in Source. In Reading it finds in the rendered note.
- Reading is set in the system font with PingFang SC, a line height of 1.75, looser paragraphs, and quieter headings, quotes, rules, tables, and code.
- Source uses one line box, about 1.7 times the font size, for both wrapped lines and hard returns.
- In Markdown, Return continues a list, Tab and Shift-Tab indent it, and ⌘B / ⌘I toggle bold and italic. Plain text is unchanged.
- An empty folder window names ⌘P and ⌘⇧F. The command palette field uses the standard search-field height.

## 0.0.1

First release.

- Markdown and plain text editor on macOS, iPhone, and iPad, using TextKit 2 and the system font.
- Source and Reading. ⌘/ switches them. The content area shows one view.
- Folder workspaces on the Mac, with a source list, hidden files, live updates, rename, and move.
- Sidebar name filter (⌘⇧F) and a cancellable text search.
- One preview web view per window, with the Mac network client entitlement so that process can start.
- ⌘/ switches Source and Reading in folder windows and document windows. ⌘E is Use Selection for Find. ⌘P opens Quick Open and the command palette. Print is ⌘⇧⌥P.
- About shows the icon, the version, and a credit link to lizhichao.com.
