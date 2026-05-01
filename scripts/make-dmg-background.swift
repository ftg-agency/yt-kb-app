#!/usr/bin/env swift
// Generate the background image used in the install DMG.
// Usage: scripts/make-dmg-background.swift <output.png>
//
// The DMG window is laid out 640×400 with two 128pt icons centred vertically:
//   YTKB.app at (160, 200) ───►  Applications at (480, 200)
// We draw a curved arrow between those icon centres + a hint text below.

import AppKit
import Foundation

let outPath = CommandLine.arguments.dropFirst().first ?? {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}()

let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
image.lockFocus()

// Background — soft vertical gradient (light grey to slightly darker)
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.94, alpha: 1.0)
])!
bg.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Coordinates: Finder uses a flipped coordinate system relative to NSGraphicsContext,
// so when AppleScript positions icon at (160, 200) Finder draws icon centre at
// (160, 400-200) = (160, 200) from the BOTTOM in our drawing context. They match
// for the centre y.
//
// Icon centres on screen (Finder coords from top-left):
//   App:  (160, 200)
//   Apps: (480, 200)
// In our flipped drawing (origin top-left → bottom-left), centre y stays the same:
//   y = 400 - 200 = 200 from bottom
let leftIconCenter  = NSPoint(x: 160, y: 200)
let rightIconCenter = NSPoint(x: 480, y: 200)

// Arrow — curved cubic between icons, slightly arching upward
let arrowStart = NSPoint(x: leftIconCenter.x + 70, y: leftIconCenter.y)
let arrowEnd   = NSPoint(x: rightIconCenter.x - 70, y: rightIconCenter.y)
let arch: CGFloat = 50
let cp1 = NSPoint(x: arrowStart.x + 60, y: arrowStart.y + arch)
let cp2 = NSPoint(x: arrowEnd.x - 60, y: arrowEnd.y + arch)

let arrowPath = NSBezierPath()
arrowPath.move(to: arrowStart)
arrowPath.curve(to: arrowEnd, controlPoint1: cp1, controlPoint2: cp2)

let arrowColor = NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.85, alpha: 0.85)
arrowColor.setStroke()
arrowPath.lineWidth = 4
arrowPath.lineCapStyle = .round
arrowPath.stroke()

// Arrow head — pointing slightly down-right toward Applications icon
let head = NSBezierPath()
let headSize: CGFloat = 16
head.move(to: arrowEnd)
head.line(to: NSPoint(x: arrowEnd.x - headSize * 1.2, y: arrowEnd.y + headSize * 0.7))
head.line(to: NSPoint(x: arrowEnd.x - headSize * 1.2, y: arrowEnd.y - headSize * 0.7))
head.close()
arrowColor.setFill()
head.fill()

// Hint text below
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1.0),
    .paragraphStyle: para
]
let text = "Перетащите YTKB в папку Applications"
let textSize = (text as NSString).size(withAttributes: attrs)
let textRect = NSRect(
    x: (size.width - textSize.width) / 2,
    y: 60,
    width: textSize.width,
    height: textSize.height
)
(text as NSString).draw(in: textRect, withAttributes: attrs)

// Header text
let headerAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1.0),
    .paragraphStyle: para
]
let header = "yt-kb"
let headerSize = (header as NSString).size(withAttributes: headerAttrs)
let headerRect = NSRect(
    x: (size.width - headerSize.width) / 2,
    y: 340,
    width: headerSize.width,
    height: headerSize.height
)
(header as NSString).draw(in: headerRect, withAttributes: headerAttrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG export failed\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
