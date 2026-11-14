import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Mode: Equatable {
        /// Mic opened but no audio yet (Bluetooth headsets take a moment) — don't talk yet.
        case starting
        case listening, locked, transcribing
        case message(String)
    }

    static let barCount = 16
    @Published var mode: Mode = .listening
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.barCount)
    /// Short language code shown while recording, e.g. "EN" or "RO".
    @Published var languageTag = ""
    /// Draft of what's being said, shown in a card above the pill; empty hides the card.
    @Published var previewText = ""
    /// Mic and language, shown at the bottom of the card.
    @Published var previewFooter = ""

    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// The card holds about seven lines; older words scroll off the top.
    private static let visibleCharacters = 300
    /// The newest words are the likeliest to change, so they're drawn fainter.
    private static let unsettledWords = 2

    private var showsCard: Bool {
        guard !model.previewText.isEmpty else { return false }
        switch model.mode {
        case .listening, .locked, .transcribing: return true
        case .starting, .message: return false
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if showsCard { card }
            pill
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewLines
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(3)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.previewFooter)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(16)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private var previewLines: Text {
        var words = model.previewText.split(separator: " ").map(String.init)
        var clipped = false
        while words.joined(separator: " ").count > Self.visibleCharacters {
            words.removeFirst()
            clipped = true
        }
        let settled = (clipped ? ["…"] : []) + words.dropLast(Self.unsettledWords)
        let unsettled = words.suffix(Self.unsettledWords).joined(separator: " ")
        return Text(settled.joined(separator: " ") + (settled.isEmpty ? "" : " ")).foregroundColor(.white)
            + Text(unsettled).foregroundColor(.white.opacity(0.5))
    }

    private var pill: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .starting:
                Circle().fill(Color.white.opacity(0.5)).frame(width: 7, height: 7)
                Text("Mic starting…")
            case .listening, .locked:
                Circle().fill(Color.red).frame(width: 7, height: 7)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 3, height: 3 + model.levels[i] * 18)
                    }
                }
                .frame(height: 22)
                .animation(.linear(duration: 0.08), value: model.levels)
                if !model.languageTag.isEmpty {
                    Text(model.languageTag)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                }
                if model.mode == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Transcribing…")
            case .message(let text):
                Text(text).lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

/// A click-through, non-activating floating pill (and preview card) near the bottom of the active
/// screen. The panel is always card-sized; the empty part is transparent and ignores the mouse.
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 310),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ mode: OverlayModel.Mode) {
        hideWork?.cancel()
        if mode == .starting || mode == .listening { model.resetLevels() }
        model.mode = mode
        position()
        panel.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 1.6) {
        show(.message(message))
        hide(after: seconds)
    }

    func hide(after seconds: Double = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 36))
    }
}
