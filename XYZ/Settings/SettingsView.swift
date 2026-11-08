#if os(macOS)
import SwiftUI

/// XYZ → Settings…: one pane, grouped like System Settings.
struct SettingsView: View {
    /// One trailing value column, so "12 pt" and "1.0" line up above one another.
    private static let valueColumnWidth: CGFloat = 34

    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system
    @AppStorage(XYZEditorStyle.fontSizeKey) private var fontSize = XYZEditorStyle.defaultFontSize
    @AppStorage(XYZEditorStyle.lineSpacingKey) private var lineSpacing = XYZEditorStyle.defaultLineSpacing
    @AppStorage(XYZEditorStyle.wordWrapKey) private var wordWrap = true
    @AppStorage(WordCountSetting.key) private var showsWordCount = false
    @AppStorage(HiddenFilesSetting.key) private var showsHiddenFiles = true
    @AppStorage(RemoteImagesSetting.key) private var loadsRemoteImages = false

    /// The language this process launched with. A different choice waits for a restart.
    @State private var launchLanguage = AppLanguage.stored

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } footer: {
                if language != launchLanguage {
                    HStack(spacing: 8) {
                        Text("XYZ uses the new language after it restarts.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Restart Now") {
                            AppLanguage.relaunch()
                        }
                    }
                    .font(.callout)
                }
            }

            Section {
                LabeledContent("Size") {
                    Stepper(value: $fontSize, in: XYZEditorStyle.fontSizes, step: 1) {
                        Text("\(Int(XYZEditorStyle.clampedFontSize(fontSize))) pt")
                            .monospacedDigit()
                            .frame(width: Self.valueColumnWidth, alignment: .trailing)
                    }
                }

                LabeledContent("Line spacing") {
                    Stepper(value: $lineSpacing, in: XYZEditorStyle.lineSpacings, step: 0.1) {
                        Text(String(format: "%.1f", XYZEditorStyle.clampedLineSpacing(lineSpacing)))
                            .monospacedDigit()
                            .frame(width: Self.valueColumnWidth, alignment: .trailing)
                    }
                }

                Toggle(isOn: $wordWrap) {
                    Text("Wrap lines")
                    Text("Long lines break at the editor width.")
                        .lineLimit(1)
                }
            } header: {
                Text("Text")
            }

            Section("Reading") {
                Toggle(isOn: $loadsRemoteImages) {
                    Text("Load remote images")
                    Text("Off by default. Local pictures still load.")
                        .lineLimit(1)
                }
            }

            Section("View") {
                Toggle(isOn: $showsWordCount) {
                    Text("Show word count")
                    Text("Chinese and Japanese by character, others by word.")
                        .lineLimit(1)
                }

                Toggle(isOn: $showsHiddenFiles) {
                    Text("Show hidden files")
                    Text("Lists names that start with a dot.")
                        .lineLimit(1)
                }
            }
        }
        .formStyle(.grouped)
        .closesOnEscape()
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { _, value in
            value.apply()
        }
        .onChange(of: language) { _, value in
            value.apply()
        }
    }
}

/// Shown from XYZ → Settings…. Built only when asked, so launch does not keep a hidden window.
@MainActor
enum SettingsWindow {
    private static var panel: NSPanel?

    static func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Settings")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        EscapeKey.register(panel)
        let host = NSHostingController(rootView: SettingsView())
        host.view.frame = NSRect(x: 0, y: 0, width: 480, height: 520)
        host.view.layoutSubtreeIfNeeded()
        let fitted = host.view.fittingSize
        let height = fitted.height > 1 ? fitted.height : 520
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 480, height: height))
        return panel
    }
}
#endif
