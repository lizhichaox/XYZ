import XCTest
@testable import XYZCore

final class TextFindTests: XCTestCase {
    func testCaseAndWholeWord() {
        let text = "Cat catalog cat"
        let loose = TextFind.matches(in: text, query: FindQuery(pattern: "cat"))
        XCTAssertEqual(loose.count, 3)
        let exact = TextFind.matches(in: text, query: FindQuery(pattern: "cat", matchCase: true))
        XCTAssertEqual(exact.count, 2)
        XCTAssertEqual(exact.last?.range, SourceRange(location: 12, length: 3))
        let word = TextFind.matches(in: text, query: FindQuery(pattern: "cat", wholeWord: true))
        XCTAssertEqual(word.count, 2)
    }

    func testRegexGroupReplaceKeepsTheRestOfTheLine() {
        let text = "a-1\r\nb-2"
        let replaced = TextFind.replaceAll(
            in: text,
            query: FindQuery(pattern: "([a-z])-(\\d)", matchCase: true, regex: true),
            with: "$2:$1"
        )
        XCTAssertEqual(replaced.count, 2)
        XCTAssertEqual(replaced.text, "1:a\r\n2:b")
    }

    func testLiteralReplaceDoesNotEatTheDollarAndKeepsCRLF() {
        let text = "cost $1\r\ncost $1"
        let replaced = TextFind.replaceAll(in: text, query: FindQuery(pattern: "$1"), with: "$2")
        XCTAssertEqual(replaced.text, "cost $2\r\ncost $2")
        XCTAssertEqual(replaced.count, 2)
    }

    func testEmptyAndBrokenPatternsMatchNothing() {
        XCTAssertTrue(TextFind.matches(in: "abc", query: FindQuery(pattern: "")).isEmpty)
        XCTAssertTrue(TextFind.matches(in: "abc", query: FindQuery(pattern: "(", regex: true)).isEmpty)
        XCTAssertFalse(TextFind.isValid(FindQuery(pattern: "(", regex: true)))
    }

    func testNextWrapsAndPreviousWalksBack() {
        let text = "a a a"
        let matches = TextFind.matches(in: text, query: FindQuery(pattern: "a", matchCase: true))
        XCTAssertEqual(TextFind.step(from: SourceRange(location: 0, length: 1), matches: matches, forward: true), 1)
        XCTAssertEqual(TextFind.step(from: SourceRange(location: 4, length: 1), matches: matches, forward: true), 0)
        XCTAssertEqual(TextFind.stepDetail(from: SourceRange(location: 4, length: 1), matches: matches, forward: true)?.wrapped, true)
        XCTAssertEqual(TextFind.stepDetail(from: SourceRange(location: 0, length: 1), matches: matches, forward: true)?.wrapped, false)
        XCTAssertEqual(TextFind.step(from: SourceRange(location: 2, length: 0), matches: matches, forward: false), 0)
    }

    func testGlobIncludeAndExclude() {
        XCTAssertTrue(PathGlob.allows("src/A.swift", include: "*.swift", exclude: ""))
        XCTAssertFalse(PathGlob.allows("src/A.md", include: "*.swift", exclude: ""))
        XCTAssertFalse(PathGlob.allows("vendor/A.swift", include: "", exclude: "vendor/*"))
        XCTAssertTrue(PathGlob.allows("Notes/a.md", include: "", exclude: ""))
    }

    func testFindScrollCentersAnOffscreenMatchAndKeepsOneInView() {
        XCTAssertEqual(
            FindScroll.origin(matchMin: 800, matchMax: 820, visibleOrigin: 0, visibleLength: 200, contentLength: 2000, margin: 40),
            710 as CGFloat
        )
        XCTAssertEqual(
            FindScroll.origin(matchMin: 40, matchMax: 60, visibleOrigin: 0, visibleLength: 200, contentLength: 2000, margin: 40),
            0 as CGFloat
        )
        XCTAssertEqual(
            FindScroll.origin(matchMin: 10, matchMax: 30, visibleOrigin: 400, visibleLength: 200, contentLength: 2000, margin: 40),
            0 as CGFloat
        )
    }
}

final class LogicalLineGutterTests: XCTestCase {
    func testWrappedFragmentsKeepTheLogicalLine() {
        let text = "alpha beta\nsecond"
        XCTAssertEqual(
            LogicalLineGutter.labels(text: text, fragmentOffsets: [0, 6, 11]),
            [1, nil, 2]
        )
    }

    func testBlankLinesAndCRLFStayOneNumberEach() {
        XCTAssertEqual(
            LogicalLineGutter.labels(text: "a\n\nb", fragmentOffsets: [0, 2, 3]),
            [1, 2, 3]
        )
        XCTAssertEqual(
            LogicalLineGutter.labels(text: "a\r\n\r\nb", fragmentOffsets: [0, 1, 3, 5]),
            [1, nil, 2, 3]
        )
    }

    func testMarkdownBlocksUseSourceLinesNotRenderedRows() {
        let list = LogicalLineGutter.readingLabels(
            blocks: [LogicalLineGutter.Block(start: 1, end: 1), LogicalLineGutter.Block(start: 2, end: 2)],
            visualRows: [1, 2]
        )
        XCTAssertEqual(list, [1, 2, nil])
        XCTAssertEqual(LogicalLineGutter.blockLabels(start: 4, end: 6, visualRows: 3), [4, 5, 6])
        XCTAssertEqual(LogicalLineGutter.blockLabels(start: 4, end: 6, visualRows: 5), [4, nil, 5, nil, 6])
        XCTAssertEqual(LogicalLineGutter.blockLabels(start: 10, end: 12, visualRows: 3), [10, 11, 12])
        XCTAssertEqual(LogicalLineGutter.blockLabels(start: 8, end: 9, visualRows: 4), [8, nil, 9, nil])
    }

    func testCurrentLineHighlightFollowsTheLogicalLine() {
        XCTAssertEqual(
            LogicalLineGutter.highlighted(sourceLines: [1, 1, 2, 3, 3], caret: 1),
            [true, true, false, false, false]
        )
    }
}

final class TextTransformTests: XCTestCase {
    func testDuplicateMoveAndDeleteALine() {
        let text = "one\ntwo\nthree\n"
        let duplicated = apply(TextTransforms.duplicateLine(in: text, selection: caret(0), above: false), to: text)
        XCTAssertTrue(duplicated.hasPrefix("one\none\n"))
        let moved = apply(TextTransforms.moveLine(in: text, selection: caret(0), up: false), to: text)
        XCTAssertTrue(moved.hasPrefix("two\none\n"))
        let deleted = apply(TextTransforms.deleteLine(in: text, selection: caret(4)), to: text)
        XCTAssertFalse(deleted.contains("two"))
    }

    func testCommentIndentJoinSortTrimAndCase() {
        let commented = apply(TextTransforms.toggleComment(in: "a\nb", selection: range(0, 3), prefix: "// "), to: "a\nb")
        XCTAssertEqual(commented, "// a\n// b")
        let plain = apply(TextTransforms.toggleComment(in: commented, selection: range(0, commented.utf16.count), prefix: "// "), to: commented)
        XCTAssertEqual(plain, "a\nb")
        XCTAssertNil(TextTransforms.lineComment(for: .markdown))
        XCTAssertEqual(TextTransforms.lineComment(for: .swift), "// ")
        XCTAssertEqual(TextTransforms.lineComment(for: .python), "# ")
        let html = apply(
            TextTransforms.toggleComment(in: "a", selection: range(0, 1), prefix: "<!-- ", suffix: " -->"),
            to: "a"
        )
        XCTAssertEqual(html, "<!-- a -->")
        XCTAssertEqual(
            apply(TextTransforms.toggleComment(in: html, selection: range(0, html.utf16.count), prefix: "<!-- ", suffix: " -->"), to: html),
            "a"
        )

        let indented = apply(TextTransforms.indentLines(in: "a\nb", selection: range(0, 3), outdent: false), to: "a\nb")
        XCTAssertEqual(indented, "    a\n    b")
        let out = apply(TextTransforms.indentLines(in: indented, selection: range(0, indented.utf16.count), outdent: true), to: indented)
        XCTAssertEqual(out, "a\nb")

        XCTAssertEqual(apply(TextTransforms.joinLines(in: "a\nb", selection: range(0, 3)), to: "a\nb"), "a b")
        XCTAssertEqual(apply(TextTransforms.sortLines(in: "b\na\n", selection: range(0, 4)), to: "b\na\n"), "a\nb\n")
        XCTAssertEqual(
            apply(TextTransforms.trimTrailingWhitespace(in: "a  \nb\t", selection: range(0, 6)), to: "a  \nb\t"),
            "a\nb"
        )
        XCTAssertEqual(
            apply(TextTransforms.transformCase(in: "Hello", selection: range(0, 5), style: .lower), to: "Hello"),
            "hello"
        )
        XCTAssertEqual(
            apply(TextTransforms.transformCase(in: "hello", selection: range(0, 5), style: .title), to: "hello"),
            "Hello"
        )
    }

    private func apply(_ edit: SourceReplacement?, to text: String) -> String {
        guard let edit else { return text }
        let ns = text as NSString
        return ns.replacingCharacters(in: NSRange(location: edit.range.location, length: edit.range.length), with: edit.text)
    }

    private func caret(_ location: Int) -> SourceRange {
        SourceRange(location: location, length: 0)
    }

    private func range(_ location: Int, _ length: Int) -> SourceRange {
        SourceRange(location: location, length: length)
    }
}
