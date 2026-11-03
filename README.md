# XYZ

[![CI](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml/badge.svg)](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml)

XYZ is a small native document editor for Markdown and plain text. One SwiftUI codebase runs on macOS, iPhone, and iPad. Opening and saving goes through Apple's document browser, so iCloud Drive files are ordinary documents once the app is signed with the iCloud capability.

New documents are Markdown (`.md`). The app also opens and saves `.markdown` and plain text (`.txt`). Text is UTF-8. A leading byte-order mark is dropped on read and is not written back.

## What you see

- A proportional text editor in the system font (SF Pro, with PingFang SC for Chinese), 16pt, with a line box about 1.7 times the font size so wrapped lines and hard returns share one rhythm. The text uses the width of the pane, with side padding that stays between 24 and 64 points. Markdown markers are tinted and headings are slightly larger. Settings chooses the font (Default or Monospaced) and the size, and can limit the line width (see Settings below). On the Mac the view is an `NSTextView`; on iOS it is a `UITextView`. Both use TextKit 2. In a Markdown file, Return continues a list (and leaves the list on an empty item), Tab and Shift-Tab indent it, and the Format menu edits Markdown (see Format below). Other files, such as `.txt`, `.gitignore`, or source code, are plain text: no heading sizes or tinted markers, and none of those edits. Spell checking is on for Markdown and `.txt` only, so config files and code are not underlined.
- A Markdown note is either Source (the editor) or Reading (the rendered note). The content area shows one of them. The choice is remembered for each folder window, and for a document window while it is open. A newly opened file uses Reading only when that window was last in Reading. The reading and editing surface has no buttons of its own, including the toolbar above it. The sidebar toggle stays on the sidebar side.
- On iPhone and iPad the same two modes are in the View menu.
- Reading renders headings, emphasis, lists, task lists, links, pictures, tables, code, and blockquotes. Wide tables scroll sideways inside the page. Fenced code that names its language is colored. Pictures with a relative path load from the note's folder. A `#fragment` link scrolls to the heading with that id, and a relative link opens the file it names. The page uses the same side padding as the editor, a line height of 1.75, and hanging punctuation where the system supports it. It follows light and dark mode. Code uses one monospace face in both.

Reading is an HTML page in one `WKWebView` per window. The view stays with the window and is shown again the next time that window is in Reading. A folder window replaces the note text when you select another file. Parsing is [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm: tables, strikethrough, task lists). A separate walker turns that syntax tree into HTML. Typing waits about 220ms (a little longer for a large note), then the page body is replaced in place. The shell is loaded once; a script error does not load it again. Raw HTML in the file is shown as text, and `javascript:` / `data:` URLs are not turned into links. The Mac sandbox has the network client entitlement so the web content process can start. The renderer still does not request remote images. The iOS entitlements do not add that key.

## View modes

The View menu lists Source and Reading. ⌘/ is Source Code Mode, as in [Typora's shortcut list](https://support.typora.io/Shortcut-Keys/). It switches Source and Reading. ⌘E is Edit → Use Selection for Find. ⌘1 through ⌘9 are left unbound so window tabs can use them. Find in the open note stays ⌘F. XYZ has no print command; Print is ⌘⇧⌥P, and ⌘P opens the command palette.

⌘P is Quick Open. An empty field lists files opened in that folder, most recent first. Typing matches any file, and the matched characters are semibold. A leading `>` lists commands (view modes, Go to Heading, sidebar, new file, new folder, Open Folder, Reveal in Finder, Copy Path, Reload, About XYZ) and shows each shortcut on the right. A leading `@` lists the note's headings, deeper ones indented; View → Go to Heading… (⌘R) opens the palette that way. Choosing a heading puts the caret on it in Source, or scrolls Reading to it. ↑ and ↓, or ⌃P and ⌃N, move the selection. Return runs it. ⌘Return opens a file in a new window. Esc or a click outside dismisses the palette. It is not a button on the note.

The sidebar filter is a native search field. On macOS 26 and later the command palette uses Liquid Glass when Reduce Transparency and Increase Contrast are off. Earlier systems keep a sidebar material and a material palette.

## Format

The Format menu edits the Markdown source. Its items are enabled while a Markdown editor has focus, and dimmed in Reading and in plain text. Shortcuts follow Typora where macOS leaves them free; headings use ⌥⌘ because ⌘1 to ⌘9 stay with window tabs.

| Item | Shortcut | Item | Shortcut |
|---|---|---|---|
| Bold | ⌘B | Quote | ⌥⌘Q |
| Italic | ⌘I | Bulleted List | ⌥⌘U |
| Strikethrough | ⇧⌘X | Numbered List | ⌥⌘O |
| Inline Code | ⌃` | Task List | ⌥⌘X |
| Link | ⌘K | Code Block | ⌥⌘C |
| Heading → Paragraph | ⌥⌘0 | Table | |
| Heading → Heading 1 to 6 | ⌥⌘1 to ⌥⌘6 | | |

Inline formats wrap the selection, or unwrap it when it is already wrapped. Line formats apply to every line the selection touches: choosing the level a heading already has, or a list kind the lines already are, turns it off. A numbered list is renumbered from 1. Link wraps the selection as `[text]()` with the caret in the parentheses; a selected web address becomes the destination instead. Code Block fences the lines and leaves the caret where the language goes. Lines inside a code fence are left alone. Each command is one undo step.

## Settings

XYZ → Settings… is one pane:

- Appearance: System, Light, or Dark, for the whole app.
- Language: System, English, or 简体中文. It sets the app's own language list; XYZ uses the new language after it restarts, and Restart Now does that.
- Text: Default or Monospaced font; a size from 12 to 24 pt shared by Source and Reading; and Limit line width, which keeps a line near 42 em (about 42 Chinese characters) in wide windows. View → Zoom In (⌘+), Zoom Out (⌘−), and Actual Size (⌘0) step the same size.
- Text also has Show line numbers, on by default: Source numbers each line of the file in the left padding, right-aligned against the text, and a wrapped line keeps its number on its first row. View → Show Line Numbers is the same switch.
- View: Show word count. A quiet line under the note shows the count and the reading time. Chinese and Japanese count by character, other languages by word. View → Show Word Count is the same switch.

Esc closes Settings, About, alerts (it picks Cancel, or OK when that is the only button), the command palette, and the find bars.

The interface is in English and Simplified Chinese, from `XYZ/Resources/Localizable.xcstrings`. Menu code finds the system menus by their actions rather than their titles, so it works in either language.

## Layout

`XYZCore` is a local Swift package linked by the app:

- `TextDocument` reads and writes UTF-8.
- `MarkdownFileDocument` is the `ReferenceFileDocument` the document scene saves. The text view keeps the buffer; SwiftUI is not given a new string on every keystroke.
- `MarkdownParser` builds the syntax tree. `HTMLRenderer` only walks a tree, and gives headings GitHub-style ids. `MarkdownHTML` is the small public wrapper.
- `SourceEditing` holds the typing and Format edits as pure functions from text and selection to one replacement.
- `MarkdownOutline` lists headings with their source lines. `TextStatistics` counts words and characters.

The app target is shared SwiftUI. `XYZMacEditor` and `XYZIOSEditor` are the platform text views. They share `XYZEditor` / `XYZTextEditing`. The Mac editor applies light heading and marker styling in the text storage without putting those attributes in the saved file. Find and replace, and large-file updates, can still land on `textLayoutManager`.

Typing undo uses the text view, pointed at the document scene's undo manager, so the system can tell the file is dirty and autosave it.

## Folders on Mac

File → Open Folder… (⇧⌘O) opens a folder beside the single-document windows. That panel accepts only folders, shows hidden files, and its button says Open Folder. File → Open (⌘O) still opens Markdown and plain text; choosing a folder there opens the same workspace. You can also drop a folder on the Dock icon or on a workspace window. The sidebar is a source list. A filter field sits at its top (Filter Files, ⌘⇧F). Typing matches file and folder names, including hidden ones, and keeps the parent folders of a match. Esc clears the field. A second section lists text matches from Markdown and other text files. That search skips `.git`, `node_modules`, and `.build`, skips large and binary files, and can be cancelled. The window title is the open file. Its subtitle is the way there from the workspace root, such as `LIZHICHAO › DT`; a deep path keeps the root and the nearest folders, with `…` between. ⌘-click the title for the full path.

Names truncate at the tail, with the full name in the tooltip. Extensions stay visible and are dimmed for `.md`, `.markdown`, `.txt`, and `.text`. Folders sort first, then by the system natural order, so `v0.0.10` follows `v0.0.9`. Hidden files are dimmed. ⇧⌘. hides them, the same shortcut Finder uses. `.git` starts collapsed, and expanding it is not remembered. Children load when a folder is expanded, off the main thread, and the list updates when files are added, removed, or renamed without collapsing folders you opened. A single click opens a file. Return or Space opens a file or expands a folder. The context menu can create a file or folder, rename in place, reveal the item, copy its path, or move it to the Trash. Dragging an item onto a folder moves it inside the workspace.

Markdown files (`.md`, `.markdown`) follow the window's view mode. Other text, including source files and dotfiles, opens in the editor. A file is not treated as binary just because an 8 KiB sample ends in the middle of a UTF-8 character, which is common with Chinese text. Binary files and files over 5 MB show a short message and can be handed to the default app. Edits are written back with a coordinated save. If the file changes on disk while you have unsaved edits, XYZ asks before overwriting.

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

XYZ uses MAJOR.MINOR.PATCH. `MARKETING_VERSION` in `Config/Base.xcconfig` is the version shown in About, and `CURRENT_PROJECT_VERSION` is the build number. Those two assignments are the only version source. The target does not set them again, because a value in the project file would override the xcconfig. A small change bumps the last number, a medium change the middle number, and a large or breaking change the first. This release is 0.0.3 (build 5). See `CHANGELOG.md`.

About XYZ is a small window titled About XYZ. It shows the app icon, the version line `0.0.3 (5)`, and the credit line. The credit links the name LIZHICHAO to [lizhichao.com](https://lizhichao.com). Esc or ⌘W closes it.

## App icon

The icon is the name, `_xyz`, set in Inter and converted to outlines, on a soft gray field (light) or near-black (dark); tinted is white on black. The underscore is drawn as a bar as heavy as the letters' stems and sits on the baseline. Up to 64 pixels the word is set larger and heavier so it stays legible in Finder and in menus.

`tools/make_icons.py` draws it. `--write` renders the iOS light, dark, and tinted 1024 images and the macOS sizes (on the rounded plate with its shadow) into `AppIcon.appiconset`, and the source vectors into `Design/Icon/`. `--sheet OUT.html` writes a review sheet at full size and at 128, 64, 32, and 16 pixels. It needs fontTools (`pip3 install fonttools`) and Inter; set `INTER` to the folder with the Inter `.otf` files if they are not in a standard font folder. It renders with headless Chrome; set `CHROME` to another Chromium binary if Chrome is not in `/Applications`.

## License

XYZ is released under the [MIT License](LICENSE). Copyright (c) 2026 lizhichaox.

Parsing uses [swift-markdown](https://github.com/swiftlang/swift-markdown), which is licensed under the Apache License 2.0.

Reading colors code with [highlight.js](https://highlightjs.org) 11.11.1 (common languages), bundled as `XYZ/Resources/highlight.min.js` under the BSD 3-Clause License.

The app icon wordmark is set in Inter (SIL Open Font License 1.1) and converted to outlines. The source vectors are in `Design/Icon/`.
