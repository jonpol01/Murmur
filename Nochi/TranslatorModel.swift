import AppKit
import Foundation
import Combine
import CoreGraphics

@MainActor
final class TranslatorModel: ObservableObject {
    enum SpeechEngine: String, CaseIterable {
        case appleSpeech
        case whisperKit

        var label: String {
            switch self {
            case .appleSpeech: return "Apple Speech"
            case .whisperKit: return "WhisperKit"
            }
        }
    }

    enum DisplayMode: String, CaseIterable {
        case translationOnly
        case both

        var label: String {
            switch self {
            case .translationOnly: return "Translation Only"
            case .both: return "Original + Translation"
            }
        }
    }

    enum WhisperModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    static let shared = TranslatorModel()

    // Pipeline state
    @Published var isListening: Bool = false
    @Published var isPipelineReady: Bool = false
    @Published var pipelineError: String?

    // Transcript display
    @Published var originalText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false

    // Scrolling subtitle lines
    struct SubtitleLine: Identifiable {
        let id = UUID()
        let original: String
        let translated: String
    }
    @Published var subtitleLines: [SubtitleLine] = []
    private let maxVisibleLines = 2

    // Settings (persisted)
    @Published var sourceLanguageCode: String = "ja"
    @Published var targetLanguageCode: String = "en"
    @Published var speechEngine: SpeechEngine = .appleSpeech
    @Published var displayMode: DisplayMode = .both
    @Published var fontSize: Double = 18
    @Published var overlayWidth: Double = 700
    @Published var overlayHeight: Double = 160
    @Published var isOverlayVisible: Bool = true
    @Published var selectedScreenID: CGDirectDisplayID = 0
    @Published var autoCommitWordCount: Int = 0    // 0 = disabled
    @Published var maxDisplayChars: Int = 80

    // WhisperKit
    @Published var whisperModelState: WhisperModelState = .notDownloaded

    // Managers (created on demand)
    var audioCaptureManager: AudioCaptureManager?
    var speechRecognizer: (any SpeechRecognizerProtocol)?
    var translationService: TranslationService?

    private var translationTask: Task<Void, Never>?

    private enum DefaultsKey {
        static let hasSavedSession = "hasSavedSession"
        static let sourceLanguageCode = "sourceLanguageCode"
        static let targetLanguageCode = "targetLanguageCode"
        static let speechEngine = "speechEngine"
        static let displayMode = "displayMode"
        static let fontSize = "fontSize"
        static let overlayWidth = "overlayWidth"
        static let overlayHeight = "overlayHeight"
        static let isOverlayVisible = "isOverlayVisible"
        static let selectedScreenID = "selectedScreenID"
        static let autoCommitWordCount = "autoCommitWordCount"
        static let maxDisplayChars = "maxDisplayChars"
    }

    private init() {}

    // MARK: - Pipeline Control

    func startListening() {
        guard !isListening else { return }
        pipelineError = nil
        originalText = ""
        translatedText = ""
        subtitleLines.removeAll()
        pendingPartialText = nil
        pendingCommits.removeAll()
        translating = false
        committedSentenceCount = 0
        pauseCommitTask?.cancel()

        DebugLog.log("Model", "Starting pipeline: source=\(sourceLanguageCode) target=\(targetLanguageCode) engine=\(speechEngine.rawValue)")

        Task {
            do {
                // 1. Reuse audio capture (avoids TCC prompt on every start)
                let capture = self.audioCaptureManager ?? AudioCaptureManager()
                self.audioCaptureManager = capture

                // 2. Set up speech recognizer
                let recognizer: any SpeechRecognizerProtocol
                switch speechEngine {
                case .appleSpeech:
                    let localeID: String
                    if sourceLanguageCode == "auto" {
                        localeID = Locale.current.identifier
                    } else {
                        localeID = sourceLanguageCode
                    }
                    NSLog("[Model] Creating AppleSpeechRecognizer with locale: %@", localeID)
                    recognizer = AppleSpeechRecognizer(locale: Locale(identifier: localeID))
                case .whisperKit:
                    recognizer = WhisperRecognizer()
                }
                recognizer.onTranscript = { [weak self] text, isFinal in
                    Task { @MainActor in
                        self?.handleTranscript(text, isFinal: isFinal)
                    }
                }
                self.speechRecognizer = recognizer

                // 3. Set up translation
                let translation = TranslationService()
                self.translationService = translation

                // 4. Wire audio -> speech
                capture.onAudioBuffer = { [weak recognizer] buffer in
                    recognizer?.feedAudio(buffer)
                }
                capture.onError = { [weak self] error in
                    NSLog("[Model] Audio capture error: %@", error.localizedDescription)
                    Task { @MainActor in
                        self?.pipelineError = error.localizedDescription
                        self?.stopListening()
                    }
                }

                // 5. Start everything
                try recognizer.start()
                try await capture.startCapture()
                isListening = true
                isPipelineReady = true
                NSLog("[Model] Pipeline started successfully")
            } catch {
                NSLog("[Model] Pipeline failed to start: %@", error.localizedDescription)
                pipelineError = error.localizedDescription
                stopListening()
            }
        }
    }

    func stopListening() {
        NSLog("[Model] Stopping pipeline")
        audioCaptureManager?.stopCapture()
        // Don't nil — reuse on next start to avoid TCC prompt
        speechRecognizer?.stop()
        speechRecognizer = nil
        translationTask?.cancel()
        translationTask = nil
        translationService?.teardown()
        translationService = nil
        isListening = false
        isPipelineReady = false
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    // MARK: - Transcript Handling

    /// Generation counter for partial translations — stale partials are discarded.
    private var translationGeneration = 0
    /// True while ANY XPC translate call is in-flight (commit or partial).
    private var translating = false
    /// Latest partial text queued while a translation was in-flight.
    private var pendingPartialText: String?
    /// Timer that commits current text when the speaker pauses (~1.5s).
    private var pauseCommitTask: Task<Void, Never>?
    /// Completed sentences queued for translation.
    private var pendingCommits: [String] = []
    /// Number of complete sentences already committed from the current
    /// recognition session. Tracked by count (not content) so recognizer
    /// text revisions don't cause duplicates.
    private var committedSentenceCount = 0

    private static let sentenceEndChars = Set<Character>(["。", "！", "？", ".", "!", "?"])

    private func handleTranscript(_ text: String, isFinal: Bool) {
        pauseCommitTask?.cancel()

        if isFinal {
            pendingPartialText = nil
            originalText = ""
            translatedText = ""

            // Only commit sentences not already shown (fuzzy prefix match
            // catches revisions where the recognizer tweaked the ending)
            let parts = splitSentences(text)
            for part in parts {
                if !isDuplicate(part) {
                    pendingCommits.append(part)
                }
            }
            committedSentenceCount = 0
            drainQueue()
            return
        }

        // Split into sentences — commit completed ones, show only the tail
        let parts = splitSentences(text)
        let lastChar = text.last
        let hasTrailing = lastChar != nil && !Self.sentenceEndChars.contains(lastChar!)
        let completedCount = hasTrailing ? parts.count - 1 : parts.count

        if completedCount > committedSentenceCount {
            for i in committedSentenceCount..<completedCount {
                if !isDuplicate(parts[i]) {
                    pendingCommits.append(parts[i])
                }
            }
            committedSentenceCount = completedCount
        } else if completedCount < committedSentenceCount {
            // Recognizer revised away a sentence-ender — undo pending commits
            let excess = committedSentenceCount - completedCount
            pendingCommits = Array(pendingCommits.dropLast(min(excess, pendingCommits.count)))
            committedSentenceCount = completedCount
        }

        // Display only the trailing fragment (capped to maxDisplayChars)
        var tail = hasTrailing ? (parts.last ?? "") : ""
        if tail.count > maxDisplayChars {
            tail = String(tail.suffix(maxDisplayChars))
        }

        // Auto-commit by word count: if enabled and tail exceeds threshold, commit immediately
        let fullTail = hasTrailing ? (parts.last ?? "") : ""
        let wordCount = fullTail.split(separator: " ").count
        if autoCommitWordCount > 0 && wordCount >= autoCommitWordCount {
            let toCommit = fullTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !toCommit.isEmpty && !isDuplicate(toCommit) {
                pendingCommits.append(toCommit)
                committedSentenceCount += 1
            }
            originalText = ""
            translatedText = ""
            pendingPartialText = nil
            drainQueue()
            return
        }

        originalText = tail
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingPartialText = tail
        } else {
            pendingPartialText = nil
            translatedText = ""
        }
        drainQueue()

        // Pause detection: if no new partial arrives within 1.5s, the
        // speaker has paused — commit current text even without punctuation.
        let currentTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTail.isEmpty {
            pauseCommitTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                let toCommit = self.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !toCommit.isEmpty, !self.isDuplicate(toCommit) else { return }
                self.pendingCommits.append(toCommit)
                self.committedSentenceCount += 1
                self.originalText = ""
                self.translatedText = ""
                self.pendingPartialText = nil
                self.drainQueue()
            }
        }
    }

    /// Fuzzy duplicate check — catches revisions where the recognizer
    /// tweaked the ending of an already-committed sentence.
    private func isDuplicate(_ text: String) -> Bool {
        let prefix = String(text.prefix(min(15, text.count)))
        guard !prefix.isEmpty else { return false }
        return subtitleLines.contains { $0.original.hasPrefix(prefix) }
            || pendingCommits.contains { $0.hasPrefix(prefix) }
    }

    /// Split text into individual sentences at sentence-ending punctuation.
    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if Self.sentenceEndChars.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }

    /// Process one item at a time: live partials first (keeps display
    /// responsive), then queued commits. Only ONE XPC call at a time.
    private func drainQueue() {
        guard !translating else { return }

        // Live partials first — user sees these updating in real-time
        if let partial = pendingPartialText {
            pendingPartialText = nil
            translating = true
            translationGeneration += 1
            let gen = translationGeneration
            Task {
                let translated = await self.getTranslation(partial)
                self.translating = false
                if gen == self.translationGeneration {
                    self.translatedText = translated
                }
                self.drainQueue()
            }
            return
        }

        // Then queued commits — completed sentences for subtitle lines
        if let commit = pendingCommits.first {
            pendingCommits.removeFirst()
            translating = true
            Task {
                let translated = await getTranslation(commit)
                subtitleLines.append(SubtitleLine(original: commit, translated: translated))
                if subtitleLines.count > maxVisibleLines {
                    subtitleLines.removeFirst(subtitleLines.count - maxVisibleLines)
                }
                translating = false
                drainQueue()
            }
        }
    }

    private func lastSentenceEndIndex(in text: String) -> String.Index? {
        var last: String.Index?
        for idx in text.indices where Self.sentenceEndChars.contains(text[idx]) {
            last = idx
        }
        return last
    }

    /// Get translation or pass-through for same-language mode.
    private func getTranslation(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if sourceLanguageCode == targetLanguageCode { return text }

        guard #available(macOS 26.0, *) else { return text }

        do {
            if translationService == nil { translationService = TranslationService() }
            let sourceLocale: Locale.Language? = sourceLanguageCode == "auto" ? nil : Locale.Language(identifier: sourceLanguageCode)
            let targetLocale = Locale.Language(identifier: targetLanguageCode)
            return try await translationService!.translate(text, from: sourceLocale, to: targetLocale)
        } catch {
            NSLog("[Model] Translation error: %@", error.localizedDescription)
            return text
        }
    }

    // MARK: - Font Size

    func adjustFontSize(delta: Double) {
        fontSize = max(12, min(40, fontSize + delta))
    }

    // MARK: - Display Selection

    struct ScreenInfo: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isCurrent: Bool
    }

    var availableScreens: [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return ScreenInfo(id: id, name: screen.localizedName, isCurrent: id == selectedScreenID)
        }
    }

    func selectScreen(_ id: CGDirectDisplayID) {
        selectedScreenID = id
        saveToDefaults()
    }

    // MARK: - Persistence

    func loadFromDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasSavedSession) else { return }

        sourceLanguageCode = defaults.string(forKey: DefaultsKey.sourceLanguageCode) ?? sourceLanguageCode
        targetLanguageCode = defaults.string(forKey: DefaultsKey.targetLanguageCode) ?? targetLanguageCode
        if let raw = defaults.string(forKey: DefaultsKey.speechEngine),
           let engine = SpeechEngine(rawValue: raw) {
            speechEngine = engine
        }
        if let raw = defaults.string(forKey: DefaultsKey.displayMode),
           let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
        }
        fontSize = clamp(defaults.object(forKey: DefaultsKey.fontSize) as? Double ?? fontSize, lower: 12, upper: 40)
        overlayWidth = clamp(defaults.object(forKey: DefaultsKey.overlayWidth) as? Double ?? overlayWidth, lower: 400, upper: 1200)
        overlayHeight = clamp(defaults.object(forKey: DefaultsKey.overlayHeight) as? Double ?? overlayHeight, lower: 120, upper: 300)
        isOverlayVisible = defaults.object(forKey: DefaultsKey.isOverlayVisible) as? Bool ?? true
        selectedScreenID = CGDirectDisplayID(defaults.object(forKey: DefaultsKey.selectedScreenID) as? UInt32 ?? 0)
        autoCommitWordCount = max(0, min(30, defaults.object(forKey: DefaultsKey.autoCommitWordCount) as? Int ?? 0))
        maxDisplayChars = max(40, min(200, defaults.object(forKey: DefaultsKey.maxDisplayChars) as? Int ?? 80))
        isListening = false
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.hasSavedSession)
        defaults.set(sourceLanguageCode, forKey: DefaultsKey.sourceLanguageCode)
        defaults.set(targetLanguageCode, forKey: DefaultsKey.targetLanguageCode)
        defaults.set(speechEngine.rawValue, forKey: DefaultsKey.speechEngine)
        defaults.set(displayMode.rawValue, forKey: DefaultsKey.displayMode)
        defaults.set(fontSize, forKey: DefaultsKey.fontSize)
        defaults.set(overlayWidth, forKey: DefaultsKey.overlayWidth)
        defaults.set(overlayHeight, forKey: DefaultsKey.overlayHeight)
        defaults.set(isOverlayVisible, forKey: DefaultsKey.isOverlayVisible)
        defaults.set(selectedScreenID, forKey: DefaultsKey.selectedScreenID)
        defaults.set(autoCommitWordCount, forKey: DefaultsKey.autoCommitWordCount)
        defaults.set(maxDisplayChars, forKey: DefaultsKey.maxDisplayChars)
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
