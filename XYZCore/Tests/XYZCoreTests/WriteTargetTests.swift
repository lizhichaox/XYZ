import XCTest
@testable import XYZCore

final class WriteTargetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("xyz-write-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testAPlainPathIsReturnedStandardized() throws {
        let file = root.appendingPathComponent("note.md")
        try write("one\n", to: file)
        XCTAssertEqual(WorkspaceWriteTarget.resolveForWriting(file).path, file.standardizedFileURL.path)
        let missing = root.appendingPathComponent("missing.md")
        XCTAssertEqual(WorkspaceWriteTarget.resolveForWriting(missing).path, missing.standardizedFileURL.path)
    }

    func testASymbolicLinkResolvesToItsFile() throws {
        let target = try makeFolder("real").appendingPathComponent("note.md")
        try write("one\n", to: target)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let resolved = WorkspaceWriteTarget.resolveForWriting(link)
        XCTAssertEqual(resolved.path, target.standardizedFileURL.path)
        XCTAssertNotEqual(resolved.path, link.path)
    }

    /// The point of resolving: an atomic write through the link replaces the link with
    /// a regular file and leaves the file it names at its old text.
    func testWritingThroughTheResolvedPathKeepsTheLinkAndUpdatesTheTarget() throws {
        let target = try makeFolder("real").appendingPathComponent("note.md")
        try write("one\n", to: target)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let writeTarget = WorkspaceWriteTarget.resolveForWriting(link)
        try write("two\n", to: writeTarget)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "two\n")
    }

    func testAChainOfLinksResolvesToTheLastFile() throws {
        let target = root.appendingPathComponent("note.md")
        try write("one\n", to: target)
        let middle = root.appendingPathComponent("middle.md")
        try FileManager.default.createSymbolicLink(at: middle, withDestinationURL: target)
        let first = root.appendingPathComponent("first.md")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: middle)
        XCTAssertEqual(WorkspaceWriteTarget.resolveForWriting(first).path, target.standardizedFileURL.path)
    }

    func testALinkLoopFallsBackToThePathTheCallerAskedFor() throws {
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertEqual(WorkspaceWriteTarget.resolveForWriting(a).path, a.standardizedFileURL.path)
    }
}
