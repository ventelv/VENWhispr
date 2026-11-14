import Foundation

/// Light, rule-based cleanup of Whisper output. No network, no LLM.
enum TextCleaner {
    /// Standalone hesitation sounds per language. Only matched as whole words.
    private static let fillers: [String: String] = [
        "en": #"u+m+|u+h+m*|e+r+m+|e+r+|a+h+|h+m+|m+h*m+"#,
        "ro": #"[ăâ]+m*|î+m*|e+m+|a+h+|h+m+|m+h*m+"#,
    ]

    static func clean(_ raw: String, language: String, removeFillers: Bool) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ")

        // Whisper annotations for non-speech: [BLANK_AUDIO], [Music], (laughs), *coughs* ...
        t = replace(t, #"\[[^\]]*\]"#, " ")
        t = replace(t, #"(?i)[(*](?:music|silence|laughs?|laughter|applause|coughs?|sighs?|inaudible|blank[ _]audio|no speech|background noise|static|muzică|râsete)[^)*]*[)*]"#, " ")

        if removeFillers {
            let pattern: String?
            if language == "auto" {
                pattern = [fillers["en"]!, fillers["ro"]!].joined(separator: "|")
            } else {
                pattern = fillers[language]
            }
            if let pattern {
                // Drop the filler plus a trailing comma/period that Whisper attaches to it.
                t = replace(t, #"(?i)(^|[\s,.;:!?])(?:"# + pattern + #")(?=[\s,.;:!?]|$)[,.]?"#, "$1")
            }
        }
        return tidy(t, language: language)
    }

    /// Whitespace, punctuation spacing, sentence capitals and Romanian diacritics.
    static func tidy(_ s: String, language: String) -> String {
        var t = replace(s, #"\s+"#, " ")
        t = replace(t, #"\s+([,.;:!?])"#, "$1")
        t = replace(t, #",\s*([,.;:!?])"#, "$1")
        t = replace(t, #"^[\s,.;:]+"#, "")
        t = t.trimmingCharacters(in: .whitespaces)

        if language == "ro" || language == "auto" {
            // Whisper and LLMs often emit the legacy cedilla forms; Romanian uses comma-below.
            t = t.replacingOccurrences(of: "ş", with: "ș").replacingOccurrences(of: "Ş", with: "Ș")
                 .replacingOccurrences(of: "ţ", with: "ț").replacingOccurrences(of: "Ţ", with: "Ț")
        }

        if let first = t.first, first.isLowercase {
            t = first.uppercased() + t.dropFirst()
        }
        return capitalizeAfterSentenceEnds(t)
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static func capitalizeAfterSentenceEnds(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([.!?]\s+)(\p{Ll})"#) else { return s }
        let ns = s as NSString
        var result = s
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = match.range(at: 2)
            result = (result as NSString).replacingCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return result
    }
}
