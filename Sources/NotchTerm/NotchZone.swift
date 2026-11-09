import AppKit

/// Vista invisibile sopra il notch: passaggio del mouse, clic e trascinamento di file.
@MainActor
final class NotchZoneView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var hoverDelay: TimeInterval = 0.25
    var hoverEnabled = true
    var dropEnabled = true { didSet { updateDragTypes() } }

    private var tracking: NSTrackingArea?
    private var hoverTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Quasi trasparente ma non del tutto: le finestre completamente trasparenti
        // lasciano passare i clic e non ricevono gli eventi del mouse.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
        updateDragTypes()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateDragTypes() {
        unregisterDraggedTypes()
        if dropEnabled { registerForDraggedTypes([.fileURL]) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        // Niente apertura mentre si trascina una finestra o si tiene premuto il mouse.
        guard hoverEnabled, NSEvent.pressedMouseButtons == 0 else { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      NSMouseInRect(NSEvent.mouseLocation, window.frame, false) else { return }
                self.onHover?()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate()
        onClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropEnabled else { return [] }
        // Il pannello si apre sotto il cursore: il rilascio avviene direttamente lì.
        onDragEnter?()
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// Finestra grande quanto il notch, sempre presente quando il terminale è chiuso.
@MainActor
final class NotchZoneController {
    private let panel: NotchPanel
    let view = NotchZoneView(frame: NSRect(x: 0, y: 0, width: 190, height: 32))
    private var config: Config
    private var suspended = false

    init(config: Config) {
        self.config = config
        panel = NotchPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.allowsKeyFocus = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        update(config: config)
    }

    func update(config: Config) {
        self.config = config
        let z = config.notchZone
        view.hoverEnabled = z.hoverToOpen
        view.hoverDelay = max(0, z.hoverDelay)
        view.dropEnabled = z.dropFiles
        refresh()
    }

    /// Il terminale è aperto: la zona sparisce (il pannello copre già il notch).
    func setSuspended(_ value: Bool) {
        suspended = value
        refresh()
    }

    private var isEnabled: Bool {
        let z = config.notchZone
        return z.hoverToOpen || z.clickToOpen || z.dropFiles
    }

    private func refresh() {
        guard isEnabled, !suspended else { panel.orderOut(nil); return }
        let screen = NotchMetrics.targetScreen(config)
        let m = NotchMetrics.of(screen, fallbackWidth: CGFloat(config.fallbackNotchWidth))
        let sf = screen.frame
        panel.setFrame(NSRect(x: sf.midX - m.width / 2, y: sf.maxY - m.height, width: m.width, height: m.height),
                       display: false)
        panel.orderFrontRegardless()
    }

    var clickToOpen: Bool { config.notchZone.clickToOpen }

    /// Torna sopra agli altri pannelli del notch (es. l'indicatore dei comandi),
    /// così passaggio del mouse e clic sul notch continuano a funzionare.
    func raise() {
        if panel.isVisible { panel.orderFrontRegardless() }
    }
}
