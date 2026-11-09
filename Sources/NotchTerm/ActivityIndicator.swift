import AppKit

/// Anello che gira: il segno che un comando è ancora in corso.
final class SpinnerView: NSView {
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = 0.72
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    var color: NSColor = .white { didSet { ring.strokeColor = color.cgColor } }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        CATransaction.commit()
    }

    func start() {
        guard ring.animation(forKey: "spin") == nil else { return }
        ring.strokeColor = color.cgColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi   // in senso orario (AppKit ha l'asse y verso l'alto)
        spin.duration = 0.9
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func stop() { ring.removeAnimation(forKey: "spin") }
}

/// Indicatore "live" nel notch quando il terminale è chiuso: il notch si allarga
/// di poco ai lati e mostra il tempo trascorso a sinistra e un anello che gira a destra.
@MainActor
final class ActivityIndicatorController {
    private let panel: NotchPanel
    private let root = NotchRootView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
    private let content = PassthroughContainer()
    private let timeLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let spinner = SpinnerView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))

    private var metrics = NotchMetrics(width: 190, height: 32, hasHardwareNotch: false)
    private var activity: (command: String, since: Date, tab: String?, count: Int)?
    private var suppressed = false
    private var ticker: Timer?
    private(set) var isShowing = false
    var config: Config
    var onClick: (() -> Void)?

    /// Larghezza aggiunta su ciascun lato del notch.
    private let side: CGFloat = 46
    private let ear: CGFloat = 6

    init(config: Config) {
        self.config = config
        panel = NotchPanel(contentRect: root.frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.allowsKeyFocus = false
        panel.contentView = root

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        timeLabel.alignment = .center
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        countLabel.alignment = .left
        spinner.color = NSColor(srgbRed: 0.35, green: 0.86, blue: 0.5, alpha: 1)
        for v in [timeLabel, countLabel, spinner] as [NSView] { content.addSubview(v) }
        content.onClick = { [weak self] in self?.onClick?() }
        root.addSubview(content)
        root.setSurface(material: "solid", tint: .black, border: 0)
    }

    /// Nuovo stato: il comando in corso (o nil) e se qualcos'altro occupa il notch
    /// (terminale aperto, avviso di fine comando o del brano).
    func update(activity new: (command: String, since: Date, tab: String?, count: Int)?, suppressed: Bool) {
        activity = config.commandNotify.liveIndicator ? new : nil
        self.suppressed = suppressed
        if activity == nil {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        tick()
    }

    private func tick() {
        guard let activity, !suppressed else {
            // Se un altro avviso prende il notch si sparisce subito, senza animazione.
            hide(immediately: suppressed)
            return
        }
        let elapsed = Date().timeIntervalSince(activity.since)
        guard elapsed >= config.commandNotify.liveIndicatorDelay else { hide(immediately: false); return }
        timeLabel.stringValue = CommandResult.clock(elapsed)
        let count = activity.count > 1 ? "×\(activity.count)" : ""
        if count != countLabel.stringValue {
            countLabel.stringValue = count
            layoutRightWing()
        }
        var tip = activity.command
        if let tab = activity.tab { tip += "  ·  \(tab)" }
        content.toolTip = tip.isEmpty ? "Comando in corso" : tip
        show()
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true
        layout()
        let collapsed = collapsedPath()
        setPath(collapsed)
        content.alphaValue = 0
        panel.orderFrontRegardless()
        spinner.start()
        ShapeAnimator.animate([root.maskLayer, root.borderShape], from: collapsed, to: expandedPath(),
                              opening: true, animation: config.animation, speed: 0.8, completion: nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.style == "none" ? 0 : config.animation.duration * 0.6
            content.animator().alphaValue = 1
        }
    }

    private func hide(immediately: Bool) {
        guard isShowing else { return }
        isShowing = false
        if immediately || config.animation.style == "none" {
            spinner.stop()
            panel.orderOut(nil)
            return
        }
        let from = root.maskLayer.presentation()?.path ?? expandedPath()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.duration * 0.3
            content.animator().alphaValue = 0
        }
        ShapeAnimator.animate([root.maskLayer, root.borderShape], from: from, to: collapsedPath(),
                              opening: false, animation: config.animation) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.spinner.stop()
            self.panel.orderOut(nil)
        }
    }

    /// Lo schermo o il config sono cambiati.
    func refreshLayout() {
        guard isShowing else { return }
        layout()
        setPath(expandedPath())
    }

    // MARK: Geometria

    private func layout() {
        let screen = NotchMetrics.targetScreen(config)
        metrics = NotchMetrics.of(screen, fallbackWidth: CGFloat(config.fallbackNotchWidth))
        let sf = screen.frame
        let bodyW = metrics.width + 2 * side
        let h = metrics.height
        let w = bodyW + 2 * ear
        panel.setFrame(NSRect(x: sf.midX - w / 2, y: sf.maxY - h, width: w, height: h), display: false)
        root.frame = NSRect(x: 0, y: 0, width: w, height: h)
        root.layoutSubtreeIfNeeded()

        content.frame = root.bounds
        // Il contenuto sta nelle due "ali" accanto al notch, centrato in verticale.
        let leftWing = NSRect(x: ear + 4, y: 0, width: side - 8, height: h)
        let timeH: CGFloat = 15
        timeLabel.frame = NSRect(x: leftWing.minX - 4, y: (h - timeH) / 2, width: leftWing.width + 8, height: timeH)
        layoutRightWing()
    }

    /// Anello al centro dell'ala destra; con più comandi in corso, accanto il loro numero.
    private func layoutRightWing() {
        let w = root.bounds.width, h = root.bounds.height
        let wing = NSRect(x: w - ear - side + 4, y: 0, width: side - 8, height: h)
        let sp: CGFloat = 14
        if countLabel.stringValue.isEmpty {
            spinner.frame = NSRect(x: wing.midX - sp / 2, y: (h - sp) / 2, width: sp, height: sp)
            countLabel.frame = .zero
        } else {
            spinner.frame = NSRect(x: wing.minX + 2, y: (h - sp) / 2, width: sp, height: sp)
            countLabel.frame = NSRect(x: spinner.frame.maxX + 2, y: (h - 12) / 2, width: wing.maxX - spinner.frame.maxX - 2, height: 12)
        }
    }

    private func expandedPath() -> CGPath {
        let b = root.bounds
        return NotchShape.path(body: CGRect(x: ear, y: 0, width: b.width - 2 * ear, height: b.height),
                               ear: ear, radius: min(b.height * 0.4, 14))
    }

    private func collapsedPath() -> CGPath {
        let b = root.bounds
        let body = CGRect(x: b.midX - metrics.width / 2, y: 0, width: metrics.width, height: b.height)
        return NotchShape.path(body: body, ear: ear, radius: min(b.height * 0.35, 12))
    }

    private func setPath(_ p: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.maskLayer.path = p
        root.borderShape.path = p
        CATransaction.commit()
    }
}
