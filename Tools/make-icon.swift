// Generates Resources/AppIcon.icns: a flat flame on a dark rounded square.
// Run from the repo root:  swift Tools/make-icon.swift
// The flame is our own path (SF Symbols may not be used in app icons).
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")

/// Flame outline in a y-up unit box. Bulbous base, a shoulder on the left,
/// tip leaning right, and a teardrop cut out of the core.
func flamePath(in box: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }
    let path = CGMutablePath()
    // outer
    path.move(to: p(0.60, 1.00))
    path.addCurve(to: p(0.82, 0.30), control1: p(0.70, 0.80), control2: p(0.82, 0.58))
    path.addCurve(to: p(0.50, 0.00), control1: p(0.82, 0.12), control2: p(0.68, 0.00))
    path.addCurve(to: p(0.18, 0.30), control1: p(0.32, 0.00), control2: p(0.18, 0.12))
    path.addCurve(to: p(0.28, 0.66), control1: p(0.18, 0.50), control2: p(0.20, 0.60))
    path.addCurve(to: p(0.60, 1.00), control1: p(0.36, 0.72), control2: p(0.50, 0.74))
    path.closeSubpath()
    // inner cutout
    path.move(to: p(0.50, 0.54))
    path.addCurve(to: p(0.66, 0.25), control1: p(0.59, 0.43), control2: p(0.66, 0.35))
    path.addCurve(to: p(0.50, 0.10), control1: p(0.66, 0.16), control2: p(0.59, 0.10))
    path.addCurve(to: p(0.34, 0.25), control1: p(0.41, 0.10), control2: p(0.34, 0.16))
    path.addCurve(to: p(0.50, 0.54), control1: p(0.34, 0.35), control2: p(0.41, 0.43))
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the tile is ~80% of the canvas, corners ~22.5% of the tile.
    let tile = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let radius = tile.width * 0.225
    let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [CGColor(srgbRed: 0.165, green: 0.165, blue: 0.19, alpha: 1),
                                 CGColor(srgbRed: 0.075, green: 0.075, blue: 0.09, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // flame, warm gradient, lighter at the top
    let box = CGRect(x: s * 0.26, y: s * 0.19, width: s * 0.48, height: s * 0.62)
    ctx.saveGState()
    ctx.addPath(flamePath(in: box))
    ctx.clip(using: .evenOdd)
    let fire = CGGradient(colorsSpace: space,
                          colors: [CGColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1),
                                   CGColor(srgbRed: 1.0, green: 0.36, blue: 0.18, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(fire, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(icns.path)" : "iconutil failed (\(iconutil.terminationStatus))")
