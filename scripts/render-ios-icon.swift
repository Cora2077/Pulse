import AppKit
import Foundation

// Opaque RGB graphics context. A three-channel NSBitmapImageRep cannot back an
// AppKit drawing context reliably; a nil context silently produced a black PNG.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSGradient(starting: NSColor(red: 0.035, green: 0.09, blue: 0.16, alpha: 1),
    ending: NSColor(red: 0.07, green: 0.17, blue: 0.28, alpha: 1))!
    .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)), angle: 60)
let path = NSBezierPath()
path.move(to: NSPoint(x: 155, y: 520)); path.line(to: NSPoint(x: 325, y: 520))
path.line(to: NSPoint(x: 410, y: 720)); path.line(to: NSPoint(x: 555, y: 280))
path.line(to: NSPoint(x: 675, y: 545)); path.line(to: NSPoint(x: 865, y: 545))
path.lineWidth = 66; path.lineCapStyle = .round; path.lineJoinStyle = .round
NSColor.white.setStroke(); path.stroke()
let blue = NSBezierPath()
blue.move(to: NSPoint(x: 675, y: 545)); blue.line(to: NSPoint(x: 865, y: 545))
blue.lineWidth = 66; blue.lineCapStyle = .round
NSColor(red: 0.26, green: 0.62, blue: 1, alpha: 1).setStroke(); blue.stroke()
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
guard !bitmap.hasAlpha, let center = bitmap.colorAt(x: size / 2, y: size / 2),
      center.redComponent + center.greenComponent + center.blueComponent > 0.05 else {
    fatalError("Icon rendering produced an invalid or blank surface")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Verified opaque RGB iPhone icon, 1024 × 1024")
