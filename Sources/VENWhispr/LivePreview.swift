import Foundation

/// What the preview needs from the recorder; lets it be tested against a recorded clip.
protocol PreviewAudioSource: AnyObject {
    var sampleCount: Int { get }
    var peakSoFar: Float { get }
    func snapshot(_ range: Range<Int>) -> [Float]
}

/// While dictating, repeatedly transcribes the audio so far with a small model and shows the draft
/// in the overlay card. Only a draft: the pasted text still comes from the main model.
final class LivePreview {
    let engine = WhisperEngine.preview()

    private let audio: PreviewAudioSource
    private let overlay: OverlayModel
    private let settings = Settings.shared

    /// Bumped on every begin/end, so a reply that lands late is ignored.
    private var generation = 0
    private var language = Language.named("en")
    private var isActive: () -> Bool = { false }
    /// Long dictations are cut into finished blocks so each refresh stays quick.
    private var windowStart = 0
    private var committed = ""

    private let sampleRate = 16_000
    private let minimumAudio = 8_000                // 0.5 s
    private let silenceFloor: Float = 0.004         // same gate as the final transcription
    private let maximumWindow = 25 * 16_000
    private let refreshInterval: TimeInterval = 0.4

    init(audio: PreviewAudioSource, overlay: OverlayModel) {
        self.audio = audio
        self.overlay = overlay
    }

    func begin(language: Language, micName: String, isActive: @escaping () -> Bool) {
        generation += 1
        self.language = language
        self.isActive = isActive
        windowStart = 0
        committed = ""
        overlay.previewText = ""
        overlay.previewFooter = "\(micName) · \(language.name)"
        schedule(after: 0.4, generation)
    }

    func end() {
        generation += 1
    }

    private func schedule(after delay: TimeInterval, _ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick(gen) }
    }

    private func tick(_ gen: Int) {
        guard gen == generation, settings.livePreview else { return }
        let total = audio.sampleCount
        guard engine.isReady, isActive(), total - windowStart >= minimumAudio, audio.peakSoFar >= silenceFloor else {
            schedule(after: 0.15, gen)
            return
        }

        // Past the window, finish a block at the quietest moment of the last 2 s, between words.
        let committing = total - windowStart > maximumWindow
        let end = committing ? quietestPoint(in: max(windowStart, total - 2 * sampleRate)..<total) : total
        let wav = WAV.encode(audio.snapshot(windowStart..<end))
        let code = language.code
        let prompt = settings.customWords.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()
        engine.transcribe(wav: wav, language: code, prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if case .success(let raw) = result {
                    let text = TextCleaner.clean(raw, language: code, removeFillers: self.settings.removeFillers)
                    self.show(text, finishingBlock: committing, blockEnd: end)
                }
                self.schedule(after: max(0.05, self.refreshInterval - Date().timeIntervalSince(started)), gen)
            }
        }
    }

    private func show(_ text: String, finishingBlock: Bool, blockEnd: Int) {
        let joined = [committed, text].filter { !$0.isEmpty }.joined(separator: " ")
        if finishingBlock {
            committed = joined
            windowStart = blockEnd
        }
        overlay.previewText = joined
    }

    private func quietestPoint(in range: Range<Int>) -> Int {
        let samples = audio.snapshot(range)
        let frame = sampleRate / 10
        guard samples.count > frame else { return range.upperBound }
        var best = 0
        var lowest = Float.infinity
        for start in stride(from: 0, to: samples.count - frame, by: frame / 2) {
            let energy = samples[start..<(start + frame)].reduce(0) { $0 + $1 * $1 }
            if energy < lowest {
                lowest = energy
                best = start
            }
        }
        return range.lowerBound + best + frame / 2
    }
}
