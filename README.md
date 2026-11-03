# XYZ

[![CI](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml/badge.svg)](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml)

XYZ is a native editor for text, code, and everyday files. One SwiftUI codebase runs on macOS, iPhone, and iPad. On the Mac, opening a folder gives a source list, tabs, and a status bar. iPhone and iPad still use the document browser. Opening and saving goes through Apple's document browser, so iCloud Drive files are ordinary documents once the app is signed with the iCloud capability.

New documents are Markdown (`.md`). The app also opens and saves `.markdown` and plain text (`.txt`). A folder on the Mac opens any text file, and shows pictures, PDF, audio, video, and a Quick Look preview for the rest. Workspace files keep the encoding and line endings they had (UTF-8, UTF-8 with a byte-order mark, UTF-16, or Windows-1252). New documents are still UTF-8, and a byte-order mark is not added.

## What you see

- A proportional text editor in the system font (SF Pro, with PingFang SC for Chinese), 16pt, with a line box about 1.7 times the font size so wrapped lines and hard returns share one rhythm. The text uses the width of the pane, with side padding that stays between 24 and 64 points. Markdown markers are tinted and headings are slightly larger. Settings chooses the font (Default or Monospaced) and the size, and can limit the line width (see Settings below). On the Mac the view is an `NSTextView`; on iOS it is a `UITextView`. Both use TextKit 2. In a Markdown file, Return continues a list (and leaves the list on an empty item), and Tab and Shift-Tab indent it. Other files, such as `.txt`, `.gitignore`, or source code, are plain text: no heading sizes or tinted markers, and none of those edits. Spell checking is on for Markdown and `.txt` only, so config files and code are not underlined.
- A file opens in Reading. Markdown Reading is the rendered note. Other text Reading is the colored source, and it cannot be edited. ⌘/ switches to Editing, which shows line numbers and a highlight on the current line. ⌘/ again returns to Reading. The choice is not saved. The reading and editing surface has no buttons of its own, and the window has no toolbar. ⌘B toggles the sidebar. View → Toggle Sidebar is the same command.
- On iPhone and iPad the same two modes are in the View menu.
- Reading renders headings, emphasis, lists, task lists, links, pictures, tables, code, and blockquotes. Wide tables scroll sideways inside the page. Fenced code that names its language is colored. Pictures with a relative path load from the note's folder. A `#fragment` link scrolls to the heading with that id, and a relative link opens the file it names. The page uses the same side padding as the editor, a line height of 1.75, and hanging punctuation where the system supports it. It follows light and dark mode. Code uses one monospace face in both.

Reading is an HTML page in one `WKWebView` per window. The view stays with the window and is shown again the next time that window is in Reading. A folder window replaces the note text when you select another file. Parsing is [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm: tables, strikethrough, task lists). A separate walker turns that syntax tree into HTML. Typing waits about 220ms (a little longer for a large note), then the page body is replaced in place. The shell is loaded once; a script error does not load it again. Raw HTML in the file is shown as text, and `javascript:` / `data:` URLs are not turned into links. The Mac sandbox has the network client entitlement so the web content process can start. The renderer still does not request remote images. The iOS entitlements do not add that key.

## View modes

The View menu lists Source and Reading. ⌘/ is Source Code Mode, as in [Typora's shortcut list](https://support.typora.io/Shortcut-Keys/). It switches Source and Reading. ⌘E is Edit → Use Selection for Find. In a folder window, ⌘1 through ⌘8 select those tabs and ⌘9 selects the last. ⌘W closes the current tab. Find in the open file is ⌘F, in a bar above the editor. ⌥⌘F adds replace. ⌘K opens a search panel over the window: recent files, then filename and text matches as you type. Esc or ⌘K closes it. Replace across files is Edit → Replace in Folder…, only in Editing, and Replace All still asks before it changes anything. ⌘P opens the command palette. XYZ has no print command; Print is ⌘⇧⌥P.

⌘P is Quick Open. An empty field lists files opened in that folder, most recent first. Typing matches any file, and the matched characters are semibold. A leading `>` lists commands (view modes, Go to Heading, sidebar, new file, new folder, Open Folder, Reveal in Finder, Copy Path, Copy Relative Path, Close Tab, Reload, About XYZ) and shows each shortcut on the right. A leading `@` lists the note's headings, deeper ones indented; View → Go to Heading… (⌘R) opens the palette that way. Choosing a heading puts the caret on it in Source, or scrolls Reading to it. ↑ and ↓, or ⌃P and ⌃N, move the selection. Return runs it. ⌘Return opens a file in a new window. Esc or a click outside dismisses the palette. It is not a button on the note.

The sidebar has no filter field. ⌘K searches file names, paths, and text in the open folder. On macOS 26 and later the command palette uses Liquid Glass when Reduce Transparency and Increase Contrast are off. Earlier systems keep a sidebar material and a material palette.

## Settings

XYZ → Settings… is one pane:

- Appearance: System, Light, or Dark, for the whole app.
- Language: System, English, or 简体中文. It sets the app's own language list; XYZ uses the new language after it restarts, and Restart Now does that.
- Text: Default or Monospaced font; a size from 12 to 24 pt shared by Source and Reading; and Limit line width, which keeps a line near 42 em (about 42 Chinese characters) in wide windows. View → Zoom In (⌘+), Zoom Out (⌘−), and Actual Size (⌘0) step the same size.
- Text also has Show line numbers, on by default: Source numbers each line of the file in the left padding, right-aligned against the text, and a wrapped line keeps its number on its first row. View → Show Line Numbers is the same switch.
- View: Show word count. A quiet line under the note shows the count and the reading time. Chinese and Japanese count by character, other languages by word. View → Show Word Count is the same switch.

Esc closes the topmost popup wherever focus is, including the find field and the Reading page: the find bar, folder search, the command palette, Go to Line, the ⌃Tab switcher (Esc cancels it), a status-bar menu, Settings, About, or a confirmation (Cancel, or OK when that is the only button). Focus then returns to the editor. An input method that is still composing keeps Esc.

The interface is in English and Simplified Chinese, from `XYZ/Resources/Localizable.xcstrings`. Menu code finds the system menus by their actions rather than their titles, so it works in either language.

## Layout

`XYZCore` is a local Swift package linked by the app:

- `TextDocument` reads and writes UTF-8.
- `MarkdownFileDocument` is the `ReferenceFileDocument` the document scene saves. The text view keeps the buffer; SwiftUI is not given a new string on every keystroke.
- `MarkdownParser` builds the syntax tree. `HTMLRenderer` only walks a tree, and gives headings GitHub-style ids. `MarkdownHTML` is the small public wrapper.
- `SourceEditing` holds list continuation and indent as pure functions from text and selection to one replacement.
- `MarkdownOutline` lists headings with their source lines. `TextStatistics` counts words and characters.

The app target is shared SwiftUI. `XYZMacEditor` and `XYZIOSEditor` are the platform text views. They share `XYZEditor` / `XYZTextEditing`. The Mac editor applies light heading and marker styling in the text storage without putting those attributes in the saved file. Find and replace, and large-file updates, can still land on `textLayoutManager`.

Typing undo uses the text view, pointed at the document scene's undo manager, so the system can tell the file is dirty and autosave it.

## Folders on Mac

File → Open Folder… (⇧⌘O) opens a folder beside the single-document windows. That panel accepts only folders, shows hidden files, and its button says Open Folder. File → Open (⌘O) still opens Markdown and plain text; choosing a folder there opens the same workspace. You can also drop a folder on the Dock icon or on a workspace window. The sidebar is the explorer. Its header says Explorer, then the folder name and the tree. There is no filter field. Edit → Find in Files (⌘K) opens a centered search panel for filenames, paths, and text in the folder. Hidden files are included when they are shown in the sidebar. Outline is a collapsed section at the bottom. The window title, centered in the title bar, is the open file, an em dash, and the folder. ⌘K matches file names and paths, including hidden files when they are shown, and it searches text in the folder. That text search skips `.git`, `node_modules`, and `.build`, skips large and binary files, and can be cancelled. With no file open, the editor shows only the empty state. The breadcrumb under the tabs is the way there from the workspace root.

Names truncate at the tail, with the full name in the tooltip. Extensions stay visible and are dimmed for `.md`, `.markdown`, `.txt`, and `.text`. Folders sort first, then by the system natural order, so `v0.0.10` follows `v0.0.9`. Hidden files are dimmed. ⇧⌘. hides them, the same shortcut Finder uses. `.git` starts collapsed, and expanding it is not remembered. Children load when a folder is expanded, off the main thread, and the list updates when files are added, removed, or renamed without collapsing folders you opened. A single click opens a file. Return or Space opens a file or expands a folder. The context menu can create a file or folder, rename in place, reveal the item, copy its path, or move it to the Trash. Dragging an item onto a folder moves it inside the workspace.

Markdown files (`.md`, `.markdown`) follow the window's view mode. Other text, including source files and dotfiles, opens in the editor. Code and structured text use a fixed-width face and a quiet coloring of comments, strings, numbers, and keywords. JSON can be pretty-printed in Reading, and CSV or TSV can be a table. A file is not treated as binary just because an 8 KiB sample ends in the middle of a UTF-8 character, which is common with Chinese text. Pictures, PDF, and audio or video open in a viewer. Anything else that is not text uses Quick Look. Text over 5 MB stays out of the editor and can be handed to the default app. Edits are written back with a coordinated save, in the encoding and line ending the file already used. If the file changes on disk while you have unsaved edits, XYZ asks before overwriting.

Open files stay in a tab bar under the title bar, across the editor. A tab shows an icon, the name, and a close button. A single click replaces the preview tab. Editing, or a double click, pins it. A breadcrumb row under the tabs is the path. The status bar runs the full width of the window and shows the caret, encoding, line ending, file type, and Read-only or Editing.

The Mac sandbox already has user-selected read-write and app-scoped bookmark entitlements. Opening a folder stores a security-scoped bookmark in your user defaults (not in the repo) so recent folders can reopen next launch. iPhone and iPad still use the document browser only; the tree model lives in `XYZCore` so a later iOS folder view can reuse it.

## Build and run

You need Xcode with the macOS 14 and iOS 17 SDKs. CI uses the current `macos-latest` runner and selects the newest Xcode installed there. Open the project and run the **XYZ** scheme on My Mac or an iOS Simulator:

```sh
open XYZ.xcodeproj
```

From the command line, without signing:

```sh
xcodebuild \
  -project XYZ.xcodeproj \
  -scheme XYZ \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  build
```

iOS Simulator:

```sh
xcodebuild \
  -project XYZ.xcodeproj \
  -scheme XYZ \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  build
```

Package tests (document round-trip and Markdown HTML):

```sh
swift test --package-path XYZCore
```

Signing is Automatic. `Config/Base.xcconfig` is the base configuration for the app target's Debug and Release, and it sets `DEVELOPMENT_TEAM` to empty. CI still passes `CODE_SIGNING_ALLOWED=NO`, so the GitHub build stays unsigned. Hardened Runtime is off so that unsigned build can succeed. Turn Hardened Runtime on before you notarize a Mac build.

To sign on your own Mac, copy the example and put your team id in the gitignored file:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` then contains:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

Replace `YOURTEAMID` with the id from Xcode Settings → Accounts. `Base.xcconfig` includes that file when it exists, and a later assignment there overrides the empty default. Do not also set Development Team in the target's Build Settings. A value in the project file overrides the xcconfig, and it would be committed.

## iCloud Drive

The project already declares the iCloud Documents capability:

- Mac entitlements in `XYZ/XYZ-macOS.entitlements` (App Sandbox, outgoing network for the preview process, user-selected files, app-scoped bookmarks, iCloud Documents).
- iOS entitlements in `XYZ/XYZ-iOS.entitlements`.
- Container `iCloud.com.lizhichao.XYZ`, also listed under `NSUbiquitousContainers` in `XYZ/Info.plist`, with the document scope public so the folder can show up in iCloud Drive.
- Document types so XYZ is an editor for `net.daringfireball.markdown` and plain text. Handler rank is Alternate, so it appears in Open With and does not take over every Markdown file.

That is not enough for iCloud to work on a device. Apple only grants the container to a signed app. In Xcode:

1. Select the XYZ target, then Signing & Capabilities.
2. Set your team id in `Config/Local.xcconfig`, as described under Build and run. Leave the target's Development Team build setting unset.
3. Leave signing on Automatic. Xcode will create a provisioning profile.
4. Confirm iCloud is enabled with **iCloud Documents** (CloudKit is not required). The container identifier must stay `iCloud.com.lizhichao.XYZ`. If Xcode warns that the container is missing, create it from that capability editor. The Apple ID needs a program membership that can register iCloud containers.
5. Run on a device or a Mac that is signed into iCloud. The system open panel (Mac) and document browser (iPhone and iPad) then list iCloud Drive directly. The app's own folder appears in iCloud Drive after the container has been provisioned and the app has launched once.

A build made with `CODE_SIGNING_ALLOWED=NO` does not embed these entitlements, so iCloud will not work until you sign with a team. On the Mac, the sandbox also needs the user-selected file entitlement (already in the Mac entitlements) or Open and Save cannot see files the user picks, including files that live in iCloud Drive.

## Version

XYZ uses MAJOR.MINOR.PATCH. `MARKETING_VERSION` in `Config/Base.xcconfig` is the version shown in About, and `CURRENT_PROJECT_VERSION` is the build number. Those two assignments are the only version source. The target does not set them again, because a value in the project file would override the xcconfig. A small change bumps the last number, a medium change the middle number, and a large or breaking change the first. This release is 0.5.5 (build 21). See `CHANGELOG.md`.

About XYZ is a small window titled About XYZ. It shows the app icon, the version line `0.5.5 (21)`, and the credit line. The credit links the name LIZHICHAO to [lizhichao.com](https://lizhichao.com). Esc or ⌘W closes it.

## App icon

The icon is the name, `_xyz`, set in Inter and converted to outlines, on a soft gray field (light) or near-black (dark); tinted is white on black. The underscore is drawn as a bar as heavy as the letters' stems and sits on the baseline. Up to 64 pixels the word is set larger and heavier so it stays legible in Finder and in menus.

`tools/make_icons.py` draws it. `--write` renders the iOS light, dark, and tinted 1024 images and the macOS sizes (on the rounded plate with its shadow) into `AppIcon.appiconset`, and the source vectors into `Design/Icon/`. `--sheet OUT.html` writes a review sheet at full size and at 128, 64, 32, and 16 pixels. It needs fontTools (`pip3 install fonttools`) and Inter; set `INTER` to the folder with the Inter `.otf` files if they are not in a standard font folder. It renders with headless Chrome; set `CHROME` to another Chromium binary if Chrome is not in `/Applications`.

## License

XYZ is released under the [MIT License](LICENSE). Copyright (c) 2026 lizhichaox.

Parsing uses [swift-markdown](https://github.com/swiftlang/swift-markdown), which is licensed under the Apache License 2.0.

Reading colors code with [highlight.js](https://highlightjs.org) 11.11.1 (common languages), bundled as `XYZ/Resources/highlight.min.js` under the BSD 3-Clause License.

The app icon wordmark is set in Inter (SIL Open Font License 1.1) and converted to outlines. The source vectors are in `Design/Icon/`.
