import Foundation

/// One theme color. Stored as 0...1 components so XYZCore stays free of AppKit/UIKit;
/// the app converts these to `NSColor`/`Color` per platform.
public struct XYZColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public func withAlpha(_ alpha: Double) -> XYZColor {
        XYZColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// WCAG relative luminance, 0...1.
    public var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors, 1...21. Alpha is ignored.
    public static func contrast(_ first: XYZColor, _ second: XYZColor) -> Double {
        let lighter = max(first.luminance, second.luminance)
        let darker = min(first.luminance, second.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The six kinds syntax coloring uses. Each has one color per theme variant.
public struct SyntaxPalette: Equatable, Sendable {
    public var comment: XYZColor
    public var string: XYZColor
    public var number: XYZColor
    public var keyword: XYZColor
    public var type: XYZColor
    public var key: XYZColor

    public init(comment: XYZColor, string: XYZColor, number: XYZColor, keyword: XYZColor, type: XYZColor, key: XYZColor) {
        self.comment = comment
        self.string = string
        self.number = number
        self.keyword = keyword
        self.type = type
        self.key = key
    }

    public func color(for kind: SyntaxTokenKind) -> XYZColor? {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        case .key: key
        }
    }
}

/// One display theme. Every color the app draws comes from here: the editor canvas, the
/// chrome, the accents and the syntax palette. Two built-in themes exist; the Appearance
/// setting picks which one the app resolves.
public struct XYZTheme: Equatable, Sendable {
    /// Editor and Reading canvas.
    public var editor: XYZColor
    /// Sidebar, status bar and title-bar field.
    public var sidebar: XYZColor
    /// Body text.
    public var ink: XYZColor
    /// Tree, breadcrumbs, status, gutter numbers.
    public var secondaryText: XYZColor
    /// The quietest labels: placeholders, separators, folded markers.
    public var tertiaryText: XYZColor
    /// Dividers, hairline surfaces and the few accent marks.
    public var accent: XYZColor
    /// Selected rows and pressed toggles: the accent at a soft alpha.
    public var selection: XYZColor
    /// The text-selection block inside the editor.
    public var selectionText: XYZColor
    /// The band behind the caret's line in Editing.
    public var currentLine: XYZColor
    /// Hairline between surfaces.
    public var divider: XYZColor
    /// Hover feedback on rows, toggles and title-bar buttons.
    public var hover: XYZColor
    /// A control that cannot be used.
    public var disabledTint: XYZColor
    /// All other occurrences of the find pattern.
    public var findMatch: XYZColor
    /// The find match the editor is currently on.
    public var findCurrent: XYZColor
    /// Pressed find toggles.
    public var findToggleFill: XYZColor
    public var findToggleInk: XYZColor
    /// Syntax colors, one entry per variant.
    public var syntax: SyntaxPalette

    public init(
        editor: XYZColor,
        sidebar: XYZColor,
        ink: XYZColor,
        secondaryText: XYZColor,
        tertiaryText: XYZColor,
        accent: XYZColor,
        selection: XYZColor,
        selectionText: XYZColor,
        currentLine: XYZColor,
        divider: XYZColor,
        hover: XYZColor,
        disabledTint: XYZColor,
        findMatch: XYZColor,
        findCurrent: XYZColor,
        findToggleFill: XYZColor,
        findToggleInk: XYZColor,
        syntax: SyntaxPalette
    ) {
        self.editor = editor
        self.sidebar = sidebar
        self.ink = ink
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accent = accent
        self.selection = selection
        self.selectionText = selectionText
        self.currentLine = currentLine
        self.divider = divider
        self.hover = hover
        self.disabledTint = disabledTint
        self.findMatch = findMatch
        self.findCurrent = findCurrent
        self.findToggleFill = findToggleFill
        self.findToggleInk = findToggleInk
        self.syntax = syntax
    }

    /// The light theme: white surfaces, blue accent, quiet colors.
    public static let light = XYZTheme(
        editor: XYZColor(hex: 0xFFFFFF),
        sidebar: XYZColor(hex: 0xFFFFFF),
        ink: XYZColor(hex: 0x1F1F1F),
        secondaryText: XYZColor(hex: 0x5F6368),
        tertiaryText: XYZColor(hex: 0x9BA0A5),
        accent: XYZColor(hex: 0x0078D4),
        selection: XYZColor(hex: 0x0078D4, alpha: 0.14),
        selectionText: XYZColor(hex: 0x0078D4, alpha: 0.28),
        currentLine: XYZColor(hex: 0x0078D4, alpha: 0.06),
        divider: XYZColor(hex: 0xE5E5E5),
        hover: XYZColor(hex: 0x1F1F1F, alpha: 0.07),
        disabledTint: XYZColor(hex: 0x5F6368, alpha: 0.35),
        findMatch: XYZColor(hex: 0x0078D4, alpha: 0.16),
        findCurrent: XYZColor(hex: 0x0078D4, alpha: 0.42),
        findToggleFill: XYZColor(hex: 0x0078D4, alpha: 0.14),
        findToggleInk: XYZColor(hex: 0x0078D4),
        syntax: SyntaxPalette(
            comment: XYZColor(hex: 0x5F6368),
            string: XYZColor(hex: 0xA31515),
            number: XYZColor(hex: 0x098658),
            keyword: XYZColor(hex: 0x1F2F93),
            type: XYZColor(hex: 0x267F99),
            key: XYZColor(hex: 0x0852A6)
        )
    )

    /// The dark theme: near-black surfaces, the same accent, warmer syntax.
    public static let dark = XYZTheme(
        editor: XYZColor(hex: 0x1E1E1E),
        sidebar: XYZColor(hex: 0x181818),
        ink: XYZColor(hex: 0xD4D4D4),
        secondaryText: XYZColor(hex: 0x9D9D9D),
        tertiaryText: XYZColor(hex: 0x6B6B6B),
        accent: XYZColor(hex: 0x0078D4),
        selection: XYZColor(hex: 0x0078D4, alpha: 0.20),
        selectionText: XYZColor(hex: 0x264F78),
        currentLine: XYZColor(hex: 0xD4D4D4, alpha: 0.08),
        divider: XYZColor(hex: 0x2B2B2B),
        hover: XYZColor(hex: 0xD4D4D4, alpha: 0.07),
        disabledTint: XYZColor(hex: 0x9D9D9D, alpha: 0.35),
        findMatch: XYZColor(hex: 0xEA5C00, alpha: 0.50),
        findCurrent: XYZColor(hex: 0xEA5C00, alpha: 0.92),
        findToggleFill: XYZColor(hex: 0x0078D4),
        findToggleInk: XYZColor(hex: 0xFFFFFF),
        syntax: SyntaxPalette(
            comment: XYZColor(hex: 0x7F7F7F),
            string: XYZColor(hex: 0xCE9178),
            number: XYZColor(hex: 0xB5CEA8),
            keyword: XYZColor(hex: 0x569CD6),
            type: XYZColor(hex: 0x4EC9B0),
            key: XYZColor(hex: 0x9CDCFE)
        )
    )

    public static func resolved(dark: Bool) -> XYZTheme {
        dark ? .dark : .light
    }
}
