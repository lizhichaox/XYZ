import XCTest
@testable import XYZCore

final class LinkedNotePathTests: XCTestCase {
    private let root = "/Vault"
    private let folder = "/Vault/ST/MEM"

    func testRootRelativeTargetFallsBackToTheVaultRoot() {
        let file = LinkedNotePath.rootRelative(
            linkPath: "/Vault/ST/MEM/ST/AGENTS.md",
            noteFolderPath: folder,
            rootPath: root,
            isFile: { $0 == "/Vault/ST/AGENTS.md" }
        )
        XCTAssertEqual(file, "ST/AGENTS.md")
    }

    func testMissingFileStaysMissing() {
        XCTAssertNil(LinkedNotePath.rootRelative(
            linkPath: "/Vault/ST/MEM/AGENTS.md",
            noteFolderPath: folder,
            rootPath: root,
            isFile: { _ in false }
        ))
    }

    func testLinkOutsideTheNoteFolderIsNotRewritten() {
        XCTAssertNil(LinkedNotePath.rootRelative(
            linkPath: "/Vault/HM/People/Li_Zhichao.md",
            noteFolderPath: folder,
            rootPath: root,
            isFile: { _ in true }
        ))
    }

    func testTrailingSlashesAreIgnored() {
        XCTAssertEqual(
            LinkedNotePath.rootRelative(
                linkPath: "/Vault/ST/MEM/ST/AGENTS.md",
                noteFolderPath: folder + "/",
                rootPath: root + "/",
                isFile: { $0 == "/Vault/ST/AGENTS.md" }
            ),
            "ST/AGENTS.md"
        )
    }

    func testTheNoteItselfIsNotAValidTarget() {
        XCTAssertNil(LinkedNotePath.rootRelative(
            linkPath: "/Vault/ST/MEM/",
            noteFolderPath: folder,
            rootPath: root,
            isFile: { _ in true }
        ))
    }
}
