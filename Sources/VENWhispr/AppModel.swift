import AppKit
import AVFoundation
import ServiceManagement

/// Observable front for `Settings` plus live app status, shared by the menu and the Settings window
/// so a change in one shows up in the other.
final class AppModel: ObservableObject {
    private let settings = Settings.shared

    @Published var engineStatus: LocalServer.Status = .starting
    @Published var punctuationStatus: LocalServer.Status = .stopped
    @Published var previewStatus: LocalServer.Status = .stopped
    @Published private(set) var accessibilityGranted = Paster.isTrusted
    @Published private(set) var microphoneAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Called with the newly chosen key whenever either dictation key changes.
    var onHotkeyChange: (Hotkey?) -> Void = { _ in }
    var onAIPunctuationChange: (Bool) -> Void = { _ in }
    var onRestartWhisper: () -> Void = {}
    var onKeepMicWarmChange: (Bool) -> Void = { _ in }
    var onLivePreviewChange: (Bool) -> Void = { _ in }

    var hotkey: Hotkey {
        get { settings.hotkey }
        set {
            guard newValue != settings.hotkey else { return }
            objectWillChange.send()
            // Picking the second key as the first swaps the two (languages stay with their slot).
            if newValue == settings.secondHotkey { settings.secondHotkey = settings.hotkey }
            settings.hotkey = newValue
            onHotkeyChange(newValue)
        }
    }
    /// Language of the first key.
    var language: String {
        get { settings.language }
        set { objectWillChange.send(); settings.language = newValue }
    }
    /// Optional second dictation key; nil = off.
    var secondHotkey: Hotkey? {
        get { settings.secondHotkey }
        set {
            guard newValue != settings.secondHotkey, newValue == nil || newValue != settings.hotkey else { return }
            objectWillChange.send()
            settings.secondHotkey = newValue
            onHotkeyChange(newValue)
        }
    }
    var secondLanguage: String {
        get { settings.secondLanguage }
        set { objectWillChange.send(); settings.secondLanguage = newValue }
    }
    /// Core Audio UID of the chosen mic; "" means the system default.
    var microphoneUID: String {
        get { settings.microphoneUID ?? "" }
        set { objectWillChange.send(); settings.microphoneUID = newValue.isEmpty ? nil : newValue }
    }
    var aiPunctuation: Bool {
        get { settings.aiPunctuation }
        set {
            guard newValue != settings.aiPunctuation else { return }
            objectWillChange.send()
            settings.aiPunctuation = newValue
            onAIPunctuationChange(newValue)
        }
    }
    var removeFillers: Bool {
        get { settings.removeFillers }
        set { objectWillChange.send(); settings.removeFillers = newValue }
    }
    var trailingSpace: Bool {
        get { settings.trailingSpace }
        set { objectWillChange.send(); settings.trailingSpace = newValue }
    }
    var sounds: Bool {
        get { settings.sounds }
        set { objectWillChange.send(); settings.sounds = newValue }
    }
    var livePreview: Bool {
        get { settings.livePreview }
        set {
            guard newValue != settings.livePreview else { return }
            objectWillChange.send()
            settings.livePreview = newValue
            onLivePreviewChange(newValue)
        }
    }
    var keepMicWarm: Bool {
        get { settings.keepMicWarm }
        set { objectWillChange.send(); settings.keepMicWarm = newValue; onKeepMicWarmChange(newValue) }
    }
    var muteWhileRecording: Bool {
        get { settings.muteWhileRecording }
        set { objectWillChange.send(); settings.muteWhileRecording = newValue }
    }
    var customWords: String {
        get { settings.customWords }
        set { objectWillChange.send(); settings.customWords = newValue }
    }
    var customWordCount: Int {
        customWords.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var microphoneAllowed: Bool { microphoneAuth == .authorized }
    var microphoneBlocked: Bool { microphoneAuth == .denied || microphoneAuth == .restricted }

    func refreshPermissions() {
        let trusted = Paster.isTrusted
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let login = SMAppService.mainApp.status == .enabled
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
        if mic != microphoneAuth { microphoneAuth = mic }
        if login != launchAtLogin { launchAtLogin = login }
    }

    func setLaunchAtLogin(_ on: Bool) throws {
        defer { refreshPermissions() }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: Model files

    struct ModelInfo {
        let name: String
        let size: String?
    }

    static func whisperModel() -> ModelInfo {
        guard let url = WhisperEngine.findModel() else { return ModelInfo(name: "Whisper", size: nil) }
        let name = url.lastPathComponent == "ggml-large-v3-turbo.bin"
            ? "Whisper large-v3-turbo"
            : "Whisper " + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        return ModelInfo(name: name, size: fileSize(url))
    }

    static func previewModel() -> ModelInfo {
        ModelInfo(name: "Whisper base", size: WhisperEngine.findPreviewModel().flatMap(fileSize))
    }

    static func punctuationModel() -> ModelInfo {
        guard let url = PunctuationEngine.findModel() else { return ModelInfo(name: "Gemma 3 4B", size: nil) }
        let name = url.lastPathComponent == "gemma-3-4b-it-Q4_K_M.gguf" ? "Gemma 3 4B" : url.deletingPathExtension().lastPathComponent
        return ModelInfo(name: name, size: fileSize(url))
    }

    private static func fileSize(_ url: URL) -> String? {
        guard let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
