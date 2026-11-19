import SwiftUI
import AppKit

enum DialogPalette {
    static let ink = Color(red: 0.15, green: 0.19, blue: 0.15)
    static let sage = Color(red: 0.33, green: 0.44, blue: 0.27)
    static let muted = Color(red: 0.54, green: 0.59, blue: 0.49)
    static let canvas = Color(red: 0.97, green: 0.98, blue: 0.96)
    static let line = Color(red: 0.88, green: 0.91, blue: 0.85)
    static let controlHeight: CGFloat = 36
}

struct DialogToolbarButtonStyle: ButtonStyle {
    var primary = false
    var tint = DialogPalette.sage
    func makeBody(configuration: Configuration) -> some View {
        ToolbarSurface(configuration: configuration, primary: primary, tint: tint)
    }
    private struct ToolbarSurface: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        private var active: Bool { enabled && (hovered || configuration.isPressed) }
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? .white : DialogPalette.ink)
                .padding(.horizontal, 12).frame(height: DialogPalette.controlHeight)
                .background(primary ? tint.opacity(active ? 0.86 : 1) : active ? tint.opacity(0.10) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : tint.opacity(active ? 0.28 : 0.17)).allowsHitTesting(false))
                .contentShape(Rectangle()).opacity(enabled ? 1 : 0.42)
                .scaleEffect(enabled && hovered && configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .onHover { inside in hovered = inside; if inside && enabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                .onDisappear { if hovered { NSCursor.arrow.set() } }
        }
    }
}

struct DialogAnswerModePicker: View {
    @Binding var automatic: Bool
    var body: some View {
        HStack(spacing: 0) {
            option("Автоответ", value: true)
            option("По клавише", value: false)
        }.frame(height: DialogPalette.controlHeight)
            .background(DialogPalette.sage.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DialogPalette.sage.opacity(0.16)).allowsHitTesting(false))
            .accessibilityElement(children: .contain).accessibilityLabel("Режим ответа").accessibilityIdentifier("answer.mode")
    }
    private func option(_ title: String, value: Bool) -> some View {
        Button { automatic = value } label: { Text(title).font(.system(size: 12, weight: .medium)).frame(width: 94, height: DialogPalette.controlHeight).contentShape(Rectangle()) }
            .buttonStyle(ModeOptionStyle(selected: automatic == value))
            .accessibilityAddTraits(automatic == value ? [.isSelected] : [])
            .accessibilityIdentifier(value ? "answer.mode.auto" : "answer.mode.manual")
    }
    private struct ModeOptionStyle: ButtonStyle {
        let selected: Bool
        func makeBody(configuration: Configuration) -> some View { ModeSurface(configuration: configuration, selected: selected) }
        private struct ModeSurface: View {
            let configuration: ButtonStyle.Configuration
            let selected: Bool
            @Environment(\.isEnabled) private var enabled
            @State private var hovered = false
            var body: some View {
                configuration.label
                    .foregroundStyle(selected ? .white : DialogPalette.sage)
                    .background(selected ? DialogPalette.sage.opacity(configuration.isPressed ? 0.82 : 1) : DialogPalette.sage.opacity(hovered || configuration.isPressed ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle()).opacity(enabled ? 1 : 0.42)
                    .onHover { inside in hovered = inside; if inside && enabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                    .onDisappear { if hovered { NSCursor.arrow.set() } }
            }
        }
    }
}
