import Foundation

enum Hotkey: String, CaseIterable {
    case rightOption, rightCommand, fn

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .fn: return "Fn / Globe"
        }
    }

    var shortTitle: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .fn: return "Fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    /// Device-dependent modifier bits, so the left-hand key never triggers dictation.
    func isDown(_ rawFlags: UInt) -> Bool {
        switch self {
        case .rightOption: return rawFlags & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return rawFlags & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .fn: return rawFlags & 0x800000 != 0           // NSEvent.ModifierFlags.function
        }
    }
}

struct Language {
    let code: String
    let name: String
    /// A well-punctuated sentence given to Whisper as its initial prompt. Whisper imitates the
    /// style of its prompt, so this makes it punctuate long speech instead of producing run-ons.
    let stylePrompt: String?
    /// One before/after pair shown to the AI punctuation model.
    let example: (input: String, output: String)?

    static let all: [Language] = [
        Language(code: "en", name: "English",
                 stylePrompt: "Hi, thanks for the update. So, as I was saying, let's meet tomorrow at 3:30. Does that work for you? Great!",
                 example: ("so i was thinking we could meet tomorrow what time works for you let me know thanks",
                           "So I was thinking we could meet tomorrow. What time works for you? Let me know, thanks.")),
        Language(code: "ro", name: "Română",
                 stylePrompt: "Bună, mulțumesc pentru mesaj. Deci, cum spuneam, ne vedem mâine la 15:30. Ți se potrivește? Perfect!",
                 example: ("deci mă gândeam că ne putem vedea mâine la ce oră ți se potrivește spune-mi te rog mulțumesc",
                           "Deci, mă gândeam că ne putem vedea mâine. La ce oră ți se potrivește? Spune-mi, te rog. Mulțumesc.")),
        Language(code: "auto", name: "Auto-detect", stylePrompt: nil, example: nil),
        Language(code: "af", name: "Afrikaans", stylePrompt: nil, example: nil),
        Language(code: "nl", name: "Dutch", stylePrompt: nil, example: nil),
        Language(code: "fr", name: "French", stylePrompt: nil, example: nil),
        Language(code: "de", name: "German", stylePrompt: nil, example: nil),
        Language(code: "it", name: "Italian", stylePrompt: nil, example: nil),
        Language(code: "pt", name: "Portuguese", stylePrompt: nil, example: nil),
        Language(code: "es", name: "Spanish", stylePrompt: nil, example: nil),
    ]

    static func named(_ code: String) -> Language {
        all.first { $0.code == code } ?? all[0]
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "hotkey": Hotkey.rightOption.rawValue,
            "language": "en",
            "removeFillers": true,
            "trailingSpace": true,
            "sounds": true,
            "customWords": "",
            "history": [String](),
            "aiPunctuation": true,
            "muteWhileRecording": true,
            "keepMicWarm": true,
            "livePreview": true,
            "secondHotkey": Hotkey.rightCommand.rawValue,
            "secondLanguage": "ro",
        ])
    }

    var hotkey: Hotkey {
        get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    /// Optional second dictation key with its own language ("" in defaults = off), so switching
    /// language is just a matter of which key you hold — no auto-detect pass, which costs ~0.8 s.
    var secondHotkey: Hotkey? {
        get { Hotkey(rawValue: d.string(forKey: "secondHotkey") ?? "") }
        set { d.set(newValue?.rawValue ?? "", forKey: "secondHotkey") }
    }
    var secondLanguage: String {
        get { d.string(forKey: "secondLanguage") ?? "ro" }
        set { d.set(newValue, forKey: "secondLanguage") }
    }
    var activeHotkeys: [Hotkey] {
        [hotkey] + [secondHotkey].compactMap { $0 }.filter { $0 != hotkey }
    }
    func language(for key: Hotkey) -> String {
        key == hotkey ? language : secondLanguage
    }

    /// Language of the first dictation key.
    var language: String {
        get { d.string(forKey: "language") ?? "en" }
        set { d.set(newValue, forKey: "language") }
    }
    var removeFillers: Bool {
        get { d.bool(forKey: "removeFillers") }
        set { d.set(newValue, forKey: "removeFillers") }
    }
    var trailingSpace: Bool {
        get { d.bool(forKey: "trailingSpace") }
        set { d.set(newValue, forKey: "trailingSpace") }
    }
    var sounds: Bool {
        get { d.bool(forKey: "sounds") }
        set { d.set(newValue, forKey: "sounds") }
    }
    /// Comma-separated names/jargon fed to Whisper as an initial prompt.
    var customWords: String {
        get { d.string(forKey: "customWords") ?? "" }
        set { d.set(newValue, forKey: "customWords") }
    }

    /// Polish punctuation with the local Gemma model after Whisper.
    var aiPunctuation: Bool {
        get { d.bool(forKey: "aiPunctuation") }
        set { d.set(newValue, forKey: "aiPunctuation") }
    }
    /// Show a draft of the words in a card while dictating, using a small extra Whisper model.
    var livePreview: Bool {
        get { d.bool(forKey: "livePreview") }
        set { d.set(newValue, forKey: "livePreview") }
    }
    /// Leave the mic on for 2 minutes after each dictation so the next one starts instantly.
    var keepMicWarm: Bool {
        get { d.bool(forKey: "keepMicWarm") }
        set { d.set(newValue, forKey: "keepMicWarm") }
    }
    /// Silence system audio output (music, videos) while the mic is recording.
    var muteWhileRecording: Bool {
        get { d.bool(forKey: "muteWhileRecording") }
        set { d.set(newValue, forKey: "muteWhileRecording") }
    }
    /// Core Audio UID of the chosen microphone; nil means the system default input.
    var microphoneUID: String? {
        get { d.string(forKey: "microphoneUID") }
        set { d.set(newValue, forKey: "microphoneUID") }
    }

    var history: [String] {
        get { d.stringArray(forKey: "history") ?? [] }
        set { d.set(Array(newValue.prefix(20)), forKey: "history") }
    }

    func addToHistory(_ text: String) {
        history = [text] + history
    }
}
