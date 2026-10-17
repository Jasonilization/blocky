// DMG background — "drag me into the slot" layout:
// a procedural grass-block meadow, a glowing pad under the app, a dashed
// ghost cube where Applications sits, a hand-off arrow between them, and
// the wordmark. All original art (no game assets are distributed here).
import Foundation
import CoreGraphics
import ImageIO
import CoreText
import AppKit

let output = CommandLine.arguments[1]

let width = 660, height = 400
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// CG is bottom-left origin; Finder icon positions are top-left origin.
// Icon slots: Finder (165,180) and (495,180) → CG (165,220) and (495,220).
let slotA = CGPoint(x: 165, y: 220)   // Blocky.app
let slotB = CGPoint(x: 495, y: 220)   // Applications

func seeded(_ i: Int) -> Double {
    var value = abs(Double(i % 100003) + 0.5)
    value = sin(value * 12.9898) * 43758.5453
    return value - value.rounded(.towardZero)
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// ── 1. Grass-block meadow (procedural, 44 pt blocks of 8×8 texels) ────────
let block: CGFloat = 44
let texels = 8
let texel = block / CGFloat(texels)
let columns = Int(CGFloat(width) / block) + 1
let rows = Int(CGFloat(height) / block) + 1

func grassRamp(_ t: Double) -> (Double, Double, Double) {
    let low = (0.16, 0.34, 0.12), mid = (0.42, 0.66, 0.30), high = (0.55, 0.82, 0.42)
    let clamped = max(0.0, min(1.0, t))
    let f: Double
    let a: (Double, Double, Double); let b: (Double, Double, Double)
    if clamped < 0.5 { f = clamped * 2; a = low; b = mid } else { f = (clamped - 0.5) * 2; a = mid; b = high }
    return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
}

for row in 0..<rows {
    for column in 0..<columns {
        let blockSeed = column &* 73856093 &+ row &* 19349663
        let blockShade = CGFloat(0.86 + seeded(blockSeed &+ 3) * 0.28)
        for ty in 0..<texels {
            for tx in 0..<texels {
                let texelSeed = blockSeed &+ tx &* 83492791 &+ ty &* 2971215073
                let noise = seeded(texelSeed)
                var shade: Double
                if ty <= 1 { shade = noise < 0.18 ? 0.5 : 0.85 }              // crown
                else if ty == 2 { shade = seeded(blockSeed &+ tx &* 733) > 0.45 ? 0.7 : 0.55 }  // ragged edge
                else if ty == 3 && noise < 0.3 { shade = 0.6 }                 // hanging blades
                else if noise < 0.22 { shade = 0.22 }                          // dark clods
                else if noise > 0.9 { shade = 0.75 }                           // pale grit
                else { shade = 0.45 + noise * 0.15 }
                let ramp = grassRamp(shade)
                ctx.setFillColor(red: ramp.0 * Double(blockShade),
                                  green: ramp.1 * Double(blockShade),
                                  blue: ramp.2 * Double(blockShade), alpha: 1)
                ctx.fill(CGRect(
                    x: CGFloat(column) * block + CGFloat(tx) * texel,
                    y: CGFloat(row) * block + CGFloat(ty) * texel,
                    width: texel + 0.5, height: texel + 0.5
                ))
            }
        }
    }
}

// ── 2. Readability scrim + vignette ──────────────────────────────────────
ctx.setFillColor(rgb(8, 10, 16, 0.52))
ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
let vignette = CGGradient(
    colorsSpace: space,
    colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.34)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 330, y: 200), startRadius: 120,
                       endCenter: CGPoint(x: 330, y: 200), endRadius: 470, options: [])

// ── 3. Left slot: glowing pad under Blocky.app ───────────────────────────
let padGlow = CGGradient(
    colorsSpace: space,
    colors: [rgb(126, 211, 94, 0.30), rgb(126, 211, 94, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(padGlow, startCenter: slotA, startRadius: 8,
                       endCenter: slotA, endRadius: 120, options: [])
ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
ctx.setLineWidth(1.5)
ctx.strokeEllipse(in: CGRect(x: slotA.x - 58, y: slotA.y - 40, width: 116, height: 80))

// ── 4. Right slot: dashed ghost cube — the drop target ────────────────────
let a: CGFloat = 52, b: CGFloat = 26, h: CGFloat = 50
let cx = slotB.x, topY = slotB.y - 14
let n = CGPoint(x: cx, y: topY + b), e = CGPoint(x: cx + a, y: topY)
let s = CGPoint(x: cx, y: topY - b), w = CGPoint(x: cx - a, y: topY)
let dropGlow = CGGradient(
    colorsSpace: space,
    colors: [rgb(255, 255, 255, 0.14), rgb(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(dropGlow, startCenter: slotB, startRadius: 8,
                       endCenter: slotB, endRadius: 130, options: [])
ctx.setStrokeColor(rgb(255, 255, 255, 0.55))
ctx.setLineWidth(2)
ctx.setLineDash(phase: 0, lengths: [6, 5])
func path(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.move(to: points[0])
    for point in points.dropFirst() { p.addLine(to: point) }
    p.closeSubpath(); return p
}
ctx.addPath(path([n, e, s, w])); ctx.strokePath()
ctx.addPath(path([w, s, CGPoint(x: s.x, y: s.y - h), CGPoint(x: w.x, y: w.y - h)])); ctx.strokePath()
ctx.addPath(path([s, e, CGPoint(x: e.x, y: e.y - h), CGPoint(x: s.x, y: s.y - h)])); ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// ── 5. Drag arrow: pad → ghost cube (lifted, bright — clears the icons) ──
ctx.setStrokeColor(rgb(255, 255, 255, 0.72))
ctx.setLineWidth(3.5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: slotA.x + 92, y: slotA.y - 14))
ctx.addQuadCurve(
    to: CGPoint(x: slotB.x - 92, y: slotB.y - 14),
    control: CGPoint(x: (slotA.x + slotB.x) / 2, y: slotA.y - 48)
)
ctx.strokePath()
// arrowhead
ctx.setFillColor(rgb(255, 255, 255, 0.72))
ctx.move(to: CGPoint(x: slotB.x - 102, y: slotB.y + 8))
ctx.addLine(to: CGPoint(x: slotB.x - 92, y: slotB.y - 14))
ctx.addLine(to: CGPoint(x: slotB.x - 80, y: slotB.y + 4))
ctx.closePath(); ctx.fillPath()

// ── 6. Wordmark ───────────────────────────────────────────────────────────
func drawText(_ text: String, font: NSFont, kerning: CGFloat,
              at point: CGPoint, alpha: Double) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
        .kern: kerning,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}
drawText("BLOCKY",
         font: NSFont.monospacedSystemFont(ofSize: 30, weight: .heavy),
         kerning: 6, at: CGPoint(x: 42, y: 56), alpha: 0.95)
drawText("opensource minecraft launcher. enjoy!",
         font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
         kerning: 1.5, at: CGPoint(x: 44, y: 34), alpha: 0.55)

// ── Export ────────────────────────────────────────────────────────────────
let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
