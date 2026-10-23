# XYZ

[![CI](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml/badge.svg)](https://github.com/lizhichaox/XYZ/actions/workflows/ci.yml)

XYZ is a small native document editor for Markdown and plain text. One SwiftUI codebase runs on macOS, iPhone, and iPad. Opening and saving goes through Apple's document browser, so iCloud Drive files are ordinary documents once the app is signed with the iCloud capability.

New documents are Markdown (`.md`). The app also opens and saves `.markdown` and plain text (`.txt`). Text is UTF-8. A leading byte-order mark is dropped on read and is not written back.

## What you see

- A proportional text editor in the system font (SF Pro, with PingFang SC for Chinese), about 16pt with comfortable line height. Markdown markers are tinted and headings are slightly larger. Settings → Monospaced editor font switches the editor to a fixed-width face. On the Mac the view is an `NSTextView`; on iOS it is a `UITextView`. Both use TextKit 2.
- A Markdown preview beside the editor on the Mac and on iPad, starting at half the width. Drag the divider to resize it. The toolbar Preview button (and View → Show/Hide Preview, ⇧⌘P) shows or hides it.
- On iPhone, an Edit / Preview control switches between the two. The text view stays mounted, so the cursor is still there when you come back.
- Preview renders headings, emphasis, lists, task lists, links, images (as tags), tables, code, and blockquotes. It follows light and dark mode.

The preview is an HTML page in a `WKWebView`. Parsing is [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm: tables, strikethrough, task lists). A separate walker turns that syntax tree into HTML. Typing waits about 220ms, then the page body is replaced in place instead of reloading the web view. Raw HTML in the file is shown as text, and `javascript:` / `data:` URLs are not turned into links. Remote images are not fetched: the Mac sandbox has no network entitlement.

## Layout

`XYZCore` is a local Swift package linked by the app:

- `TextDocument` reads and writes UTF-8.
- `MarkdownFileDocument` is the `ReferenceFileDocument` the document scene saves. The text view keeps the buffer; SwiftUI is not given a new string on every keystroke.
- `MarkdownParser` builds the syntax tree. `HTMLRenderer` only walks a tree. `MarkdownHTML` is the small public wrapper.

The app target is shared SwiftUI. `XYZMacEditor` and `XYZIOSEditor` are the platform text views. They share `XYZEditor` / `XYZTextEditing`. The Mac editor applies light heading and marker styling in the text storage without putting those attributes in the saved file. Find and replace, and large-file updates, can still land on `textLayoutManager`.

Typing undo uses the text view, pointed at the document scene's undo manager, so the system can tell the file is dirty and autosave it.

## Folders on Mac

File → Open Folder… (⇧⌘O) opens a folder beside the single-document windows. That panel accepts only folders, shows hidden files, and its button says Open Folder. File → Open (⌘O) still opens Markdown and plain text; choosing a folder there opens the same workspace. You can also drop a folder on the Dock icon or on a workspace window. The sidebar is a source list headed by the folder name. It lists every subdirectory and file, including hidden ones (`.gitignore`, `.github`, `.DS_Store`), which are drawn in the secondary label color. ⇧⌘. hides those, the same shortcut Finder uses. Folders sort first, then names, without regard to case. Children load when a folder is expanded, off the main thread, and the list updates when files are added, removed, or renamed. The window title is the open file, with the folder name as its subtitle.

Markdown files (`.md`, `.markdown`) open in the editor and preview. Other text, including source files and dotfiles, opens in the editor with the preview hidden. Binary files and files over 5 MB show a short message and can be handed to the default app. Edits are written back with a coordinated save. If the file changes on disk while you have unsaved edits, XYZ asks before overwriting.

The Mac sandbox already has user-selected read-write and app-scoped bookmark entitlements. Opening a folder stores a security-scoped bookmark in your user defaults (not in the repo) so recent folders can reopen next launch. iPhone and iPad still use the document browser only; the tree model lives in `XYZCore` so a later iOS folder view can reuse it.

## Build and run

You need Xcode with the macOS 14 and iOS 17 SDKs (the CI image is the current `macos-latest` runner). Open the project and run the **XYZ** scheme on My Mac or an iOS Simulator:

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

- Mac entitlements in `XYZ/XYZ-macOS.entitlements` (App Sandbox, user-selected files, app-scoped bookmarks, iCloud Documents).
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

## License

XYZ is released under the [MIT License](LICENSE). Copyright (c) 2026 lizhichaox.

Parsing uses [swift-markdown](https://github.com/swiftlang/swift-markdown), which is licensed under the Apache License 2.0.

The app icon wordmark is set in Inter (SIL Open Font License 1.1) and converted to outlines. The source vectors are in `Design/Icon/`.
