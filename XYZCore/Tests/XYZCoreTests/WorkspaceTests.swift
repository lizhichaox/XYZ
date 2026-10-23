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
