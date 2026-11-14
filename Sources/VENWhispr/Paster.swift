import AppKit
import ApplicationServices

/// Inserts text into whatever app has focus by putting it on the clipboard and sending ⌘V,
/// then restores the user's previous clipboard.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask clipboard managers not to record this transient write.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pb.changeCount

        sendCommandV()

        // Give the target app time to read the clipboard before restoring it. Busy apps (browsers,
        // Slack and other Electron apps) can take well over half a second; restoring too early
        // makes them paste the old clipboard instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard pb.changeCount == ourChange, !saved.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Types ⌘V the way a real keyboard does — ⌘ down, V down, V up, ⌘ up, with short gaps —
    /// because some apps ignore a lone V event that merely carries the ⌘ flag.
    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command: CGKeyCode = 55, v: CGKeyCode = 9
        let events: [(CGKeyCode, Bool)] = [(command, true), (v, true), (v, false), (command, false)]
        for (key, down) in events {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = (key == v || down) ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }
}
