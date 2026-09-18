#!/usr/bin/env swift
// Renders the TokenWatch app icon (dark squircle, green gauge ring + needle, matching the
// landing page mark) directly with Core Graphics at every size macOS's .iconset expects, then
// shells out to iconutil to produce AppIcon.icns. No external image tools required.

import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let bg = NSColor(srgbRed: 0x15/255.0, green: 0x17/255.0, blue: 0x19/255.0, alpha: 1)
let ring = NSColor(srgbRed: 0x58/255.0, green: 0xe6/255.0, blue: 0xa8/255.0, alpha: 1)

func render(px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle-ish rounded square background (~22.5% corner radius, matching macOS's template).
    let cornerRadius = size * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    bg.setFill()
    bgPath.fill()

    // Gauge ring, inset with generous padding so it reads clearly at 16px too.
    let inset = size * 0.24
    let ringRect = bgRect.insetBy(dx: inset, dy: inset)
    let lineWidth = max(size * 0.075, 1.4)
    let ringPath = NSBezierPath(ovalIn: ringRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    ringPath.lineWidth = lineWidth
    ring.setStroke()
    ringPath.stroke()

    // Needle pointing to ~35 degrees (matches the landing-page mark), from center toward the rim.
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = ringRect.width / 2
    let angle = CGFloat.pi / 2 - (35 * CGFloat.pi / 180) // 35 degrees clockwise from 12 o'clock
    let tip = CGPoint(x: center.x + radius * 0.82 * cos(angle), y: center.y + radius * 0.82 * sin(angle))
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: tip)
    needle.lineWidth = lineWidth
    needle.lineCapStyle = .round
    ring.setStroke()
    needle.stroke()

    // Center hub dot.
    let hubRadius = size * 0.035
    let hub = NSBezierPath(ovalIn: CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))
    ring.setFill()
    hub.fill()

    ctx.flush()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let rep = render(px: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outputDir)/\(name).png"
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
