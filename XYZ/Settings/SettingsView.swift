#if os(macOS)
import SwiftUI

/// XYZ → Settings…: one pane, grouped like System Settings.
struct SettingsView: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system
    @AppStorage(XYZEditorStyle.monospacedKey) private var monospaced = false
    @AppStorage(XYZEditorStyle.fontSizeKey) private var fontSize = XYZEditorStyle.defaultFontSize
    @AppStorage(XYZEditorStyle.readableWidthKey) private var readableWidth = false
    @AppStorage(WordCountSetting.key) private var showsWordCount = false

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

            Section("Text") {
                Picker("Font", selection: $monospaced) {
                    Text("System").tag(false)
                    Text("Monospaced").tag(true)
                }
                .pickerStyle(.segmented)

                LabeledContent("Size") {
                    Stepper(value: $fontSize, in: XYZEditorStyle.fontSizes, step: 1) {
                        Text("\(Int(XYZEditorStyle.clampedFontSize(fontSize))) pt")
                            .monospacedDigit()
                    }
                }

                Toggle(isOn: $readableWidth) {
                    Text("Limit line width")
                    Text("Keeps lines at a comfortable length in wide windows, in Source and Reading.")
                }
            }

            Section("View") {
                Toggle(isOn: $showsWordCount) {
                    Text("Show word count")
                    Text("Counts Chinese and Japanese by character, other languages by word.")
                }
            }
        }
        .formStyle(.grouped)
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
#endif
