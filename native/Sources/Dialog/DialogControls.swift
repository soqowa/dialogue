import SwiftUI
import AppKit

enum DialogPalette {
    static let ink = Color.white.opacity(0.92)
    /// The single accent colour: main action, selection, icons, my replies.
    static let accent = Color(red: 0.42, green: 0.62, blue: 1.00)
    static let danger = Color(red: 0.90, green: 0.40, blue: 0.38)
    static let muted = Color.white.opacity(0.52)
    static let icon = accent
    static let canvas = Color(red: 0.043, green: 0.051, blue: 0.078)
    static let line = Color.white.opacity(0.09)
    static let field = Color.white.opacity(0.06)
    static let controlHeight: CGFloat = 36
}

struct DialogToolbarButtonStyle: ButtonStyle {
    var primary = false
    var tint = DialogPalette.accent
    func makeBody(configuration: Configuration) -> some View {
        DialogButtonStyle(primary ? .primary : .standard, tint: tint)
            .makeBody(configuration: configuration)
            .font(.system(size: 12, weight: .medium))
    }
}

struct DialogAnswerModePicker: View {
    @Binding var automatic: Bool
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            option("Автоответ", value: true)
            option("По клавише", value: false)
        }
        .padding(3)
        .frame(height: DialogPalette.controlHeight)
        .liquidGlass(Capsule())
        .accessibilityElement(children: .contain).accessibilityLabel("Режим ответа").accessibilityIdentifier("answer.mode")
    }

    private func option(_ title: String, value: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)) { automatic = value }
        } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .frame(width: 92, height: DialogPalette.controlHeight - 6)
                .contentShape(Capsule())
        }
        .buttonStyle(ModeOptionStyle(selected: automatic == value, namespace: pill))
        .accessibilityAddTraits(automatic == value ? [.isSelected] : [])
        .accessibilityIdentifier(value ? "answer.mode.auto" : "answer.mode.manual")
    }

    private struct ModeOptionStyle: ButtonStyle {
        let selected: Bool
        let namespace: Namespace.ID
        func makeBody(configuration: Configuration) -> some View { ModeSurface(configuration: configuration, selected: selected, namespace: namespace) }
        private struct ModeSurface: View {
            let configuration: ButtonStyle.Configuration
            let selected: Bool
            let namespace: Namespace.ID
            @Environment(\.isEnabled) private var enabled
            @State private var hovered = false
            var body: some View {
                configuration.label
                    .foregroundStyle(selected ? Color.white : DialogPalette.ink.opacity(0.72))
                    .background {
                        if selected {
                            Capsule()
                                .fill(DialogPalette.accent.opacity(configuration.isPressed ? 0.45 : 0.6))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        } else if hovered || configuration.isPressed {
                            Capsule().fill(.white.opacity(configuration.isPressed ? 0.12 : 0.07))
                        }
                    }
                    .contentShape(Capsule()).opacity(enabled ? 1 : 0.4)
                    .onHover { inside in hovered = inside; if inside && enabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                    .onDisappear { if hovered { NSCursor.arrow.set() } }
            }
        }
    }
}
