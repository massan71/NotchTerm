import AppKit

/// Pulsanti ⏮ ⏯ ⏭.
@MainActor
final class MediaButtons: NSView {
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    private let prev = NSButton()
    private let play = NSButton()
    private let next = NSButton()
    private let pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        for (b, sel, name, label) in [(prev, #selector(prevTapped), "backward.fill", "Brano precedente"),
                                      (play, #selector(playTapped), "play.fill", "Play/Pausa"),
                                      (next, #selector(nextTapped), "forward.fill", "Brano successivo")] {
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.target = self
            b.action = sel
            b.image = symbol(name, label)
            b.toolTip = label
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    func update(isPlaying: Bool, tint: NSColor) {
        play.image = symbol(isPlaying ? "pause.fill" : "play.fill", "Play/Pausa")
        for b in [prev, play, next] { b.contentTintColor = tint }
    }

    /// Larghezza consigliata per i tre pulsanti.
    var preferredWidth: CGFloat { pointSize * 6.6 }

    override func layout() {
        super.layout()
        let w = bounds.width / 3
        for (i, b) in [prev, play, next].enumerated() {
            b.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
    }

    @objc private func prevTapped() { onPrevious?() }
    @objc private func playTapped() { onPlayPause?() }
    @objc private func nextTapped() { onNext?() }
}

/// Copertina con angoli arrotondati e un segnaposto quando manca.
@MainActor
final class ArtworkView: NSImageView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        imageScaling = .scaleProportionallyUpOrDown
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Icona di sistema al posto della copertina (es. esito di un comando).
    func setSymbol(_ name: String, color: NSColor) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        contentTintColor = color
        imageScaling = .scaleNone
    }

    func set(_ artwork: NSImage?, tint: NSColor) {
        imageScaling = .scaleProportionallyUpOrDown
        if let artwork {
            image = artwork
            layer?.backgroundColor = .clear
            contentTintColor = nil
        } else {
            image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            contentTintColor = tint.withAlphaComponent(0.7)
        }
    }
}

/// Mini-player nell'header del terminale, a destra del notch.
@MainActor
final class HeaderMediaView: NSView {
    let buttons = MediaButtons(pointSize: 9)
    private let art = ArtworkView(cornerRadius: 4)
    private let label = NSTextField(labelWithString: "")
    var onActivate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(art)
        addSubview(label)
        addSubview(buttons)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onActivate?() }   // clic su titolo/copertina → apre il lettore

    func update(track: NowPlayingTrack, artwork: NSImage?, tint: NSColor) {
        art.set(artwork, tint: tint)
        let title = NSAttributedString(string: track.title, attributes: [.foregroundColor: tint.withAlphaComponent(0.9)])
        let s = NSMutableAttributedString(attributedString: title)
        if !track.artist.isEmpty {
            s.append(NSAttributedString(string: "  ·  " + track.artist,
                                        attributes: [.foregroundColor: tint.withAlphaComponent(0.5)]))
        }
        label.attributedStringValue = s
        label.toolTip = "\(track.title) — \(track.artist)\n\(track.album)"
        buttons.update(isPlaying: track.isPlaying, tint: tint.withAlphaComponent(0.75))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let bw = buttons.preferredWidth
        art.frame = NSRect(x: 0, y: (h - 18) / 2, width: 18, height: 18)
        buttons.frame = NSRect(x: bounds.width - bw, y: (h - 20) / 2, width: bw, height: 20)
        let lx = art.frame.maxX + 7
        label.frame = NSRect(x: lx, y: (h - 15) / 2, width: max(0, buttons.frame.minX - lx - 6), height: 15)
        // Se lo spazio è poco si tengono solo i pulsanti.
        let tight = bounds.width < bw + 70
        art.isHidden = tight
        label.isHidden = tight
    }
}

// MARK: - Avviso al cambio brano

/// Avvisi dal notch: si allarga per qualche secondo (in stile Dynamic Island)
/// per mostrare il brano appena iniziato o l'esito di un comando lungo.
@MainActor
final class PeekController {
    private let panel: NotchPanel
    private let root = NotchRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    private let content = PassthroughContainer()
    private let art = ArtworkView(cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let buttons = MediaButtons(pointSize: 13)

    private var metrics = NotchMetrics(width: 190, height: 32, hasHardwareNotch: false)
    private var hideTimer: Timer?
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { onVisibilityChange?() } }
    }
    /// L'avviso è comparso o sparito (l'indicatore dei comandi si fa da parte).
    var onVisibilityChange: (() -> Void)?
    private enum Mode { case media, command }
    private var mode = Mode.media
    private var onContentClick: (() -> Void)?
    var config: Config

    var onPlayPause: (() -> Void)? { didSet { buttons.onPlayPause = onPlayPause } }
    var onNext: (() -> Void)? { didSet { buttons.onNext = onNext } }
    var onPrevious: (() -> Void)? { didSet { buttons.onPrevious = onPrevious } }
    var onActivate: (() -> Void)?

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
        panel.contentView = root
        panel.allowsKeyFocus = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        artistLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        for l in [titleLabel, artistLabel] {
            l.lineBreakMode = .byTruncatingTail
            content.addSubview(l)
        }
        content.addSubview(art)
        content.addSubview(buttons)
        content.onClick = { [weak self] in
            self?.onContentClick?()
            self?.hide()
        }
        root.addSubview(content)
        root.bringBorderToFront()
        // Nero come il notch hardware, così sembra il notch che si allarga.
        root.setSurface(material: "solid", tint: .black, border: 0)
    }

    func show(track: NowPlayingTrack, artwork: NSImage?) {
        mode = .media
        onContentClick = onActivate
        buttons.isHidden = false
        fill(track: track, artwork: artwork)
        present(duration: config.media.peekDuration)
    }

    /// Esito di un comando terminato. Un clic sull'avviso esegue `onClick`.
    func show(command result: CommandResult, tab: String?, onClick: @escaping () -> Void) {
        mode = .command
        onContentClick = onClick
        buttons.isHidden = true
        let ok = result.succeeded
        art.setSymbol(ok ? "checkmark" : "xmark",
                      color: ok ? NSColor(srgbRed: 0.35, green: 0.86, blue: 0.5, alpha: 1)
                                : NSColor(srgbRed: 1, green: 0.42, blue: 0.4, alpha: 1))
        titleLabel.stringValue = result.command.isEmpty ? "Comando terminato" : result.command
        titleLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white
        let time = CommandResult.format(result.duration)
        var detail = ok ? "Completato in \(time)" : "Errore \(result.exitCode) dopo \(time)"
        if let tab { detail += "  ·  \(tab)" }
        artistLabel.stringValue = detail
        artistLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        // Gli errori restano visibili un po' di più.
        present(duration: ok ? 5 : 8)
    }

    private func present(duration: Double) {
        scheduleHide(after: duration)
        guard !isShowing else { layoutLabels(); return }
        isShowing = true
        layout()
        let collapsed = collapsedPath()
        setPath(collapsed)
        panel.orderFrontRegardless()
        content.alphaValue = 0
        ShapeAnimator.animate([root.maskLayer, root.borderShape], from: collapsed, to: expandedPath(),
                              opening: true, animation: config.animation, completion: nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.style == "none" ? 0 : config.animation.duration * 0.7
            content.animator().alphaValue = 1
        }
    }

    /// Aggiorna i dati se l'avviso è già visibile (es. play/pausa dal suo pulsante).
    func refresh(track: NowPlayingTrack?, artwork: NSImage?) {
        guard isShowing, mode == .media else { return }
        guard let track else { hide(); return }
        fill(track: track, artwork: artwork)
    }

    func hide(immediately: Bool = false) {
        hideTimer?.invalidate()
        guard isShowing else { return }
        isShowing = false
        if immediately {
            panel.orderOut(nil)
            return
        }
        let from = root.maskLayer.presentation()?.path ?? expandedPath()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.style == "none" ? 0 : config.animation.duration * 0.3
            content.animator().alphaValue = 0
        }
        ShapeAnimator.animate([root.maskLayer, root.borderShape], from: from, to: collapsedPath(),
                              opening: false, animation: config.animation) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel.orderOut(nil)
        }
    }

    private func scheduleHide(after duration: Double) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(1, duration), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Con il mouse sopra l'avviso resta aperto.
                if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                    self.hideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleHideAfterHover() }
                    }
                } else {
                    self.hide()
                }
            }
        }
    }

    private func scheduleHideAfterHover() {
        if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHideAfterHover() }
            }
        } else {
            hide()
        }
    }

    private func fill(track: NowPlayingTrack, artwork: NSImage?) {
        art.set(artwork, tint: .white)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.stringValue = track.title
        titleLabel.textColor = .white
        artistLabel.stringValue = track.artist.isEmpty ? track.album : track.artist
        artistLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        buttons.update(isPlaying: track.isPlaying, tint: NSColor.white.withAlphaComponent(0.9))
    }

    // MARK: Geometria

    private let ear: CGFloat = 8
    private let contentHeight: CGFloat = 58

    private func layout() {
        let screen = NotchMetrics.targetScreen(config)
        metrics = NotchMetrics.of(screen, fallbackWidth: CGFloat(config.fallbackNotchWidth))
        let sf = screen.frame
        let bodyW = max(metrics.width + 160, 380)
        let bodyH = metrics.height + contentHeight
        let w = bodyW + 2 * ear
        panel.setFrame(NSRect(x: sf.midX - w / 2, y: sf.maxY - bodyH, width: w, height: bodyH), display: false)
        root.frame = NSRect(x: 0, y: 0, width: w, height: bodyH)
        root.layoutSubtreeIfNeeded()

        content.frame = NSRect(x: ear + 14, y: 8, width: bodyW - 28, height: contentHeight - 12)
        let ch = content.bounds.height
        art.frame = NSRect(x: 0, y: (ch - 40) / 2, width: 40, height: 40)
        let bw = buttons.preferredWidth
        buttons.frame = NSRect(x: content.bounds.width - bw, y: (ch - 26) / 2, width: bw, height: 26)
        layoutLabels()
    }

    private func layoutLabels() {
        let ch = content.bounds.height
        let tx = art.frame.maxX + 11
        let right = buttons.isHidden ? content.bounds.width : buttons.frame.minX - 10
        let tw = max(0, right - tx)
        titleLabel.frame = NSRect(x: tx, y: ch / 2 + 1, width: tw, height: 17)
        artistLabel.frame = NSRect(x: tx, y: ch / 2 - 16, width: tw, height: 15)
    }

    private func expandedPath() -> CGPath {
        let b = root.bounds
        return NotchShape.path(body: CGRect(x: ear, y: 0, width: b.width - 2 * ear, height: b.height),
                               ear: ear, radius: 20)
    }

    private func collapsedPath() -> CGPath {
        let b = root.bounds
        let body = CGRect(x: b.midX - metrics.width / 2, y: b.height - metrics.height,
                          width: metrics.width, height: metrics.height)
        return NotchShape.path(body: body, ear: 6, radius: min(metrics.height * 0.35, 12))
    }

    private func setPath(_ p: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.maskLayer.path = p
        root.borderShape.path = p
        CATransaction.commit()
    }
}

/// Contenitore che inoltra il clic (fuori dai pulsanti) a una closure.
@MainActor
final class PassthroughContainer: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
