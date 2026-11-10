# XYZCore Analysis Report

> Analyst: core-analyst (read-only analysis; no repository file was modified)
> Output: /tmp/xyz-analysis/core.md
> Baseline: the Lead verified `swift test --package-path XYZCore` = 191 tests / 0 failures (local Xcode 27.2 + Swift 6.4.2), and the sources contain no TODO/FIXME/HACK. All conclusions in this report come from source reading plus grep reference checks; the tests were not re-run.

## 0. Scope, Method, and One Factual Correction

- Source directory: `XYZCore/Sources/XYZCore/` — **29 .swift files, 5,761 lines in reality** (not the 21 stated in the task brief).
- Test directory: `XYZCore/Tests/XYZCoreTests/` — **9 .swift files, 2,177 lines, 191 `func test`, 741 XCTAssert** in reality (not 8).
- Package configuration: `Package.swift` (swift-tools-version 5.9, macOS 14 / iOS 17, single target + single testTarget, sole external dependency swift-markdown); `Package.resolved` pins swift-markdown 0.9.0 (`25cb61d…`) and swift-cmark 0.9.0 (`08ddb52…`).
- The repo-wide figure of 66 Swift files / 28.4k lines is reproducible: 27 App target files (20,456 lines) + 29 Core source files (5,761 lines) + 9 test files (2,177 lines) + `XYZCore/Package.swift` = 66 files, about 28.4k lines. In other words, "21 source files / 8 test files" is a typo in the task brief.
- Method: `read` covered all 29 source files and 9 test files; `grep -rn` checked the real callers of every public symbol in `XYZ/` (the App target) and `XYZCore/Sources`; `wc`/`grep -c` counted lines and tests; git log traced the commits that introduced key APIs. All line numbers were located with read's offset/limit or grep -n and can be traced back directly.

## 1. Module Map

### 1.1 Per-File Responsibilities (29 files)

| Group | Files (lines) | Responsibility |
|---|---|---|
| Text IO | TextBytes.swift (309) | Encoding detection (UTF-8/BOM/UTF-16/Windows-1252), line-ending normalization and write-back, read-only preview |
| | TextDocument.swift (42) | Minimal UTF-8-only document value type; BOM stripped on read, never added on write |
| | FileFormat.swift (242) | Extension → language/Reading/font/viewer; shebang detection; isTextualName |
| | ContentTypes.swift (12) | Custom `UTType.markdown` (`net.daringfireball.markdown`) |
| | MarkdownFileDocument.swift (64) | SwiftUI `ReferenceFileDocument` adapter (document scene), NSLock + String |
| Editing logic | SourceEditing.swift (462) | Markdown list continuation/indent/inline markers (**/~~/`), SourceRange/SourceReplacement, fence/lineRange/split helpers |
| | SourceFormatting.swift (283) | `extension SourceEditing`: six block-level commands — heading/quote/list/code block/table/link |
| | TextTransforms.swift (280) | Line editing: duplicate/move/delete line, comment toggling, indent, join/sort/trim trailing whitespace/case |
| | TextFind.swift (182) | Find and replace (literal/regex/wholeWord/case), single `scan` find, `PathGlob` path glob |
| | TextStatistics.swift (114) | Word/character counts and reading time; `LineIndex` UTF-16 line index |
| | EditorCaret.swift (101) | Caret line/column and selection statistics; `GoToPosition` parsing and in-line character column → UTF-16 offset |
| Line numbers/geometry | LogicalLineGutter.swift (148) | Logical line-number labels, Reading block line numbers, `FindScroll` scroll landing |
| Markdown/Reading | MarkdownParser.swift (16) | swift-markdown parsing (internal, `disableSmartOpts`) |
| | HTMLRenderer.swift (512) | AST → HTML (internal walker), heading anchors, callouts, `HTMLText` escaping, `URLPolicy` URL allowlist |
| | MarkdownHTML.swift (16) | The only public Markdown → HTML facade |
| | ReadingSource.swift (198) | Pre-render preprocessing: front matter → properties, `[[wiki link]]` rewrite (internal) |
| | MarkdownOutline.swift (37) | Heading outline (public) |
| | FileOutline.swift (237) | Outline facade: Markdown headings / JSON keys / declaration scanning; follow-line policy |
| | SyntaxColoring.swift (488) | Lightweight coloring span computation for 24 languages (250k scan cap + visible window) |
| | StructuredText.swift (110) | JSON pretty print, CSV/TSV table parsing (500-row cap) |
| Workspace/tree | WorkspaceNode.swift (130) | Tree nodes/breadcrumbs/path helpers/natural sort/visibility filter |
| | WorkspaceDirectoryLoader.swift (34) | Single-level directory listing (symlinks as files, hidden entries included) |
| | WorkspaceSearch.swift (438) | Name matching (substring/fuzzy), tree filtering, file icons, new-name generation, content search, sidebar geometry (SidebarFit/OutlineDisclosure/ExplorerSection) |
| | GlobalSearch.swift (63) | ⌘K file name/path fuzzy matching and ranking |
| Tabs/modes | EditorTabs.swift (384) | Tab strip (preview/pin/dirty/close), close history, window-state Codable, TabMRU, cross-window targeting |
| | EditorViewMode.swift (255) | Source/Reading modes, file access level, `EditorScrollAnchor`, `ReadingLineMap` |
| Policy/misc | WorkspaceFilePolicy.swift (281) | File classification/size/UTF-8 sampling, open routing, disk-change and write decisions, read-install and save-follow predicates |
| | CommandPalette.swift (312) | Fuzzy matcher, palette command table/registry, row generation for the three `>` `@` `:` modes |
| | PhantomWindowPolicy.swift (11) | Phantom window (TUINSWindow) cleanup allowlist |

### 1.2 Real Reference Relationships (grep-verified, not self-reported)

- Text IO: `TextDocument` is used only by `MarkdownFileDocument` (MarkdownFileDocument.swift:37, 62) → the document-scene path = TextDocument/UTF-8; the workspace path = `TextBytes` (App `XYZ/Workspace/WorkspaceFileAccess.swift:122,139,163`, `WorkspaceSession.swift:1326…`). **Two IO stacks coexist.**
- Editing layer: `TextTransforms`/`TextFind` depend on `SourceRange` (defined in SourceEditing.swift:28-38); `SourceFormatting` reuses internal helpers through `extension SourceEditing` (contains/coveringLines/insideFence/collectLines/lineRange/split, SourceFormatting.swift:175-180, 90-93, 109-111).
- Line numbers/caret: `LineIndex` (TextStatistics.swift:75-114) is used by `EditorCaret.swift:22,30,31`, `LogicalLineGutter.swift:13,39`, and App `XYZMacEditor.swift:655,711`; `TextFind.lineNumber:126-136`, `EditorScrollAnchor.lineNumber/utf16Location:144-184`, and `WorkspaceContentSearch.newlineCount:408-416` each recompute it themselves (see §4.1).
- Markdown: `MarkdownHTML` (MarkdownHTML.swift:9-11) → `ReadingSource.prepare` → `MarkdownParser.parse` → `HTMLRenderer.render`; `ReadingSource` depends on `HTMLText`/`HeadingAnchor` (ReadingSource.swift:16-18, 183); `MarkdownOutline` calls `MarkdownParser.parse` directly (MarkdownOutline.swift:23); `FileOutline` → `MarkdownOutline` (FileOutline.swift:38). The public surface is only `MarkdownHTML`/`MarkdownOutline`; parser/renderer/ReadingSource are all internal — **this is the cleanest separation in the package**.
- Workspace: `WorkspaceFilePolicy` → `TextBytes`/`FileFormats` (WorkspaceFilePolicy.swift:89, 105); `WorkspaceSearch` → `WorkspaceNode`/`WorkspacePaths`/`WorkspaceTreeSort`/`WorkspaceFileClassifier`/`FileFormats`/`TextFind` (WorkspaceSearch.swift:136, 188-212, 204, 351-356, 369, 390); `WorkspaceDirectoryLoader` → `WorkspaceNode`/`WorkspaceTreeSort` (WorkspaceDirectoryLoader.swift:24-32); `GlobalSearch` → `WorkspacePathEntry` + `FuzzyMatcher` (GlobalSearch.swift:44-45); `EditorTabs` → `EditorViewMode` + `WorkspacePaths` (EditorTabs.swift:16, 200-203); `CommandPalette` → `FuzzyMatcher`/`OutlineHeading`/`GoToPosition` (CommandPalette.swift:161, 195, 208).
- The App target's public dependencies on Core (19 files `import XYZCore`): preview MarkdownHTML (`XYZ/Preview/MarkdownPreview.swift:51,69,72,84`, `GutterSnapshot.swift:1330`), encoding menu (`EditorChrome.swift:1022,1041`), saving (`WorkspaceFileAccess.swift:122-164`), find (`XYZMacEditor.swift:461,492,506,514-569`), outline (`EditorChrome.swift:1232,1298`), workspace policy (`WorkspaceSession.swift:553,1791,1813,1828,1917`), tabs (`WorkspaceSession.swift:31,630,702,718`), palette/search.

### 1.3 Is the Layering Reasonable?

Reasonable parts:
- Markdown parsing/rendering/preprocessing/outline form a clear small pipeline; the facades (MarkdownHTML/MarkdownOutline) and the implementations (internal MarkdownParser/HTMLRenderer/ReadingSource) are separated correctly.
- The policy layer (WorkspaceFilePolicy) is separated from UI/IO, its pure functions are unit-testable, and the App only receives decision enums — the design most worth keeping in the whole package.

Unreasonable/mixed parts:
- A 5.7k-line single-target package mixes five layers: pure text algorithms, file IO policy, window policy (PhantomWindowPolicy), sidebar geometry (SidebarFit), and a SwiftUI document adapter (MarkdownFileDocument directly `import SwiftUI/Combine`, MarkdownFileDocument.swift:1-4). The last three are not "core text"; putting them here makes `swift test` depend on UI frameworks and blocks future CLI/server-side reuse.
- `SourceEditing` (an enum) is both a namespace and split out via extension by SourceFormatting; the file boundary equals the historical commit boundary, not the module boundary. All four inline toggles in `SourceEditing` and the six block-level commands in SourceFormatting no longer have a caller in the App (see §2.2).
- `WorkspaceSearch.swift` (438 lines, 15 public types) is misnamed: it holds name matching, tree filtering, file icons, new-name generation, move validation, content search, sidebar fit math, and disclosure positions together. The same applies to `EditorViewMode.swift` (modes + access level + scroll anchor + Reading line mapping).
- Line numbers/line indices have no single source of truth: while `LineIndex` exists, there are five more independent implementations (§4.1), a direct consequence of the missing layering.

## 2. Public API Surface

### 2.1 Scale

`grep -c "^\s*public "` over the 29 source files totals **446 lines of public declarations** (including public properties/inits), far beyond what the App actually uses: for a local package serving a single App in this repo, `public` is effectively the default and there is no internal narrowing.

### 2.2 Public but Not Referenced at All by the App Target (grep over `XYZ/` = zero hits; some are test-only or module-internal only)

| Symbol | Evidence | Status |
|---|---|---|
| SourceFormatting's six commands `setHeading/toggleQuote/toggleList/insertCodeBlock/insertTable/insertLink` | SourceFormatting.swift:17-144; `grep -rn "setHeading\|toggleQuote\|toggleList\|insertCodeBlock\|insertTable\|insertLink" XYZ/` = 0 | The product removed the formatting menu (`XYZ/Editor/FormatMenu.swift:4-16` explicitly removes bold/italic/link/heading etc.), yet Core keeps the code plus 16 tests |
| SourceEditing inline toggles `toggleBold/toggleItalic/toggleStrikethrough/toggleInlineCode` | SourceEditing.swift:93-107; `grep` over App = 0 | Same as above; dead code |
| LogicalLineGutter's `labels/editingLabels/placedReading/readingLabels/blockLabels/ReadingLabel/Block` | LogicalLineGutter.swift:11-121; the App only calls `highlighted` (`XYZ/Editor/LineNumberGutter.swift:89`) | Orphaned after 0.5.26 removed Reading line numbers (CHANGELOG.md:55; commit e98f3e5) |
| `ReadingLineMap` | EditorViewMode.swift:234-255; `grep -rn ReadingLineMap XYZ/ XYZCore/Sources` finds only the definition; test WorkspaceTests.swift:332-359 | Test-only dead code |
| `TextFind.step(from:matches:forward:)` | TextFind.swift:42-44; the App uses `stepDetail` (XYZMacEditor.swift:492) | Test-only |
| `WorkspacePaths.breadcrumb(rootName:relativePath:limit:)` | WorkspaceNode.swift:81-88; the App uses `crumbs` (EditorChrome.swift:869) | Test-only |
| `ExplorerSection.fileCount` | WorkspaceSearch.swift:87-93; 0 App references; commit 97c2212 replaced it with header actions (CHANGELOG.md:57) | Test-only |
| `HeadingAnchor` | HTMLRenderer.swift:389-421; 0 in the App; used inside the module by HTMLRenderer/ReadingSource | Could be internal |
| `FuzzyMatcher` | CommandPalette.swift:14-62; 0 in the App (used inside the module by CommandPalette/GlobalFileSearch) | Could be internal; `FuzzyMatch` must stay public because it appears in PaletteRow/GlobalFileHit |
| `WorkspaceNameMatching` | WorkspaceSearch.swift:130-164; 0 in the App (used internally by WorkspaceTreeQuery) | Could be internal |
| `FileFormats.shebangLanguage` | FileFormat.swift:116-123; 0 in the App (used internally by resolved) | Could be internal |
| `CommandPalette.parse` / `PaletteMode` | CommandPalette.swift:213-227, 307-312; the App only uses `rows` (0 uses of parse) | Could be internal |
| `TextBytes.looksLikeUTF16` | TextBytes.swift:157-165; 0 in the App (used internally by WorkspaceFileClassifier) | Could be internal |
| `SyntaxColoring.spans(in: NSString…)` | SyntaxColoring.swift:40-44; the App uses the String overload (XYZMacEditor.swift:1722) | Could be internal |
| `WorkspaceContentSearch.excerpt` | WorkspaceSearch.swift:419-437; 0 in the App (used internally by hits) | Could be internal |
| `EditorModeChoice.showsLineNumbers` | EditorViewMode.swift:75-77, has exactly the same condition as `isEditing` (70-72); the App calls both separately (WorkspaceView.swift:1566,1570) | Redundant semantic API |
| `PaletteCommandRegistry`'s "plugin" narrative | CommandPalette.swift:79, 149-155; `grep -ri plugin` only finds the test CommandPaletteTests.swift:99-122, with no plugin loading path | Premature abstraction |

Also, the `markdown` parameter of `EditorModeChoice.access(kind:markdown:)` is dead: the only App call passes `markdown: buffer.kind == .markdown` (WorkspaceSession.swift:352), and the `.plainText + markdown:true → .preview` branch (EditorViewMode.swift:48-50) is unreachable in the App; only test WorkspaceTests.swift:257-258 covers that combination.

### 2.3 The App Target Re-implements Logic That Core Already Has

1. **fence scanning**: `XYZ/Editor/XYZMacEditor.swift:1762-1783` (`fenceIsOpen`), `:1915-1930` (`isFence`), `:1987` (`contentRange`) are line-for-line isomorphic to Core's `SourceEditing.insideFence/isFence/split` (SourceEditing.swift:377-414, 439-455). Because these two Core functions are internal (SourceEditing.swift:377, 393), the App can only copy them → changing fence semantics (e.g. four backticks, 4-space indentation, `~~~` rules) will make the two drift. Recommendation: promote fence/line splitting to public (or split out a small `SourceTextLines` module) for the App to reuse.
2. **Link scheme allowlist**: `URLPolicy.linkSchemes = ["http","https","mailto"]` (HTMLRenderer.swift:481) and the App's `openIfSafe` switch in `MarkdownWebView.swift:686-696` are two hardcoded copies of the same set; if either side adds a scheme (e.g. `x-apple.systempreferences`), they will diverge.
3. **Formatting**: the App removed the menu (FormatMenu.swift:12-14 still strips selectors such as `xyzBold:`, but the repo no longer defines them), while Core keeps the full implementation — this is not "the App re-implements" but a half-migrated state of "Core keeps it, the App abandoned it"; tests on both sides still cover unreachable code.

## 3. Test Coverage

### 3.1 Quantified Rough Impression (No Fabricated Percentages)

- 191 tests / 741 assertions; test code 2,177 lines vs source 5,761 lines ≈ **0.38:1**.
- Of the 29 source files, about **25 have direct tests and 4 have only indirect coverage** (MarkdownParser, HTMLRenderer, ReadingSource are covered indirectly through MarkdownHTML; ContentTypes is covered indirectly through the MarkdownFileDocument test). No source file has "zero tests", but depth varies a lot: TextFind/TextBytes/WorkspaceFilePolicy are thick, SyntaxColoring/HTMLRenderer/FileOutline are thin.
- Test distribution is uneven: `EditorShellTests.swift` alone packs 9 unrelated suites (TextBytes/EditorTab/WindowRestore/ReadOnlyPreview/OutlineFollow/PhantomWindowPolicy/EditorCaret/FileFormat/FileOutline, 518 lines, 47 tests), whereas `SyntaxColoring` (488 lines) has only 4 tests and `HTMLRenderer` (512 lines) has no dedicated test file.

### 3.2 Module → Test Mapping

| Source module | Test location | Assessment |
|---|---|---|
| TextBytes | EditorShellTests.swift:4-88, 309-339 | BOM/CRLF/CR/mixed/UTF-16LE BOM/1252/preview are all covered; **BOM-less UTF-16 heuristic decoding, UTF-16BE, and UTF-32 rejection are untested** |
| TextDocument / MarkdownFileDocument | TextDocumentTests.swift:5-50; MarkdownHTMLTests.swift:232-258 | Only value semantics tested; `init(configuration:)`/`fileWrapper`/concurrency/`objectWillChange` untested |
| FileFormat | EditorShellTests.swift:404-486 | Only a few extensions covered; `isTextualName` has zero tests (which is why the dotfile logic bug slipped through) |
| FileOutline / MarkdownOutline | EditorShellTests.swift:488-510; SourceFormattingTests.swift:127-134 | Markdown/JSON/Swift basics covered; front matter, wiki-link headings, and the 250k/4k caps untested |
| HTMLRenderer / MarkdownHTML | MarkdownHTMLTests.swift:6-230 | Escaping/unsafe URLs/task lists/tables/callouts/anchors are well covered; **no tests for CRLF front matter, inline HTML, multi-paragraph callouts, or relative images** |
| SyntaxColoring | EditorShellTests.swift:451-485 | Only swift/ini/json + large-file windows; the other 20 languages, block-comment continuation, triple quotes, and escapes are untested |
| TextFind | TextFindTests.swift:4-71 | matches/stepDetail/replaceAll/PathGlob covered; **zero tests for `scan` (actually used by the find bar), `replacement(in:)`, `lineNumber`, zero-length regex, and the wholeWord+regex combination** |
| TextTransforms | TextFindTests.swift:134-197 | Main paths covered; **untested: moveLine upward, deleteLine at the end of the file, comment-suffix boundaries, and sortLines stability** |
| SourceEditing / SourceFormatting | SourceEditingTests.swift:4-129; SourceFormattingTests.swift:4-124 | List continuation/indent/inline markers/six block commands are all covered; **no test for the destructive path of running formatting with the caret on an opening fence line** |
| WorkspaceFilePolicy | WorkspaceTests.swift:361-573 | Classification/ambiguous truncation/conflicts/installation/dirty versions/follow-up saves are all tested; the highest-quality group |
| WorkspaceSearch / WorkspaceNode / GlobalSearch | WorkspaceTests.swift:4-237; GlobalSearchTests.swift:4-118 | Paths/sort/filter/content search/excerpt covered; **no tests for matchLimit=400 truncated, hitLimit=40 truncation, more>0** |
| EditorTabs / EditorViewMode / EditorScrollAnchor | EditorShellTests.swift:90-307; WorkspaceTests.swift:239-330 | preview/pin/close/MRU/window restore well covered; **no tests for setPreview creating multiple previews, retarget conflicts, unknown mode decoding** |
| LogicalLineGutter | TextFindTests.swift:73-131 | The function-level tests are actually decent, but **the tested functions have no caller in the App** (§2.2) — maintaining tests for dead code |
| CommandPalette / FuzzyMatcher | CommandPaletteTests.swift:4-152 | Mode parsing/recent files/command matching/registry covered; the odd heading-limit logic (CommandPalette.swift:206) untested |
| PhantomWindowPolicy | EditorShellTests.swift:350-357 | 11 lines, full coverage |

### 3.3 Key Branches Named by the Task: Tested / Untested

| Branch | Verdict | Evidence |
|---|---|---|
| Encoding/BOM | Tested (UTF-8 BOM, UTF-16LE BOM, 1252 round-trip) | EditorShellTests.swift:14-64 |
| UTF-16 heuristic (no BOM) | **Untested** | No test entry for `heuristicEndian`/`decodeUnicode` at :190-195, :204-222; tests only go through the BOM path |
| Windows-1252 | Tested (decode/encode/canStore) | EditorShellTests.swift:57-64, 512-517 |
| Line endings (LF/CRLF/CR/mixed) | Tested (both TextBytes and LineIndex) | EditorShellTests.swift:22-45; SourceFormattingTests.swift:147-158; WorkspaceTests.swift:318-323 |
| 5 MB cap | Only the classification boundary is tested | WorkspaceTests.swift:391-394 (`editLimit+1 → .tooLarge`); **the previewByteLimit 2 MB truncation path and the open routing for >5 MB files have no Core tests** (logic mainly lives in the App) |
| Search cancellation | **Core has no cancellation logic** (cancellation/generation lives in the App `WorkspaceSession`), and `TextFind.scan` itself is untested | TextFind.swift:96-124; `grep "scan("` tests = 0 |
| Markdown list continuation | Tested (bullet/ordered/task/fence/empty-item indent) | SourceEditingTests.swift:24-73 |
| HTML escaping | Tested (raw HTML, text, attributes, javascript:/data:, image alt) | MarkdownHTMLTests.swift:58-66, 137-171 |
| Find and replace | Partial (literal `$`, CRLF, regex groups, wholeWord, wrap) | TextFindTests.swift:4-48; **scan/replacement/lineNumber absent** |
| Command palette | Tested (9 tests) | CommandPaletteTests.swift |
| Tab preview/pin | Tested (14 tests) | EditorShellTests.swift:90-253 |
| Outline | Partial (Markdown/JSON/Swift) | EditorShellTests.swift:488-510; **the front matter vs Reading inconsistency bug is untested** |

### 3.4 Coupling to Implementation Details / Flaky Risk

- **Exact HTML string assertions**: MarkdownHTMLTests.swift:13 (`<h1 id="hello" data-line="1"`), :20, :55, :156 require attribute names and order to match exactly; an order change or one extra space fails them. Acceptable as a rendering contract, but once attribute order may change, these become meaningless failures.
- **Facade = internal pipeline equivalence test**: MarkdownHTMLTests.swift:194-202 `testFacadeMatchesDecoupledRenderer` uses `@testable` to compare `MarkdownHTML.render` with `HTMLRenderer().render(MarkdownParser.parse(...))`; any preprocessing change (front matter/wiki link order) makes this test express "the internal implementation must stay as it is" rather than "the output is correct".
- **Constant coupling**: EditorShellTests.swift:467-478 builds 130,000 lines to assert `scanLimit` behavior (>250k characters); :512-517 `sampleCutting` depends on the 8,192 constant; once a cap is adjusted, the failures carry no information.
- **Real file system/symlinks**: WorkspaceTests.swift:72-104 creates a temporary directory + `createSymbolicLink`; it may be flaky in restricted CI/sandboxes or on APFS case-sensitivity configurations (low probability, but this is the only test that touches disk).
- **Trailing empty-line semantics tied to `lines(in:)`**: expected values in WorkspaceTests.swift:283-296, :291-296 depend on EditorScrollAnchor.swift:202-226 not counting the trailing empty line; this differs from `LineIndex` (which counts it), so changing either side fails the test.
- **Locale sorting**: WorkspaceTreeSort (WorkspaceNode.swift:107-121), TextTransforms.sortLines (TextTransforms.swift:140), and the tie-break in CommandPalette/GlobalFileSearch use `localizedStandardCompare`; order may differ under non-en/zh locales. Existing assertions are mostly ASCII-only, so the risk is low.
- There are no time-based / network / concurrency tests, and **not a single async/concurrency test** (the MarkdownFileDocument lock and the App's cancellation logic are outside test coverage) — this is a coverage gap rather than a flakiness source.

## 4. Code Quality

### 4.1 Duplicated Code

1. **Six line/newline implementations**: `LineIndex` (TextStatistics.swift:75-114, handles \r\n and lone \r correctly), `TextFind.lineNumber` (TextFind.swift:126-136, **counts only `\n`**), `EditorScrollAnchor.lineNumber/utf16Location` (EditorViewMode.swift:144-184), `SourceEditing.lineRange` (SourceEditing.swift:426-437), `TextTransforms.coveringLines` (TextTransforms.swift:209-220), `WorkspaceContentSearch.newlineCount` (WorkspaceSearch.swift:408-416, **counts only `\n`**). For CR-only text (old Mac line endings, reachable through the document scene), the last two give wrong line numbers. Recommendation: unify on `LineIndex`.
2. **Extension/text classification knowledge appears in at least 5 places**: FileFormat.swift:105-241 (format/viewer/textualExtensions), WorkspaceFilePolicy.swift:32-33 (markdown/plain sets), WorkspaceSearch.swift:239-279 (icon mapping), SourceEditing.swift:4-24 (TextMarkup prose/markup), EditorViewMode.swift:42-54 (access level). Adding one format requires changing 4-5 places, and drift has already appeared: FileFormats' image viewers include bmp/ico/tif (FileFormat.swift:200), while WorkspaceFileSymbolChoice's image icon list omits bmp/ico (WorkspaceSearch.swift:252) → the same file opens in a viewer but shows a generic document icon.
3. **Two text IO stacks**: TextBytes (workspace, 7 encodings/line-ending fidelity) vs TextDocument+MarkdownFileDocument (document scene, UTF-8 only, strips BOM). The same product's "open text" has two semantically different paths (§5/P1-1).
4. **The App copies Core's fence scanning** (§2.3-1); **two copies of the link scheme allowlist** (§2.3-2).
5. Smaller items: `EditorModeChoice.isEditing` and `showsLineNumbers` have verbatim identical conditions (EditorViewMode.swift:70-77); both branches of the ternary expression in `FileFormat.init` are identical (FileFormat.swift:95); `TextTransforms.lineCommentSuffix` and `lineComment` are split across two places (TextTransforms.swift:184-207).

### 4.2 Dead Code (public but with no product caller / leftovers of removed features)

| Item | Evidence | Note |
|---|---|---|
| SourceFormatting, whole file + SourceEditing inline toggles | SourceFormatting.swift:17-144; SourceEditing.swift:93-107; App grep = 0; FormatMenu.swift:4-16 explicitly removes them | Unreachable feature; 283 lines of implementation + 16 tests |
| Seven Reading/label APIs in LogicalLineGutter | LogicalLineGutter.swift:11-121; the App only uses :23-25 | Left over after 0.5.26 removed Reading line numbers (CHANGELOG.md:55) |
| The whole `ReadingLineMap` type | EditorViewMode.swift:234-255; referenced repo-wide only by tests | Old reading scroll mapping; handled on the JS side now |
| `TextFind.step` | TextFind.swift:42-44 | Used only by tests; the App uses stepDetail |
| `WorkspacePaths.breadcrumb` | WorkspaceNode.swift:81-88 | The App uses crumbs |
| `ExplorerSection.fileCount` | WorkspaceSearch.swift:87-93 | Left over after 0.5.26 removed the Explorer file count (CHANGELOG.md:57, commit 97c2212) |
| `MarkdownFileDocument.objectWillChange` | MarkdownFileDocument.swift:16; `storeEditorText` at :48-52 never sends | A dead publisher that exists only to satisfy the ObservableObject protocol (see P1-4) |
| `FileFormat.viewer` — dead branch of the label ternary in init | FileFormat.swift:95 | Dead expression |
| `EditorModeChoice.access(markdown:)` parameter | EditorViewMode.swift:45-54 + WorkspaceSession.swift:352 | Dead parameter |
| `ContentTypes.UTType.markdown` comment and implementation | ContentTypes.swift:5-11 | The comment claims "the SDK has no UTType.markdown", but the local MacOSX27.2 SDK already declares `UTTypeMarkdown` (`UTCoreTypes.h:488`, API_AVAILABLE(macos(27.0)); Swift side `UTType.markdown`); the member defined in this package currently shadows it inside the module, so the comment is outdated. Low risk but misleading. |

### 4.3 Naming / Layering Issues

- `EditorShellTests.swift` has no "EditorShell" type (nor does any source file) — the test file name is a historical artifact; 9 unrelated suites in one file make failures expensive to locate.
- `WorkspaceSearch.swift` is misnamed (name matching + sidebar geometry + icons + new names + content search).
- `EditorViewMode.swift` is misnamed (modes + access level + scroll anchor + reading line map).
- The split between `SourceEditing` and `SourceFormatting` corresponds only to commit history; `SourceEditing` as an enum serves as a namespace for utility functions (contains/lineRange/split/insideFence) and is extended by SourceFormatting; its name reads like "all source editing", but it is actually a set of Markdown editing functions.
- `TextFind.swift` holds both `TextFind` and `PathGlob` (two unrelated public APIs in 182 lines).
- `MarkdownFileDocument`'s comment still says "Typing undo is owned by the TextKit 2 view" (MarkdownFileDocument.swift:10-12), while README/docs clearly state that the Mac path reads `layoutManager` and installs TextKit 1 (README.md:11; docs/architecture.md:15) — the comment is the opposite of the current architecture.
- No `@available`/`Sendable` annotation issues: almost all pure value types are marked `Sendable`, which is fine when mixed with the App's `@MainActor`; but `MarkdownFileDocument` is a mutable class + NSLock, not isolated, and tests have no concurrency coverage.

### 4.4 Error Handling (throws vs Silent Failure)

- The package has only 3 throwing APIs: `WorkspaceDirectoryLoader.children` (:9), `TextDocument.init(data:)` (:15), `MarkdownFileDocument.init(configuration:)` (:33). Everything else returns `nil`/empty array/default values.
- This is intentional by design (editor commands return nil = do not modify), but the cost is that **errors are not observable**: `TextBytes.decode`'s nil (TextBytes.swift:77-100) forces callers to distinguish "not text / encoding unsupported"; `TextFind.matches` returns an empty array for an invalid regex (TextFind.swift:32-38), so only a separate `isValid` call distinguishes "no match" from "bad regex"; `FileFormats.isTextualName` returning false silently disables legacy decoding and the UTF-16 heuristic (see P2-9); `WorkspaceDirectoryLoader`'s `try? resourceValues` (:21) downgrades a metadata failure to a regular file.
- `TextBytes.EncodingError.unrepresentable` (:70-73) is the only business error type; the App's save path handles it (WorkspaceSession.swift:1929), but there is no Core-side test for the user-visible message/fallback of "typing Chinese into a Windows-1252 file → save fails".
- No `try!`/force-unwrap crash risks were found (only a few `!` in `ReadingLineMap`/`SidebarFit` and similar, in test/safe contexts).

### 4.5 Performance Hazards (Large Files / Regex / Per-Character Loops)

1. **TextBytes.decodeUnicode decodes UTF-8 twice**: `if String(data: data, encoding: .utf8) != nil, let text = String(data: data, encoding: .utf8)` (TextBytes.swift:187). Opening a 5 MB file / sampling disk changes = 2 full decodes.
2. **TextBytes builds strings scalar by scalar**: `splitEndings` calls `result.append` once per scalar (:261-282), `restore` likewise (:300-306), `utf16()` calls `Data.append` twice per UTF-16 unit (:233-243). 5 MB of text = millions of small appends, clearly slow on the save/open paths; `String.UnicodeScalarView` batching + `reserveCapacity`/`Data.reserveCapacity` would help.
3. **SyntaxColoring allocates an NSString substring per character**: every iteration of the main loop calls `lineCommentEnd`, which does `ns.substring(with: NSRange(location: index, length: min(4, limit - index)))` (SyntaxColoring.swift:154-157). Recoloring the visible window (on every scroll/keystroke in the App, XYZMacEditor.swift:1722) over a 250k-character window = 250k short-string allocations; block-comment matching also does byte-by-byte substrings (:182-188, :320-326). This is the clearest hotspot in Core.
4. **TextFind.matches is unbounded**: it returns the whole match array (:29-39), and `scan` rebuilds it on every ⌘G (:96-124); in a 5 MB file a frequent word (e.g. "a") produces millions of `FindMatch` values (each 24B + array overhead) → ~100 MB of transient memory / main-thread stall risk. Together with `replaceAll` bridging `NSMutableString` to a `String` copy per match (:74, `result as String`), and `lineNumber` copying a prefix string per match (:126-136), replace-all is O(n·m)-scale.
5. **EditorCaret.characterCount copies a substring on every caret move** (EditorCaret.swift:54-57): in a JSON file with a single 5 MB line, every left/right move = one 5 MB `substring`.
6. **FileOutline copies 250k scalars on every refresh** (FileOutline.swift:50-54); `SyntaxColoring` for files ≤250k always scans from 0 to the window end (:47-51), not O(window).
7. `PathGlob.matches` runs `range(of:options:.regularExpression)` per path × pattern (TextFind.swift:167-181) → folder replace compiles a fresh regex per file; cache the compiled result.
8. `WorkspaceContentSearch.hits(FindQuery)` first does full matches, then copies a prefix string per hit via `newlineCount` (WorkspaceSearch.swift:385-416) → O(hits · n).
9. `CSVText.parse` keeps parsing the full text to count `rowCount` after hitting the 500-row cap (StructuredText.swift:41-101) — a 5 MB CSV wastes a full scan on the Reading path; if called on the main thread it stalls (the call site is in the App).

## 5. Consistency Check (XYZCore Claims in docs/architecture.md, CHANGELOG 0.5.28, and README)

| # | Claim | Code fact | Verdict |
|---|---|---|---|
| 1 | CHANGELOG.md:21 "A slow open installs only when it is still the latest request and the path has no buffer yet (`WorkspaceFilePolicy.shouldInstallRead`)" | `shouldInstallRead(request:latest:alreadyInstalled:) = request==latest && !alreadyInstalled` (WorkspaceFilePolicy.swift:266-270); added by commit `ee0b4bd` (0.5.28) | ✅ Consistent; note: the "path has no buffer" condition lives in the App's `alreadyInstalled` argument, Core only expresses "latest + not installed" |
| 2 | CHANGELOG.md:21 "A disk sample applies only if the buffer has not been edited or saved since the sample started" | `isCurrentObservation(started:current:) = started == current` (:272-275); the App increments on the observation epoch (`WorkspaceSession.swift:1652-1653,1791,1813`) | ✅ Consistent (a pure comparator; the timing lives in the App) |
| 3 | CHANGELOG.md:21 "A save that finishes after the text has moved schedules another save" | `needsFollowUpSave(written:current:) = written != current` (:277-280); used by App WorkspaceSession.swift:1917 | ✅ Consistent; likewise a predicate rather than a scheduler |
| 4 | CHANGELOG.md:14 "because 'editor equals last saved' means 'take the disk'" | `interpretChange`: `editor == lastSaved → .reload` (:239-247) | ✅ Consistent |
| 5 | CHANGELOG.md:23 "Not done: … a new dependency" | Package.swift:14-19: the only dependency is swift-markdown (since 0.0.3, git log `06fa239`); Package.resolved 0.9.0 | ✅ Consistent |
| 6 | docs/architecture.md:9 "A debounced save writes through `WorkspaceFilePolicy`, which refuses to replace a newer disk copy unless the user chooses Keep Mine" | `decideWrite`: disk differs from lastSaved and no force → `.conflict` (:250-264); the App handles the `.write/.conflict/.upToDate` branches | ✅ Consistent (Core side; the anti-overwrite semantics holds) |
| 7 | docs/architecture.md:19 "Directory loads already ignore a stale generation. Opening a file did not. … The sample is now dropped when the buffer's observation has moved." | Core has the `shouldInstallRead`/`isCurrentObservation` predicates (:266-275); directory/file generations themselves live in the App | ✅ The primitives Core provides match the claim; the whole behavior cannot be proven from Core alone |
| 8 | docs/architecture.md:15 "The gutter therefore numbers lines from the layout manager… a contiguous remeasure is used only when the visible numbers skip" | The gutter computation in `LogicalLineGutter` is no longer on the App path (the App uses GutterSnapshot's own scan, `XYZ/Editor/GutterSnapshot.swift`; it only calls `LogicalLineGutter.highlighted`, LineNumberGutter.swift:89) | ⚠️ The claimed implementation location disagrees with Core's leftover code: the algorithm described in the doc is not in XYZCore, and the same-named algorithm in Core is dead code |
| 9 | README.md:52 "`TextDocument` reads and writes UTF-8." | TextDocument.swift:5-7,19-21,29-40: UTF-8, strips BOM on read, never adds it on write | ✅ Literally consistent; but compared with README.md:7 "Workspace files keep … UTF-8 with a byte-order mark": only the workspace path preserves the BOM; the document-scene path does not |
| 10 | README.md:53 "`MarkdownFileDocument` is the `ReferenceFileDocument` the document scene saves. The text view keeps the buffer; SwiftUI is not given a new string on every keystroke." | MarkdownFileDocument.swift:13-63 + XYZApp.swift:33 `DocumentGroup`; `storeEditorText` only writes storage and never sends objectWillChange (:16, :48-52) | ✅ Structurally consistent; but "the system knows the document is dirty" relies entirely on the undo manager, see P1-4 |
| 11 | README.md:54 "`HTMLRenderer` only walks a tree, and gives headings GitHub-style ids." | HTMLRenderer.render only traverses the passed Document (:9-17), does no parsing ✅; `HeadingAnchor` is nevertheless public (:389) and unused by the App | ✅ Consistent ("only walks a tree" holds; the public surface is too broad) |
| 12 | README.md:55 "`SourceEditing` holds list continuation and indent as pure functions" | SourceEditing.swift:57-91 pure functions ✅; but the same enum also has four inline toggles (:93-107) and the whole SourceFormatting extension, all unused by the App | ✅ Literally consistent; actual content is larger than the claim |
| 13 | README.md:68 "Text over 5 MB stays out of the editor" / 8 KiB sampling / coordinated save preserves encoding and line endings | editLimit=5_000_000 (WorkspaceFilePolicy.swift:30), sampleLimit=8_192 (:28), TextBytes encode/decode + App coordinated write (WorkspaceFileAccess.swift:98-165) | ✅ Consistent |
| 14 | README.md:16 "The renderer still does not request remote images." | `URLPolicy.imageSchemes = ["http","https"]` (HTMLRenderer.swift:482) and outputs `<img src="https://…">` (:301-318) → the renderer itself does not fetch, but the page it produces makes WKWebView request them; whether they are blocked depends on the App (no content-blocking rule found in `MarkdownWebView`) | ⚠️ Semantics are ambiguous / not provable from code alone: Core explicitly allows remote image URLs, so "does not request" can only mean "the renderer does not download on its own" |
| 15 | README.md:16 "Raw HTML … shown as text, javascript:/data: not links" | HTMLBlock/InlineHTML escape (:128-134, :279-281), URLPolicy rejects the three schemes (:500-502) | ✅ Consistent |
| 16 | README.md:72 "tree model lives in `XYZCore` so a later iOS folder view can reuse it" | WorkspaceNode/DirectoryLoader/WorkspaceSearch are in Core and platform-independent ✅; currently used only by the macOS App (`XYZ/Workspace/*` is the macOS path) | ✅ Consistent ("later" is a future promise) |
| 17 | CHANGELOG.md:55 "Reading has no line numbers… saved 'on' value does not bring them back." | `showsLineNumbers` returns true only for `.source` (EditorViewMode.swift:75-77); `restored` only accepts "reading" (:22-24) | ✅ Consistent; but LogicalLineGutter's Reading-label code was not removed (dead code) |
| 18 | CHANGELOG.md:57 "The Explorer header no longer shows a file count." | The App no longer calls `ExplorerSection.fileCount` (grep 0), but Core keeps the public API + tests (WorkspaceSearch.swift:87-93; WorkspaceTests does not test it directly — GlobalSearchTests.swift:98-113 tests fileCount) | ⚠️ Feature removed, API kept (dead code / docs out of sync) |
| 19 | docs/architecture.md:9 "`WorkspaceFileBuffer` owns … the dirty flag (`text != lastSaved`)" | The App implementation is `text != lastSaved \|\| encoding != savedEncoding \|\| lineEnding != savedLineEnding` (WorkspaceSession.swift:1655-1658) | ⚠️ The claim is a simplified version (not XYZCore, but part of the same doc's cross-check; encoding/line-ending changes also count as dirty) |

## 6. Findings List

### P0 (Correctness / Data Loss / Security)

No **confirmable P0** was found inside XYZCore: code review and the existing tests (MarkdownHTMLTests.swift:58-66,137-171) found no bypass of the HTML injection surface (raw HTML escaping + attribute escaping + URL scheme allowlist, HTMLRenderer.swift:448-511); the lossy branches of text encoding either refuse to open or have App-side conflict protection. P1-1/P1-4 below carry **potential** data loss and need App-side joint verification, so they are not raised to P0.

### P1 (Clear Defects / High Maintenance Risk)

**P1-1 The document-scene text IO supports only UTF-8; opening non-UTF-8 text on iOS/⌘O fails, and the BOM is silently removed**
- Evidence: TextDocument.swift:5-7,15-40 (only `.utf8`, strips BOM on read, never adds it on write); MarkdownFileDocument.swift:33-38 (throws `fileReadCorruptFile` when `TextDocument(data:)` fails); compare the workspace path TextBytes.swift:77-100,133-153 (7 encodings).
- Impact: README.md:4-7 says iOS can only go through the document browser; Windows-1252/UTF-16 `.txt`/`.md` files cannot be opened on iOS (the same files also fail with ⌘O on Mac, and only the "open folder" path can open them). UTF-8 files with a BOM lose the BOM after a save through the document scene, inconsistent with README.md:7 "BOM is an encoding form that is preserved" on the two paths.
- Suggestion: have `MarkdownFileDocument` use `TextBytes.decode/encode` internally and keep encoding/lineEnding as derived state in the ReadConfiguration/WriteConfiguration (or explicitly reject non-UTF-8 in the document scene and tell the user in the UI); add encoding tests for `init(configuration:)`/`fileWrapper`.

**P1-2 On CRLF documents the front matter eats the newlines, shifting all Reading line numbers**
- Evidence: ReadingSource.swift:65-71 iterates `head` per `Character`, keeping only when `character == "\n" || character == "\r"`; in Swift `"\r\n"` is a **single** Character, so it takes the else branch and is replaced with a space. Thus all front-matter newlines in CRLF are lost and the following `data-line`/outline line numbers shift.
- Impact: in a CRLF Markdown file opened through the document scene (TextDocument preserves CRLF and MarkdownHTML consumes that text directly), Reading block line numbers, Go to Heading, and outline line numbers are all wrong; LF documents are unaffected (existing tests MarkdownHTMLTests.swift:90-97 only cover LF).
- Suggestion: scan by unicodeScalars (or reuse the scalar approach of TextBytes.splitEndings), and add a CRLF front-matter regression test (first `data-line` from `MarkdownHTML.render`, then the outline).

**P1-3 The outline bypasses Reading's preprocessing, so front matter becomes a ghost heading and wiki-link headings differ**
- Evidence: MarkdownOutline.swift:20-26 calls `MarkdownParser.parse(markdown)` directly, while MarkdownHTML.swift:8-11 calls `ReadingSource.prepare` first (front-matter masking + wiki-link rewriting). The App uses each entry point: FileOutline.swift:38 (sidebar outline), and `paletteHeadings()` in `XYZ/DocumentEditorView.swift` → `MarkdownOutline.headings(in: currentText())` (raw text).
- Impact: for any note with YAML front matter, the preview shows a properties block (no heading), while the sidebar/⌘R can produce extra headings parsed from `---`/setext rules (e.g. the `title: …` line), and heading text/anchors differ from the preview; when `[[wiki link]]` appears in a heading, the text differs between the two sides as well.
- Suggestion: have MarkdownOutline or FileOutline reuse `ReadingSource.prepare` (mask only, do not render properties), and add a front-matter outline test.

**P1-4 `MarkdownFileDocument`'s `objectWillChange` never sends, leaving dirty tracking/autosave with the undo manager as the only route**
- Evidence: MarkdownFileDocument.swift:16 `public let objectWillChange = ObservableObjectPublisher()`; nothing in the file ever calls `.send()` (`storeEditorText` at :48-52 only mutates storage); no test covers dirty tracking/save triggering.
- Impact: README.md:53 and the comment (:8-12) both say the system learns dirty state through the undo manager; but if any edit path bypasses undo (programmatic replacement, IME commit boundaries, reload/formatting, external writes), SwiftUI/NSDocument may consider the document unmodified → no prompt on close/quit, no autosave → risk of losing edits. No test currently proves this chain holds.
- Suggestion: either explicitly send `objectWillChange` inside `storeEditorText` (and make SwiftUI track it correctly), or add a document-scene integration test (edit → do not save manually → `hasUnsavedChanges` is true on close), and document "undo-only" as a constraint in a comment.

**P1-5 `SourceFormatting` + the inline toggles are a complete implementation of a removed feature; 283 lines + 16 tests all cover unreachable code**
- Evidence: SourceFormatting.swift:17-144, SourceEditing.swift:93-107; zero App callers repo-wide (grep); `XYZ/Editor/FormatMenu.swift:4-16` explicitly "settles" removing Markdown formatting commands; tests SourceFormattingTests.swift:4-124, SourceEditingTests.swift:94-114 cover them.
- Impact: maintainers will believe the product has formatting capability (tests are green) although the menu is gone; any future "fix" or extension of this code is pure waste; it also enlarges the public surface and the mental load.
- Suggestion: delete them (together with the tests) or record in README/CHANGELOG the decision "keep the API but do not expose it in the product"; deleting is preferred, and it can be restored from git if needed.

**P1-6 Running block-level formatting on an opening fence line breaks the code-block boundary**
- Evidence: `SourceFormatting.rewriteLines` only checks `insideFence(ns, before: span.location)` (SourceFormatting.swift:177; insideFence defined at SourceEditing.swift:377-391). If the caret/selection start lands exactly on the **opening fence line**, the `before:` state is "not inside a fence" → allowed; then `setHeading/toggleQuote/toggleList` turns ``` into `# ```/`> ```/`- ```. The existing test SourceFormattingTests.swift:101-106 only tests caret(5) inside a fence, not the fence line itself.
- Impact: one command turns a code block in the document into plain text and later content renders incorrectly; undo recovers it, but this is a clear correctness defect.
- Suggestion: make `rewriteLines/insertCodeBlock/insertTable` return nil when "the first line of the selection is itself a fence line", and add tests (opening fence line, closing fence line, fence-only document).

**P1-7 `WorkspaceItemName.unique` silently returns a duplicate name after 10,000 collisions**
- Evidence: WorkspaceSearch.swift:297-309, `while number < 10_000`, then `return preferred` after the loop (no uniqueness guarantee).
- Impact: callers (New File/New Folder, WorkspaceSession.swift:418,494) treat it as a unique name; in an extreme directory it can hit an existing name → later create/overwrite paths may target the wrong file. Extreme, but the function contract is "unique", and silently breaking the contract is a data risk.
- Suggestion: return `String?`/`Result`, or stop falling back and use a UUID suffix instead; add a test.

**P1-8 The main find/replace paths (`scan`, `replacement`, `lineNumber`) have no tests at all, and `matches` is unbounded**
- Evidence: TextFind.swift:96-124 (scan), :81-89 (replacement), :126-136 (lineNumber) have zero references in TextFindTests.swift; `matches` (:29-39) returns all matches at once; the App calls `TextFind.scan` on every ⌘G (XYZMacEditor.swift:461) and then `matches` for highlighting (:514).
- Impact: the find bar is a high-frequency feature, yet the four-tuple combination (current match/line/wrapped/invalid) has no regression protection; a frequent word in a 5 MB file produces a million-element match array (each struct + Array overhead), with stall/memory-peak risk.
- Suggestion: add behavior tests for scan (forward/backward/wrap/stay/invalid pattern/empty match), add a `limit` to `matches` or a streaming interface via `NSRegularExpression.enumerateMatches`; make `lineNumber` use `LineIndex`.

### P2 (Improvements)

**P2-1 Six line-number/newline implementations, two of which only recognize `\n`, inconsistent with `LineIndex`'s CR support**
- Evidence: TextStatistics.swift:75-114 vs TextFind.swift:126-136 (:132 counts only "\n") vs WorkspaceSearch.swift:408-416 (only "\n") vs EditorViewMode.swift:144-184 vs SourceEditing.swift:426-437 vs TextTransforms.swift:209-220; also EditorScrollAnchor.lines (EditorViewMode.swift:202-226) does not count the trailing empty line, while LineIndex does.
- Impact: line numbers in find/content search/outline can be off by one or more for CR-only text; the two "line count" semantics make the scroll anchor and the line-number display disagree.
- Suggestion: unify on `LineIndex` (as a separate file) and make the other implementations call it; make `EditorScrollAnchor.lines` explicitly reuse the same model.

**P2-2 Extension/classification knowledge scattered across 5 places, already drifting**
- Evidence: FileFormat.swift:105-241, WorkspaceFilePolicy.swift:32-33, WorkspaceSearch.swift:239-279, SourceEditing.swift:4-24, EditorViewMode.swift:42-54; concrete drift: bmp/ico are image viewers in FileFormat.swift:200 but missing from the icon table in WorkspaceSearch.swift:252 → shown with a document icon.
- Impact: adding/adjusting a format requires changing several places, easily producing "opens but icon wrong / icon right but cannot open" inconsistencies.
- Suggestion: make `FileFormats` the single source of truth; derive `WorkspaceFileSymbolChoice` icons from `FileViewerKind`.

**P2-3 Two UTF-8 decodes and per-scalar concatenation in TextBytes hot paths**
- Evidence: TextBytes.swift:187 (the same data decoded twice), :255-293 (splitEndings appends per scalar), :295-308 (restore appends per scalar), :228-245 (UTF-16 appends to Data twice per unit).
- Impact: opening/saving/sampling a 5 MB file costs noticeably more CPU and memory, conflicting with the product narrative that large files do not stall.
- Suggestion: decode once with `if let`; use `String.UnicodeScalarView`'s `replaceSubrange` or a single `components` scan for splitEndings; preallocate with `withUnsafeBytes`/`reserveCapacity` for utf16.

**P2-4 SyntaxColoring allocates a short substring per character + scans large-file windows from 0**
- Evidence: SyntaxColoring.swift:154-157 (a `substring` per character), :182-188/:320-326 (byte-by-byte substrings for block comments), :47-51 (for ≤scanLimit, `scan(from: 0, limit: windowEnd)`, which is not O(window)), :341-364 (the block-comment lookback for >scanLimit is capped at 16,000 bytes and may mis-color).
- Impact: recoloring the visible area on every edit of a long file (XYZMacEditor.swift:1722) is Core's heaviest CPU path; scrolling in a 256 KB file is perceptible.
- Suggestion: compare prefixes with `ns.character(at:)`/`range(of:)`; start window scans at `origin` (the `lineStart` logic already exists — just route the ≤limit branch to origin and look back for block comments from origin); document/test the 16 KB lookback cap.

**P2-5 `PathGlob` compiles a fresh regex per path×pattern; `WorkspaceContentSearch` copies a prefix per hit**
- Evidence: TextFind.swift:167-181 (`range(of:options:.regularExpression)`); WorkspaceSearch.swift:385-416 (`newlineCount` at :408-416 copies a prefix).
- Impact: folder-wide replace/content search over thousands of files and 40 hits wastes considerable time.
- Suggestion: compile and cache the regex (or write a hand-rolled `*`/`?` matcher); compute line numbers with `LineIndex` or an incremental scan.

**P2-6 `TextTransforms.lineComment` falls back to `// ` for languages without line comments**
- Evidence: TextTransforms.swift:194-207, `default: return "// "` (:204-205). JSON (.json) and CSS (.css) have no `//` line comments (JSONC/CSS only have `/* */`), yet Toggle Comment (⌘;) in the App still inserts `// ` for these files (EditorCommands.swift:390-399, 858-878).
- Impact: running the comment command on JSON/CSS produces an invalid file directly (downstream parsing fails after save); a user-visible correctness defect (lower severity than P1 because it needs explicit action and is undoable).
- Suggestion: return nil for `.json` (non-jsonc) and for `.css`, or switch to block comments; add table-driven tests per language.

**P2-7 `FileFormats.isTextualName` always returns false for dotfiles, making the gitignore/editorconfig entries in `textualExtensions` unreachable**
- Evidence: FileFormat.swift:189-196: `let ext = pathExtension(of: name); if ext.isEmpty { return false }`; but `pathExtension` of `.gitignore`/`.editorconfig` is the empty string (hidden files have no extension), while `textualExtensions` does contain "gitignore"/"gitattributes"/"editorconfig" (:239). This function decides legacy decoding and the UTF-16 heuristic (WorkspaceFilePolicy.swift:89,105; App WorkspaceSession.swift:1403,1461).
- Impact: Windows-1252 or UTF-16 dotfiles (credentials/config) are not decoded as text → read-only preview or binary; conflicts with README.md:68 "dotfiles also open as text" (UTF-8 dotfiles are unaffected because they take the UTF-8 branch).
- Suggestion: for basenames starting with ".", first look up the whole lowercased name in textualBasenames/textualExtensions, then fall back to the extension; add 1252/UTF-16 tests for `.gitignore`.

**P2-8 BOM-less UTF-16 whose bytes happen to be valid UTF-8 is decoded as UTF-8 (saving rewrites the bytes)**
- Evidence: TextBytes.swift:187-195 tries UTF-8 first, then heuristic UTF-16; the heuristic at :204-222 requires paired 0 bytes. Some BOM-less UTF-16 content (e.g. text consisting entirely of low-frequency CJK, all bytes <0x80) passes UTF-8 validation first → opens as garbled text, and after editing and saving the original bytes become UTF-8 mojibake.
- Impact: an edge but real byte-rewriting path; the docs only say "UTF-16 support", not that it is heuristic-only.
- Suggestion: state in README/TextBytes comments that "BOM-less UTF-16 is only recognized when 0 bytes are present"; or tighten the heuristic for suspicious double-byte interleaving and add tests.

**P2-9 `EditorModeChoice.access(kind:markdown:)` has a dead parameter; `showsLineNumbers` duplicates `isEditing`**
- Evidence: EditorViewMode.swift:45-54, :70-77; the only App call WorkspaceSession.swift:352 passes `markdown: kind == .markdown`; test WorkspaceTests.swift:257-258 covers an unreachable combination.
- Impact: the API suggests a third state of "plainText with markdown semantics"; increases the misuse surface.
- Suggestion: drop the parameter or drive it from `FileFormat`; make `showsLineNumbers` reuse `isEditing` directly.

**P2-10 `MarkdownFileDocument`'s comment is the opposite of the current architecture (TextKit 2 vs TextKit 1)**
- Evidence: MarkdownFileDocument.swift:8-12 "Typing undo is owned by the TextKit 2 view"; README.md:11 and docs/architecture.md:15 both state that the Mac reading `layoutManager` switches back to TextKit 1, and 0.5.28 explicitly does not rewrite TextKit 2 (CHANGELOG.md:21-25).
- Impact: misleads future developers.
- Suggestion: change it to "the text view's undo manager points at the document scene's undo manager" and do not name a specific TextKit version.

**P2-11 `ContentTypes.swift`'s "the SDK has no UTType.markdown" is outdated, and the custom member shadows the system one on new SDKs**
- Evidence: ContentTypes.swift:5-11; the local MacOSX27.2 SDK declares `UTTypeMarkdown` at `UTCoreTypes.h:488` (`API_AVAILABLE(macos(27.0))`; Swift side `UTType.markdown`). The `static let markdown` in this module shares the system member's name and compiles inside the module (verified that this project's form typechecks with `swiftc -typecheck`), but cross-module callers may see two candidates.
- Impact: low (the App does not reference the system `.markdown` across modules today), but the comment misleads, and future SDKs may produce ambiguity/deprecation warnings.
- Suggestion: use `if #available(macOS 27, iOS 27, *) { return .markdown } else { return UTType(importedAs:…) }`, or change the comment to "provides the constant for the macOS 14/iOS 17 deployment targets (the system only has it since macOS 27)".

**P2-12 Test organization and a few brittle assertions**
- Evidence: EditorShellTests.swift (518 lines, 9 unrelated suites, and the type its filename implies does not exist); MarkdownHTMLTests.swift:13/:20/:55/:156 exact attribute strings; :194-202 facade = internal pipeline equivalence; EditorShellTests.swift:467-478 depends on the 250k constant; WorkspaceTests.swift:72-104 real symlinks.
- Impact: expensive failure localization, red on implementation changes, occasional CI flakiness (symlinks).
- Suggestion: split test files by module under test; make HTML assertions inclusive (as some already are) or parse `data-line`; turn "pipeline equivalence" into an output snapshot; mark file-system tests with `XCTSkip` conditions or move to an in-memory abstraction.

**P2-13 Error semantics are not observable, and the `throws` surface is too narrow**
- Evidence: the package has only 3 throwing APIs (WorkspaceDirectoryLoader.swift:9, TextDocument.swift:15, MarkdownFileDocument.swift:33); `TextBytes.decode` returns nil and `TextFind.matches` silently returns an empty array for an invalid regex (TextFind.swift:32-38, needing a separate isValid call);
- Impact: callers easily conflate "decode failed / regex error / no match"; the App already covers this with `isValid`, but there is no unified error enum in Core.
- Suggestion: add a result type to decode that distinguishes the reasons (or fix the contract in the docs and add tests); add a throwing variant for `matches` or document "invalid regex = empty result, call isValid first".

## 7. Suggested Handling Order (Wrap-up Advice for the Lead)

1. Do P1-2 and P1-3 first (front matter/outline): small changes, user-visible, easy to cover with regression tests.
2. P1-4 (document dirty tracking) needs joint App-side verification; its priority depends on whether the product relies on autosave. Adding a document-scene test directly is recommended.
3. Delete the dead formatting code (P1-5) or at least mark it, and clean up the 16 tests and the README wording accordingly.
4. Treat P1-1 (document-scene encoding) and P1-8 (find engine) as medium-term work: the former affects the iOS compatibility narrative, the latter affects the 5 MB file interaction experience.
5. Among P2, prioritize the TextBytes double decode (P2-3) and the SyntaxColoring allocations (P2-4); both are hot paths and the changes are local.

---

### Appendix: Line-Number Sources in This Report

All `file:line` were located with the read tool (offset/limit) or `grep -n`; test/source line numbers are for the current working tree (HEAD `db12a62`). No `swift test`/`xcodebuild` was run (the Lead provided the 191 tests / 0 failures baseline); `swiftc -typecheck` was used only to verify the UTType shadowing claim at ContentTypes.swift:5-11 (temporary file /tmp/uttype_probe.swift, never added to the repo).
