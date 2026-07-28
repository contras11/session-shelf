import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("出力先PNGを指定してください\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
guard let representation = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: representation) else {
    fputs("描画領域を生成できませんでした\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

// Finderで小さく表示しても形が残る、棚と会話カードの意匠。
let backgroundRect = NSRect(x: 76, y: 76, width: 872, height: 872)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 190, yRadius: 190)
NSColor(calibratedRed: 0.94, green: 0.91, blue: 0.82, alpha: 1).setFill()
background.fill()

let ink = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1)
ink.setFill()

for y in [304.0, 506.0, 708.0] {
    let shelf = NSBezierPath(roundedRect: NSRect(x: 218, y: y, width: 588, height: 50), xRadius: 25, yRadius: 25)
    shelf.fill()
}

let cards: [(NSRect, NSColor)] = [
    (NSRect(x: 270, y: 355, width: 210, height: 122), NSColor(calibratedRed: 0.41, green: 0.55, blue: 0.49, alpha: 1)),
    (NSRect(x: 515, y: 355, width: 238, height: 122), NSColor(calibratedRed: 0.77, green: 0.43, blue: 0.31, alpha: 1)),
    (NSRect(x: 270, y: 557, width: 292, height: 122), NSColor(calibratedRed: 0.32, green: 0.42, blue: 0.58, alpha: 1)),
    (NSRect(x: 598, y: 557, width: 155, height: 122), NSColor(calibratedRed: 0.55, green: 0.46, blue: 0.61, alpha: 1))
]

for (rect, color) in cards {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34).fill()
    NSColor.white.withAlphaComponent(0.82).setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX + 34, y: rect.midY + 9, width: rect.width - 68, height: 16), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX + 34, y: rect.midY - 27, width: (rect.width - 68) * 0.66, height: 16), xRadius: 8, yRadius: 8).fill()
}

guard let png = representation.representation(using: .png, properties: [:]) else {
    fputs("アイコンPNGを生成できませんでした\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
