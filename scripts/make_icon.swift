// Draws the app icon: a simple head shape with a light side and a shadow side.
// Run: swift scripts/make_icon.swift Resources/AppIcon.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Paper on a rounded square, with the macOS icon margin.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1))
ctx.fillPath()

// The head: skull circle and jaw, in one path.
let center = CGPoint(x: 512, y: 590)
let radius = 215.0
let head = CGMutablePath()
head.addArc(center: center, radius: radius, startAngle: .pi * 1.12, endAngle: -.pi * 0.12, clockwise: true)
head.addLine(to: CGPoint(x: 680, y: 380))
head.addLine(to: CGPoint(x: 560, y: 250))
head.addLine(to: CGPoint(x: 464, y: 250))
head.addLine(to: CGPoint(x: 344, y: 380))
head.closeSubpath()

// Light family on the left, shadow family on the right, with a core shadow at the edge.
ctx.saveGState()
ctx.addPath(head)
ctx.clip()
ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
ctx.fill(tile)
ctx.setFillColor(CGColor(gray: 0.42, alpha: 1))
ctx.fill(CGRect(x: 560, y: 0, width: 600, height: 1024))
ctx.setFillColor(CGColor(gray: 0.28, alpha: 1))
ctx.fill(CGRect(x: 560, y: 0, width: 38, height: 1024))
ctx.restoreGState()

// A bold outline, so that the head reads at small sizes.
ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
ctx.setLineWidth(22)
ctx.setLineJoin(.round)
ctx.addPath(head)
ctx.strokePath()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
