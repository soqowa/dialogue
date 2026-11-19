import SwiftUI
import AppKit

/// Padding, hit testing and feedback live in the button style so every button,
/// including an icon-only label, has the same complete interaction surface.
///
/// `standard`, `primary` and `glassIcon` float on the backdrop as Liquid Glass.
/// `icon`, `row`, `card` and `textLink` sit inside glass panels and stay flat,
/// because glass stacked on glass loses its refraction and looks muddy.
struct DialogButtonStyle: ButtonStyle {
    enum Kind { case standard, primary, icon, glassIcon, row, card, textLink }
    var kind: Kind = .standard
    var selected = false
    var tint = DialogPalette.accent

    init(_ kind: Kind = .standard, selected: Bool = false, tint: Color = DialogPalette.accent) {
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
    private var floating: Bool { kind == .standard || kind == .primary || kind == .glassIcon }

    /// Flat fill for controls that live inside a glass panel.
    private var flatFill: Color {
        if pressed { return .white.opacity(0.16) }
        if highlighted { return .white.opacity(selected ? 0.14 : 0.08) }
        if selected { return .white.opacity(0.10) }
        return .clear
    }

    var body: some View {
        surface
            .scaleEffect(!floating && kind != .textLink && pressed && highlighted && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { inside in
                hovered = inside && isEnabled
                if inside && isEnabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false; NSCursor.arrow.set() }
            }
            .onDisappear { if hovered { NSCursor.arrow.set() } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion || !highlighted ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }

    @ViewBuilder private var surface: some View {
        switch kind {
        case .primary:
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(minHeight: DialogPalette.controlHeight)
                .background { Capsule().fill(.white.opacity(highlighted ? 0.10 : 0)).allowsHitTesting(false) }
                .contentShape(Capsule())
                .liquidGlass(Capsule(), tint: tint.opacity(pressed ? 0.58 : 0.74), interactive: isEnabled)
        case .standard:
            configuration.label
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(minHeight: DialogPalette.controlHeight)
                .background { Capsule().fill(.white.opacity(highlighted ? 0.07 : 0)).allowsHitTesting(false) }
                .contentShape(Capsule())
                .liquidGlass(Capsule(), tint: selected ? tint.opacity(0.3) : nil, interactive: isEnabled)
        case .glassIcon:
            configuration.label
                .frame(width: DialogPalette.controlHeight, height: DialogPalette.controlHeight)
                .background { Circle().fill(.white.opacity(highlighted ? 0.08 : 0)).allowsHitTesting(false) }
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: selected ? tint.opacity(0.3) : nil, interactive: isEnabled)
        case .icon:
            configuration.label
                .frame(width: 32, height: 32)
                .background(Circle().fill(flatFill))
                .contentShape(Circle())
        case .row:
            configuration.label
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(flatFill))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .card:
            configuration.label
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(pressed ? 0.10 : highlighted ? 0.07 : 0.035)))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(highlighted ? 0.30 : 0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .textLink:
            configuration.label
                .foregroundStyle(tint.opacity(highlighted ? 1 : 0.7))
                .opacity(pressed ? 0.6 : 1)
                .padding(.horizontal, 4).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
    }
}

struct DialogIconButton: View {
    let symbol: String
    let label: String
    var glass = false
    let action: () -> Void

    init(symbol: String, label: String, glass: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.glass = glass; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(DialogButtonStyle(glass ? .glassIcon : .icon))
        .help(label)
        .accessibilityLabel(label)
    }
}
