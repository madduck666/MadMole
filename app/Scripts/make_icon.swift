// Draws the MadMole app icon as a 1024x1024 PNG.
// Usage: swift make_icon.swift <output.png>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}

let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let size = CGFloat(pixels)

// The macOS icon grid: an 824pt rounded square centered on the canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.37, green: 0.36, blue: 0.90, alpha: 1),
    NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
    NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.45, alpha: 1),
])
gradient?.draw(in: shape, angle: -50)

// A soft glossy highlight on the upper half.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
highlight?.draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The mark: white sparkles.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .bold)
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    let white = NSImage(size: symbolSize)
    white.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
    white.unlockFocus()

    let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2 - 6)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glow.shadowBlurRadius = 18
    glow.shadowOffset = NSSize(width: 0, height: -8)
    glow.set()
    white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: arguments[1]))
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
