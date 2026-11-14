import AppKit
import CryptoKit
import SwiftUI

/// A model the app needs: where to get it and how to recognise a good copy.
/// Keep this list in sync with MODELS in install.sh.
struct ModelFile {
    let name: String
    let url: URL
    let size: Int64
    let sha256: String
    let destination: URL

    /// `path` is relative to ~/Library/Application Support/VENWhispr unless `directory` is given.
    init(name: String, path: String, url: URL, size: Int64, sha256: String, directory: URL = LocalServer.supportDir) {
        self.name = name
        self.url = url
        self.size = size
        self.sha256 = sha256
        destination = directory.appendingPathComponent(path)
    }

    var partial: URL { destination.appendingPathExtension("part") }
    /// Files only get their final name once their checksum matched, so the size is enough here.
    var isPresent: Bool { fileSize(destination) == size }

    static let all: [ModelFile] = [
        ModelFile(name: "Whisper large-v3-turbo", path: "ggml-large-v3-turbo.bin",
                  url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
                  size: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        ModelFile(name: "Whisper base (Live Preview)", path: "preview/ggml-base.bin",
                  url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
                  size: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        ModelFile(name: "Gemma 3 4B (Smart Punctuation)", path: "gemma-3-4b-it-Q4_K_M.gguf",
                  url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!,
                  size: 2_489_757_856, sha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863"),
    ]
}

private func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Downloads missing models one at a time into a `.part` file, resuming after interruptions
/// (also across app launches), and only gives a file its real name once its SHA-256 matches.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDataDelegate {
    enum Phase: Equatable {
        case idle, downloading, verifying, finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentName = ""
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0

    /// Called on the main queue once every model is in place.
    var onFinished: () -> Void = {}

    let files: [ModelFile]

    init(files: [ModelFile] = ModelFile.all) {
        self.files = files
    }

    static var missing: [ModelFile] { ModelFile.all.filter { !$0.isPresent } }
    var missing: [ModelFile] { files.filter { !$0.isPresent } }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.size } }

    var isBusy: Bool { phase == .downloading || phase == .verifying }

    private static let maxAttempts = 5

    // Everything below is only touched on `work`, the session's delegate queue.
    private let work: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: work)
    private var queue: [ModelFile] = []
    private var current: ModelFile?
    private var handle: FileHandle?
    private var finishedBytes: Int64 = 0
    private var partBytes: Int64 = 0
    private var attempts = 0
    private var responseError: String?
    private var lastPublished = Date.distantPast

    /// Call on the main queue.
    func start() {
        guard !isBusy else { return }
        let missing = self.missing
        guard !missing.isEmpty else {
            phase = .finished
            onFinished()
            return
        }
        let needed = missing.reduce(Int64(0)) { $0 + $1.size - min(fileSize($1.partial), $1.size) }
        let free = (try? (missing.first?.destination.deletingLastPathComponent() ?? LocalServer.supportDir).deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        if let free, free < needed + 500_000_000 {
            phase = .failed("Not enough free disk space. The models need \(Self.format(needed + 500_000_000)), and \(Self.format(free)) is free.")
            return
        }
        totalBytes = missing.reduce(0) { $0 + $1.size }
        receivedBytes = 0
        phase = .downloading
        work.addOperation {
            self.queue = missing
            self.finishedBytes = 0
            self.next()
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Work queue

    private func next() {
        guard !queue.isEmpty else {
            current = nil
            publish { $0.phase = .finished; $0.receivedBytes = $0.totalBytes }
            DispatchQueue.main.async { self.onFinished() }
            return
        }
        let file = queue.removeFirst()
        current = file
        attempts = 0
        publish { $0.currentName = file.name; $0.phase = .downloading }
        request(file)
    }

    private func request(_ file: ModelFile) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = fileSize(file.partial)
        if existing > file.size {
            try? fm.removeItem(at: file.partial)
            existing = 0
        }
        if existing == file.size {
            verify(file)
            return
        }
        if !fm.fileExists(atPath: file.partial.path) {
            fm.createFile(atPath: file.partial.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: file.partial) else {
            return fail("Couldn't write to \(file.partial.deletingLastPathComponent().path).")
        }
        h.seekToEndOfFile()
        handle = h
        partBytes = existing
        responseError = nil
        publishProgress(force: true)

        var req = URLRequest(url: file.url)
        req.timeoutInterval = 60
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        session.dataTask(with: req).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server ignored our Range header, so the body starts from byte 0.
            if partBytes > 0 {
                try? handle?.truncate(atOffset: 0)
                partBytes = 0
            }
            completionHandler(.allow)
        default:
            responseError = "the server answered \(status)"
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        partBytes += Int64(data.count)
        publishProgress(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        guard let file = current else { return }

        let problem = responseError ?? error?.localizedDescription
            ?? (fileSize(file.partial) == file.size ? nil : "the download ended early")
        guard let problem else {
            verify(file)
            return
        }
        attempts += 1
        guard attempts < Self.maxAttempts else {
            return fail("Couldn't download \(file.name): \(problem). Check your internet connection and try again; it will pick up where it stopped.")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            self.work.addOperation { self.request(file) }
        }
    }

    private func verify(_ file: ModelFile) {
        partBytes = fileSize(file.partial)
        publishProgress(force: true)
        publish { $0.phase = .verifying }
        guard let digest = Self.sha256(of: file.partial), digest == file.sha256 else {
            try? FileManager.default.removeItem(at: file.partial)
            return fail("\(file.name) didn't match its checksum, so it was deleted. Try again to download it fresh.")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: file.destination)
        do {
            try fm.moveItem(at: file.partial, to: file.destination)
        } catch {
            return fail("Couldn't save \(file.name): \(error.localizedDescription)")
        }
        finishedBytes += file.size
        partBytes = 0
        next()
    }

    private static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 8 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fail(_ message: String) {
        current = nil
        queue.removeAll()
        publish { $0.phase = .failed(message) }
    }

    private func publishProgress(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) > 0.1 else { return }
        lastPublished = now
        let received = finishedBytes + partBytes
        publish { $0.receivedBytes = received }
    }

    private func publish(_ change: @escaping (ModelDownloader) -> Void) {
        DispatchQueue.main.async { change(self) }
    }
}

// MARK: - Setup window

struct ModelSetupView: View {
    @ObservedObject var downloader: ModelDownloader
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    Text(progressText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if case .failed(let message) = downloader.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var title: String {
        switch downloader.phase {
        case .idle, .failed: return "Download the speech models"
        case .downloading, .verifying: return "Downloading models…"
        case .finished: return "VENWhispr is ready"
        }
    }

    private var detail: String {
        switch downloader.phase {
        case .finished:
            let key = Settings.shared.hotkey
            return "Hold \(key.shortTitle) and speak, then let go to paste your words into any app."
        case .downloading, .verifying:
            return "You can close this window. The download keeps going, and if it's interrupted it resumes next time."
        case .idle, .failed:
            return "VENWhispr turns your speech into text entirely on this Mac. For that it needs three AI models, \(ModelDownloader.format(max(downloader.missingBytes, 1))) in total, downloaded once from Hugging Face. Nothing you say ever leaves your Mac."
        }
    }

    private var showsProgress: Bool {
        downloader.phase == .downloading || downloader.phase == .verifying
    }

    private var fraction: Double {
        downloader.totalBytes > 0 ? min(1, Double(downloader.receivedBytes) / Double(downloader.totalBytes)) : 0
    }

    private var progressText: String {
        let amounts = "\(ModelDownloader.format(downloader.receivedBytes)) of \(ModelDownloader.format(downloader.totalBytes))"
        if downloader.phase == .verifying { return "\(amounts) · Checking \(downloader.currentName)…" }
        return "\(amounts) · \(downloader.currentName)"
    }

    @ViewBuilder private var buttons: some View {
        switch downloader.phase {
        case .idle:
            Button("Later", action: onClose)
            Button("Download") { downloader.start() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Later", action: onClose)
            Button("Try Again") { downloader.start() }
                .keyboardShortcut(.defaultAction)
        case .downloading, .verifying:
            Button("Hide", action: onClose)
                .keyboardShortcut(.defaultAction)
        case .finished:
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }
}

final class ModelSetupWindowController {
    private let window: NSWindow

    init(downloader: ModelDownloader) {
        var close: () -> Void = {}
        let host = NSHostingController(rootView: ModelSetupView(downloader: downloader) { close() })
        // The window grows and shrinks with the view (e.g. when the progress bar appears).
        host.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "VENWhispr Setup"
        window.isReleasedWhenClosed = false
        window.center()
        close = { [weak window] in window?.close() }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
