import SwiftUI
import AppKit

struct ConversationSplitView: View {
    @AppStorage("dialog.transcriptWidth") private var preferredWidth = 310.0
    @State private var dragStartWidth: CGFloat?
    @State private var draggedWidth: CGFloat?
    @State private var hovered = false
    @FocusState private var dividerFocused: Bool

    private let dividerWidth: CGFloat = 18
    private let minimumAnswerWidth: CGFloat = 380
    private let minimumTranscriptWidth: CGFloat = 260
    private let tint = Color(red: 0.33, green: 0.44, blue: 0.27)

    var body: some View {
        GeometryReader { geometry in
            let maximumWidth = max(minimumTranscriptWidth, geometry.size.width - dividerWidth - minimumAnswerWidth)
            let width = bounded(draggedWidth ?? preferredWidth, maximum: maximumWidth)

            HStack(spacing: 0) {
                AnswerView()
                    .frame(width: max(0, geometry.size.width - dividerWidth - width))
                    .frame(maxHeight: .infinity)
                divider(width: width, maximum: maximumWidth)
                TranscriptView()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
            }
            .coordinateSpace(name: "conversation.panels")
        }
    }

    private func divider(width: CGFloat, maximum: CGFloat) -> some View {
        Capsule()
            .fill(tint.opacity(hovered || dragStartWidth != nil || dividerFocused ? 0.65 : 0.22))
            .frame(width: 3, height: 32)
            .frame(width: dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                updateCursor()
            }
            .onDisappear { if hovered || dragStartWidth != nil { NSCursor.arrow.set() } }
            .onTapGesture(count: 2) { preferredWidth = 310 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("conversation.panels"))
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        draggedWidth = bounded((dragStartWidth ?? width) - value.translation.width, maximum: maximum)
                        NSCursor.resizeLeftRight.set()
                    }
                    .onEnded { value in
                        preferredWidth = bounded((dragStartWidth ?? width) - value.translation.width, maximum: maximum)
                        draggedWidth = nil
                        dragStartWidth = nil
                        updateCursor()
                    }
            )
            .focusable()
            .focused($dividerFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { preferredWidth = bounded(width + 24, maximum: maximum); return .handled }
            .onKeyPress(.rightArrow) { preferredWidth = bounded(width - 24, maximum: maximum); return .handled }
            .accessibilityElement()
            .accessibilityLabel("Ширина диалога")
            .accessibilityValue("\(Int(width)) пунктов")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: preferredWidth = bounded(width + 24, maximum: maximum)
                case .decrement: preferredWidth = bounded(width - 24, maximum: maximum)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("conversation.divider")
            .help("Перетащи, чтобы изменить ширину. Двойной щелчок — сброс.")
    }

    private func bounded(_ width: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(width, minimumTranscriptWidth), maximum)
    }

    private func updateCursor() {
        if hovered || dragStartWidth != nil { NSCursor.resizeLeftRight.set() }
        else { NSCursor.arrow.set() }
    }
}
