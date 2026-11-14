import AudioToolbox
import CoreAudio
import Foundation

extension Notification.Name {
    /// Posted on the main queue when mics are connected/disconnected or the default input changes.
    static let audioDevicesChanged = Notification.Name("VENWhisprAudioDevicesChanged")
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Loopback/virtual drivers (Teams, Background Music, eqMac…) and aggregates rather than real mics.
    let isVirtual: Bool
    let transport: UInt32

    /// AirPods and other headsets: opening their mic switches them into call mode, which takes
    /// ~0.5–1.5 s (cutting off your first words) and drops music to call quality.
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Core Audio device helpers. UIDs are stable across reboots and reconnects; IDs are not.
enum AudioDevices {
    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            let virtual = transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            return AudioInputDevice(id: id, uid: uid, name: name.trimmingCharacters(in: .whitespaces),
                                    isVirtual: virtual, transport: transport)
        }
    }

    static func defaultInput() -> AudioInputDevice? {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return inputs().first { $0.id == id }
    }

    /// The mic "Automatic" records from: the system default, unless that's a Bluetooth headset,
    /// in which case a wired mic — external USB (e.g. Studio Display) first, then the built-in one.
    static func automaticInput() -> AudioInputDevice? {
        let all = inputs()
        guard let current = defaultInput() else { return nil }
        guard current.isBluetooth else { return current }
        let wired = all.filter { !$0.isVirtual && !$0.isBluetooth && $0.transport != kAudioDeviceTransportTypeContinuityCaptureWired
                                  && $0.transport != kAudioDeviceTransportTypeContinuityCaptureWireless }
        return wired.first { $0.transport == kAudioDeviceTransportTypeUSB }
            ?? wired.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? wired.first
            ?? current
    }

    /// Starts posting `.audioDevicesChanged`. Safe to call more than once.
    static func startObservingChanges() {
        guard !observing else { return }
        observing = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { _, _ in
                NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
            }
        }
    }
    private static var observing = false

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    static func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    static func defaultInputName() -> String? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { string($0, kAudioObjectPropertyName) }
    }

    static func defaultOutputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    // MARK: Output controls (mute switch / main volume)

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(selector, scope: scope)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr)
            && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr
            && settable.boolValue
    }

    @discardableResult
    static func setUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32,
                          scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(selector, scope: scope)
        var value = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func float32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Float32? {
        var addr = address(selector, scope: scope)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setFloat32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Float32,
                           scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(selector, scope: scope)
        var value = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
