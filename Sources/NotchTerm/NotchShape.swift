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

extension NotchMetrics {
    /// Altezza della barra dei menu su questo schermo (anche se è nascosta in automatico,
    /// sugli schermi col notch resta l'altezza del notch).
    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
    }

    /// Lo schermo su cui mostrare il pannello secondo l'opzione "screen".
    static func targetScreen(_ config: Config) -> NSScreen {
        switch config.screen.lowercased() {
        case "mouse":
            let p = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens[0]
        case "main":
            return NSScreen.screens[0]
        default:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens[0]
        }
    }
}

/// Anima il contorno di più CAShapeLayer insieme (maschera + bordo),
/// con molla in apertura e accelerazione in chiusura.
enum ShapeAnimator {
    static func animate(_ layers: [CAShapeLayer], from: CGPath, to: CGPath, opening: Bool,
                        animation a: Config.Animation, speed: Double = 1, completion: (() -> Void)?) {
        for l in layers { l.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        for l in layers { l.path = to }

        let style = a.style.lowercased()
        let duration = a.duration * speed
        if style != "none" && duration > 0 {
            let anim: CABasicAnimation
            if opening && style == "spring" {
                let s = CASpringAnimation(keyPath: "path")
                let omega = 2 * Double.pi / max(0.05, duration)
                s.mass = 1
                s.stiffness = omega * omega
                s.damping = 2 * max(0.1, min(1.0, a.damping)) * omega
                s.duration = s.settlingDuration
                anim = s
            } else {
                anim = CABasicAnimation(keyPath: "path")
                anim.duration = opening ? duration : duration * 0.6
                anim.timingFunction = opening
                    ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
            }
            anim.fromValue = from
            anim.toValue = to
            for l in layers { l.add(anim, forKey: "path") }
        }
        CATransaction.commit()
    }
}
