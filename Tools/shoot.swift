// Captures HeatWatch's panel as a single-window image (nothing else on screen
// is included) and composes it on a transparent canvas with a soft shadow and
// the menu-bar flame drawn above the arrow, where the status item sits.
// The status item is not a window the app owns on macOS 26, so the glyph is
// rendered here the way the menu bar renders it (template symbol, white).
// Usage:  shoot <out.png> [--no-shadow] [--no-icon] [--icon-black]
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: shoot <out.png> [--no-shadow] [--no-icon] [--icon-black]"); exit(2) }
let outURL = URL(fileURLWithPath: args[1])
let wantShadow = !args.contains("--no-shadow")
let wantIcon = !args.contains("--no-icon")
let iconColor: NSColor = args.contains("--icon-black") ? .black : .white

struct Win { let id: CGWindowID; let bounds: CGRect }

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("cannot list windows"); exit(1)
}
var wins: [Win] = []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "HeatWatch" {
    guard let id = w[kCGWindowNumber as String] as? CGWindowID,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
    wins.append(Win(id: id, bounds: CGRect(x: x, y: y, width: width, height: height)))
}
guard let panel = wins.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
      panel.bounds.height > 100 else {
    print("panel window not found — is the popover open?"); exit(1)
}

/// `screencapture -l` renders one window alone at the display's backing scale.
/// The PNG is read into memory before the temp file goes away — CGImageSource
/// decodes lazily, so a file-backed image would draw nothing later.
func grab(_ id: CGWindowID) -> CGImage? {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hw-\(id).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-l", String(id), "-o", "-x", "-t", "png", tmp.path]
    try? p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let data = try? Data(contentsOf: tmp),
          let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
}

guard let panelImage = grab(panel.id) else { print("capture failed (Screen Recording permission?)"); exit(1) }
let scale = CGFloat(panelImage.width) / panel.bounds.width

// Menu bar geometry: the status item sits centred above the popover's arrow.
let screen = NSScreen.main!
let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
let iconSize: CGFloat = 22
let iconRect = CGRect(x: panel.bounds.midX - iconSize / 2, y: (menuBarHeight - iconSize) / 2, width: iconSize, height: iconSize)

var union = panel.bounds
if wantIcon { union = union.union(iconRect) }
let margin: CGFloat = wantShadow ? 48 : 0
let canvas = CGSize(width: (union.width + 2 * margin) * scale, height: (union.height + 2 * margin) * scale)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

/// Screen coordinates are y-down from the top-left; CG draws y-up.
func dest(_ b: CGRect) -> CGRect {
    let x = (b.minX - union.minX + margin) * scale
    let top = (b.minY - union.minY + margin) * scale
    return CGRect(x: x, y: canvas.height - top - b.height * scale, width: b.width * scale, height: b.height * scale)
}

ctx.saveGState()
if wantShadow {
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38))
}
ctx.draw(panelImage, in: dest(panel.bounds))
ctx.restoreGState()

if wantIcon {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            iconColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        var proposed = CGRect(origin: .zero, size: symbol.size)
        if let glyph = tinted.cgImage(forProposedRect: &proposed, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) {
            // centre the glyph in the icon rect at its natural point size
            let g = CGRect(x: iconRect.midX - symbol.size.width / 2, y: iconRect.midY - symbol.size.height / 2,
                           width: symbol.size.width, height: symbol.size.height)
            ctx.draw(glyph, in: dest(g))
        }
    }
}

let result = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outURL.lastPathComponent)  \(result.width)×\(result.height)  panel \(Int(panel.bounds.width))×\(Int(panel.bounds.height))pt\(wantIcon ? " + icon" : "")")
