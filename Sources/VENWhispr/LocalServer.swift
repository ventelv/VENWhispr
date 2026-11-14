import Foundation
import Security

/// A localhost HTTP server (whisper-server, llama-server) run as a child process so its model
/// stays loaded in memory between dictations.
final class LocalServer {
    enum Status: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VENWhispr", isDirectory: true)
    static let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/VENWhispr", isDirectory: true)

    let binaryName: String
    let port: Int
    private let healthPath: String

    /// Always delivered on the main queue.
    var onStatus: ((Status) -> Void)?
    /// Called once the health check passes. The owner warms the model up, then calls `markReady()`.
    var onHealthy: (() -> Void)?

    private(set) var status: Status = .stopped {
        didSet {
            let s = status
            if s != oldValue { DispatchQueue.main.async { self.onStatus?(s) } }
        }
    }
    private var process: Process?

    /// A fresh random value for every launch of the app. Localhost isn't private: any web page
    /// open in a browser can send requests to 127.0.0.1. The owner uses this secret as an API key
    /// or as a secret URL prefix, so only VENWhispr can reach the server.
    let secret: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("No secure random numbers available")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()
    /// Prepended to every request path, e.g. "/<secret>" for whisper-server's --request-path.
    var pathPrefix = ""

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(pathPrefix)/\(path)")!
    }
    var isRunning: Bool { process != nil }
    var logURL: URL { Self.logDir.appendingPathComponent("\(logName).log") }
    private let logName: String

    init(binaryName: String, port: Int, healthPath: String, logName: String? = nil) {
        self.binaryName = binaryName
        self.logName = logName ?? binaryName
        self.port = port
        self.healthPath = healthPath
    }

    /// The copy bundled inside the app (Contents/MacOS) first; Homebrew's for builds made without it.
    static func findBinary(_ name: String) -> URL? {
        ([Bundle.main.url(forAuxiliaryExecutable: name)].compactMap { $0 }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].map(URL.init(fileURLWithPath:)))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `environment` is added to the server's environment (a good place for keys, which unlike
    /// arguments aren't visible in `ps`).
    func start(arguments: [String], environment: [String: String] = [:]) {
        guard process == nil else { return }
        guard let bin = Self.findBinary(binaryName) else {
            fail("\(binaryName) is missing. Download VENWhispr again from github.com/ventelv/VENWhispr")
            return
        }
        killStale()
        Self.clearQuarantineIfBundled(bin)

        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = bin
        p.arguments = arguments + ["--host", "127.0.0.1", "--port", "\(port)"]
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.fail("\(self.binaryName) stopped (see log)")
            }
        }
        do {
            try p.run()
        } catch {
            fail("Could not start \(binaryName): \(error.localizedDescription)")
            return
        }
        process = p
        status = .starting
        waitUntilHealthy(attempt: 0)
    }

    func stop() {
        let p = process
        process = nil
        p?.terminate()
        status = .stopped
    }

    func markReady() { status = .ready }
    func fail(_ message: String) { status = .failed(message) }

    /// Stops a server left over from a previous run (e.g. after a force quit) that would hold the port.
    /// Only processes whose program file really is this server are stopped, so a shell or editor
    /// whose command line merely mentions "whisper-server --port 8178" is left alone.
    private func killStale() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "--", "--port \(port)( |$)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let pids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        for pid in pids where Self.programName(of: pid) == binaryName {
            kill(pid, SIGTERM)
        }
    }

    /// A downloaded app's files all carry the quarantine flag. Opening the app (with the user's
    /// "Open Anyway" approval) clears Gatekeeper for the app, but each server inside it would still be
    /// blocked on its own. They are part of the app the user just approved and covered by its
    /// signature, so lift the flag on them before running them. Homebrew's copies are left alone.
    private static func clearQuarantineIfBundled(_ binary: URL) {
        let bundled = binary.resolvingSymlinksInPath().path
            .hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
        guard bundled else { return }
        removexattr(binary.path, "com.apple.quarantine", 0)
    }

    private static func programName(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent
    }

    private func waitUntilHealthy(attempt: Int) {
        guard process != nil else { return }
        guard attempt < 240 else {
            fail("\(binaryName) did not start in time")
            return
        }
        var req = URLRequest(url: url(healthPath))
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    if let onHealthy = self.onHealthy { onHealthy() } else { self.markReady() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitUntilHealthy(attempt: attempt + 1) }
                }
            }
        }.resume()
    }
}
