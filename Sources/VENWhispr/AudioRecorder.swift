import AVFoundation

/// Records one microphone as 16 kHz mono Float32, which is what Whisper expects.
///
/// Uses AVCaptureSession rather than AVAudioEngine: AVAudioEngine always opens the *system default*
/// input first, so switching it to another mic (e.g. the Studio Display while AirPods are the
/// default) either delivers no audio or fails with a format error. A capture session opens exactly
/// the device asked for and converts to 16 kHz mono itself.
///
/// Mics power down after ~10 s unused and take ~0.65 s to wake (USB mics like the Studio Display).
/// So the session stays running for `keepWarm` seconds after each dictation: the next one starts
/// instantly, and keeps the last 0.3 s before the key press so a first word isn't clipped.
/// While warm and not dictating, only that 0.3 s is kept in memory.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, PreviewAudioSource {
    struct Recording {
        let samples: [Float]
        let peakRMS: Float
        var duration: Double { Double(samples.count) / 16_000 }
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone available" }
    }

    /// Called on the audio queue with a 0...1 level, only while dictating.
    var onLevel: ((Float) -> Void)?
    /// Called once per dictation when real signal arrives — i.e. when it's safe to start talking.
    /// Immediately if the mic is still warm.
    var onFirstAudio: (() -> Void)?
    /// Seconds the mic stays on after a dictation; 0 turns it off as soon as you stop.
    var keepWarm: TimeInterval = 120 {
        didSet { if keepWarm <= 0, !isCapturing { shutdown() } }
    }

    private let preRoll = 16_000 * 3 / 10
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var deviceUID: String?
    private var idleStop: DispatchWorkItem?
    private let audioQueue = DispatchQueue(label: "VENWhispr.audio")
    /// startRunning/stopRunning block, so they run here, in order, off the main thread.
    private let sessionQueue = DispatchQueue(label: "VENWhispr.capture-session")

    // Guarded by `lock` (written on the audio queue, read on main).
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakRMS: Float = 0
    private var heardAudio = false
    private var capturing = false
    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
    }

    /// `deviceUID` is a Core Audio device UID (the same as AVCaptureDevice.uniqueID); nil, or a
    /// device that's gone, records from the system default.
    func start(deviceUID: String?) throws {
        guard let device = deviceUID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noInput
        }
        idleStop?.cancel()
        let warm = session.isRunning && self.deviceUID == device.uniqueID
        if !warm {
            let session = self.session
            if session.isRunning { sessionQueue.sync { session.stopRunning() } }
            try configure(device)
        }

        lock.lock()
        samples = warm ? Array(samples.suffix(preRoll)) : []
        samples.reserveCapacity(16_000 * 30)
        peakRMS = 0
        heardAudio = warm
        capturing = true
        lock.unlock()

        if warm {
            onFirstAudio?()
        } else {
            let session = self.session
            sessionQueue.async { session.startRunning() }
        }
    }

    /// Ends the dictation and returns it; the mic stays warm for `keepWarm` seconds.
    func stop() -> Recording {
        audioQueue.sync {}  // let any buffer already in flight land
        lock.lock()
        capturing = false
        let recording = Recording(samples: samples, peakRMS: peakRMS)
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        if keepWarm > 0 {
            let work = DispatchWorkItem { [weak self] in self?.shutdown() }
            idleStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + keepWarm, execute: work)
        } else {
            shutdown()
        }
        return recording
    }

    // MARK: Reading the dictation while it's still being recorded

    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
    var peakSoFar: Float { lock.lock(); defer { lock.unlock() }; return peakRMS }

    func snapshot(_ range: Range<Int>) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples[range.clamped(to: 0..<samples.count)])
    }

    /// Turns the mic off now (idle timeout, setting switched off, quitting).
    func shutdown() {
        idleStop?.cancel()
        idleStop = nil
        guard !isCapturing else { return }
        let session = self.session
        sessionQueue.async { session.stopRunning() }
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    private func configure(_ device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw RecorderError.noInput }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw RecorderError.noInput }
            session.addOutput(output)
        }
        deviceUID = device.uniqueID
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(count))

        lock.lock()
        samples.append(contentsOf: chunk)
        guard capturing else {
            // Warm but idle: keep only the pre-roll.
            if samples.count > preRoll * 4 { samples.removeFirst(samples.count - preRoll) }
            lock.unlock()
            return
        }
        peakRMS = max(peakRMS, rms)
        let first = !heardAudio && rms > 1e-5
        if first { heardAudio = true }
        lock.unlock()
        if first { onFirstAudio?() }

        // Map -50 dB...-10 dB to 0...1 for the level meter.
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 50) / 40)))
    }
}

enum WAV {
    /// 16-bit PCM, 16 kHz, mono.
    static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return data
    }
}
