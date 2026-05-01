#!/usr/bin/env swift
// Generate the DMG background image — straight thick arrow only.
// Usage: scripts/make-dmg-background.swift <output.png>
//
// Window in Finder: 520×320. PNG canvas is 1040×640 (2× resolution) so
// Finder shows it pixel-sharp on retina displays. Icons are positioned at
// (130, 160) and (390, 160) in Finder window coords; we draw the arrow
// between them.

import AppKit
import Foundation

let outPath = CommandLine.arguments.dropFirst().first ?? {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}()

// Logical (Finder window) dimensions
let scale: CGFloat = 2.0
let logicalW: CGFloat = 520
let logicalH: CGFloat = 320

// Pixel-sized canvas for retina sharpness
let canvasSize = NSSize(width: logicalW * scale, height: logicalH * scale)
let image = NSImage(size: canvasSize)
image.lockFocus()

// Background — soft vertical gradient (light grey)
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.94, alpha: 1.0)
])!
bg.draw(in: NSRect(origin: .zero, size: canvasSize), angle: -90)

// Icon centres in logical (Finder) coords. Finder uses top-left origin so
// the y here is from the top. Our drawing context is bottom-left origin
// (NSImage default), so we flip: drawY = logicalH - y.
let leftCx_logical:  CGFloat = 130
let rightCx_logical: CGFloat = 390
let cy_logical:      CGFloat = 160

let leftCx  = leftCx_logical * scale
let rightCx = rightCx_logical * scale
let cy      = (logicalH - cy_logical) * scale  // flip y

// Arrow: leave a gap so the icons themselves aren't covered
let iconHalf:    CGFloat = 50 * scale     // icons are 100pt → 50pt half
let gap:         CGFloat = 24 * scale     // breathing room between icon and arrow
let startX = leftCx  + iconHalf + gap
let endX   = rightCx - iconHalf - gap

// Stroke thick arrow shaft
let arrowColor = NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.85, alpha: 0.95)
arrowColor.setStroke()
arrowColor.setFill()

let lineWidth: CGFloat = 8 * scale
let path = NSBezierPath()
path.move(to: NSPoint(x: startX, y: cy))
// Stop the line short of the arrowhead so the rounded cap doesn't poke out past the triangle
let headLen: CGFloat = 22 * scale
path.line(to: NSPoint(x: endX - headLen, y: cy))
path.lineWidth = lineWidth
path.lineCapStyle = .round
path.stroke()

// Arrowhead — solid triangle
let head = NSBezierPath()
let headHalfW: CGFloat = 18 * scale
head.move(to: NSPoint(x: endX, y: cy))
head.line(to: NSPoint(x: endX - headLen, y: cy + headHalfW))
head.line(to: NSPoint(x: endX - headLen, y: cy - headHalfW))
head.close()
head.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG export failed\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) (\(Int(canvasSize.width))×\(Int(canvasSize.height)))")
