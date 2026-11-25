import AppKit
import Foundation

// App icon: the sidebar logo (accent quote bubble) on a navy backdrop.

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)! }

let accent = (r: CGFloat(0.42), g: CGFloat(0.62), b: CGFloat(1.00))
let center = CGPoint(x: 512, y: 512)

// macOS icon grid: 824 pt body with a drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(squircle); ctx.setFillColor(rgb(0.043, 0.051, 0.078)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Backdrop: the window gradient plus the blue and teal glows.
ctx.drawLinearGradient(gradient([rgb(0.165, 0.190, 0.380), rgb(0.060, 0.068, 0.140)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
func glow(_ c: (CGFloat, CGFloat, CGFloat), at p: CGPoint, radius: CGFloat, alpha: CGFloat) {
    ctx.drawRadialGradient(gradient([rgb(c.0, c.1, c.2, alpha), rgb(c.0, c.1, c.2, 0)], [0, 1]),
                           startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}
glow((0.28, 0.36, 0.90), at: CGPoint(x: 230, y: 880), radius: 620, alpha: 0.40)
glow((0.08, 0.52, 0.66), at: CGPoint(x: 880, y: 130), radius: 520, alpha: 0.22)

// The sidebar logo: the accent quote bubble.
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.26, alpha: 1), NSColor(calibratedRed: accent.r, green: accent.g, blue: accent.b, alpha: 1)]))
if let symbol = NSImage(systemSymbolName: "quote.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    let rect = CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2 + 6, width: s.width, height: s.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 48, color: rgb(0.10, 0.20, 0.70, 0.75))
    symbol.draw(in: rect)
    ctx.restoreGState()
    // Light from above across the bubble, kept inside the symbol shape.
    let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    ctx.saveGState()
    ctx.clip(to: rect, mask: mask)
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)], [0, 1]),
                           start: CGPoint(x: 512, y: rect.maxY), end: CGPoint(x: 512, y: rect.midY - 40), options: [])
    ctx.restoreGState()
}

// Hairline edge on the squircle.
ctx.addPath(squircle); ctx.setLineWidth(4); ctx.setStrokeColor(rgb(1, 1, 1, 0.12)); ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
