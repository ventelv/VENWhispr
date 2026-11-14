import AppKit
import AVFoundation

/// The hold-to-talk / double-tap-to-lock state machine:
/// - Each dictation key has its own language (e.g. Right ⌥ English, Right ⌘ Romanian).
/// - Hold a key ≥ 0.3 s → records while held, transcribes on release.
/// - Tap twice quickly → recording locks on; tap once more to finish.
/// - Esc cancels. Typing another key while holding (an ⌥-chord) cancels silently.
final class DictationController {
    enum Phase {
        case idle
        case holding(since: Date)
        case awaitingSecondTap
        case locked
    }

    private(set) var phase: Phase = .idle {
        didSet { onChange?() }
    }
    private(set) var pendingTranscriptions = 0 {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    var isRecording: Bool {
        if case .idle = phase { return false }
        return true
    }

    let engine = WhisperEngine()
    let punctuation = PunctuationEngine()
    let overlay = OverlayController()
    private let settings = Settings.shared
    /// One long-lived mic, so it can stay warm between dictations.
    let mic = AudioRecorder()
    private var capturing = false
    private(set) lazy var preview = LivePreview(audio: mic, overlay: overlay.model)
    private var ignoreNextRelease = false
    private var tapTimer: Timer?
    private var muteTimer: Timer?
    /// The key that started the current recording, and the language it dictates in.
    private var activeKey: Hotkey?
    private var activeLanguage = Language.named("en")
    private var micName = ""
    /// True once the mic actually delivers sound (see `AudioRecorder.onFirstAudio`).
    private var micLive = false

    private let holdThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.35
    private let escKeyCode: UInt16 = 53

    init() {
        connectMic()
        mic.keepWarm = settings.keepMicWarm ? 120 : 0
    }

    // MARK: Hotkey events

    func hotkeyDown(_ key: Hotkey) {
        // While recording, only the key that started it controls it.
        if isRecording, key != activeKey { return }
        switch phase {
        case .idle:
            guard startRecording(key) else { return }
            phase = .holding(since: Date())
            // Only mute once this is clearly a hold (≥ holdThreshold): quick taps and ⌥-key
            // combos are cancelled before then, so they never blip your music.
            scheduleMute(after: holdThreshold + 0.05)
        case .awaitingSecondTap:
            tapTimer?.invalidate()
            ignoreNextRelease = true
            phase = .locked
            if micLive { overlay.show(.locked) }
            playSound("Morse")
            scheduleMute(after: 0.3)
        case .locked:
            ignoreNextRelease = true
            finishRecording()
        case .holding:
            break
        }
    }

    func hotkeyUp(_ key: Hotkey) {
        guard key == activeKey else { return }
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard case .holding(let since) = phase else { return }
        if Date().timeIntervalSince(since) >= holdThreshold {
            finishRecording()
        } else {
            // Short tap: keep recording briefly in case a second tap locks it on.
            phase = .awaitingSecondTap
            tapTimer?.invalidate()
            tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                guard let self, case .awaitingSecondTap = self.phase else { return }
                self.cancelRecording(message: nil)
            }
        }
    }

    func otherKeyPressed(_ keyCode: UInt16) {
        switch phase {
        case .idle:
            return
        case .locked, .awaitingSecondTap:
            if keyCode == escKeyCode { cancelRecording(message: "Cancelled") }
        case .holding:
            cancelRecording(message: keyCode == escKeyCode ? "Cancelled" : nil)
        }
    }

    // MARK: Recording

    private func startRecording(_ key: Hotkey) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            overlay.flash("Microphone access needed")
            return false
        }
        // An explicitly chosen mic wins; otherwise "Automatic" skips Bluetooth headsets.
        let chosen = settings.microphoneUID.flatMap { uid in AudioDevices.inputs().first { $0.uid == uid } }
        let device = chosen ?? AudioDevices.automaticInput()

        micLive = false
        do {
            try mic.start(deviceUID: device?.uid)
        } catch {
            overlay.flash(error.localizedDescription)
            return false
        }
        capturing = true
        ignoreNextRelease = false
        activeKey = key
        activeLanguage = Language.named(settings.language(for: key))
        micName = device?.name ?? "default"
        overlay.model.languageTag = activeLanguage.code == "auto" ? "" : activeLanguage.code.uppercased()
        overlay.show(.starting)
        preview.begin(language: activeLanguage, micName: micName) { [weak self] in
            // Not during a quick tap, which is about to be cancelled.
            switch self?.phase {
            case .holding(let since): return Date().timeIntervalSince(since) >= 0.35
            case .locked: return true
            default: return false
            }
        }
        return true
    }

    /// Wires the mic's callbacks once; called from init.
    private func connectMic() {
        mic.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.overlay.model.push(CGFloat(level)) }
        }
        mic.onFirstAudio = { [weak self] in
            DispatchQueue.main.async { self?.micBecameLive() }
        }
    }

    /// The start sound and "Listening" wait for real audio, so they mean "talk now".
    private func micBecameLive() {
        guard capturing, !micLive else { return }
        micLive = true
        switch phase {
        case .locked: overlay.show(.locked)
        case .holding, .awaitingSecondTap: overlay.show(.listening)
        case .idle: return
        }
        playSound("Tink")
    }

    func cancelRecording(message: String?) {
        tapTimer?.invalidate()
        unmute()
        preview.end()
        if capturing { _ = mic.stop() }
        capturing = false
        phase = .idle
        ignoreNextRelease = false
        if let message {
            overlay.flash(message, seconds: 0.9)
        } else if pendingTranscriptions == 0 {
            overlay.hide()
        } else {
            overlay.show(.transcribing)
        }
    }

    private func finishRecording() {
        tapTimer?.invalidate()
        unmute()
        phase = .idle
        preview.end()
        guard capturing else { return }
        capturing = false
        let recording = mic.stop()
        var log = DictationLog.Entry(language: activeLanguage.code, mic: micName,
                                     audioSeconds: recording.duration, peak: recording.peakRMS)

        guard recording.duration >= 0.3, recording.peakRMS >= 0.004 else {
            log.outcome = micLive ? "too quiet" : "no audio from mic"
            DictationLog.write(log)
            overlay.flash(micLive ? "No speech detected" : "Mic didn't start — try again", seconds: 1.2)
            return
        }
        playSound("Pop")
        overlay.show(.transcribing)
        pendingTranscriptions += 1

        let language = activeLanguage
        let prompt = [language.stylePrompt ?? "", settings.customWords.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let started = Date()
        engine.transcribe(wav: WAV.encode(recording.samples), language: language.code, prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                log.whisperSeconds = Date().timeIntervalSince(started)
                self?.handle(result, language: language, log: log)
            }
        }
    }

    private func handle(_ result: Result<String, Error>, language: Language, log: DictationLog.Entry) {
        var log = log
        switch result {
        case .success(let raw):
            let text = TextCleaner.clean(raw, language: language.code, removeFillers: settings.removeFillers)
            log.words = text.split(separator: " ").count
            guard !text.isEmpty else {
                pendingTranscriptions -= 1
                log.outcome = "empty transcript"
                DictationLog.write(log)
                if !isRecording { overlay.flash("No speech detected", seconds: 1.0) }
                return
            }
            // Whisper punctuates normal speech well once the language is fixed; Gemma only
            // steps in for long run-on text, which saves 0.6–3 s on most dictations.
            if settings.aiPunctuation, punctuation.isReady, PunctuationEngine.needsPunctuation(text) {
                let started = Date()
                punctuation.punctuate(text, language: language) { [weak self] improved in
                    DispatchQueue.main.async {
                        log.gemmaSeconds = Date().timeIntervalSince(started)
                        log.gemmaUsed = improved != nil
                        self?.deliver(improved.map { TextCleaner.tidy($0, language: language.code) } ?? text, log: log)
                    }
                }
            } else {
                deliver(text, log: log)
            }
        case .failure(let error):
            pendingTranscriptions -= 1
            log.outcome = "whisper error: \(error.localizedDescription)"
            DictationLog.write(log)
            NSLog("VENWhispr transcription failed: \(error.localizedDescription)")
            if !isRecording { overlay.flash("Transcription failed", seconds: 2.0) }
        }
    }

    private func deliver(_ text: String, log: DictationLog.Entry) {
        var log = log
        pendingTranscriptions -= 1
        settings.addToHistory(text)
        let output = settings.trailingSpace ? text + " " : text
        if Paster.isTrusted {
            Paster.paste(output)
            log.outcome = "pasted"
            if !isRecording && pendingTranscriptions == 0 { overlay.hide() }
        } else {
            Paster.copy(output)
            log.outcome = "copied (no Accessibility)"
            overlay.flash("Copied — grant Accessibility to auto-paste", seconds: 2.5)
        }
        DictationLog.write(log)
    }

    /// Mutes system output after `delay` if still recording; the delay also lets the start/lock sound play.
    private func scheduleMute(after delay: TimeInterval) {
        muteTimer?.invalidate()
        guard settings.muteWhileRecording else { return }
        muteTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            switch self.phase {
            case .holding, .locked:
                // Wait for the start sound, which plays once the mic is live.
                if self.micLive { OutputMuter.mute() } else { self.scheduleMute(after: 0.15) }
            case .idle, .awaitingSecondTap: break
            }
        }
    }

    private func unmute() {
        muteTimer?.invalidate()
        muteTimer = nil
        OutputMuter.restore()
    }

    private func playSound(_ name: String) {
        guard settings.sounds, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.25
        sound.play()
    }
}
