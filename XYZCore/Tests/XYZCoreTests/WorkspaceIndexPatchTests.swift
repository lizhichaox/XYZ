import XCTest
@testable import XYZCore

final class WorkspaceIndexPatchTests: XCTestCase {
    private func entry(_ path: String, directory: Bool = false) -> WorkspacePathEntry {
        WorkspacePathEntry(
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            isDirectory: directory,
            isHidden: false
        )
    }

    func testReplacesDirectChildrenInPlace() {
        let entries = [entry("A"), entry("A/one.md"), entry("A/two.md"), entry("B")]
        let patched = WorkspaceIndexPatch.replacing(
            entries: entries,
            parent: "A",
            children: [entry("A/one.md"), entry("A/three.md")]
        )
        XCTAssertEqual(patched.map(\.relativePath), ["A", "A/one.md", "A/three.md", "B"])
    }

    func testKeepsDeeperEntries() {
        let entries = [entry("A", directory: true), entry("A/sub", directory: true), entry("A/sub/deep.md")]
        let patched = WorkspaceIndexPatch.replacing(
            entries: entries,
            parent: "A",
            children: [entry("A/sub", directory: true)]
        )
        XCTAssertEqual(patched.map(\.relativePath), ["A", "A/sub", "A/sub/deep.md"])
    }

    func testAppendsWhenParentsEntriesWereMissing() {
        let entries = [entry("B")]
        let patched = WorkspaceIndexPatch.replacing(
            entries: entries,
            parent: "A",
            children: [entry("A/one.md")]
        )
        XCTAssertEqual(patched.map(\.relativePath), ["B", "A/one.md"])
    }

    func testEmptyChildrenRemoveTheFolderContents() {
        let entries = [entry("A/one.md"), entry("B")]
        let patched = WorkspaceIndexPatch.replacing(entries: entries, parent: "A", children: [])
        XCTAssertEqual(patched.map(\.relativePath), ["B"])
    }

    func testRootParentReplacesOnlyTopLevelEntries() {
        let entries = [entry("A", directory: true), entry("A/deep.md"), entry("B")]
        let patched = WorkspaceIndexPatch.replacing(
            entries: entries,
            parent: "",
            children: [entry("A", directory: true), entry("B"), entry("C")]
        )
        XCTAssertEqual(patched.map(\.relativePath), ["A", "B", "C", "A/deep.md"])
    }
}
