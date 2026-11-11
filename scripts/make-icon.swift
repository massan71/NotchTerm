// Disegna l'icona di NotchTerm (1024×1024) e la salva come PNG.
// Uso: swift scripts/make-icon.swift <output.png>
// Il pannello del terminale "scende" dal notch, con il prompt in verde.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Come NotchShape.path dell'app: orecchie concave in alto, angoli tondi in basso.
func notchPath(body: CGRect, ear e: CGFloat, radius r: CGFloat) -> CGPath {
    let top = body.maxY
    let p = CGMutablePath()
    p.move(to: CGPoint(x: body.minX - e, y: top))
    p.addQuadCurve(to: CGPoint(x: body.minX, y: top - e), control: CGPoint(x: body.minX, y: top))
    p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
    p.addQuadCurve(to: CGPoint(x: body.minX + r, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
    p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
    p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + r), control: CGPoint(x: body.maxX, y: body.minY))
    p.addLine(to: CGPoint(x: body.maxX, y: top - e))
    p.addQuadCurve(to: CGPoint(x: body.maxX + e, y: top), control: CGPoint(x: body.maxX, y: top))
    p.addLine(to: CGPoint(x: body.minX - e, y: top))
    p.closeSubpath()
    return p
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Griglia delle icone macOS: tessera da 824 pt centrata, con margine per l'ombra.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Ombra della tessera.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x0B0E18))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Sfondo: blu notte, più chiaro in alto.
let bg = CGGradient(colorsSpace: cs, colors: [color(0x23294A), color(0x0B0E1A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Alone verde dietro al pannello.
let glow = CGGradient(colorsSpace: cs, colors: [color(0x3DDC84, 0.28), color(0x3DDC84, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 330), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 330), endRadius: 380, options: [])

// Pannello che scende dal bordo superiore.
let panelBody = CGRect(x: 214, y: 352, width: 596, height: tile.maxY - 352)
let panel = notchPath(body: panelBody, ear: 44, radius: 84)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.55))
ctx.addPath(panel)
ctx.setFillColor(color(0x10131F))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(panel)
ctx.clip()
let glass = CGGradient(colorsSpace: cs, colors: [color(0x2E3658), color(0x151A2C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glass, start: CGPoint(x: 0, y: panelBody.maxY), end: CGPoint(x: 0, y: panelBody.minY), options: [])
ctx.restoreGState()

// Bordo luminoso, più intenso in basso (come nell'app).
ctx.saveGState()
ctx.addPath(panel)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.08), color(0xFFFFFF, 0.5)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: panelBody.maxY), end: CGPoint(x: 0, y: panelBody.minY), options: [])
ctx.restoreGState()

// Il notch hardware, nero, in cima al pannello.
let notch = notchPath(body: CGRect(x: 512 - 118, y: tile.maxY - 62, width: 236, height: 62), ear: 16, radius: 30)
ctx.addPath(notch)
ctx.setFillColor(color(0x000000))
ctx.fillPath()

// Prompt: chevron verde e cursore a blocco.
let green = color(0x4BE38E)
ctx.setStrokeColor(green)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let cy: CGFloat = 650
ctx.move(to: CGPoint(x: 340, y: cy + 92))
ctx.addLine(to: CGPoint(x: 446, y: cy))
ctx.addLine(to: CGPoint(x: 340, y: cy - 92))
ctx.strokePath()

let cursor = CGPath(roundedRect: CGRect(x: 500, y: cy - 98, width: 168, height: 40),
                    cornerWidth: 12, cornerHeight: 12, transform: nil)
ctx.addPath(cursor)
ctx.setFillColor(color(0xE8ECF8, 0.92))
ctx.fillPath()

// Due righe di "output" sfumate sotto al prompt.
for (i, w) in [CGFloat(360), 250].enumerated() {
    let y = 466 - CGFloat(i) * 50
    let line = CGPath(roundedRect: CGRect(x: 300, y: y, width: w, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.addPath(line)
    ctx.setFillColor(color(0xFFFFFF, 0.14 - CGFloat(i) * 0.05))
    ctx.fillPath()
}

// Riflesso leggero in alto sulla tessera.
let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.maxY - 260), options: [])
ctx.restoreGState()

// Contorno sottile della tessera.
ctx.addPath(tilePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
