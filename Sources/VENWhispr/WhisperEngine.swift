import Foundation

/// Speech-to-text through Homebrew's `whisper-server` (whisper.cpp on the Metal GPU).
final class WhisperEngine {
    let server: LocalServer
    private let findModelFile: () -> URL?
    private let extraArguments: [String]

    var isReady: Bool { server.status == .ready }

    /// The main engine, whose text gets pasted.
    init() {
        server = LocalServer(binaryName: "whisper-server", port: 8178, healthPath: "")
        findModelFile = Self.findModel
        // --carry-initial-prompt keeps the punctuated style prompt in front of every 30 s window,
        // so long dictations don't drift into unpunctuated run-on text.
        extraArguments = ["--carry-initial-prompt"]
        lockToSecretPath()
    }

    /// A separate small model for the live preview, so drafts never queue in front of the final text.
    private init(previewModel: @escaping () -> URL?) {
        server = LocalServer(binaryName: "whisper-server", port: 8181, healthPath: "", logName: "whisper-preview")
        findModelFile = previewModel
        extraArguments = []
        lockToSecretPath()
    }

    /// whisper-server has no API key and allows requests from any web page, including /load,
    /// which makes it open any file as a model. Serving everything under a random secret path
    /// means only VENWhispr, which knows the path, can reach it.
    private func lockToSecretPath() {
        server.pathPrefix = "/" + server.secret
    }

    static func preview() -> WhisperEngine {
        WhisperEngine(previewModel: findPreviewModel)
    }

    static func findPreviewModel() -> URL? {
        let url = LocalServer.supportDir.appendingPathComponent("preview/ggml-base.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Prefers large-v3-turbo; otherwise takes any ggml model dropped into the support folder.
    static func findModel() -> URL? {
        let dir = LocalServer.supportDir
        let preferred = dir.appendingPathComponent("ggml-large-v3-turbo.bin")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
    }

    func start() {
        guard let model = findModelFile() else {
            server.fail("No Whisper model in ~/Library/Application Support/VENWhispr")
            return
        }
        server.onHealthy = { [weak self] in self?.warmUp() }
        server.start(arguments: ["-m", model.path, "-t", "4", "-nt", "-l", "en",
                                 "--request-path", server.pathPrefix] + extraArguments)
    }

    func stop() { server.stop() }

    func restart() {
        stop()
        start()
    }

    /// The first Metal inference compiles shaders; do it now so the first real dictation is fast.
    private func warmUp() {
        let silence = WAV.encode([Float](repeating: 0, count: 16_000))
        send(wav: silence, language: "en", prompt: "") { [weak self] _ in
            DispatchQueue.main.async { self?.server.markReady() }
        }
    }

    func transcribe(wav: Data, language: String, prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        if !server.isRunning {
            start()
        }
        send(wav: wav, language: language, prompt: prompt, completion: completion)
    }

    private func send(wav: Data, language: String, prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        let boundary = "venwhispr-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "json")
        field("temperature", "0.0")
        field("language", language)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: server.url("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "VENWhispr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad response from whisper-server"])))
                return
            }
            if let message = json["error"] as? String {
                completion(.failure(NSError(domain: "VENWhispr", code: 2, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }
            completion(.success((json["text"] as? String) ?? ""))
        }.resume()
    }
}
