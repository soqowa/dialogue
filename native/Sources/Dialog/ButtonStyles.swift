import SwiftUI
import AppKit

/// Padding, hit testing and feedback live in the button style so every button,
/// including an icon-only label, has the same complete interaction surface.
struct DialogButtonStyle: ButtonStyle {
    enum Kind { case standard, primary, icon, row, card, textLink }
    var kind: Kind = .standard
    var selected = false
    var tint = Color(red: 0.33, green: 0.44, blue: 0.27)

    init(_ kind: Kind = .standard, selected: Bool = false, tint: Color = Color(red: 0.33, green: 0.44, blue: 0.27)) {
        self.kind = kind; self.selected = selected; self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        DialogButtonSurface(configuration: configuration, kind: kind, selected: selected, tint: tint)
    }
}

private struct DialogButtonSurface: View {
    let configuration: ButtonStyle.Configuration
    let kind: DialogButtonStyle.Kind
    let selected: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var pressed: Bool { isEnabled && configuration.isPressed }
    private var highlighted: Bool { isEnabled && hovered }
    private var fill: Color {
        if kind == .textLink { return .clear }
        if kind == .primary { return tint.opacity(pressed ? 0.76 : highlighted ? 0.88 : 1) }
        if pressed { return tint.opacity(0.19) }
        if highlighted { return tint.opacity(selected ? 0.18 : 0.11) }
        if selected { return tint.opacity(0.10) }
        return tint.opacity(kind == .standard || kind == .card ? 0.045 : 0)
    }
    private var stroke: Color {
        if kind == .textLink { return .clear }
        if kind == .primary || kind == .row { return .clear }
        return tint.opacity(pressed ? 0.32 : highlighted ? 0.23 : kind == .icon ? 0 : 0.16)
    }

    var body: some View {
        label
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: kind == .card ? [4] : []))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .scaleEffect(kind != .textLink && pressed && highlighted && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { inside in
                hovered = inside && isEnabled
                if inside && isEnabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false; NSCursor.arrow.set() }
            }
            .onDisappear { if hovered { NSCursor.arrow.set() } }
            .animation(reduceMotion || !highlighted ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }

    @ViewBuilder private var label: some View {
        if kind == .textLink {
            configuration.label
                .foregroundStyle(tint.opacity(highlighted ? 1 : 0.65))
                .opacity(pressed ? 0.65 : 1)
                .padding(.horizontal, 4).padding(.vertical, 4)
                .contentShape(Rectangle())
        } else if kind == .icon {
            configuration.label
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        } else if kind == .primary {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        } else {
            configuration.label
                .padding(.horizontal, kind == .card ? 0 : kind == .row ? 10 : 12)
                .padding(.vertical, kind == .row || kind == .card ? 0 : 8)
                .frame(maxWidth: kind == .row || kind == .card ? .infinity : nil,
                       minHeight: kind == .row || kind == .card ? 44 : 36,
                       alignment: kind == .row ? .leading : .center)
                .contentShape(Rectangle())
        }
    }
}

struct DialogIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(DialogButtonStyle(.icon))
        .help(label)
        .accessibilityLabel(label)
    }
}
