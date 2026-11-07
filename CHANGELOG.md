# Changelog

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
