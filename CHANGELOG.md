# Changelog

## 0.0.2

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
