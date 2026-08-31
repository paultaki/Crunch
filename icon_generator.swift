#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Background: rich indigo-to-deep-blue gradient
    let bgColors = [
        CGColor(red: 0.35, green: 0.22, blue: 0.82, alpha: 1.0),
        CGColor(red: 0.18, green: 0.12, blue: 0.55, alpha: 1.0)
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: bgColors as CFArray,
        locations: [0.0, 1.0]
    )!

    // macOS icon shape: rounded rect
    let iconRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22
    let path = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])

    // Subtle inner glow at top
    let glowColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.15),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ]
    let glowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: glowColors as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(glowGrad, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: s * 0.55), options: [])

    // Draw two chevrons pointing inward (compression symbol)
    let lineWidth = s * 0.055
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cx = s / 2
    let cy = s / 2
    let chevronW = s * 0.22
    let chevronH = s * 0.13
    let gap = s * 0.1

    // Top chevron (pointing down)
    let topY = cy + gap
    ctx.move(to: CGPoint(x: cx - chevronW, y: topY + chevronH))
    ctx.addLine(to: CGPoint(x: cx, y: topY))
    ctx.addLine(to: CGPoint(x: cx + chevronW, y: topY + chevronH))
    ctx.strokePath()

    // Bottom chevron (pointing up)
    let botY = cy - gap
    ctx.move(to: CGPoint(x: cx - chevronW, y: botY - chevronH))
    ctx.addLine(to: CGPoint(x: cx, y: botY))
    ctx.addLine(to: CGPoint(x: cx + chevronW, y: botY - chevronH))
    ctx.strokePath()

    // Left bracket
    let bracketInset = s * 0.22
    let bracketH = s * 0.3
    let bracketW = s * 0.08
    ctx.setLineWidth(lineWidth * 0.85)

    // Left [
    ctx.move(to: CGPoint(x: bracketInset + bracketW, y: cy + bracketH))
    ctx.addLine(to: CGPoint(x: bracketInset, y: cy + bracketH))
    ctx.addLine(to: CGPoint(x: bracketInset, y: cy - bracketH))
    ctx.addLine(to: CGPoint(x: bracketInset + bracketW, y: cy - bracketH))
    ctx.strokePath()

    // Right ]
    ctx.move(to: CGPoint(x: s - bracketInset - bracketW, y: cy + bracketH))
    ctx.addLine(to: CGPoint(x: s - bracketInset, y: cy + bracketH))
    ctx.addLine(to: CGPoint(x: s - bracketInset, y: cy - bracketH))
    ctx.addLine(to: CGPoint(x: s - bracketInset - bracketW, y: cy - bracketH))
    ctx.strokePath()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else { return }
    try? pngData.write(to: URL(fileURLWithPath: path))
}

// Generate iconset
let iconsetPath = "/tmp/Crunch.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for entry in sizes {
    let image = renderIcon(size: entry.size)
    savePNG(image, to: "\(iconsetPath)/\(entry.name).png")
    print("Generated \(entry.name).png (\(entry.size)x\(entry.size))")
}

print("Iconset created at \(iconsetPath)")
