import AppKit

/// Watches the dictation modifier keys system-wide. Needs Accessibility permission to see global events.
final class HotkeyMonitor {
    var hotkeys: [Hotkey] {
        didSet { down.removeAll() }
    }
    var onDown: (Hotkey) -> Void = { _ in }
    var onUp: (Hotkey) -> Void = { _ in }
    /// Any non-modifier key pressed anywhere (keyCode).
    var onOtherKey: (UInt16) -> Void = { _ in }

    private var monitors: [Any] = []
    private var down: Set<Hotkey> = []

    init(hotkeys: [Hotkey]) {
        self.hotkeys = hotkeys
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        down.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard let key = hotkeys.first(where: { $0.keyCode == event.keyCode }) else { return }
            let isDown = key.isDown(event.modifierFlags.rawValue)
            if isDown && !down.contains(key) {
                down.insert(key)
                onDown(key)
            } else if !isDown && down.contains(key) {
                down.remove(key)
                onUp(key)
            }
        case .keyDown:
            onOtherKey(event.keyCode)
        default:
            break
        }
    }
}
