#!/usr/bin/env swift
// Draws the Minutes app icon and writes Resources/AppIcon.icns.
//
// Concept: meeting notes from speech. A white note card on an indigo-to-violet squircle; a
// colourful waveform sits above three grey text lines. Shapes are deliberately few and thick so
// the icon still reads at 16-32 px.
//
// Usage: swift scripts/make-icon.swift [outdir]
//   Writes <outdir>/AppIcon.iconset (all standard sizes) and <outdir>/AppIcon-1024.png, then runs
//   iconutil to produce Resources/AppIcon.icns. outdir defaults to a temporary directory.
import AppKit
import Foundation

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple-style continuous-corner rectangle, approximated by a superellipse in each corner.
func squircle(_ r: CGRect, radius: CGFloat, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 64
    // Corner centres, walking counter-clockwise starting at the bottom-right corner.
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - radius, y: r.minY + radius), -.pi / 2),
        (CGPoint(x: r.maxX - radius, y: r.maxY - radius), 0),
        (CGPoint(x: r.minX + radius, y: r.maxY - radius), .pi / 2),
        (CGPoint(x: r.minX + radius, y: r.minY + radius), .pi),
    ]
    for (i, (c, start)) in corners.enumerated() {
        for s in 0...steps {
            let t = start + CGFloat(s) / CGFloat(steps) * (.pi / 2)
            let ct = cos(t), st = sin(t)
            let x = c.x + radius * copysign(pow(abs(ct), 2 / n), ct)
            let y = c.y + radius * copysign(pow(abs(st), 2 / n), st)
            if i == 0 && s == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Level of detail. Small renders get fewer, thicker shapes so they stay crisp instead of blurring.
enum Detail { case full, small, tiny }

func drawIcon(_ ctx: CGContext, detail: Detail) {
    // Apple icon grid: 824 pt body centred on the 1024 canvas, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 230, exponent: 4)

    // Body with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x3B2A9E)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo (bottom left) to violet/magenta (top right).
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    linearGradient(ctx, [color(0x2A2F9E), color(0x5B3FD6), color(0xA24BE0)],
                   from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY))
    // Gentle top highlight for depth.
    linearGradient(ctx, [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)],
                   from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.midY))
    ctx.restoreGState()

    // Note card.
    let card = CGRect(x: 262, y: 200, width: 500, height: 624)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 52, cornerHeight: 52, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x140A50, 0.45))
    ctx.addPath(cardPath); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cardPath); ctx.clip()
    linearGradient(ctx, [color(0xFFFFFF), color(0xF1EEFB)],
                   from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY))
    ctx.restoreGState()

    // Waveform: rounded bars, symmetric around a centre line, coloured by a warm-to-cool gradient.
    let (heights, barWidth, gap): ([CGFloat], CGFloat, CGFloat) = switch detail {
    case .full: ([0.30, 0.62, 1.0, 0.72, 0.42, 0.82, 0.50], 44, 20)
    case .small: ([0.45, 1.0, 0.62, 0.88, 0.45], 64, 32)
    case .tiny: ([0.55, 1.0, 0.70], 96, 64)
    }
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let waveCentreY: CGFloat = 640, maxHeight: CGFloat = 240
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = card.midX - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
        let height = max(barWidth, h * maxHeight)
        bars.addRoundedRect(in: CGRect(x: x, y: waveCentreY - height / 2, width: barWidth, height: height),
                            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
    }
    ctx.saveGState()
    ctx.addPath(bars); ctx.clip()
    linearGradient(ctx, [color(0xFF6A5C), color(0xFF3D9A), color(0x8A4DFF), color(0x3F7BFF)],
                   from: CGPoint(x: card.midX - totalWidth / 2, y: 0), to: CGPoint(x: card.midX + totalWidth / 2, y: 0))
    ctx.restoreGState()

    // Text lines.
    let (lineHeight, lines, lineColor): (CGFloat, [(y: CGFloat, width: CGFloat)], UInt32) = switch detail {
    case .full: (34, [(430, 372), (350, 372), (270, 236)], 0xC3BDD9)
    case .small: (48, [(416, 372), (304, 248)], 0xA8A0CC)
    case .tiny: (64, [(400, 372), (272, 248)], 0x9890C2)
    }
    let left = card.midX - 186
    ctx.setFillColor(color(lineColor))
    for line in lines {
        ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: line.y, width: line.width, height: lineHeight),
                           cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
    }
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx, detail: size <= 16 ? .tiny : size <= 32 ? .small : .full)
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : FileManager.default.temporaryDirectory.appendingPathComponent("minutes-icon")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each size is drawn directly at its pixel size (vector), not downscaled from 1024.
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

let icns = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)\nPreview: \(outDir.appendingPathComponent("AppIcon-1024.png").path)")
