import SwiftUI
import Speech

struct ContentView: View {
    @ObservedObject private var model = TranslatorModel.shared
    @State private var speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    // Audio Recording permission is auto-prompted by Core Audio on first capture

    private let supportedLanguages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
        ("id", "Indonesian"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("nl", "Dutch"),
        ("uk", "Ukrainian"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "settings.title"))
                    .font(.title2.bold())
                    .padding(.bottom, 4)

                languagesSection
                speechEngineSection
                displaySection
                appearanceSection
                commitBehaviorSection
                permissionsSection
                shortcutsSection
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 700, minHeight: 500)
        .onAppear {
            checkPermissions()
        }
    }

    // MARK: - Languages

    private var languagesSection: some View {
        SettingsSection(title: String(localized: "settings.languages")) {
            HStack {
                Text(String(localized: "settings.sourceLanguage"))
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $model.sourceLanguageCode) {
                    ForEach(supportedLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            HStack {
                Text(String(localized: "settings.targetLanguage"))
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $model.targetLanguageCode) {
                    ForEach(supportedLanguages.filter { $0.code != "auto" }, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
        }
    }

    // MARK: - Speech Engine

    private var speechEngineSection: some View {
        SettingsSection(title: String(localized: "settings.speechEngine")) {
            Picker("Engine", selection: $model.speechEngine) {
                ForEach(TranslatorModel.SpeechEngine.allCases, id: \.self) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if model.speechEngine == .whisperKit {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.whisperModelState {
                    case .notDownloaded:
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                            Text(String(localized: "settings.whisperNotDownloaded"))
                                .foregroundStyle(.secondary)
                        }
                        Text(String(localized: "settings.whisperHelp"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    case .downloading(let progress):
                        ProgressView("Downloading model\u{2026}", value: progress, total: 1.0)
                    case .ready:
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(String(localized: "settings.whisperReady"))
                        }
                    case .error(let message):
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        SettingsSection(title: String(localized: "settings.display")) {
            Picker("Mode", selection: $model.displayMode) {
                ForEach(TranslatorModel.DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(String(localized: "settings.showOverlayOn"))
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $model.selectedScreenID) {
                    Text(String(localized: "settings.autoBuiltIn")).tag(CGDirectDisplayID(0))
                    ForEach(screenDescriptors(), id: \.id) { screen in
                        Text(screen.localizedName).tag(screen.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            Toggle(String(localized: "settings.showOverlay"), isOn: $model.isOverlayVisible)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsSection(title: String(localized: "settings.appearance")) {
            sliderRow(label: String(localized: "settings.fontSize"), value: $model.fontSize, range: 12...40, step: 1)
            sliderRow(label: String(localized: "settings.overlayWidth"), value: $model.overlayWidth, range: 400...1200, step: 10)
            sliderRow(label: String(localized: "settings.overlayHeight"), value: $model.overlayHeight, range: 120...300, step: 5)
        }
    }

    // MARK: - Commit Behavior

    private var commitBehaviorSection: some View {
        SettingsSection(title: String(localized: "settings.commitBehavior")) {
            HStack {
                Text(String(localized: "settings.autoCommitAfter"))
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $model.autoCommitWordCount) {
                    Text(String(localized: "settings.disabled")).tag(0)
                    ForEach([5, 8, 10, 12, 15, 20, 25, 30], id: \.self) { n in
                        Text(String(format: String(localized: "settings.nWords"), n)).tag(n)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            sliderRow(label: String(localized: "settings.maxDisplayChars"), value: Binding(
                get: { Double(model.maxDisplayChars) },
                set: { model.maxDisplayChars = Int($0) }
            ), range: 40...200, step: 10)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsSection(title: String(localized: "settings.permissions")) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "settings.audioRecording"))
                Spacer()
            }

            HStack {
                Image(systemName: speechAuthStatus == .authorized ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(speechAuthStatus == .authorized ? .green : .secondary)
                Text(String(localized: "settings.speechRecognition"))
                Spacer()
                if speechAuthStatus != .authorized {
                    Button(String(localized: "settings.request")) {
                        Task {
                            speechAuthStatus = await AppleSpeechRecognizer.requestAuthorization()
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        SettingsSection(title: String(localized: "settings.keyboardShortcuts")) {
            ForEach(ShortcutCommand.allCases, id: \.self) { command in
                HStack {
                    Text(command.displayShortcut)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 60, alignment: .leading)
                    Text(command.menuTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue))")
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func screenDescriptors() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return ScreenDescriptor(
                id: id,
                localizedName: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMenuBarScreen: id == CGMainDisplayID()
            )
        }
    }

    private func checkPermissions() {
        speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        Task {
            // Audio Recording permission handled automatically by Core Audio
        }
    }

    private func openSystemSettings(_ panel: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panel)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings Section

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}
