import AppKit

/// Geometria del notch: forma "a goccia rovesciata" con il bordo superiore
/// attaccato allo schermo, due raccordi concavi in alto ("orecchie")
/// e angoli arrotondati in basso — come il notch hardware, ma più grande.
enum NotchShape {
    /// - Parameters:
    ///   - body: rettangolo del corpo (senza orecchie); il suo maxY coincide con il bordo alto.
    ///   - ear: raggio dei raccordi concavi superiori.
    ///   - radius: raggio degli angoli inferiori.
    /// Il path ha sempre lo stesso numero di elementi, così Core Animation
    /// può interpolare tra stato chiuso e stato aperto.
    static func path(body: CGRect, ear: CGFloat, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, body.width / 2, body.height - ear))
        let e = max(0, min(ear, body.height / 2))
        let top = body.maxY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: body.minX - e, y: top))
        // orecchia sinistra (concava)
        p.addQuadCurve(to: CGPoint(x: body.minX, y: top - e), control: CGPoint(x: body.minX, y: top))
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        // angolo in basso a sinistra
        p.addQuadCurve(to: CGPoint(x: body.minX + r, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        // angolo in basso a destra
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + r), control: CGPoint(x: body.maxX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX, y: top - e))
        // orecchia destra (concava)
        p.addQuadCurve(to: CGPoint(x: body.maxX + e, y: top), control: CGPoint(x: body.maxX, y: top))
        p.closeSubpath()
        return p
    }
}

/// Dati del notch per uno schermo. Sugli schermi senza notch ne simula uno.
struct NotchMetrics {
    var width: CGFloat
    var height: CGFloat
    var hasHardwareNotch: Bool

    static func of(_ screen: NSScreen, fallbackWidth: CGFloat) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let w = screen.frame.width - left.width - right.width
            return NotchMetrics(width: w, height: top, hasHardwareNotch: true)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchMetrics(width: fallbackWidth, height: menuBar, hasHardwareNotch: false)
    }
}
