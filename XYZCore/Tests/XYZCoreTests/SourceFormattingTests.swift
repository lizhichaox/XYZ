import XCTest
import XYZCore

final class SourceFormattingTests: XCTestCase {
    func testStrikethroughAndInlineCodeWrapAndUnwrap() {
        let struck = apply(SourceEditing.toggleStrikethrough(in: "gone", selection: range(0, 4)), to: "gone")
        XCTAssertEqual(struck?.text, "~~gone~~")
        XCTAssertEqual(struck?.selection, range(2, 4))
        let back = apply(SourceEditing.toggleStrikethrough(in: "~~gone~~", selection: range(2, 4)), to: "~~gone~~")
        XCTAssertEqual(back?.text, "gone")
        let code = apply(SourceEditing.toggleInlineCode(in: "let x", selection: range(0, 5)), to: "let x")
        XCTAssertEqual(code?.text, "`let x`")
    }

    func testHeadingSetsChangesAndClearsTheLevel() {
        let set = apply(SourceEditing.setHeading(level: 2, in: "标题", selection: caret(1)), to: "标题")
        XCTAssertEqual(set?.text, "## 标题")
        XCTAssertEqual(set?.selection, caret(4))
        let changed = apply(SourceEditing.setHeading(level: 1, in: "## 标题", selection: caret(4)), to: "## 标题")
        XCTAssertEqual(changed?.text, "# 标题")
        XCTAssertEqual(changed?.selection, caret(3))
        let cleared = apply(SourceEditing.setHeading(level: 1, in: "# 标题", selection: caret(3)), to: "# 标题")
        XCTAssertEqual(cleared?.text, "标题")
        XCTAssertEqual(cleared?.selection, caret(1))
        let paragraph = apply(SourceEditing.setHeading(level: 0, in: "### a\n", selection: caret(0)), to: "### a\n")
        XCTAssertEqual(paragraph?.text, "a\n")
        XCTAssertEqual(paragraph?.selection, caret(0))
    }

    func testHeadingTouchesOnlyTheCaretLine() {
        let text = "one\ntwo\nthree"
        let edit = apply(SourceEditing.setHeading(level: 3, in: text, selection: caret(5)), to: text)
        XCTAssertEqual(edit?.text, "one\n### two\nthree")
        XCTAssertEqual(edit?.selection, caret(9))
    }

    func testQuoteAddsAndRemovesAcrossLines() {
        let text = "a\n\nb\n"
        let quoted = apply(SourceEditing.toggleQuote(in: text, selection: range(0, 4)), to: text)
        XCTAssertEqual(quoted?.text, "> a\n>\n> b\n")
        XCTAssertEqual(quoted?.selection, range(0, 9))
        let plain = apply(SourceEditing.toggleQuote(in: "> a\n>\n> b\n", selection: range(0, 10)), to: "> a\n>\n> b\n")
        XCTAssertEqual(plain?.text, "a\n\nb\n")
    }

    func testListsConvertNumberAndToggleOff() {
        let text = "milk\neggs"
        let bullets = apply(SourceEditing.toggleList(.bullet, in: text, selection: range(0, 9)), to: text)
        XCTAssertEqual(bullets?.text, "- milk\n- eggs")
        let numbered = apply(SourceEditing.toggleList(.ordered, in: "- milk\n- eggs", selection: range(0, 13)), to: "- milk\n- eggs")
        XCTAssertEqual(numbered?.text, "1. milk\n2. eggs")
        let tasks = apply(SourceEditing.toggleList(.task, in: "1. milk\n2. eggs", selection: range(0, 15)), to: "1. milk\n2. eggs")
        XCTAssertEqual(tasks?.text, "- [ ] milk\n- [ ] eggs")
        let off = apply(SourceEditing.toggleList(.task, in: "- [x] milk", selection: caret(8)), to: "- [x] milk")
        XCTAssertEqual(off?.text, "milk")
        XCTAssertEqual(off?.selection, caret(2))
    }

    func testListOnAnEmptyLineStartsAnItem() {
        let edit = apply(SourceEditing.toggleList(.bullet, in: "", selection: caret(0)), to: "")
        XCTAssertEqual(edit?.text, "- ")
        XCTAssertEqual(edit?.selection, caret(2))
    }

    func testListKeepsIndentation() {
        let edit = apply(SourceEditing.toggleList(.ordered, in: "  - a", selection: caret(4)), to: "  - a")
        XCTAssertEqual(edit?.text, "  1. a")
    }

    func testCodeBlockFencesTheLinesAndPutsTheCaretAtTheLanguage() {
        let text = "let a = 1\nlet b = 2\nafter"
        let edit = apply(SourceEditing.insertCodeBlock(in: text, selection: range(0, 19)), to: text)
        XCTAssertEqual(edit?.text, "```\nlet a = 1\nlet b = 2\n```\nafter")
        XCTAssertEqual(edit?.selection, caret(3))
        let empty = apply(SourceEditing.insertCodeBlock(in: "", selection: caret(0)), to: "")
        XCTAssertEqual(empty?.text, "```\n\n```")
    }

    func testTableGoesOnAnEmptyLineOrBelowText() {
        let empty = apply(SourceEditing.insertTable(in: "", selection: caret(0)), to: "")
        XCTAssertEqual(empty?.text, "|  |  |\n| --- | --- |\n|  |  |")
        XCTAssertEqual(empty?.selection, caret(2))
        let below = apply(SourceEditing.insertTable(in: "Intro", selection: caret(2)), to: "Intro")
        XCTAssertEqual(below?.text, "Intro\n\n|  |  |\n| --- | --- |\n|  |  |")
        XCTAssertEqual(below?.selection, caret(9))
    }

    func testLinkWrapsTextOrAnAddress() {
        let text = apply(SourceEditing.insertLink(in: "see docs", selection: range(4, 4)), to: "see docs")
        XCTAssertEqual(text?.text, "see [docs]()")
        XCTAssertEqual(text?.selection, caret(11))
        let address = "https://example.com"
        let url = apply(SourceEditing.insertLink(in: address, selection: range(0, 19)), to: address)
        XCTAssertEqual(url?.text, "[](https://example.com)")
        XCTAssertEqual(url?.selection, caret(1))
        let empty = apply(SourceEditing.insertLink(in: "", selection: caret(0)), to: "")
        XCTAssertEqual(empty?.text, "[]()")
        XCTAssertEqual(empty?.selection, caret(1))
    }

    func testFormatsLeaveCodeFencesAlone() {
        let text = "```\ncode\n```\n"
        XCTAssertNil(SourceEditing.setHeading(level: 1, in: text, selection: caret(5)))
        XCTAssertNil(SourceEditing.toggleQuote(in: text, selection: caret(5)))
        XCTAssertNil(SourceEditing.toggleList(.bullet, in: text, selection: caret(5)))
    }

    private func caret(_ location: Int) -> SourceRange {
        SourceRange(location: location, length: 0)
    }

    private func range(_ location: Int, _ length: Int) -> SourceRange {
        SourceRange(location: location, length: length)
    }

    private func apply(_ edit: SourceReplacement?, to text: String) -> (text: String, selection: SourceRange)? {
        guard let edit else { return nil }
        let next = (text as NSString).replacingCharacters(
            in: NSRange(location: edit.range.location, length: edit.range.length),
            with: edit.text
        )
        return (next, edit.selection)
    }
}

final class DocumentInsightTests: XCTestCase {
    func testOutlineListsHeadingsWithLinesAndSkipsCode() {
        let text = "# 第一章\n\ntext\n\n```\n# not a heading\n```\n\nSetext\n---\n\n### Deep *one*\n"
        XCTAssertEqual(MarkdownOutline.headings(in: text), [
            OutlineHeading(level: 1, title: "第一章", line: 1),
            OutlineHeading(level: 2, title: "Setext", line: 9),
            OutlineHeading(level: 3, title: "Deep one", line: 12),
        ])
    }

    func testStatisticsCountCJKCharactersAndWords() {
        let stats = TextStatistics.count("你好，world! **Bold** it's 2026.")
        XCTAssertEqual(stats.ideographs, 2)
        XCTAssertEqual(stats.words, 4)
        XCTAssertEqual(stats.total, 6)
        XCTAssertEqual(stats.characters, 26)
        XCTAssertEqual(stats.readingMinutes, 1)
        XCTAssertEqual(TextStatistics.count("  \n").readingMinutes, 0)
        XCTAssertEqual(TextStatistics.count(String(repeating: "字", count: 1200)).readingMinutes, 3)
    }

    func testLineIndexFindsTheLineOfAnOffset() {
        let index = LineIndex("one\r\ntwo\rthree\n")
        XCTAssertEqual(index.starts, [0, 5, 9, 15])
        XCTAssertEqual(index.count, 4)
        XCTAssertEqual(index.line(at: 0), 1)
        XCTAssertEqual(index.line(at: 4), 1)
        XCTAssertEqual(index.line(at: 5), 2)
        XCTAssertEqual(index.line(at: 12), 3)
        XCTAssertEqual(index.line(at: 15), 4)
        XCTAssertEqual(LineIndex("").count, 1)
        XCTAssertEqual(LineIndex("").line(at: 0), 1)
    }

    func testHeadingIDsAreSlugsAndUnique() {
        let html = MarkdownHTML.render("# Hello, World!\n\n## Hello World\n\n## 安装 指南\n\n# Hello World\n")
        XCTAssertTrue(html.contains("<h1 id=\"hello-world\""))
        XCTAssertTrue(html.contains("<h2 id=\"hello-world-1\""))
        XCTAssertTrue(html.contains("<h2 id=\"安装-指南\""))
        XCTAssertTrue(html.contains("<h1 id=\"hello-world-2\""))
        XCTAssertEqual(HeadingAnchor.slug("?!"), "section")
    }

    func testPaletteListsHeadingsAfterAt() {
        let headings = [
            OutlineHeading(level: 1, title: "Introduction", line: 1),
            OutlineHeading(level: 2, title: "Install", line: 8),
            OutlineHeading(level: 2, title: "Usage", line: 20),
        ]
        let all = CommandPalette.rows(rawQuery: "@", files: [], registry: PaletteCommandRegistry(), headings: headings)
        XCTAssertEqual(all.map(\.id), ["heading:1", "heading:8", "heading:20"])
        let matched = CommandPalette.rows(rawQuery: "@ins", files: [], registry: PaletteCommandRegistry(), headings: headings)
        XCTAssertEqual(matched.first?.id, "heading:8")
        XCTAssertEqual(CommandPalette.parse("@ x").mode, .headings)
    }
}
