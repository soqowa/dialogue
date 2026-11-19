import SwiftUI

/// Liquid Glass helpers. On macOS 26+ they use the system glass material;
/// older systems get a frosted material with a specular edge so the app keeps
/// the same shape language down to the macOS 14 deployment target.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(dialogGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.55)) }
                    }
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    ).allowsHitTesting(false)
                }
        }
    }
}

@available(macOS 26.0, *)
private func dialogGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

/// Groups neighbouring glass shapes so they sample one backdrop and blend
/// into each other the way system toolbars do.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Hairline separator for use inside glass panels.
struct GlassDivider: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(DialogPalette.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// Dark backdrop with soft coloured light behind the glass. Glass needs
/// something to refract; a flat black window would make it look grey.
struct DialogBackdrop: View {
    var compact = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = compact ? 0.7 : 1.0
            ZStack {
                LinearGradient(colors: [Color(red: 0.055, green: 0.063, blue: 0.094),
                                        Color(red: 0.030, green: 0.034, blue: 0.050)],
                               startPoint: .top, endPoint: .bottom)
                glow(Color(red: 0.28, green: 0.36, blue: 0.90), diameter: 700 * scale)
                    .position(x: size.width * 0.15, y: size.height * 0.06)
                    .opacity(0.32)
                glow(Color(red: 0.08, green: 0.52, blue: 0.66), diameter: 600 * scale)
                    .position(x: size.width * 0.92, y: size.height * 0.94)
                    .opacity(0.22)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .blur(radius: 40)
    }
}
