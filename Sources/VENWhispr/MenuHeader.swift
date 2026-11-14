import AppKit
import SwiftUI

enum StatusTone {
    case ready, pending, warn, danger

    var color: Color {
        switch self {
        case .ready: return Color(nsColor: .systemGreen)
        case .pending: return Color(nsColor: .systemGray)
        case .warn: return Color(nsColor: .systemOrange)
        case .danger: return Color(nsColor: .systemRed)
        }
    }
}

/// A 7 pt status dot. Always shown next to a word, never alone.
struct StatusDot: View {
    let tone: StatusTone

    var body: some View {
        Circle().fill(tone.color).frame(width: 7, height: 7)
    }
}

/// Dot + word, e.g. "● Ready".
struct StatusLabel: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// A key or chord label, e.g. "Right ⌘" or "Esc".
struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
    }
}

/// The first block of the status menu: app name, current state, and how to dictate.
struct MenuHeaderView: View {
    static let width: CGFloat = 300

    let status: String
    let tone: StatusTone
    /// Replaces the how-to hints when something needs explaining.
    let detail: String?
    /// Each dictation key with the language it dictates in.
    let keys: [(key: String, language: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("VENWhispr").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    StatusDot(tone: tone)
                    Text(status).font(.system(size: 12, weight: .medium))
                }
            }
            Group {
                if let detail {
                    Text(detail).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 4) {
                        Text("Hold")
                        ForEach(Array(keys.enumerated()), id: \.offset) { i, pair in
                            if i > 0 { Text("·") }
                            Keycap(pair.key)
                            Text(pair.language)
                        }
                    }
                    HStack(spacing: 4) { Text("Double-tap to lock ·"); Keycap("Esc"); Text("cancels") }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 14))
        .frame(width: Self.width, alignment: .leading)
    }

    /// Wraps the header in a menu item; custom-view items don't highlight on hover.
    func menuItem() -> NSMenuItem {
        let host = NSHostingView(rootView: self)
        host.frame.size = host.fittingSize
        let item = NSMenuItem()
        item.view = host
        return item
    }
}
