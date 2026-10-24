# Changelog

## Unreleased

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

## 0.0.3

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
