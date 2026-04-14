import AppKit
import Combine
import Speech
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

    private let model = TranslatorModel.shared

    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    private var toggleListeningItem: NSMenuItem?
    private var showOverlayItem: NSMenuItem?
    private var displayModeItem: NSMenuItem?
    private var shortcutWarningItem: NSMenuItem?
    private var shortcutWarningSeparator: NSMenuItem?
    private lazy var hotkeyManager = GlobalHotkeyManager { [weak self] command in
        self?.performShortcut(command)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("App", "Launch. source=\(model.sourceLanguageCode) target=\(model.targetLanguageCode)")
        model.loadFromDefaults()
        overlayController = OverlayWindowController(model: model)
        overlayController?.setVisible(model.isOverlayVisible)

        // Only prompt for Speech if never asked before; Screen Recording
        // is requested lazily when the user starts listening (avoids a
        // system prompt on every launch on macOS 15+).
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }

        setupEditMenu()
        wireModel()
        hotkeyManager.registerAll()
        setupStatusBar()
        installEditKeyHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopListening()
        model.saveToDefaults()
        hotkeyManager.unregisterAll()
        cancellables.removeAll()
    }

    private func wireModel() {
        model.$isOverlayVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                self?.overlayController?.setVisible(isVisible)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$overlayWidth, model.$overlayHeight)
            .removeDuplicates { lhs, rhs in
                Int(lhs.0) == Int(rhs.0) && Int(lhs.1) == Int(rhs.1)
            }
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        model.$selectedScreenID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        // Auto-save on settings changes
        Publishers.MergeMany(
            model.$sourceLanguageCode.map { _ in () }.eraseToAnyPublisher(),
            model.$targetLanguageCode.map { _ in () }.eraseToAnyPublisher(),
            model.$speechEngine.map { _ in () }.eraseToAnyPublisher(),
            model.$displayMode.map { _ in () }.eraseToAnyPublisher(),
            model.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayWidth.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayHeight.map { _ in () }.eraseToAnyPublisher(),
            model.$isOverlayVisible.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedScreenID.map { _ in () }.eraseToAnyPublisher(),
            model.$autoCommitWordCount.map { _ in () }.eraseToAnyPublisher(),
            model.$maxDisplayChars.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.model.saveToDefaults()
        }
        .store(in: &cancellables)
    }

    private func setupEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        if let mainMenu = NSApp.mainMenu {
            mainMenu.addItem(editMenuItem)
        } else {
            let mainMenu = NSMenu()
            mainMenu.addItem(editMenuItem)
            NSApp.mainMenu = mainMenu
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            item.button?.image = icon
        }
        item.button?.toolTip = "Nochi"

        let menu = NSMenu()

        let toggleListening = NSMenuItem(
            title: String(localized: "menu.startListening"),
            action: #selector(toggleListeningAction),
            keyEquivalent: ShortcutCommand.toggleListening.keyEquivalent
        )
        toggleListening.target = self
        toggleListening.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(toggleListening)
        toggleListeningItem = toggleListening

        let showOverlay = NSMenuItem(
            title: String(localized: "menu.showOverlay"),
            action: #selector(toggleOverlayVisibility),
            keyEquivalent: ShortcutCommand.toggleOverlay.keyEquivalent
        )
        showOverlay.target = self
        showOverlay.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(showOverlay)
        showOverlayItem = showOverlay

        let displayMode = NSMenuItem(
            title: String(localized: "menu.displayMode"),
            action: #selector(toggleDisplayMode),
            keyEquivalent: ShortcutCommand.toggleDisplayMode.keyEquivalent
        )
        displayMode.target = self
        displayMode.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(displayMode)
        displayModeItem = displayMode

        let fontUp = NSMenuItem(
            title: String(localized: "menu.increaseFontSize"),
            action: #selector(increaseFontSize),
            keyEquivalent: ShortcutCommand.fontUp.keyEquivalent
        )
        fontUp.target = self
        fontUp.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(fontUp)

        let fontDown = NSMenuItem(
            title: String(localized: "menu.decreaseFontSize"),
            action: #selector(decreaseFontSize),
            keyEquivalent: ShortcutCommand.fontDown.keyEquivalent
        )
        fontDown.target = self
        fontDown.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(fontDown)

        refreshShortcutWarningItems(in: menu)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: String(localized: "menu.settings"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func installEditKeyHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command ||
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else {
                return event
            }
            let key = event.charactersIgnoringModifiers ?? ""
            let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z" where event.modifierFlags.contains(.shift): NSSelectorFromString("redo:")
            case "z": NSSelectorFromString("undo:")
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    // MARK: - Actions

    @objc private func toggleListeningAction() {
        model.toggleListening()
    }

    @objc private func toggleOverlayVisibility() {
        model.isOverlayVisible.toggle()
    }

    @objc private func toggleDisplayMode() {
        model.displayMode = model.displayMode == .both ? .translationOnly : .both
    }

    @objc private func increaseFontSize() {
        model.adjustFontSize(delta: 2)
    }

    @objc private func decreaseFontSize() {
        model.adjustFontSize(delta: -2)
    }

    @objc private func openSettings() {
        Task { @MainActor in
            if settingsWindowController == nil {
                settingsWindowController = SettingsWindowController()
            }
            settingsWindowController?.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func performShortcut(_ command: ShortcutCommand) {
        switch command {
        case .toggleListening:
            model.toggleListening()
        case .toggleOverlay:
            model.isOverlayVisible.toggle()
        case .toggleDisplayMode:
            model.displayMode = model.displayMode == .both ? .translationOnly : .both
        case .fontUp:
            model.adjustFontSize(delta: 2)
        case .fontDown:
            model.adjustFontSize(delta: -2)
        }
    }

    private func refreshShortcutWarningItems(in menu: NSMenu) {
        if let shortcutWarningItem {
            menu.removeItem(shortcutWarningItem)
            self.shortcutWarningItem = nil
        }
        if let shortcutWarningSeparator {
            menu.removeItem(shortcutWarningSeparator)
            self.shortcutWarningSeparator = nil
        }

        let unavailable = hotkeyManager.failedRegistrations
        guard !unavailable.isEmpty else { return }

        let detail = unavailable.map(\.displayShortcut).joined(separator: ", ")
        let warning = NSMenuItem(
            title: "Shortcuts unavailable: \(detail)",
            action: nil,
            keyEquivalent: ""
        )
        warning.isEnabled = false
        menu.insertItem(warning, at: 0)
        shortcutWarningItem = warning

        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: 1)
        shortcutWarningSeparator = separator
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === toggleListeningItem {
            menuItem.title = model.isListening ? String(localized: "menu.stopListening") : String(localized: "menu.startListening")
            return true
        }
        if menuItem === showOverlayItem {
            menuItem.state = model.isOverlayVisible ? .on : .off
            return true
        }
        if menuItem === displayModeItem {
            menuItem.title = model.displayMode == .both ? String(localized: "display.translationOnly") : String(localized: "display.both")
            return true
        }
        return true
    }
}
