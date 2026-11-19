import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.24, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 210, yRadius: 210).fill()
NSColor(calibratedRed: 0.90, green: 0.95, blue: 0.82, alpha: 1).setStroke()
let path = NSBezierPath()
path.lineWidth = 48; path.lineCapStyle = .round; path.lineJoinStyle = .round
path.move(to: NSPoint(x: 245, y: 290)); path.line(to: NSPoint(x: 770, y: 290))
path.move(to: NSPoint(x: 315, y: 290)); path.line(to: NSPoint(x: 420, y: 725)); path.line(to: NSPoint(x: 670, y: 725)); path.line(to: NSPoint(x: 670, y: 290))
path.move(to: NSPoint(x: 245, y: 290)); path.line(to: NSPoint(x: 245, y: 175))
path.move(to: NSPoint(x: 770, y: 290)); path.line(to: NSPoint(x: 770, y: 175)); path.stroke()
NSColor(calibratedRed: 0.72, green: 0.83, blue: 0.53, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 800, y: 800, width: 110, height: 110)).fill()
image.unlockFocus()
let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
