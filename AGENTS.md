# AGENTS.md

Instructions for agents working in this repository. The owner has stated the machine
rules below more than once; follow them without being asked.

## One XYZ.app on this Mac (standing rule)

- Exactly one copy of `XYZ.app` may exist on this computer: `/Applications/XYZ.app`,
  and it must be the newest build. Do not keep a rollback copy of an older version.
- After every build, test install, or release:
  1. quit the running app (`osascript -e 'tell application "XYZ" to quit'`, or kill the
     process if it will not quit),
  2. replace the installed app: `rm -rf /Applications/XYZ.app` then
     `ditto <built path>/XYZ.app /Applications/XYZ.app`,
  3. delete every other `XYZ.app` bundle: `build/**` products (DerivedData, `export`,
     `*.xcarchive`), any mounted DMG, `/tmp`, Desktop, Downloads, Trash,
  4. verify with `mdfind "kMDItemCFBundleIdentifier == 'com.lizhichao.XYZ'"`; only
     `/Applications/XYZ.app` may be listed.
- Release artifacts (DMG/ZIP) live under `build/` for the current version only. Delete
  older versions, and unmount a DMG after inspecting it (a mounted DMG shows a second
  `XYZ.app` in Finder).
- When the build under test is signed with Apple Development instead of Developer ID,
  say so; replace it with a signed, notarized build before calling the install final.

## Project facts

- Version lives only in `Config/Base.xcconfig` (`MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`). The cloud check reads it back out of `Info.plist`.
- Tests: `swift test --package-path XYZCore` and `sh Scripts/xyz-test.sh`.
- GitHub Actions is **disabled** by the owner (`disabled_manually`), so pushes no longer
  start a run. Do not re-enable it or add a replacement workflow without being asked.
- Unsigned builds (what the CI workflow used to run):
  `xcodebuild -project XYZ.xcodeproj -scheme XYZ -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dev-macos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build`,
  and the same with `-destination 'generic/platform=iOS Simulator'`.
- Signing and notarization: `docs/release.md`, `tools/ExportOptions.plist`. Team
  `Z4FMG2KTPM`, Developer ID Application certificate in the login keychain, notary
  profile `xyz-notary` (`xcrun notarytool ... --keychain-profile xyz-notary`).
- Do not launch the GUI app unless the owner asks; a hidden launch
  (`open -j -a /Applications/XYZ.app`, then `pgrep -x XYZ`, then quit) is the quick
  check. Toggling sidebars and other interaction still needs the owner.
- The app is sandboxed with iCloud and security-scoped bookmarks; the unsigned CI build
  has no entitlements, so a green cloud run does not prove the sandboxed app works.
- **Launch and the Dock start page.** With no folder window to restore, launch shows
  `WelcomeWindow` (Open Folder…, New File, recent folders) instead of a folder panel;
  a Dock click with no visible window shows it again. Restored folder windows still open
  directly, and any workspace or document open closes the page. Do not auto-open the
  folder picker or the last folder at launch.
- **AppKit's automatic document panel must stay cancelled.** On launch and Dock reopen,
  AppKit's `_doOpenUntitled` path asks `NSDocumentController` for a Finder-like document
  open panel even when no document should open. `FolderOpening.suppressAutomaticDocumentOpen`
  recognises that call-stack path and cancels it, and a short hold covers launch; File →
  Open and the folder picker are not affected. Keep the guard when changing launch or
  restore code, or the Welcome page gets covered by the panel again.
- **The start page fills the screen.** `WelcomeWindow.show()` calls `WindowFill.fill` so a
  fresh page opens at the screen's visible frame, the same size folder windows use. A
  second `show()` while it is already visible must not resize it. The brand block and
  Recent Folders column are both vertically centered in that height; keep them centered
  rather than pinned to the top, and keep the recent-folder limit (20) generous.

## DeepSeek Harness plugin (`tools/dsh-open-in-xyz`)

`tools/dsh-open-in-xyz/` is a local [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(DSH) plugin: an `_xyz` split Open In button in the DSH Session header. It is maintained
with this repository and **never published**: the package is `private: true`, it is not on
npm or in the DSH plugin market, and it is installed only by linking this checkout into a
DSH profile. The installed DSH app is not ours to change.
`tools/dsh-open-in-xyz/README.md` has the details; read it before touching the plugin.

- **Never modify the installed DSH app.** `/Users/lizhichao/Applications/DeepSeek Harness.app`
  belongs to the DSH distribution: its `Info.plist` carries `ElectronAsarIntegrity` hashes,
  so editing anything inside can stop DSH from launching, and an update replaces it
  anyway. Change the plugin in this checkout, then restart DSH to reload it.
- **Do not rename or move the plugin, its package, or its loader id.** The
  `cordis.patch.yml` loader entry name, the `package.json` `name`, and the
  `window.__ModuleLoader__.load({ id: ... })` id in `client.js` must all stay
  `dsh-open-in-xyz`. The desktop profile (`~/.dsh/profiles/desktop/package.json`) links
  this checkout from `dsh.profile.bundles` + `dependencies`; a rename or move also needs
  that link updated, `pnpm install` in the profile, and a DSH restart.
- **Keep the DSH plugin contract.** `package.json` must keep the exports `.` / `./client`
  / `./locale/*.json` / `./icon`, `dsh.bundle.patch: ./cordis.patch.yml`, and
  `dsh.client: { platform: 'web', immediately: true }`. `cordis.patch.yml` inserts the host
  half (`id: open-in-xyz`, `name: 'dsh-open-in-xyz'`), and `client.js` stays a hand-written,
  build-free bundle (`window.__ModuleLoader__.load` + `factory(require)`) requiring only
  `react` and `@deepseek-ai/dsh-client-ui-primitives`. The shipped header button is hidden
  by shadowing its list-slot entry (`id: 'open-in-app', priority: -1`) plus one narrow CSS
  fallback; keep both mechanisms and keep the shipped `open-in-app` plugins enabled, so
  file-level Open In and document previews keep working.
- **The header wordmark tracks the app icon.** The inline `_xyz` SVG in `client.js`
  (`WORDMARK`: path, viewBox, bar; ink heights `WORDMARK_HEADER_INK = 9` and
  `WORDMARK_MENU_INK = 6.3`; accent `#0078D4`) is generated from the icon's small style in
  `tools/make_icons.py`: Inter ExtraBold (wght 800), word width 800/1024, tracking 24,
  `under_gap` 60, x-height centered at 496. If `make_icons.py`, the app icon, or the `_xyz`
  wordmark changes, regenerate the geometry and inline it again, keeping the viewBox's
  extra descender height above the x-height so the mark stays optically centered. The
  `./icon` export is the separate 256px app icon for the Plugins list, not the header mark.
- **Leave VS Code to the shipped plugin.** "Open in VS Code" reads the shipped
  `dsh-host-open-in-app` routes (`/open-in-app/apps`, `/open-in-app/icon/vscode`,
  `/open-in-app/open`); do not reimplement app detection or launching, and do not disable
  that plugin. XYZ and Finder go through this plugin's own routes.
- **Keep the host routes closed.** The host half registers exactly three routes —
  `GET /open-in-xyz/state`, `POST /open-in-xyz/open`, `POST /open-in-xyz/reveal` — all
  behind DSH composition's `connection.requestRejection()` trust fence. POST accepts only
  one JSON object with one non-empty absolute `path` string — any other field is rejected
  (64 KiB cap, `stat` must confirm an existing directory), so no other input reaches the
  launcher. The program path is fixed to the host-detected XYZ and starts through
  `execFile` argv (`/usr/bin/open -a <app> <dir>`), never a shell. Do not add a route that
  accepts an arbitrary program, extra arguments, or an unvalidated path, and do not relax
  the directory check. A new application entry should reuse the shipped host's routes or
  follow the same fence + validation pattern.
- **The plugin adds no App code or settings.** It finds and launches the installed app from
  outside (`/Applications/XYZ.app`, then `~/Applications/XYZ.app`, then the `xyz` CLI), so
  do not couple it to the app feature line, add a settings page, or write user preferences
  for it.
- **Run the plugin's own check.** `cd tools/dsh-open-in-xyz && npm test` (the
  dependency-free `node --check` + `test/smoke.mjs`, no network, launches no app).
  Host-half changes need a DSH restart; `client.js`-only changes hot-reload (refresh with
  Cmd+R if they do not).

## Theming and display style

- **Every color comes from `XYZTheme`.** The model lives in XYZCore as `XYZColor` (RGBA,
  no AppKit) with `light`/`dark` variants and pure contrast math; the app converts with
  `NSColor(xyz:)` and resolves each role per drawing appearance (`xyzResolved`). Do not
  add a hardcoded hex, `labelColor`/`secondaryLabelColor`, or a one-off
  `NSColor(srgb...)` anywhere: a color outside the theme cannot follow the Appearance
  setting and drifts from its neighbors.
- **Syntax colors are theme data too.** `NSColor.xyzSyntax(_ kind:)` resolves the active
  theme's `SyntaxPalette`; the editor's token lookup must not branch on
  `effectiveAppearance` itself.
- **Display metrics are shared constants.** Small controls (rows, hovers, toggles) use
  `xyzDisplay.controlCornerRadius`; panels use `panelCornerRadius`; hover feedback uses
  `xyzHover`; disabled controls use `xyzDisabledTint`. Radii 4 and 5 for the same kind of
  control, and alphas 0.06 vs 0.07 for the same hover, are exactly the drift to avoid.
- The Appearance setting stays system/light/dark and only switches `NSApp.appearance`;
  themes are not user-editable until the owner asks for it.

## Typography

- **No font pickers (owner decision).** Typography is fixed: bundled Sarasa Gothic SC
  for prose/headings, Sarasa Mono SC for code. Both languages use the same face; do not
  reintroduce separately selected Latin/CJK fonts. UI stays native.
- Text size and line spacing are the only typographic preferences (`xyz.text.size`,
  `xyz.text.lineSpacing`, 1.0–2.0, default 1.7), shared by Editing and Reading. Code
  renders a fixed 0.15 step tighter than prose, so one control never becomes two.
  Retired font and monospace preferences are ignored. Reading keeps the full pane width
  with its original insets. **Fixed fonts do not authorize narrowing or centering the
  content column.** Do not add a maximum reading width or a width setting. Fonts load
  offline, per process, never into Font Book. Include the unmodified font license and
  source checksums.
- Syntax highlighting changes color, not font family/weight. A keyword keeps the code
  face and cell width. Chinese headings use the same actual weight as Latin.
- Tabs repeat at two measured space advances, matching Reading and indent guides.
  Clear AppKit's default 28pt stops; mixed space/tab indentation advances to the next
  stop. Fenced blocks measure their own code font. Never rewrite the buffer for display.
- Keep minimum line height only (no clipping maximum). Measure the complete bilingual
  face so Chinese glyphs cannot clip. Size and line spacing are read from their saved
  preferences; retired font choices must not influence the fixed faces.
- `-XYZCheckGutter`'s `typography` case checks actual font runs, CJK weight and tab layout
  at 11/16/24pt. Visual preference still needs the owner's review.

## Product boundaries (owner decisions; do not re-add)

These are product decisions, not missing features. Ask the owner before adding any of
them back:

- **No terminal.** The app never embeds a shell.
- **No spelling or grammar checking.** Removed from the whole app: the macOS editor runs
  with continuous spell and grammar checking off and strips the Spelling/Grammar items
  from the context menu; iOS sets `spellCheckingType = .no`. Do not turn any of this back
  on, and do not add a "check spelling" command, setting, or underline.
- **No diff view.**
- **No split editor panes.**
- **No LSP / semantic services** (go to definition, hover, diagnostics, completion).
- **No Git integration** (no blame, no source-control panel).
- **No extensions marketplace and no remote development.**
- **No code outline panel.** The right-hand outline is Markdown headings only; code and
  JSON do not get symbol breadcrumbs or a section list.
- Deferred, not forbidden: manual language mode and the minimap ("先不做").

## AppKit sidebar: what not to repeat

This project spent a long round on a sidebar that could not open folders. The causes,
in the order they were found:

- **A click on a disclosure triangle is handled inside AppKit** and does not call the
  subclass's `expandItem`. Do not rely on that callback alone.
- **AppKit puts a private button in the disclosure slot**, and it only acts inside its
  own mouse tracking. A click delivered any other way (acceptance harness, inactive
  window) is dropped. The row view's `hitTest` returns nil over the disclosure strip so
  the outline view receives the click instead.
- **`NSTextField` is an `NSControl`**: it consumed clicks on a folder's name, so the row
  never saw them. Row labels use `SidebarPassthroughLabel`, whose `hitTest` returns nil.
- **`NSOutlineView.reloadData()` keeps the expansion of items that compare equal**, so
  clearing the model alone does not close anything. Collapse All must also collapse the
  rows it shows open.
- **A fresh `SidebarNode` per rebuild loses expansion and selection**: the outline keys
  both by object identity and by row number. Nodes are cached by path, and the selected
  row is restored by path after every rebuild.
- **AppKit calls back into expand/collapse while reloading.** Writing those callbacks to
  the session closed folders the user had just opened, about two seconds after the open
  (when the folder's children finished loading). Only user intent writes to the session
  (`SidebarOutlineView.marksUserExpansion`).
- **Do not draw a second highlight for the open file.** The row painter filled both the
  selected row and the open file's row, which read as two selections. The open file is
  marked by its name color instead.
- **AppKit numbers a quick series of clicks 1, 2, 3...** Treating `clickCount > 1` as a
  double click silently dropped every click after the first: a folder opened once and
  could not be closed while the user kept clicking. Every `mouseDown` is one toggle.
- **Do not publish `selectedPath` for a folder click.** The main window body reads it, so
  every click re-evaluated the editor, preview and outline and the sidebar felt slow. A
  folder click moves the unpublished `clickedPath`; only opening a file publishes.
- **A change the view already shows must not schedule a rebuild.** After the user opens or
  closes a folder the sidebar records a fresh snapshot, and a generation token cancels a
  rebuild that was queued earlier. Otherwise `reloadData` replaced rows under the pointer
  and swallowed the next click.
- **Do not hand-shift the disclosure or the cell.** AppKit proposes 0 or 2 for the same
  row between layout passes; adding an inset to that proposal made the triangle move after
  a close-and-open, and hiding AppKit's outline cell made `collapseItem` a no-op (verified:
  `before=true after=true`). The sidebar now uses AppKit's own geometry, with
  `-XYZCheckGutter`'s `refresh` case as the canary.

- **Do not keep per-toggle layout state in SwiftUI.** The sidebar visibility used to be a
  `@State` the whole window body read, so every ⌘B re-rendered editor, preview and outline
  and then pushed the value back down into the split view. `SidebarVisibility` and the
  split view own it now; SwiftUI passes it once and is not in the loop.
- **Do not animate a column's width.** Animating it re-lays out the editor and Reading text
  every frame; with a second press during the slide it reads as shaking. The toggle is a
  cut, one layout pass. A layer fade on the sidebar was tried too and felt abrupt.
- **⌘B must drop `isARepeat`.** A menu key equivalent fires once per auto-repeat event;
  holding ⌘B flipped the sidebar dozens of times. It is handled by the key monitor in
  `EditorCommands.handleKeyEquivalent` instead.
- **A width that was never chosen must be fitted, not remembered.** Persist a column width
  only after the divider is dragged or double-clicked, and keep the fitted width out of the
  stored value on the next open.
- **Title-bar buttons share one geometry.** Draw every glyph in the same 16 by 15 box, with
  one 3 pt corner radius and one 1.3 pt stroke, and place the centres by mirroring the real
  traffic-light frames (read them at layout time; do not hard-code 20 pt).

`-XYZCheckGutter` runs these paths as acceptance cases (`refresh`, `collapse-header`,
`nested-file`). The rest of the app must not be changed to make a harness pass, and a
passing `refresh` case is the minimum evidence that folder clicks work.

## TextKit 2 editor: what not to repeat

- **The live editor is TextKit 1, on purpose.** `makeNSView` reads `layoutManager` (for
  non-contiguous layout), and reading that property installs TextKit 1. A detached
  `XYZMacTextView(usingTextLayoutManager: true)` is TextKit 2. Anything drawn from text
  layout must work on both: `visibleTextRows(in:)` is that seam. A check that only builds a
  detached TextKit 2 view will not catch a live-editor bug (folding shipped once like
  that: the check passed and clicking the gutter did nothing).
- **Folding has two presentations.** TextKit 2 uses `NSTextContentStorageDelegate`: a
  folded paragraph is answered with a custom paragraph of the **same length** (zero-width
  spaces keep every offset identical), a 0.1 pt font and a zero line height. TextKit 1 has
  no such hook, so the folded range gets the same display attributes in the text storage
  (0.1 pt face, zero line height, clear ink) after every restyle; restyling the range is
  also how unfolding removes them. Both keep the real string, the undo stack and
  `onTextChange` untouched. Never swap the text storage for a folded display string.
- **Do not fold with a uniform line box.** Folding changes line geometry; the gutter,
  indent guides, whitespace dots, the caret band and the `⋯` marker all read laid-out
  rows, and hidden rows are skipped in the gutter.
- **Mark the backing store edited to re-ask the delegate.** `invalidateLayout` alone does
  not regenerate paragraphs; `textStorage.edited(.editedAttributes, range:, changeInLength: 0)`
  over the folded range does, with undo registration off. Covers the range before and
  after the change so both directions repaint.
- **Open a fold before anything looks inside it.** Edits (`shouldChangeText`), find
  reveals and selection changes into a hidden line all unfold first; otherwise the caret
  sits in text that is not on screen. Folds re-anchor by their header text after edits
  above them, and a document switch starts unfolded.
- **Line numbers, indent guides and the current-line band must use laid-out rows, not a
  uniform line box.** Folding changes the geometry; a formula like `(line - 1) * box`
  puts guides and the caret band on the wrong lines. Skip hidden lines in the gutter and
  in the guides, and draw the `⋯` marker after measuring the header with the editor's own
  face (a line fragment's typographic width can be the whole container).
- **One draw pass, one fold lookup.** `foldHeaderState()` is called once per gutter draw;
  `foldedInnerRanges` is cached because the content-storage delegate asks for it for every
  paragraph during layout.
