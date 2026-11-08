import XCTest
@testable import XYZCore

final class XYZThemeTests: XCTestCase {
    func testEveryThemeDefinesEverySyntaxKind() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            for kind: SyntaxTokenKind in [.comment, .string, .number, .keyword, .type, .key] {
                XCTAssertNotNil(theme.syntax.color(for: kind), "\(kind) missing")
            }
        }
    }

    func testBodyTextPassesAAOnTheEditorCanvas() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            XCTAssertGreaterThanOrEqual(XYZColor.contrast(theme.ink, theme.editor), 4.5)
        }
    }

    func testSecondaryTextPassesAA() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            XCTAssertGreaterThanOrEqual(XYZColor.contrast(theme.secondaryText, theme.editor), 4.5)
        }
    }

    func testSyntaxColorsReadOnTheCanvas() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            for kind: SyntaxTokenKind in [.string, .number, .keyword, .type, .key] {
                guard let color = theme.syntax.color(for: kind) else {
                    XCTFail("missing \(kind)")
                    continue
                }
                XCTAssertGreaterThanOrEqual(XYZColor.contrast(color, theme.editor), 2.5, "\(kind) too faint")
            }
        }
    }

    func testResolutionFollowsAppearance() {
        XCTAssertEqual(XYZTheme.resolved(dark: false), .light)
        XCTAssertEqual(XYZTheme.resolved(dark: true), .dark)
    }

    func testSelectionStaysSoft() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            XCTAssertLessThan(theme.selection.alpha, 0.3)
            XCTAssertLessThan(theme.currentLine.alpha, 0.15)
        }
    }

    func testColorHexParsing() {
        let white = XYZColor(hex: 0xFFFFFF)
        XCTAssertEqual(white.red, 1, accuracy: 0.001)
        XCTAssertEqual(white.green, 1, accuracy: 0.001)
        XCTAssertEqual(white.blue, 1, accuracy: 0.001)
        let accent = XYZColor(hex: 0x0078D4)
        XCTAssertEqual(accent.blue, 212.0 / 255, accuracy: 0.001)
    }

    func testHoverAndDisabledShareOneLanguage() {
        for theme in [XYZTheme.light, XYZTheme.dark] {
            XCTAssertGreaterThan(theme.hover.alpha, 0)
            XCTAssertGreaterThan(theme.disabledTint.alpha, 0)
        }
    }
}
