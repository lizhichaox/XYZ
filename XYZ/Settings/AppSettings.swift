import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Light, dark, or the system's choice. Stored in `AppAppearance.key`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "xyz.appearance"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    #if os(macOS)
    /// The whole app follows one appearance: editors, Reading, the sidebar, and panels.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// The interface language. `system` follows the order in System Settings; the others
/// set this app's `AppleLanguages`, which macOS reads when the app launches.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let key = "xyz.language"

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whichever one is showing.
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        switch self {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    #if os(macOS)
    /// Opens a new copy of the app, then quits this one. Open documents are saved as usual.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
    #endif
}

/// Show Word Count in the View menu. Stored in `WordCountSetting.key`.
enum WordCountSetting {
    static let key = "xyz.view.wordCount"
}

#if os(macOS)
/// View → Zoom In, Zoom Out, Actual Size. They change the text size shared by Source and Reading.
enum TextZoom {
    static func step(_ delta: Double) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: XYZEditorStyle.fontSizeKey) as? Double ?? XYZEditorStyle.defaultFontSize
        let next = XYZEditorStyle.clampedFontSize(current + delta)
        defaults.set(next, forKey: XYZEditorStyle.fontSizeKey)
    }

    static func reset() {
        UserDefaults.standard.set(XYZEditorStyle.defaultFontSize, forKey: XYZEditorStyle.fontSizeKey)
    }
}
#endif
