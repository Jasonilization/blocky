// DMG background — dark slate gradient, faint block grid, the Blocky cube,
// plus directional spacing between the app and the Applications alias.
import Foundation
import CoreGraphics
import ImageIO

let output = CommandLine.arguments[1]
let iconPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let width = 660, height = 400
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// Dark slate gradient.
let background = CGGradient(
    colorsSpace: space,
    colors: [rgb(13, 16, 24), rgb(20, 26, 40), rgb(28, 35, 52)] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])

// Faint block grid.
ctx.setStrokeColor(rgb(255, 255, 255, 0.05))
ctx.setLineWidth(1)
let cell: CGFloat = 44
var i: CGFloat = cell
while i < CGFloat(width) {
    ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: CGFloat(height)))
    i += cell
}
i = cell
while i < CGFloat(height) {
    ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: CGFloat(width), y: i))
    i += cell
}
ctx.strokePath()

// Green glow + the cube, right of center.
let glow = CGGradient(
    colorsSpace: space,
    colors: [rgb(126, 211, 94, 0.22), rgb(126, 211, 94, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 495, y: 200), startRadius: 20,
                       endCenter: CGPoint(x: 495, y: 200), endRadius: 220, options: [])

if let iconPath,
   let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: iconPath) as CFURL, nil),
   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    let size: CGFloat = 190
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 495 - size / 2, y: 200 - size / 2, width: size, height: size))
} else {
    // Fallback: hand-drawn isometric cube.
    let cx: CGFloat = 495, topY: CGFloat = 270, a: CGFloat = 95, b: CGFloat = 48, h: CGFloat = 100
    let n = CGPoint(x: cx, y: topY + b), e = CGPoint(x: cx + a, y: topY)
    let s = CGPoint(x: cx, y: topY - b), w = CGPoint(x: cx - a, y: topY)
    func quad(_ points: [CGPoint], _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath(); ctx.fillPath()
    }
    quad([w, s, CGPoint(x: s.x, y: s.y - h), CGPoint(x: w.x, y: w.y - h)], rgb(138, 90, 59))
    quad([s, e, CGPoint(x: e.x, y: e.y - h), CGPoint(x: s.x, y: s.y - h)], rgb(111, 68, 40))
    quad([n, e, s, w], rgb(150, 219, 96))
}

// Vignette.
let vignette = CGGradient(
    colorsSpace: space,
    colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.30)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 330, y: 200), startRadius: 120,
                       endCenter: CGPoint(x: 330, y: 200), endRadius: 470, options: [])

let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
