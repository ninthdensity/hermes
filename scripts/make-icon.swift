#!/usr/bin/env swift
import AppKit

// Fill the macOS icon tile with the supplied artwork, with no inner padding or backing plate.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Logo.png")
let logo = NSImage(contentsOf: source)!
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let size = CGFloat(pixels)
        let tile = NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
        // A finished rounded silhouette prevents macOS from presenting a small square
        // image inside its own generic icon plate. The artwork reaches every tile edge.
        NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).addClip()
        let imageScale = max(tile.width / logo.size.width, tile.height / logo.size.height)
        let width = logo.size.width * imageScale
        let height = logo.size.height * imageScale
        logo.draw(in: NSRect(x: tile.midX - width / 2, y: tile.midY - height / 2, width: width, height: height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let output = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: output)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Resources/AppIcon.icns from Resources/Logo.png")
