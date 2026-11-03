# Changelog

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
