#!/usr/bin/env swift
import AppKit
import Foundation

// MARK: - Audio Converter app icon generator

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let iconset = root.appendingPathComponent("AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Assets/AppIcon.icns")
let previewURL = root.appendingPathComponent("Assets/AppIcon-1024.png")

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = size
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let corner = s * 0.223
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.01, dy: s * 0.01), xRadius: corner, yRadius: corner)

    // Background — deep indigo → teal (audio / conversion feel)
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.06, green: 0.10, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.28, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.45, blue: 0.48, alpha: 1),
    ])!
    bg.draw(in: path, angle: -48)

    // Soft vignette
    let vignette = NSGradient(
        colors: [
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32),
        ],
        atLocations: [0.42, 1.0],
        colorSpace: .sRGB
    )!
    vignette.draw(in: path, relativeCenterPosition: .zero)

    // Glass highlight arc at top
    let hiPath = NSBezierPath()
    hiPath.move(to: NSPoint(x: s * 0.12, y: s * 0.78))
    hiPath.curve(
        to: NSPoint(x: s * 0.88, y: s * 0.78),
        controlPoint1: NSPoint(x: s * 0.30, y: s * 0.96),
        controlPoint2: NSPoint(x: s * 0.70, y: s * 0.96)
    )
    hiPath.curve(
        to: NSPoint(x: s * 0.12, y: s * 0.78),
        controlPoint1: NSPoint(x: s * 0.70, y: s * 0.72),
        controlPoint2: NSPoint(x: s * 0.30, y: s * 0.72)
    )
    hiPath.close()
    NSColor.white.withAlphaComponent(0.12).setFill()
    hiPath.fill()

    // --- Conversion ring (subtle) ---
    let ringCenter = NSPoint(x: s * 0.5, y: s * 0.52)
    let ringR = s * 0.34
    drawConversionRing(center: ringCenter, radius: ringR, lineWidth: max(1.5, s * 0.028), scale: s)

    // --- Waveform bars ---
    // Relative heights (0…1) for a recognizable equalizer shape
    let heights: [CGFloat] = [0.28, 0.48, 0.72, 0.95, 0.62, 0.40, 0.78, 0.52, 0.30]
    let barCount = heights.count
    let barAreaW = s * 0.46
    let barMaxH = s * 0.36
    let barGap = s * 0.012
    let barW = (barAreaW - barGap * CGFloat(barCount - 1)) / CGFloat(barCount)
    let barOriginX = s * 0.5 - barAreaW * 0.5
    let barMidY = s * 0.50

    // Soft glow behind waveform
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowBlurRadius = s * 0.06
    glow.shadowOffset = .zero
    glow.shadowColor = NSColor(srgbRed: 0.30, green: 0.95, blue: 0.90, alpha: 0.55)
    glow.set()

    for (i, h) in heights.enumerated() {
        let bh = max(barW * 1.2, barMaxH * h)
        let bx = barOriginX + CGFloat(i) * (barW + barGap)
        let by = barMidY - bh * 0.5
        let barRect = NSRect(x: bx, y: by, width: barW, height: bh)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barW * 0.45, yRadius: barW * 0.45)

        // Gradient fill per bar — cyan → mint
        let barGrad = NSGradient(colors: [
            NSColor(srgbRed: 0.45, green: 0.98, blue: 0.92, alpha: 1),
            NSColor(srgbRed: 0.25, green: 0.78, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.40, green: 0.55, blue: 1.00, alpha: 1),
        ])!
        barGrad.draw(in: barPath, angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Crisp bar overlays (no shadow) for sharpness at small sizes
    for (i, h) in heights.enumerated() {
        let bh = max(barW * 1.2, barMaxH * h)
        let bx = barOriginX + CGFloat(i) * (barW + barGap)
        let by = barMidY - bh * 0.5
        let barRect = NSRect(x: bx, y: by, width: barW, height: bh)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barW * 0.45, yRadius: barW * 0.45)
        let barGrad = NSGradient(colors: [
            NSColor(srgbRed: 0.55, green: 0.99, blue: 0.94, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.82, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.58, blue: 1.00, alpha: 1),
        ])!
        barGrad.draw(in: barPath, angle: 90)

        // Tiny top highlight on each bar
        let capH = min(bh * 0.22, barW * 0.9)
        let cap = NSRect(x: bx + barW * 0.15, y: by + bh - capH, width: barW * 0.70, height: capH)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: cap, xRadius: barW * 0.3, yRadius: barW * 0.3).fill()
    }

    // Format badges: small rounded chips bottom left / bottom right suggesting conversion
    drawFormatBadge(
        text: "IN",
        center: NSPoint(x: s * 0.24, y: s * 0.20),
        scale: s,
        fill: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.38, alpha: 0.92)
    )
    drawFormatBadge(
        text: "OUT",
        center: NSPoint(x: s * 0.76, y: s * 0.20),
        scale: s,
        fill: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.48, alpha: 0.95)
    )

    // Arrow between badges
    drawSmallArrow(
        from: NSPoint(x: s * 0.36, y: s * 0.20),
        to: NSPoint(x: s * 0.64, y: s * 0.20),
        scale: s
    )

    // Outer rim
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let rim = NSBezierPath(
        roundedRect: rect.insetBy(dx: s * 0.015, dy: s * 0.015),
        xRadius: corner * 0.95,
        yRadius: corner * 0.95
    )
    rim.lineWidth = max(1, s * 0.006)
    rim.stroke()

    return image
}

func drawConversionRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, scale s: CGFloat) {
    // Two open arcs with arrowheads — circular “convert” motion
    let stroke = NSColor(srgbRed: 0.55, green: 0.90, blue: 1.0, alpha: 0.55)

    func arc(start: CGFloat, end: CGFloat) {
        let p = NSBezierPath()
        p.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        stroke.setStroke()
        p.stroke()

        // Arrowhead at end angle
        let rad = end * .pi / 180
        let tip = NSPoint(
            x: center.x + radius * cos(rad),
            y: center.y + radius * sin(rad)
        )
        // Tangent direction (counter-clockwise)
        let tx = -sin(rad)
        let ty = cos(rad)
        let head = max(3, s * 0.035)
        let left = NSPoint(
            x: tip.x - tx * head - ty * head * 0.55,
            y: tip.y - ty * head + tx * head * 0.55
        )
        let right = NSPoint(
            x: tip.x - tx * head + ty * head * 0.55,
            y: tip.y - ty * head - tx * head * 0.55
        )
        let headPath = NSBezierPath()
        headPath.move(to: tip)
        headPath.line(to: left)
        headPath.line(to: right)
        headPath.close()
        stroke.setFill()
        headPath.fill()
    }

    // Upper-right arc and lower-left arc
    arc(start: 20, end: 150)
    arc(start: 200, end: 330)
}

func drawFormatBadge(text: String, center: NSPoint, scale s: CGFloat, fill: NSColor) {
    let fontSize = max(8, s * 0.055)
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        .kern: 0.5,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let textSize = str.size()
    let padX = s * 0.028
    let padY = s * 0.014
    let badgeW = textSize.width + padX * 2
    let badgeH = textSize.height + padY * 2
    let badgeRect = NSRect(
        x: center.x - badgeW * 0.5,
        y: center.y - badgeH * 0.5,
        width: badgeW,
        height: badgeH
    )
    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH * 0.45, yRadius: badgeH * 0.45)

    // Shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.015
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    fill.setFill()
    badgePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    fill.setFill()
    badgePath.fill()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    badgePath.lineWidth = max(0.5, s * 0.004)
    badgePath.stroke()

    let textOrigin = NSPoint(
        x: center.x - textSize.width * 0.5,
        y: center.y - textSize.height * 0.5
    )
    str.draw(at: textOrigin)
}

func drawSmallArrow(from: NSPoint, to: NSPoint, scale s: CGFloat) {
    let color = NSColor(srgbRed: 0.55, green: 0.95, blue: 0.90, alpha: 0.85)
    let path = NSBezierPath()
    path.move(to: from)
    path.line(to: to)
    path.lineWidth = max(1.5, s * 0.018)
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()

    // Arrowhead
    let head = max(3, s * 0.028)
    let tip = to
    let left = NSPoint(x: tip.x - head, y: tip.y + head * 0.65)
    let right = NSPoint(x: tip.x - head, y: tip.y - head * 0.65)
    let headPath = NSBezierPath()
    headPath.move(to: tip)
    headPath.line(to: left)
    headPath.line(to: right)
    headPath.close()
    color.setFill()
    headPath.fill()
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "bitmap rep failed",
        ])
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "png encode failed",
        ])
    }
    try data.write(to: url)
}

// iconset sizes for macOS
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("diana.k@example.org", 32),
    ("icon_32x32.png", 32),
    ("ivan.p@example.net", 64),
    ("icon_128x128.png", 128),
    ("wendy.h@example.net", 256),
    ("icon_256x256.png", 256),
    ("wendy.h@example.net", 512),
    ("icon_512x512.png", 512),
    ("walt.e@example.net", 1024),
]

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

print("Rendering Audio Converter icon…")
for entry in sizes {
    let masterSize = max(entry.px, 512)
    let master = drawIcon(size: CGFloat(masterSize))
    let out = iconset.appendingPathComponent(entry.name)
    try writePNG(master, to: out, pixelSize: entry.px)
    print("  \(entry.name) (\(entry.px)px)")
}

try writePNG(drawIcon(size: 1024), to: previewURL, pixelSize: 1024)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr)
    exit(1)
}

// Also place icns next to iconset for build-app.sh convenience
let rootIcns = root.appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: rootIcns)
try FileManager.default.copyItem(at: icnsURL, to: rootIcns)

print("Wrote \(icnsURL.path)")
print("Wrote \(previewURL.path)")
print("Wrote \(rootIcns.path)")
