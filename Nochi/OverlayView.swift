import AppKit
import SwiftUI

private extension Color {
    static let notchBlack = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1.0)
}

private struct AppleNotchShape: InsettableShape {
    var bottomCornerRadiusRatio: CGFloat = 0.18
    var sideWallDepthRatio: CGFloat = 0.82
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        let w = r.width
        let h = r.height

        let depthRatio = max(0.60, min(sideWallDepthRatio, 0.95))
        let lowerArcStartY = r.minY + (h * depthRatio)
        let maxBottomRadiusFromDepth = max(0, r.maxY - lowerArcStartY)
        let maxBottomRadiusFromWidth = w * 0.5
        let targetBottomRadius = h * bottomCornerRadiusRatio
        let bottomRadius = max(
            0,
            min(targetBottomRadius, min(maxBottomRadiusFromDepth, maxBottomRadiusFromWidth))
        )

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))

        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.maxX - bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.minX + bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()

        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

struct OverlayView: View {
    @ObservedObject var model: TranslatorModel
    @State private var showControls = true
    @State private var controlsTimer: Task<Void, Never>?

    private let languageOptions: [(code: String, flag: String, name: String)] = [
        ("ja", "\u{1F1EF}\u{1F1F5}", "JA"),
        ("en", "\u{1F1FA}\u{1F1F8}", "EN"),
        ("ko", "\u{1F1F0}\u{1F1F7}", "KO"),
        ("zh-Hans", "\u{1F1E8}\u{1F1F3}", "ZH"),
        ("es", "\u{1F1EA}\u{1F1F8}", "ES"),
        ("fr", "\u{1F1EB}\u{1F1F7}", "FR"),
        ("de", "\u{1F1E9}\u{1F1EA}", "DE"),
        ("pt", "\u{1F1E7}\u{1F1F7}", "PT"),
        ("ru", "\u{1F1F7}\u{1F1FA}", "RU"),
        ("ar", "\u{1F1F8}\u{1F1E6}", "AR"),
        ("hi", "\u{1F1EE}\u{1F1F3}", "HI"),
        ("th", "\u{1F1F9}\u{1F1ED}", "TH"),
        ("vi", "\u{1F1FB}\u{1F1F3}", "VI"),
        ("id", "\u{1F1EE}\u{1F1E9}", "ID"),
        ("it", "\u{1F1EE}\u{1F1F9}", "IT"),
        ("tr", "\u{1F1F9}\u{1F1F7}", "TR"),
    ]

    var body: some View {
        let shape = AppleNotchShape()
        let hideTopStrokeHeight: CGFloat = 2

        ZStack {
            // Background
            shape
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1.0))

            shape
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                .mask(
                    VStack(spacing: 0) {
                        Color.clear.frame(height: hideTopStrokeHeight)
                        Color.white
                    }
                )

            // Subtitle content — two fixed zones
            VStack(spacing: 4) {
                // Zone 1: Completed lines — scroll upward, fill available space
                VStack(spacing: 2) {
                    if !model.isListening && model.subtitleLines.isEmpty && model.translatedText.isEmpty {
                        Text(isSubtitleMode ? String(localized: "overlay.readySubtitles") : String(localized: "overlay.readyTranslate"))
                            .font(.system(size: CGFloat(model.fontSize * 0.85), weight: .regular))
                            .foregroundStyle(.white.opacity(0.3))
                    } else if model.isListening && model.subtitleLines.isEmpty && model.originalText.isEmpty {
                        listeningIndicator
                    } else {
                        ForEach(Array(model.subtitleLines.enumerated()), id: \.element.id) { index, line in
                            let opacity = lineOpacity(index: index, total: model.subtitleLines.count)
                            subtitleLineView(line, opacity: opacity)
                        }
                        .animation(.easeInOut(duration: 0.25), value: model.subtitleLines.count)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped()
                .geometryGroup()

                // Zone 2: Current in-progress line — fixed at bottom, never moves
                VStack(spacing: 1) {
                    if model.displayMode == .both && !isSubtitleMode && !model.originalText.isEmpty {
                        Text(model.originalText)
                            .font(.system(size: CGFloat(model.fontSize * 0.7), weight: .regular))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                    Text(model.translatedText.isEmpty ? " " : model.translatedText)
                        .font(.system(size: CGFloat(model.fontSize), weight: .medium))
                        .foregroundStyle(.white.opacity(model.translatedText.isEmpty ? 0 : 1))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .padding(.top, 36)

            // Control bar — must not animate with subtitle transitions
            HStack {
                // Left: listening indicator + toggle + language picker
                HStack(spacing: 6) {
                    OverlayControlButton(
                        symbol: model.isListening ? "stop.fill" : "mic.fill",
                        isActive: model.isListening
                    ) {
                        model.toggleListening()
                    }
                    .help(model.isListening ? String(localized: "overlay.stopListening") : String(localized: "overlay.startListening"))

                    if model.isListening {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    }

                    // Language picker: source -> target
                    OverlayLanguagePicker(
                        selectedCode: $model.sourceLanguageCode,
                        options: languageOptions,
                        label: sourceLabel
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))

                    OverlayLanguagePicker(
                        selectedCode: $model.targetLanguageCode,
                        options: languageOptions,
                        label: targetLabel
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.7), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

                Spacer(minLength: 8)

                // Right: display picker, display mode, font, close
                HStack(spacing: 6) {
                    OverlayControlButton(symbol: "display") {
                        let screens = model.availableScreens
                        guard screens.count > 1 else { return }
                        if let idx = screens.firstIndex(where: { $0.isCurrent }) {
                            let next = screens[(idx + 1) % screens.count]
                            model.selectScreen(next.id)
                        } else {
                            if let first = screens.first { model.selectScreen(first.id) }
                        }
                    }
                    .help(String(localized: "overlay.moveToDisplay"))

                    OverlayControlButton(
                        symbol: model.displayMode == .both ? "text.justify.left" : "captions.bubble"
                    ) {
                        model.displayMode = model.displayMode == .both ? .translationOnly : .both
                    }
                    .help(model.displayMode == .both ? String(localized: "overlay.translationOnly") : String(localized: "overlay.showOriginal"))

                    OverlayControlButton(symbol: "minus", repeatWhilePressed: true) {
                        model.adjustFontSize(delta: -1)
                    }
                    .help(String(localized: "overlay.decreaseFont"))

                    OverlayControlButton(symbol: "plus", repeatWhilePressed: true) {
                        model.adjustFontSize(delta: 1)
                    }
                    .help(String(localized: "overlay.increaseFont"))

                    OverlayControlButton(symbol: "xmark") {
                        NSApp.terminate(nil)
                    }
                    .help(String(localized: "overlay.quit"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.7), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: showControls)
            .transaction { $0.animation = nil }

            // Error banner
            if let error = model.pipelineError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1), in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(width: model.overlayWidth, height: model.overlayHeight)
        .onHover { hovering in
            if hovering {
                showControls = true
                resetControlsTimer()
            }
        }
        .onAppear { resetControlsTimer() }
    }

    private func resetControlsTimer() {
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    /// Older lines fade out, newest line is fully visible.
    private func lineOpacity(index: Int, total: Int) -> Double {
        let fromEnd = total - 1 - index
        switch fromEnd {
        case 0: return 0.7   // most recent completed line
        case 1: return 0.4
        case 2: return 0.2
        default: return 0.1
        }
    }

    @ViewBuilder
    private func subtitleLineView(_ line: TranslatorModel.SubtitleLine, opacity: Double) -> some View {
        VStack(spacing: 1) {
            if model.displayMode == .both && !isSubtitleMode && !line.original.isEmpty {
                Text(line.original)
                    .font(.system(size: CGFloat(model.fontSize * 0.65), weight: .regular))
                    .foregroundStyle(.white.opacity(opacity * 0.6))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            Text(line.translated)
                .font(.system(size: CGFloat(model.fontSize * 0.9), weight: .medium))
                .foregroundStyle(.white.opacity(opacity))
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
        .frame(maxWidth: .infinity)
    }

    private var isSubtitleMode: Bool {
        model.sourceLanguageCode == model.targetLanguageCode
    }

    private var listeningIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text(String(localized: "overlay.listening"))
                .font(.system(size: CGFloat(model.fontSize * 0.75), weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var sourceLabel: String {
        languageOptions.first(where: { $0.code == model.sourceLanguageCode })?.name ?? model.sourceLanguageCode.uppercased()
    }

    private var targetLabel: String {
        languageOptions.first(where: { $0.code == model.targetLanguageCode })?.name ?? model.targetLanguageCode.uppercased()
    }
}

// MARK: - Language Picker

private struct OverlayLanguagePicker: View {
    @Binding var selectedCode: String
    let options: [(code: String, flag: String, name: String)]
    let label: String

    var body: some View {
        Menu {
            ForEach(options, id: \.code) { lang in
                Button {
                    selectedCode = lang.code
                } label: {
                    HStack {
                        Text("\(lang.flag) \(lang.name)")
                        if selectedCode == lang.code {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Control Button

private struct OverlayControlButton: View {
    let symbol: String
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if !repeatWhilePressed { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(
            OverlayCircleButtonStyle(
                isActive: isActive,
                repeatWhilePressed: repeatWhilePressed,
                repeatAction: action
            )
        )
    }
}

private struct OverlayCircleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    var repeatAction: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed || isActive ? 0.18 : 0.10))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .background {
                if repeatWhilePressed {
                    RepeatWhileHeldHelper(
                        isPressed: configuration.isPressed,
                        action: repeatAction ?? {}
                    )
                }
            }
    }
}

private struct RepeatWhileHeldHelper: View {
    let isPressed: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    action()
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        stopRepeating()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            while !Task.isCancelled {
                await MainActor.run { action() }
                try? await Task.sleep(nanoseconds: 85_000_000)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
