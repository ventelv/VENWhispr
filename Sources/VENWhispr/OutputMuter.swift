import AudioToolbox
import CoreAudio
import Foundation

/// Silences the system output while dictating, so music from any app neither distracts nor leaks
/// into the mic. Only ever undoes what it changed itself, and records that in UserDefaults before
/// changing anything so a crash or force-quit can't leave the Mac muted.
enum OutputMuter {
    private struct Saved: Codable {
        let deviceUID: String
        /// nil when the device's mute switch was used; otherwise the volume that was replaced by 0.
        let previousVolume: Float32?
    }

    private static let key = "outputMutedByVENWhispr"
    private static let output = kAudioDevicePropertyScopeOutput
    private static let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private static var saved: Saved? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }

    static func mute() {
        guard saved == nil,
              let device = AudioDevices.defaultOutputID(),
              let uid = AudioDevices.uid(of: device) else { return }

        if AudioDevices.isSettable(device, kAudioDevicePropertyMute, scope: output) {
            // Already muted by the user: leave it alone, and don't unmute it afterwards either.
            guard AudioDevices.uint32(device, kAudioDevicePropertyMute, scope: output) == 0 else { return }
            saved = Saved(deviceUID: uid, previousVolume: nil)
            if !AudioDevices.setUInt32(device, kAudioDevicePropertyMute, 1, scope: output) { saved = nil }
        } else if AudioDevices.isSettable(device, volume, scope: output),
                  let current = AudioDevices.float32(device, volume, scope: output), current > 0 {
            saved = Saved(deviceUID: uid, previousVolume: current)
            if !AudioDevices.setFloat32(device, volume, 0, scope: output) { saved = nil }
        }
    }

    /// Safe to call any time, including at launch to recover from a crash mid-dictation.
    static func restore() {
        guard let s = saved else { return }
        saved = nil
        // Restore the device that was muted, even if the default output changed meanwhile.
        guard let device = AudioDevices.deviceID(forUID: s.deviceUID) else { return }

        // If the user already changed it during the recording, respect that.
        if let previous = s.previousVolume {
            if AudioDevices.float32(device, volume, scope: output) == 0 {
                AudioDevices.setFloat32(device, volume, previous, scope: output)
            }
        } else if AudioDevices.uint32(device, kAudioDevicePropertyMute, scope: output) == 1 {
            AudioDevices.setUInt32(device, kAudioDevicePropertyMute, 0, scope: output)
        }
    }
}
