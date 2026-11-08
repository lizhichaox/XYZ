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
