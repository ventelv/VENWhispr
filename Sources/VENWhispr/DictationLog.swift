import Foundation

/// One line per dictation in ~/Library/Logs/VENWhispr/dictation.log: which mic and language,
/// how loud, how long each step took and what happened. Never the transcript itself.
enum DictationLog {
    struct Entry {
        let language: String
        let mic: String
        let audioSeconds: Double
        let peak: Float
        var whisperSeconds: Double?
        var gemmaSeconds: Double?
        var gemmaUsed = false
        var words = 0
        var outcome = ""
    }

    private static let url = LocalServer.logDir.appendingPathComponent("dictation.log")
    private static let maxBytes = 512 * 1024

    static func write(_ e: Entry) {
        let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var parts = [time, e.language, "mic=\(e.mic)", String(format: "audio=%.1fs peak=%.4f", e.audioSeconds, e.peak)]
        if let w = e.whisperSeconds { parts.append(String(format: "whisper=%.2fs", w)) }
        if let g = e.gemmaSeconds { parts.append(String(format: "gemma=%.2fs%@", g, e.gemmaUsed ? "" : "(kept whisper)")) }
        parts.append("words=\(e.words)")
        parts.append(e.outcome)
        let line = parts.joined(separator: "  ") + "\n"

        try? FileManager.default.createDirectory(at: LocalServer.logDir, withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxBytes { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
