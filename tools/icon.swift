#!/usr/bin/env swift
// Generates the sonyTether app icon (.icns) with CoreGraphics.
// Usage: swift tools/icon.swift <output.icns>
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let outURL = URL(fileURLWithPath: outPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, alpha])!
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], _ locations: [CGFloat],
              from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                       locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
}

func fillPath(_ ctx: CGContext, _ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
    ctx.addPath(path)
    ctx.setFillColor(color(hex, alpha))
    ctx.fillPath()
}

func strokeCircle(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat,
                  _ width: CGFloat, _ hex: UInt32, alpha: CGFloat = 1) {
    ctx.setStrokeColor(color(hex, alpha))
    ctx.setLineWidth(width)
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.strokePath()
}

/// Draw the whole icon in a `size × size` box, origin bottom-left.
func drawIcon(_ ctx: CGContext, size s: CGFloat) {
    let squircle = CGPath(
        roundedRect: CGRect(x: s * 0.012, y: s * 0.012, width: s * 0.976, height: s * 0.976),
        cornerWidth: s * 0.235, cornerHeight: s * 0.235, transform: nil
    )

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    gradient(ctx,
             [color(0x2C3C51), color(0x151E2A), color(0x070A10)],
             [0, 0.55, 1],
             from: CGPoint(x: s * 0.18, y: s * 1.0),
             to: CGPoint(x: s * 0.86, y: s * 0.0))

    let center = CGPoint(x: s * 0.485, y: s * 0.535)
    let ringR = s * 0.330
    let barrelR = s * 0.278
    let glassR = s * 0.252
    let holeR = s * 0.098

    // White lens ring
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR,
                              width: ringR * 2, height: ringR * 2))
    ctx.clip()
    gradient(ctx,
             [color(0xFFFFFF), color(0xDCE3EC), color(0x9AA7B6)],
             [0, 0.55, 1],
             from: CGPoint(x: center.x - ringR, y: center.y + ringR),
             to: CGPoint(x: center.x + ringR, y: center.y - ringR))
    ctx.restoreGState()

    // Barrel
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - barrelR, y: center.y - barrelR,
                              width: barrelR * 2, height: barrelR * 2))
    ctx.clip()
    gradient(ctx,
             [color(0x0A0E14), color(0x202C3B)],
             [0, 1],
             from: CGPoint(x: center.x, y: center.y + barrelR),
             to: CGPoint(x: center.x, y: center.y - barrelR))
    ctx.restoreGState()

    // Glass rim
    ctx.setStrokeColor(color(0x3C4C61, 0.9))
    ctx.setLineWidth(max(1, s * 0.003))
    ctx.addEllipse(in: CGRect(x: center.x - glassR, y: center.y - glassR,
                              width: glassR * 2, height: glassR * 2))
    ctx.strokePath()

    func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    // Iris: six blades between the glass rim and the aperture opening.
    let step = CGFloat.pi / 3
    for i in 0..<6 {
        let a0 = CGFloat(i) * step - .pi / 2
        let a1 = a0 + step
        let blade = CGMutablePath()
        blade.move(to: point(glassR, a0))
        blade.addArc(center: center, radius: glassR, startAngle: a0, endAngle: a1, clockwise: false)
        blade.addLine(to: point(holeR, a1))
        blade.addLine(to: point(holeR, a0))
        blade.closeSubpath()

        let shade: CGFloat = i % 2 == 0 ? 1.0 : 0.80
        ctx.addPath(blade)
        ctx.setFillColor(color(0x000000, 0))
        ctx.drawPath(using: .fill)

        ctx.saveGState()
        ctx.addPath(blade)
        ctx.clip()
        gradient(ctx,
                 [color(0x40546D, 0.98 * shade), color(0x18212C, 0.98)],
                 [0, 1],
                 from: point(glassR, a1 + .pi / 6),
                 to: point(holeR, a1 - .pi))
        ctx.restoreGState()

        ctx.addPath(blade)
        ctx.setStrokeColor(color(0x080C12, 0.75))
        ctx.setLineWidth(max(1, s * 0.0035))
        ctx.strokePath()
    }

    // Aperture opening
    let opening = CGMutablePath()
    for i in 0..<6 {
        let a = CGFloat(i) * step - .pi / 2
        let p = point(holeR, a)
        if i == 0 { opening.move(to: p) } else { opening.addLine(to: p) }
    }
    opening.closeSubpath()
    ctx.saveGState()
    ctx.addPath(opening)
    ctx.clip()
    gradient(ctx,
             [color(0x9FEBFF), color(0x46A2F2), color(0x114478)],
             [0, 0.5, 1],
             from: point(holeR, .pi / 2),
             to: point(holeR, -.pi / 2))
    ctx.restoreGState()
    ctx.addPath(opening)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(max(1, s * 0.0025))
    ctx.strokePath()

    // Status LED, top right of the body.
    let led = CGPoint(x: s * 0.825, y: s * 0.830)
    let ledR = s * 0.033
    ctx.setFillColor(color(0x000000, 0.28))
    ctx.fillEllipse(in: CGRect(x: led.x - ledR * 1.3, y: led.y - ledR * 1.45,
                               width: ledR * 2.6, height: ledR * 2.6))
    ctx.setFillColor(color(0x5BF08F))
    ctx.fillEllipse(in: CGRect(x: led.x - ledR, y: led.y - ledR,
                               width: ledR * 2, height: ledR * 2))
    ctx.restoreGState() // squircle clip

    // Inner hairline
    let inset = CGPath(
        roundedRect: CGRect(x: s * 0.026, y: s * 0.026, width: s * 0.948, height: s * 0.948),
        cornerWidth: s * 0.222, cornerHeight: s * 0.222, transform: nil
    )
    ctx.addPath(inset)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()
}

func renderPNG(pixels: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(ctx, size: CGFloat(pixels))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let data = renderPNG(pixels: px)
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}

// Keep a 1024 preview next to the icon for the README.
let previewURL = fm.temporaryDirectory.appendingPathComponent("AppIcon-1024.png")
try! renderPNG(pixels: 1024).write(to: previewURL)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", outURL.path]
try! proc.run()
proc.waitUntilExit()
try? fm.removeItem(at: iconset)

let msg = "icon written to \(outURL.path)"
if proc.terminationStatus == 0 {
    print(msg)
} else {
    print("iconutil failed (\(proc.terminationStatus))")
    exit(1)
}
