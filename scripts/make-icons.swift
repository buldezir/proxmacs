// Generates the web UI icons (web/public/icons) and the app icon (Resources/AppIcon.icns):
//
//   swift scripts/make-icons.swift
import AppKit
import SwiftUI

// Brand mark: a rounded square split diagonally, orange over graphite (see .brand-mark in app.css).
let orange = CGColor(srgbRed: 0xE5/255, green: 0x70/255, blue: 0, alpha: 1)
let graphite = CGColor(srgbRed: 0x2B/255, green: 0x2F/255, blue: 0x36/255, alpha: 1)

/// `markScale`: mark size relative to the canvas; `fullBleed`: square corners filling the canvas, for
/// platforms that crop icons to their own shape; `continuous`: the smoother corners of a macOS app icon.
func render(_ size: Int, markScale: CGFloat, fullBleed: Bool, continuous: Bool = false, to path: String) {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = s * markScale
    let rect = CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    let shape = continuous
        ? RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).path(in: rect).cgPath
        : CGPath(roundedRect: rect, cornerWidth: fullBleed ? 0 : side * 0.22, cornerHeight: fullBleed ? 0 : side * 0.22, transform: nil)
    ctx.addPath(shape); ctx.clip()
    ctx.setFillColor(graphite); ctx.fill(rect)
    // Top-left triangle (CoreGraphics origin is bottom-left).
    ctx.setFillColor(orange)
    ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); ctx.closePath(); ctx.fillPath()
    // Light separator between the halves.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(side * 0.045)
    ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path

let web = "\(root)/web/public/icons"
render(192, markScale: 0.92, fullBleed: false, to: "\(web)/icon-192.png")
render(512, markScale: 0.92, fullBleed: false, to: "\(web)/icon-512.png")
// Maskable: launchers crop to their own shape; any crop of the split still reads as the mark.
render(512, markScale: 1, fullBleed: true, to: "\(web)/icon-maskable-512.png")
// iOS rounds the corners itself and shows transparency as black.
render(180, markScale: 1, fullBleed: true, to: "\(web)/apple-touch-icon.png")
render(32, markScale: 0.94, fullBleed: false, to: "\(web)/favicon-32.png")

// The app icon, on Apple's grid: an 824-point shape on a 1024-point canvas. macOS crops an icon that fills
// the shape to its own; one that doesn't, it shrinks onto a grey tile.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset").path
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    render(size, markScale: 824.0 / 1024, fullBleed: false, continuous: true, to: "\(iconset)/icon_\(size)x\(size).png")
    render(size * 2, markScale: 824.0 / 1024, fullBleed: false, continuous: true, to: "\(iconset)/icon_\(size)x\(size)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", "\(root)/Resources/AppIcon.icns", iconset]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(atPath: iconset)
