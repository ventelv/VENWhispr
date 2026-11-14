import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let dictation = DictationController()
    private lazy var hotkeys = HotkeyMonitor(hotkeys: settings.activeHotkeys)
    private var statusItem: NSStatusItem!
    private let model = AppModel()
    private var settingsWindow: SettingsWindowController?
    private var trustTimer: Timer?
    private let downloader = ModelDownloader()
    private var setupWindow: ModelSetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If the app crashed or was force-quit mid-dictation, bring the sound back.
        OutputMuter.restore()

        // Opened straight from the download, macOS runs the app from a hidden read-only copy where
        // its speech servers can't start. Ask for it to be moved to Applications first.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "Move VENWhispr to Applications"
            alert.informativeText = "VENWhispr can't run from the disk image or Downloads folder. Drag VENWhispr into your Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            alert.runModalInFront()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        dictation.onChange = { [weak self] in self?.updateIcon() }
        dictation.engine.server.onStatus = { [weak self] status in
            self?.model.engineStatus = status
            self?.updateIcon()
        }
        dictation.punctuation.server.onStatus = { [weak self] status in
            self?.model.punctuationStatus = status
        }
        model.onHotkeyChange = { [weak self] key in self?.hotkeyChanged(to: key) }
        model.onAIPunctuationChange = { [weak self] on in self?.aiPunctuationChanged(to: on) }
        dictation.preview.engine.server.onStatus = { [weak self] status in
            self?.model.previewStatus = status
        }
        model.onLivePreviewChange = { [weak self] on in self?.livePreviewChanged(to: on) }
        model.onRestartWhisper = { [weak self] in self?.dictation.engine.restart() }
        model.onKeepMicWarmChange = { [weak self] on in self?.dictation.mic.keepWarm = on ? 120 : 0 }
        // Models are downloaded on first launch; each engine starts once its model is there.
        downloader.onFinished = { [weak self] in
            self?.startEngines()
            self?.updateIcon()
        }
        startEngines()
        if !ModelDownloader.missing.isEmpty { showSetup() }

        hotkeys.onDown = { [weak self] key in self?.dictation.hotkeyDown(key) }
        hotkeys.onUp = { [weak self] key in self?.dictation.hotkeyUp(key) }
        AudioDevices.startObservingChanges()
        hotkeys.onOtherKey = { [weak self] code in self?.dictation.otherKeyPressed(code) }
        hotkeys.start()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !Paster.isTrusted {
            Paster.promptForAccessibility()
            waitForAccessibility()
        }
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        OutputMuter.restore()
        dictation.mic.shutdown()
        dictation.engine.stop()
        dictation.preview.engine.stop()
        dictation.punctuation.stop()
    }

    /// Starts whichever engines have their model and aren't running yet.
    private func startEngines() {
        if !dictation.engine.server.isRunning { dictation.engine.start() }
        if settings.aiPunctuation, !dictation.punctuation.server.isRunning { dictation.punctuation.start() }
        if settings.livePreview, !dictation.preview.engine.server.isRunning { dictation.preview.engine.start() }
    }

    @objc private func showSetup() {
        if setupWindow == nil { setupWindow = ModelSetupWindowController(downloader: downloader) }
        setupWindow?.show()
    }

    /// Global key monitors only start delivering events once trust is granted, so re-arm them then.
    private func waitForAccessibility() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard Paster.isTrusted else { return }
            timer.invalidate()
            self?.hotkeys.start()
            self?.model.refreshPermissions()
            self?.updateIcon()
        }
    }

    // MARK: Status icon

    private func updateIcon() {
        let symbol: String
        let state: String
        if dictation.isRecording {
            (symbol, state) = ("mic.fill", "recording")
        } else if dictation.pendingTranscriptions > 0 {
            (symbol, state) = ("waveform", "transcribing")
        } else if !ModelDownloader.missing.isEmpty {
            (symbol, state) = ("arrow.down.circle", downloader.isBusy ? "downloading models" : "needs models")
        } else if case .failed = model.engineStatus {
            (symbol, state) = ("mic.slash", "Whisper stopped")
        } else if !Paster.isTrusted || model.microphoneBlocked {
            (symbol, state) = ("mic.badge.xmark", "needs permission")
        } else {
            (symbol, state) = ("mic", "ready")
        }
        let label = "VENWhispr, \(state)"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: label)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        model.refreshPermissions()

        let header = headerState()
        let keys = settings.activeHotkeys.map { ($0.shortTitle, Language.named(settings.language(for: $0)).name) }
        menu.addItem(MenuHeaderView(status: header.status, tone: header.tone, detail: header.detail, keys: keys).menuItem())
        let modelsMissing = !ModelDownloader.missing.isEmpty
        if modelsMissing {
            menu.addItem(notice(downloader.isBusy ? "Show Download Progress…" : "Download Models…", #selector(showSetup)))
        } else if case .failed = model.engineStatus {
            menu.addItem(notice("Restart Whisper", #selector(restartEngine)))
        }
        if model.microphoneBlocked {
            menu.addItem(notice("Grant Microphone Access…", #selector(openMicrophoneSettings)))
        }
        if !Paster.isTrusted {
            menu.addItem(notice("Grant Accessibility…", #selector(openAccessibility)))
        }

        menu.addItem(.separator())
        let history = settings.history
        let pasteLast = item("Paste Last Dictation", #selector(pasteLastDictation))
        if let last = history.first {
            pasteLast.setSubtitle(truncated(last, 44))
        } else {
            pasteLast.action = nil
        }
        menu.addItem(pasteLast)
        menu.addItem(submenu("Recent", recentMenu(history)))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Input"))
        let mic = microphoneMenu()
        menu.addItem(submenu("Microphone", mic.menu, subtitle: mic.current))
        menu.addItem(submenu("Hotkeys & Languages", hotkeyMenu(),
                             subtitle: keys.map { "\($0.0) \($0.1)" }.joined(separator: " · ")))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Output"))
        menu.addItem(toggle("Smart Punctuation", model.aiPunctuation, #selector(toggleAIPunctuation),
                            subtitle: punctuationSubtitle()))
        menu.addItem(toggle("Live Preview", model.livePreview, #selector(toggleLivePreview),
                            subtitle: previewSubtitle()))
        menu.addItem(toggle("Remove Filler Words", model.removeFillers, #selector(toggleFillers), subtitle: "um, uh, ăă"))
        menu.addItem(toggle("Trailing Space", model.trailingSpace, #selector(toggleTrailingSpace),
                            subtitle: "Adds a space after each paste"))
        let words = item("Custom Words…", #selector(editCustomWords))
        if model.customWordCount > 0 { words.badge = NSMenuItemBadge(count: model.customWordCount) }
        menu.addItem(words)

        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit VENWhispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func headerState() -> (status: String, tone: StatusTone, detail: String?) {
        if !ModelDownloader.missing.isEmpty {
            if downloader.isBusy {
                let progress = "\(ModelDownloader.format(downloader.receivedBytes)) of \(ModelDownloader.format(downloader.totalBytes))"
                return ("Downloading models", .pending, progress)
            }
            return ("Needs models", .warn, "Download the speech models to start")
        }
        if case .failed(let message) = model.engineStatus { return ("Whisper stopped", .danger, message) }
        if model.microphoneBlocked { return ("Needs Microphone", .warn, "Allow microphone access to dictate") }
        if !Paster.isTrusted { return ("Needs Accessibility", .warn, "Text is copied, not pasted, until allowed") }
        switch model.engineStatus {
        case .stopped, .starting: return ("Loading model", .pending, "Warming up Whisper…")
        case .ready, .failed: break
        }
        if dictation.isRecording { return ("Listening", .ready, nil) }
        if dictation.pendingTranscriptions > 0 { return ("Transcribing", .pending, nil) }
        return ("Ready", .ready, nil)
    }

    private func punctuationSubtitle() -> String {
        let name = AppModel.punctuationModel().name
        guard model.aiPunctuation else { return "\(name) · on device" }
        switch model.punctuationStatus {
        case .stopped, .starting: return "Loading \(name)…"
        case .ready: return "\(name) · on device"
        case .failed: return "Unavailable · see Settings → Models"
        }
    }

    private func previewSubtitle() -> String {
        guard model.livePreview else { return "Shows your words as you speak" }
        switch model.previewStatus {
        case .stopped, .starting: return "Loading…"
        case .ready: return "Shows your words as you speak"
        case .failed: return "Unavailable · see Settings → Models"
        }
    }

    private func recentMenu(_ history: [String]) -> NSMenu {
        let menu = NSMenu()
        if history.isEmpty {
            menu.addItem(disabled("Nothing yet"))
            return menu
        }
        for (i, text) in history.prefix(10).enumerated() {
            let it = item(truncated(text, 60), #selector(copyHistory(_:)))
            it.tag = i
            it.toolTip = "Click to copy:\n\(text)"
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Clear History", #selector(clearHistory)))
        return menu
    }

    private func microphoneMenu() -> (menu: NSMenu, current: String) {
        let menu = NSMenu()
        let devices = AudioDevices.inputs()
        let selectedUID = settings.microphoneUID
        let selected = devices.first { $0.uid == selectedUID }
        let selectedMissing = selectedUID != nil && selected == nil
        let automaticName = AudioDevices.automaticInput()?.name
        let defaultItem = item(automaticName.map { "Automatic (\($0))" } ?? "Automatic", #selector(selectMicrophone(_:)))
        defaultItem.setSubtitle("System default, skipping Bluetooth headsets")
        defaultItem.state = selected == nil ? .on : .off
        menu.addItem(defaultItem)
        if selectedMissing {
            menu.addItem(disabled("Your chosen mic is disconnected — using default"))
        }
        for group in [devices.filter { !$0.isVirtual }, devices.filter(\.isVirtual)] where !group.isEmpty {
            menu.addItem(.separator())
            for device in group {
                let it = item(device.name, #selector(selectMicrophone(_:)))
                it.representedObject = device.uid
                it.state = device.uid == selectedUID ? .on : .off
                menu.addItem(it)
            }
        }
        let current: String
        if let selected {
            current = selected.name
        } else if selectedMissing {
            current = "Disconnected · using \(automaticName ?? "default")"
        } else {
            current = automaticName ?? "Automatic"
        }
        return (menu, current)
    }

    /// Two slots, each a key and the language it dictates in.
    private func hotkeyMenu() -> NSMenu {
        let menu = NSMenu()
        for slot in 0...1 {
            let key = slot == 0 ? model.hotkey : model.secondHotkey
            let language = slot == 0 ? model.language : model.secondLanguage
            if slot == 1 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: slot == 0 ? "First Key" : "Second Key"))
            if slot == 1 {
                let off = item("Off", #selector(selectHotkey(_:)))
                off.tag = 1
                off.state = key == nil ? .on : .off
                menu.addItem(off)
            }
            for option in Hotkey.allCases where slot == 0 || option != model.hotkey {
                let it = item(option.title, #selector(selectHotkey(_:)))
                it.representedObject = option.rawValue
                it.tag = slot
                it.state = option == key ? .on : .off
                menu.addItem(it)
            }
            if key != nil {
                let languages = NSMenu()
                for lang in Language.all {
                    let it = item(lang.name, #selector(selectLanguage(_:)))
                    it.representedObject = lang.code
                    it.tag = slot
                    it.state = lang.code == language ? .on : .off
                    languages.addItem(it)
                }
                menu.addItem(submenu("Language", languages, subtitle: Language.named(language).name))
            }
        }
        return menu
    }

    private func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector, subtitle: String? = nil) -> NSMenuItem {
        let it = item(title, action)
        it.state = on ? .on : .off
        it.setSubtitle(subtitle)
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu, subtitle: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        it.setSubtitle(subtitle)
        return it
    }

    /// An actionable problem row with an orange warning glyph.
    private func notice(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = item(title, action)
        it.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        return it
    }

    // MARK: Actions

    @objc private func restartEngine() { dictation.engine.restart() }
    @objc private func openAccessibility() { Paster.openAccessibilitySettings() }
    @objc private func openMicrophoneSettings() { AppModel.openMicrophoneSettings() }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.show()
    }

    /// The menu is closing when this runs, so wait for focus to settle back on the previous app.
    @objc private func pasteLastDictation() {
        guard let last = settings.history.first else { return }
        let text = settings.trailingSpace ? last + " " : last
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Paster.isTrusted { Paster.paste(text) } else { Paster.copy(text) }
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let history = settings.history
        guard history.indices.contains(sender.tag) else { return }
        Paster.copy(history[sender.tag])
    }

    @objc private func clearHistory() { settings.history = [] }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        let key = (sender.representedObject as? String).flatMap(Hotkey.init(rawValue:))
        if sender.tag == 0 {
            if let key { model.hotkey = key }
        } else {
            model.secondHotkey = key
        }
    }

    private func hotkeyChanged(to key: Hotkey?) {
        hotkeys.hotkeys = settings.activeHotkeys
        if key == .fn {
            let alert = NSAlert()
            alert.messageText = "Using the Fn / Globe key"
            alert.informativeText = "So macOS doesn't also open the emoji picker or its own dictation, set System Settings → Keyboard → \"Press 🌐 key to\" to \"Do Nothing\"."
            alert.runModalInFront()
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        model.microphoneUID = sender.representedObject as? String ?? ""
    }

    @objc private func toggleAIPunctuation() { model.aiPunctuation.toggle() }
    @objc private func toggleLivePreview() { model.livePreview.toggle() }

    private func livePreviewChanged(to on: Bool) {
        if on {
            dictation.preview.engine.start()
        } else {
            dictation.preview.engine.stop()
        }
    }

    private func aiPunctuationChanged(to on: Bool) {
        if on {
            dictation.punctuation.start()
        } else {
            dictation.punctuation.stop()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        if sender.tag == 0 { model.language = code } else { model.secondLanguage = code }
    }

    @objc private func editCustomWords() {
        let alert = NSAlert()
        alert.messageText = "Custom Words"
        alert.informativeText = "Names, brands and jargon Whisper should spell correctly, separated by commas."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        field.stringValue = model.customWords
        field.placeholderString = "VENWhispr, Kubernetes, Thabo, Supabase"
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModalInFront() == .alertFirstButtonReturn {
            model.customWords = field.stringValue
        }
    }

    @objc private func toggleFillers() { model.removeFillers.toggle() }
    @objc private func toggleTrailingSpace() { model.trailingSpace.toggle() }
}

private extension NSAlert {
    /// Menu-bar apps aren't active, so bring the alert forward explicitly.
    @discardableResult
    func runModalInFront() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}

private extension NSMenuItem {
    /// `NSMenuItem.subtitle` exists from macOS 14.4 but isn't in the 14.4 Command Line Tools SDK,
    /// so set it dynamically; on older systems fall back to a second line in the title.
    func setSubtitle(_ subtitle: String?) {
        guard let subtitle else { return }
        if responds(to: NSSelectorFromString("setSubtitle:")) {
            setValue(subtitle, forKey: "subtitle")
            return
        }
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        attributedTitle = text
    }
}
