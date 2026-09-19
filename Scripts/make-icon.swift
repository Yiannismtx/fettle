// Renders Fettle's app icon.
//
// Generated rather than checked in as a binary, so the design is reviewable in
// a diff. Follows the macOS icon shape: a squircle with a soft top-down
// gradient, a bright top edge where light catches it, and one glyph that stays
// legible at 16pt.
import AppKit
import CoreGraphics

let size = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let context = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("couldn't make a bitmap context") }

// macOS icons sit inside the canvas rather than filling it.
let inset = CGFloat(size) * 0.085
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let squircle = CGPath(
    roundedRect: rect,
    cornerWidth: rect.width * 0.225,
    cornerHeight: rect.height * 0.225,
    transform: nil
)

// Drop shadow under the tile.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -CGFloat(size) * 0.012),
    blur: CGFloat(size) * 0.03,
    color: NSColor.black.withAlphaComponent(0.35).cgColor
)
context.addPath(squircle)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

// Body: a top-down gradient. Green for "in good condition", which is what the
// name means, deepening towards the bottom so the tile reads as a solid object.
context.saveGState()
context.addPath(squircle)
context.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        NSColor(srgbRed: 0.42, green: 0.85, blue: 0.62, alpha: 1).cgColor,
        NSColor(srgbRed: 0.16, green: 0.62, blue: 0.53, alpha: 1).cgColor,
        NSColor(srgbRed: 0.08, green: 0.38, blue: 0.44, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 0.55, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: rect.maxY),
    end: CGPoint(x: 0, y: rect.minY),
    options: []
)

// A bright edge along the top, where light catches the material.
context.setLineWidth(CGFloat(size) * 0.006)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
context.addPath(squircle)
context.strokePath()
context.restoreGState()

// The glyph: sparkles, the clearest available shorthand for "tidied up", and
// one shape rather than two so it survives being drawn at 16pt.
let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.46, weight: .semibold)
guard let baseSymbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil),
      let symbol = baseSymbol.withSymbolConfiguration(configuration) else {
    fatalError("couldn't load the symbol")
}
symbol.isTemplate = true

let glyphRect = CGRect(
    x: rect.midX - symbol.size.width / 2,
    y: rect.midY - symbol.size.height / 2,
    width: symbol.size.width,
    height: symbol.size.height
)

// A template symbol draws in its own colour, not the context's fill colour, so
// tint it first by filling its own alpha.
let whiteGlyph = NSImage(size: symbol.size, flipped: false) { bounds in
    symbol.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    bounds.fill(using: .sourceAtop)
    return true
}

let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext
// A soft shadow lifts the glyph off the gradient without muddying it.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = CGFloat(size) * 0.022
shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.009)
shadow.set()
whiteGlyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage() else { fatalError("couldn't render") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("couldn't encode PNG")
}
try! data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
