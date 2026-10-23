import XCTest
@testable import XYZCore

final class WorkspaceTreeTests: XCTestCase {
    func testPathsJoinAndSplit() {
        XCTAssertEqual(WorkspacePaths.child(parent: "", name: ".gitignore"), ".gitignore")
        XCTAssertEqual(WorkspacePaths.child(parent: ".github", name: "workflows"), ".github/workflows")
        XCTAssertEqual(WorkspacePaths.parent(of: ".github/workflows"), ".github")
        XCTAssertEqual(WorkspacePaths.parent(of: "README.md"), "")
    }

    func testHiddenNamesIncludeDotfiles() {
        XCTAssertTrue(WorkspacePaths.isHidden(name: ".DS_Store", resourceHidden: false))
        XCTAssertTrue(WorkspacePaths.isHidden(name: "Notes.txt", resourceHidden: true))
        XCTAssertFalse(WorkspacePaths.isHidden(name: "Notes.txt", resourceHidden: false))
    }

    func testSortPutsFoldersFirstAndIgnoresCase() {
        let nodes = [
            WorkspaceNode(name: "B.txt", relativePath: "B.txt", isDirectory: false, isHidden: false),
            WorkspaceNode(name: "sub", relativePath: "sub", isDirectory: true, isHidden: false),
            WorkspaceNode(name: "a.txt", relativePath: "a.txt", isDirectory: false, isHidden: false),
            WorkspaceNode(name: ".git", relativePath: ".git", isDirectory: true, isHidden: true),
        ]
        let names = WorkspaceTreeSort.ordered(nodes).map(\.name)
        let firstFile = names.firstIndex(of: "a.txt")!
        XCTAssertLessThan(names.firstIndex(of: ".git")!, firstFile)
        XCTAssertLessThan(names.firstIndex(of: "sub")!, firstFile)
        XCTAssertLessThan(firstFile, names.firstIndex(of: "B.txt")!)
    }

    func testNaturalSortOrdersVersionNumbers() {
        let nodes = [
            WorkspaceNode(name: "v0.0.10.md", relativePath: "v0.0.10.md", isDirectory: false, isHidden: false),
            WorkspaceNode(name: "v0.0.9.md", relativePath: "v0.0.9.md", isDirectory: false, isHidden: false),
            WorkspaceNode(name: "v0.0.2.md", relativePath: "v0.0.2.md", isDirectory: false, isHidden: false),
            WorkspaceNode(name: "Notes", relativePath: "Notes", isDirectory: true, isHidden: false),
        ]
        XCTAssertEqual(
            WorkspaceTreeSort.ordered(nodes).map(\.name),
            ["Notes", "v0.0.2.md", "v0.0.9.md", "v0.0.10.md"]
        )
    }

    func testFilterHidesDotfiles() {
        let nodes = [
            WorkspaceNode(name: ".github", relativePath: ".github", isDirectory: true, isHidden: true),
            WorkspaceNode(name: ".gitignore", relativePath: ".gitignore", isDirectory: false, isHidden: true),
            WorkspaceNode(name: "README.md", relativePath: "README.md", isDirectory: false, isHidden: false),
        ]
        XCTAssertEqual(WorkspaceTreeFilter.visible(nodes, showsHidden: true).count, 3)
        XCTAssertEqual(WorkspaceTreeFilter.visible(nodes, showsHidden: false).map(\.name), ["README.md"])
    }

    func testLoaderListsHiddenChildrenAndDoesNotDescend() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("xyz-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let github = root.appendingPathComponent(".github", isDirectory: true)
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        try "name: ci\n".write(to: github.appendingPathComponent("workflows.yml"), atomically: true, encoding: .utf8)
        try "*.build\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "# Hi\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Data("store".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: github
        )

        let nodes = try WorkspaceDirectoryLoader.children(parentRelativePath: "", directoryURL: root)
        let names = Set(nodes.map(\.name))
        XCTAssertTrue(names.isSuperset(of: [".github", ".gitignore", ".DS_Store", "README.md", "link"]))
        XCTAssertFalse(names.contains("workflows.yml"))
        XCTAssertEqual(nodes.first { $0.name == ".github" }?.isDirectory, true)
        XCTAssertEqual(nodes.first { $0.name == ".gitignore" }?.isHidden, true)
        XCTAssertEqual(nodes.first { $0.name == "link" }?.isDirectory, false)
        XCTAssertEqual(nodes.first { $0.name == ".github" }?.relativePath, ".github")

        let nested = try WorkspaceDirectoryLoader.children(parentRelativePath: ".github", directoryURL: github)
        XCTAssertEqual(nested.map(\.relativePath), [".github/workflows.yml"])

        let firstFile = nodes.firstIndex { !$0.isDirectory }
        XCTAssertNotNil(firstFile)
        XCTAssertTrue(nodes.prefix(firstFile!).allSatisfy(\.isDirectory))
    }
}

final class WorkspaceSearchTests: XCTestCase {
    func testSubstringBeatsFuzzyAndIgnoresCase() {
        let spans = WorkspaceNameMatching.spans(in: "Notes.md", query: "note")
        XCTAssertEqual(spans, [WorkspaceNameSpan(location: 0, length: 4)])
        XCTAssertNil(WorkspaceNameMatching.spans(in: "Notes.md", query: "   "))
    }

    func testFuzzySubsequenceHighlightsEachCharacter() {
        let spans = WorkspaceNameMatching.spans(in: "Daily notes", query: "dn")
        XCTAssertEqual(spans?.count, 2)
        XCTAssertEqual(spans?.first, WorkspaceNameSpan(location: 0, length: 1))
        let second = spans?[1]
        let name = "Daily notes" as NSString
        XCTAssertEqual(second.map { name.substring(with: NSRange(location: $0.location, length: $0.length)) }, "n")
    }

    func testFilterKeepsParentsExpandsThemAndIncludesHiddenNames() {
        let entries = [
            WorkspacePathEntry(name: ".git", relativePath: ".git", isDirectory: true, isHidden: true),
            WorkspacePathEntry(name: "config", relativePath: ".git/config", isDirectory: false, isHidden: false),
            WorkspacePathEntry(name: "Notes", relativePath: "Notes", isDirectory: true, isHidden: false),
            WorkspacePathEntry(name: "Daily notes.md", relativePath: "Notes/Daily notes.md", isDirectory: false, isHidden: false),
            WorkspacePathEntry(name: "Other.txt", relativePath: "Other.txt", isDirectory: false, isHidden: false),
            WorkspacePathEntry(name: ".gitignore", relativePath: ".gitignore", isDirectory: false, isHidden: true),
        ]
        let tree = WorkspaceTreeQuery.filter(entries: entries, query: "git")
        XCTAssertEqual(Set(tree.children[""]?.map(\.name) ?? []), [".git", ".gitignore"])
        XCTAssertNil(tree.children[".git"])
        XCTAssertNil(tree.children["Notes"])
        XCTAssertFalse(tree.highlights[".gitignore", default: []].isEmpty)
        XCTAssertFalse(tree.highlights[".git", default: []].isEmpty)

        let nested = WorkspaceTreeQuery.filter(entries: entries, query: "config")
        XCTAssertEqual(nested.children[""]?.map(\.name), [".git"])
        XCTAssertTrue(nested.expanded.contains(".git"))
        XCTAssertEqual(nested.children[".git"]?.map(\.name), ["config"])
    }

    func testFilterDropsUnrelatedSiblings() {
        let entries = [
            WorkspacePathEntry(name: "Notes", relativePath: "Notes", isDirectory: true, isHidden: false),
            WorkspacePathEntry(name: "Daily notes.md", relativePath: "Notes/Daily notes.md", isDirectory: false, isHidden: false),
            WorkspacePathEntry(name: "Other.txt", relativePath: "Other.txt", isDirectory: false, isHidden: false),
        ]
        let tree = WorkspaceTreeQuery.filter(entries: entries, query: "daily")
        XCTAssertEqual(tree.children[""]?.map(\.name), ["Notes"])
        XCTAssertEqual(tree.children["Notes"]?.map(\.name), ["Daily notes.md"])
        XCTAssertTrue(tree.expanded.contains("Notes"))
    }

    func testSymbolsAndDimmedExtension() {
        XCTAssertEqual(WorkspaceFileSymbolChoice.symbol(name: "Notes", isDirectory: true, isExpanded: false), .folder)
        XCTAssertEqual(WorkspaceFileSymbolChoice.symbol(name: "Notes", isDirectory: true, isExpanded: true), .folderOpen)
        XCTAssertEqual(WorkspaceFileSymbolChoice.symbol(name: "Note.md", isDirectory: false, isExpanded: false), .markdown)
        XCTAssertEqual(WorkspaceFileSymbolChoice.symbol(name: ".gitignore", isDirectory: false, isExpanded: false), .gear)
        XCTAssertEqual(WorkspaceFileSymbolChoice.symbol(name: "App.swift", isDirectory: false, isExpanded: false), .document)
        let span = WorkspaceFileSymbolChoice.extensionSpan(in: "Note.md")
        XCTAssertEqual(span, WorkspaceNameSpan(location: 4, length: 3))
        XCTAssertNil(WorkspaceFileSymbolChoice.extensionSpan(in: "App.swift"))
    }

    func testNamesAndMoves() {
        XCTAssertNotNil(WorkspaceItemName.issue(with: " "))
        XCTAssertNotNil(WorkspaceItemName.issue(with: "a/b"))
        XCTAssertNil(WorkspaceItemName.issue(with: "Note.md"))
        XCTAssertEqual(
            WorkspaceItemName.unique(preferred: "Untitled.md", existing: ["Untitled.md", "Untitled 2.md"]),
            "Untitled 3.md"
        )
        XCTAssertFalse(WorkspaceItemName.canMove(item: "Notes", into: "Notes"))
        XCTAssertFalse(WorkspaceItemName.canMove(item: "Notes", into: "Notes/Drafts"))
        XCTAssertFalse(WorkspaceItemName.canMove(item: "Notes/A.md", into: "Notes"))
        XCTAssertTrue(WorkspaceItemName.canMove(item: "Notes/A.md", into: "Archive"))
    }

    func testContentHitsAndSkipRules() {
        XCTAssertTrue(WorkspaceContentSearch.shouldSkipDirectory(".git"))
        XCTAssertTrue(WorkspaceContentSearch.shouldSkipRelativePath("Notes/.git/config"))
        XCTAssertFalse(WorkspaceContentSearch.shouldSkipRelativePath("Notes/Daily.md"))
        XCTAssertTrue(WorkspaceContentSearch.shouldSkipContents(
            name: "pic.png",
            byteCount: 4,
            sample: Data([0x89, 0x50, 0x00, 0x00])
        ))
        XCTAssertTrue(WorkspaceContentSearch.shouldSkipContents(
            name: "big.md",
            byteCount: WorkspaceContentSearch.maxFileBytes + 1,
            sample: Data("hello".utf8)
        ))
        XCTAssertFalse(WorkspaceContentSearch.shouldSkipContents(
            name: "Note.md",
            byteCount: 12,
            sample: Data("alpha beta".utf8)
        ))
        let hits = WorkspaceContentSearch.hits(
            in: "intro\nalpha beta\nAlpha tail\n",
            relativePath: "Notes/Daily.md",
            query: "alpha",
            limit: 5
        )
        XCTAssertEqual(hits.map(\.lineNumber), [2, 3])
        XCTAssertEqual(hits.first?.excerpt, "alpha beta")
        XCTAssertEqual(hits.first?.relativePath, "Notes/Daily.md")
    }
}

final class EditorViewModeTests: XCTestCase {
    func testReadingToggleReturnsToTheEditingModeYouLeft() {
        let toReading = EditorViewMode.toggleReading(current: .preview, editing: .preview)
        XCTAssertEqual(toReading.mode, .reading)
        XCTAssertEqual(toReading.editing, .preview)
        let back = EditorViewMode.toggleReading(current: toReading.mode, editing: toReading.editing)
        XCTAssertEqual(back.mode, .preview)

        let fromCoding = EditorViewMode.toggleReading(current: .coding, editing: .preview)
        XCTAssertEqual(fromCoding.mode, .reading)
        XCTAssertEqual(fromCoding.editing, .coding)
        XCTAssertEqual(
            EditorViewMode.toggleReading(current: .reading, editing: .coding).mode,
            .coding
        )
    }

    func testSourceToggleMatchesTypora() {
        XCTAssertEqual(EditorViewMode.toggleSource(current: .preview), .coding)
        XCTAssertEqual(EditorViewMode.toggleSource(current: .coding), .preview)
        XCTAssertEqual(EditorViewMode.toggleSource(current: .reading), .coding)
    }
}

final class WorkspaceFilePolicyTests: XCTestCase {
    func testClassifier() {
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "README.md", byteCount: 4, sample: Data("# Hi".utf8)),
            .markdown
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "Note.markdown", byteCount: 1, sample: Data("a".utf8)),
            .markdown
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: ".gitignore", byteCount: 6, sample: Data("*.build".utf8)),
            .plainText
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "App.swift", byteCount: 2, sample: Data("{}".utf8)),
            .plainText
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "empty.txt", byteCount: 0, sample: Data()),
            .plainText
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "pic.png", byteCount: 4, sample: Data([0x89, 0x50, 0x00, 0x00])),
            .binary
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "bad.md", byteCount: 2, sample: Data([0x00, 0x01])),
            .binary
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "big.txt", byteCount: WorkspaceFileClassifier.editLimit + 1, sample: Data()),
            .tooLarge
        )
    }

    func testCJKSampleBoundaryIsText() {
        let character: [UInt8] = [0xE4, 0xB8, 0x80]
        for tail in 0..<3 {
            let sample = sampleCutting(unit: character, tailBytes: tail)
            XCTAssertEqual(sample.count, WorkspaceFileClassifier.sampleLimit)
            if tail == 0 {
                XCTAssertNotNil(String(data: sample, encoding: .utf8))
            } else {
                XCTAssertNil(String(data: sample, encoding: .utf8))
            }
            let count = sample.count + character.count
            XCTAssertFalse(WorkspaceFileClassifier.needsFullRead(byteCount: count, sample: sample))
            XCTAssertEqual(
                WorkspaceFileClassifier.kind(name: "essay.md", byteCount: count, sample: sample),
                .markdown
            )
            XCTAssertEqual(
                WorkspaceFileClassifier.kind(name: "notes.txt", byteCount: count, sample: sample),
                .plainText
            )
            XCTAssertEqual(
                WorkspaceFileClassifier.utf8Sample(sample, byteCount: count),
                .text
            )
        }
    }

    func testEmojiSampleBoundaryIsText() {
        let emoji: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        for tail in 1...3 {
            let sample = sampleCutting(unit: emoji, tailBytes: tail)
            XCTAssertNil(String(data: sample, encoding: .utf8))
            XCTAssertEqual(
                WorkspaceFileClassifier.kind(
                    name: "note.md",
                    byteCount: sample.count + 4,
                    sample: sample
                ),
                .markdown
            )
        }
    }

    func testNULIsBinary() {
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(
                name: "notes.md",
                byteCount: 4,
                sample: Data([0x61, 0x00, 0x62, 0x63])
            ),
            .binary
        )
    }

    func testLatin1IsBinaryWhenTheFileIsComplete() {
        let latin1 = Data([0x48, 0x69, 0x20, 0xE9])
        XCTAssertNil(String(data: latin1, encoding: .utf8))
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "letter.dat", byteCount: latin1.count, sample: latin1),
            .binary
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "letter.txt", byteCount: latin1.count, sample: latin1),
            .binary
        )
        XCTAssertFalse(
            WorkspaceFileClassifier.needsFullRead(byteCount: latin1.count, sample: latin1)
        )
    }

    func testAmbiguousCutReadsTheFullFile() {
        let full = Data(String(repeating: "\u{4E00}", count: 8).utf8)
        var sample = Data(full.prefix(6))
        sample.append(0xFF)
        XCTAssertTrue(WorkspaceFileClassifier.needsFullRead(byteCount: full.count, sample: sample))
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "blob.bin", byteCount: full.count, sample: sample),
            .binary
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(
                name: "blob.bin",
                byteCount: full.count,
                sample: sample,
                fullFile: full
            ),
            .plainText
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "essay.md", byteCount: full.count, sample: sample),
            .markdown
        )
    }

    private func sampleCutting(unit: [UInt8], tailBytes: Int) -> Data {
        let limit = WorkspaceFileClassifier.sampleLimit
        let incomplete = tailBytes == unit.count ? 0 : tailBytes
        let bodyCount = limit - incomplete
        var data = Data()
        let width = unit.count
        let ascii = bodyCount % width
        data.append(Data(repeating: 0x61, count: ascii))
        while data.count + width <= bodyCount {
            data.append(contentsOf: unit)
        }
        if incomplete > 0 {
            data.append(contentsOf: unit.prefix(incomplete))
        }
        return data
    }

    func testExternalChangeDoesNotClobberEdits() {
        XCTAssertEqual(
            WorkspaceFilePolicy.interpretChange(editor: "local", lastSaved: "base", disk: "remote"),
            .conflict
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.interpretChange(editor: "base", lastSaved: "base", disk: "remote"),
            .reload
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.interpretChange(editor: "local", lastSaved: "base", disk: "base"),
            .ignore
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.interpretChange(editor: "same", lastSaved: "same", disk: "same"),
            .ignore
        )
    }

    func testWriteDecision() {
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: "base", force: false),
            .write
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: "next", force: false),
            .upToDate
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: "remote", force: false),
            .conflict
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: "remote", force: true),
            .write
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "base", lastSaved: "base", disk: nil, force: false),
            .upToDate
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: nil, force: false),
            .conflict
        )
        XCTAssertEqual(
            WorkspaceFilePolicy.decideWrite(editor: "next", lastSaved: "base", disk: nil, force: true),
            .write
        )
    }
}
