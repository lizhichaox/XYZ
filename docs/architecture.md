# Editor architecture

The version record is the 0.5.28 section of `CHANGELOG.md`. This file is the ownership detail for that section. Rollback that cloud CI accepted: `02dac3c84a34f0bd0680431557ba2cb11c630f59` (0.5.28, build 44). Installed build remains 0.5.27 `a0f85fa46f1d95ca40056c771e400e7236d3172c`. This note does not reset either commit.

## What owns what

The folder window is SwiftUI inside a titled `NSWindow` (`WorkspaceRootView`). It does not use `NSHostingController`: that controller wrote the editor's flexible height back into the window until AppKit aborted.

`WorkspaceSession` owns the open folder, the tab list, and which buffer is on screen. `WorkspaceFileBuffer` owns one file's text, the last saved text, encoding, line endings, and the dirty flag (`text != lastSaved`). Keystrokes call `userEdited`. A debounced save writes through `WorkspaceFilePolicy`, which refuses to replace a newer disk copy unless the user chooses Keep Mine.

Editing is `XYZMacTextView`. Reading a Markdown note is `WKWebView`. Reading of other text is the same text view, locked, with no gutter. `PreviewBridge` keeps the latest source. `PreviewModel` drops a render when a newer one has been scheduled.

## Why the body and the gutter came apart

`makeNSView` reads `layoutManager`. On this system that installs TextKit 1 and is the path whose window picture shows the note. TextKit 2 fragment views did not appear in that picture, so the body went blank while a gutter could still draw. The gutter therefore numbers lines from the layout manager that paints the body. Noncontiguous layout estimates positions, and those estimates skipped source lines on a narrow wrap; a contiguous remeasure is used only when the visible numbers skip, and the flag is restored. That remeasure stays. The text view is not switched back to TextKit 2.

## What changed

Directory loads already ignore a stale generation. Opening a file did not. Two overlapping reads of one path could install a second buffer over the first. A disk sample taken before an edit or a save could finish afterward and reload the old bytes, because `editor == lastSaved` is treated as "take the disk." The sample is now dropped when the buffer's observation has moved. If the text changes while a save is inside the write, another save is scheduled so the older bytes are not the last ones on disk.

New File also unions the names already on disk with the names the tree has listed, so a click before the listing arrives cannot replace `Untitled.md`.

## Rejected

A TextKit 2 rewrite of the text view. It is the change that left the gutter up and the note blank. An Electron or web editor, and any new document framework. The session, the buffer, and `WorkspaceFilePolicy` already have those jobs.

## Still open

Real IME composition is not covered here. Restyle and metric changes skip `hasMarkedText()`, but that is not a Chinese input-method session. iCloud is not exercised. Explorer clicks and divider drags are still not an accepted gesture run. Check windows stay open across cases. `2bcd032` already retries the long-note picture. That retry is not treated as the fix, and it was not extended.
