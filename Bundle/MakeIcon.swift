// Draws the MacMiga app icon: "MM" over wavy Amiga-style rainbow copper bands, as a 1024×1024 PNG.
// Usage: swift Bundle/MakeIcon.swift out.png
import AppKit
import CoreText

let size = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// The rounded square of the macOS icon grid: 824 points wide, centred, corner radius 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

func rgb(hue: CGFloat, brightness: CGFloat) -> CGColor {
    let c = NSColor(calibratedHue: hue, saturation: 0.9, brightness: brightness, alpha: 1).usingColorSpace(.sRGB)!
    return c.cgColor
}

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Rainbow bands from top (red) to bottom (violet). Band edges are sine waves; each band gets a
// copper-bar shading: dark at its edges, bright in the middle.
let bandCount = 12
let bandHeight = (body.height + 120) / CGFloat(bandCount)
func edge(_ i: Int, _ x: CGFloat) -> CGFloat {
    let t = (x - body.minX) / body.width
    return body.maxY + 60 - bandHeight * CGFloat(i) + 26 * sin(t * 2 * .pi * 1.2 + CGFloat(i) * 0.35)
}
for i in 0..<bandCount {
    let path = CGMutablePath()
    let xs = stride(from: body.minX - 4, through: body.maxX + 4, by: 4).map { $0 }
    path.move(to: CGPoint(x: xs[0], y: edge(i, xs[0])))
    for x in xs { path.addLine(to: CGPoint(x: x, y: edge(i, x))) }
    for x in xs.reversed() { path.addLine(to: CGPoint(x: x, y: edge(i + 1, x) - 1)) }
    path.closeSubpath()
    let hue = CGFloat(i) / CGFloat(bandCount) * 0.80
    let shading = CGGradient(colorsSpace: space,
                             colors: [rgb(hue: hue, brightness: 0.55), rgb(hue: hue, brightness: 1.0),
                                      rgb(hue: hue, brightness: 0.55)] as CFArray,
                             locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let top = body.maxY + 60 - bandHeight * CGFloat(i) + 30
    ctx.drawLinearGradient(shading, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top - bandHeight - 60),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
// Gloss: lighter at the top, darker at the bottom.
let gloss = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 0, alpha: 0.18)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// "MM" as glyph outlines, centred on the body.
let font = NSFont.systemFont(ofSize: 360, weight: .black) as CTFont
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MM", attributes: [.font: font, .kern: 6]))
let letters = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    for (glyph, position) in zip(glyphs, positions) {
        if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
            letters.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
        }
    }
}
let bounds = letters.boundingBoxOfPath
let centred = CGMutablePath()
centred.addPath(letters, transform: CGAffineTransform(translationX: body.midX - bounds.midX, y: body.midY - bounds.midY))

// Halo outside the letters only: a thick round-joined stroke drawn first, the white fill on top of it.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: CGColor(gray: 0, alpha: 0.55))
ctx.addPath(centred)
ctx.setLineWidth(36)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.06, 0.04, 0.20, 1])!)
ctx.strokePath()
ctx.restoreGState()
ctx.addPath(centred)
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
