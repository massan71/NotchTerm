import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// Pannello senza bordi che può ricevere la tastiera senza attivare l'app
/// (come Spotlight): il focus dell'app sotto resta intatto.
final class NotchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    /// false per i pannelli che mostrano solo informazioni (es. l'avviso musicale).
    var allowsKeyFocus = true

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    /// Le scorciatoie si intercettano qui, prima che arrivino al terminale:
    /// così funzionano anche le combinazioni con Control (es. ⌃Tab).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Vista che non intercetta i clic (per i livelli decorativi sopra al terminale).
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Vista radice: materiale di sfondo + tinta + bordo luminoso, il tutto
/// ritagliato da una maschera a forma di notch.
final class NotchRootView: NSView {
    let maskLayer = CAShapeLayer()
    /// Tinta di colore sopra al materiale.
    let tintView = PassthroughView()
    /// Bordo: un gradiente (più luminoso in basso) visibile solo lungo il contorno.
    let borderView = PassthroughView()
    let borderShape = CAShapeLayer()
    private let borderGradient = CAGradientLayer()
    private var backdrop: NSView?
    private var currentMaterial = ""

    /// File rilasciati sul pannello: URL e punto (coordinate della vista).
    var onDropFiles: (([URL], NSPoint) -> Bool)? {
        didSet { onDropFiles == nil ? unregisterDraggedTypes() : registerForDraggedTypes([.fileURL]) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        return onDropFiles?(urls, convert(sender.draggingLocation, from: nil)) ?? false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        maskLayer.fillColor = NSColor.black.cgColor
        layer?.mask = maskLayer

        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)

        borderView.wantsLayer = true
        borderView.autoresizingMask = [.width, .height]
        borderShape.fillColor = nil
        borderShape.strokeColor = NSColor.white.cgColor
        borderShape.lineWidth = 2   // metà cade fuori dalla maschera → bordo da 1 pt
        borderGradient.mask = borderShape
        borderView.layer?.addSublayer(borderGradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Il bordo va sempre sopra a tutto: si richiama dopo aver aggiunto viste.
    func bringBorderToFront() {
        borderView.removeFromSuperview()
        addSubview(borderView)
    }

    func setSurface(material: String, tint: NSColor, border: CGFloat) {
        if material != currentMaterial {
            currentMaterial = material
            backdrop?.removeFromSuperview()
            backdrop = makeBackdrop(material)
            if let backdrop {
                backdrop.frame = bounds
                backdrop.autoresizingMask = [.width, .height]
                addSubview(backdrop, positioned: .below, relativeTo: tintView)
            }
        }
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            // Con il vetro la tinta la applica il materiale stesso.
            glass.tintColor = tint
            tintView.layer?.backgroundColor = .clear
        } else {
            tintView.layer?.backgroundColor = tint.cgColor
        }
        borderGradient.colors = [NSColor.white.withAlphaComponent(border * 0.35).cgColor,
                                 NSColor.white.withAlphaComponent(border).cgColor]
        borderView.isHidden = border <= 0
    }

    private func makeBackdrop(_ material: String) -> NSView? {
        switch material {
        case "glass", "glass-clear":
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.style = material == "glass-clear" ? .clear : .regular
                g.cornerRadius = 0   // la forma la dà la maschera del notch
                return g
            }
            fallthrough
        case "blur":
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        default:
            return nil
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintView.frame = bounds
        borderView.frame = bounds
        backdrop?.frame = bounds
        maskLayer.frame = bounds
        borderGradient.frame = bounds   // gradiente dall'alto (y=1 in AppKit) al basso
        borderGradient.startPoint = CGPoint(x: 0.5, y: 1)
        borderGradient.endPoint = CGPoint(x: 0.5, y: 0)
        borderShape.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
final class NotchController: NSObject {
    private(set) var config: Config
    private let panel: NotchPanel
    private let root: NotchRootView
    private let tabBar = TabBarView()
    private let newTabButton = NSButton()
    let mediaView = HeaderMediaView()
    private var mediaTrack: NowPlayingTrack?
    private var mediaArtwork: NSImage?

    private var sessions: [TerminalSession] = []
    private var selectedIndex = 0
    private var current: TerminalSession { sessions[selectedIndex] }

    private(set) var isOpen = false
    private var clickMonitor: Any?
    private var metrics = NotchMetrics(width: 190, height: 32, hasHardwareNotch: false)
    private var fontDelta: CGFloat = 0
    private var terminalFrame = NSRect(x: 0, y: 0, width: 500, height: 250)

    var onOpenConfig: (() -> Void)?
    /// Chiamato appena prima di aprire il pannello.
    var onWillOpen: (() -> Void)?
    /// Chiamato quando il pannello si è chiuso del tutto.
    var onDidClose: (() -> Void)?
    /// Un comando lungo è terminato mentre il pannello era chiuso.
    /// Parametri: esito, titolo della scheda (se più di una), azione per mostrarla.
    var onCommandNotify: ((CommandResult, String?, @escaping () -> Void) -> Void)?

    var tabCount: Int { sessions.count }

    init(config: Config) {
        self.config = config
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        root = NotchRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = root
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        root.onDropFiles = { [weak self] urls, point in self?.dropFiles(urls, at: point) ?? false }
        tabBar.onSelect = { [weak self] in self?.selectTab($0) }
        tabBar.onClose = { [weak self] in self?.closeTab(at: $0) }
        root.addSubview(tabBar)

        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Nuova scheda")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        newTabButton.imagePosition = .imageOnly
        newTabButton.toolTip = "Nuova scheda (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(newTabAction)
        root.addSubview(newTabButton)
        root.addSubview(mediaView)

        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        applyAppearance()
        newTab(directory: nil)
    }

    // MARK: - Config

    func update(config new: Config) {
        let old = config
        config = new
        applyAppearance()
        layoutForCurrentScreen()
        if isOpen { setPath(expandedPath()) }
        if old.shell != new.shell || old.shellArgs != new.shellArgs || old.env != new.env {
            restartShell()
        }
    }

    private var foreground: NSColor {
        NSColor(hex: Themes.resolve(config).foreground) ?? .white
    }

    private func applyAppearance() {
        let theme = Themes.resolve(config)
        let bg = NSColor(hex: theme.background) ?? .black
        let surface = Surface.resolve(config)
        root.setSurface(material: surface.material,
                        tint: bg.withAlphaComponent(CGFloat(surface.opacity)),
                        border: CGFloat(surface.borderOpacity))
        newTabButton.contentTintColor = foreground.withAlphaComponent(0.6)
        refreshMedia()
        tabBar.maxTabWidth = CGFloat(config.maxTabWidth)
        for s in sessions { style(s.view) }
        refreshTabBar()
    }

    private func style(_ terminal: LocalProcessTerminalView) {
        let theme = Themes.resolve(config)
        let bg = NSColor(hex: theme.background) ?? .black
        let fg = foreground
        terminal.installColors(theme.ansi.map { SwiftTerm.Color.hex($0) })
        terminal.nativeForegroundColor = fg
        // Lo sfondo lo disegna la vista radice: il terminale è trasparente
        // così header, bordo e testo hanno lo stesso colore senza giunture.
        terminal.nativeBackgroundColor = bg.withAlphaComponent(0)
        terminal.caretColor = NSColor(hex: theme.cursor) ?? fg
        terminal.selectedTextBackgroundColor = NSColor(hex: theme.selection) ?? .selectedTextBackgroundColor
        terminal.optionAsMetaKey = config.optionAsMeta
        terminal.font = resolvedFont()
        terminal.setCursorStyle(cursorStyle())
    }

    private func resolvedFont() -> NSFont {
        let size = max(6, CGFloat(config.font.size) + fontDelta)
        if !config.font.name.isEmpty {
            if let f = NSFont(name: config.font.name, size: size) { return f }
            if let f = NSFontManager.shared.font(withFamily: config.font.name, traits: [], weight: 5, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func applyFontToAll() {
        let f = resolvedFont()
        for s in sessions { s.view.font = f }
    }

    private func cursorStyle() -> CursorStyle {
        let s = config.cursorStyle.lowercased()
        let blink = s.contains("blink")
        if s.hasPrefix("bar") { return blink ? .blinkBar : .steadyBar }
        if s.hasPrefix("under") { return blink ? .blinkUnderline : .steadyUnderline }
        return blink ? .blinkBlock : .steadyBlock
    }

    // MARK: - Schede

    @objc private func newTabAction() { newTab(directory: inheritedDirectory()) }

    private func inheritedDirectory() -> String? {
        guard config.newTabInheritsDirectory, !sessions.isEmpty else { return nil }
        current.refreshDirectory()
        return current.cwd
    }

    func newTab(directory: String?) {
        let s = TerminalSession(frame: terminalFrame)
        style(s.view)
        s.view.isHidden = true
        s.onChange = { [weak self] _ in self?.refreshTabBar() }
        s.onExit = { [weak self] in self?.sessionExited($0) }
        s.onCommandFinished = { [weak self] in self?.commandFinished($0, $1) }
        root.addSubview(s.view)
        root.bringBorderToFront()
        let insertAt = sessions.isEmpty ? 0 : selectedIndex + 1
        sessions.insert(s, at: insertAt)
        s.start(config: config, directory: directory)
        selectTab(insertAt)
    }

    func selectTab(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedIndex = index
        for (i, s) in sessions.enumerated() { s.view.isHidden = i != index }
        if isOpen { sessions[index].badge = nil }
        if isOpen { panel.makeFirstResponder(current.view) }
        current.refreshDirectory()
        refreshTabBar()
    }

    func closeTab(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        if sessions.count == 1 {
            // Ultima scheda: si nasconde il pannello e la shell riparte pulita.
            close()
            restartShell()
            return
        }
        let s = sessions.remove(at: index)
        s.onExit = nil
        s.onChange = nil
        s.terminate()
        s.view.removeFromSuperview()
        if selectedIndex >= sessions.count || index < selectedIndex { selectedIndex = max(0, selectedIndex - 1) }
        selectTab(selectedIndex)
    }

    private func cycleTab(_ delta: Int) {
        guard sessions.count > 1 else { return }
        selectTab((selectedIndex + delta + sessions.count) % sessions.count)
    }

    private func moveTab(_ delta: Int) {
        let to = selectedIndex + delta
        guard sessions.indices.contains(to) else { return }
        sessions.swapAt(selectedIndex, to)
        selectTab(to)
    }

    #if DEBUG
    func debugType(_ text: String) { current.view.send(txt: text) }
    #endif

    // MARK: - File trascinati

    /// Sull'header (schede): una nuova scheda per ogni cartella (o cartella del file).
    /// Sul terminale: incolla i percorsi, già pronti per la shell.
    private func dropFiles(_ urls: [URL], at point: NSPoint) -> Bool {
        guard config.notchZone.dropFiles else { return false }
        let headerBottom = root.bounds.height - metrics.height - 4
        if point.y >= headerBottom {
            for url in urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                newTab(directory: isDir.boolValue ? url.path : url.deletingLastPathComponent().path)
            }
        } else {
            current.view.send(txt: urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " ")
        }
        panel.makeKey()
        panel.makeFirstResponder(current.view)
        return true
    }

    /// Come Terminal.app: backslash davanti ai caratteri speciali.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\\'\"()[]{}&;|<>*?$`!#~=^,")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: - Fine comando

    private func commandFinished(_ s: TerminalSession, _ result: CommandResult) {
        let cfg = config.commandNotify
        guard cfg.enabled, result.duration >= cfg.minDuration,
              cfg.notifyOnSuccess || !result.succeeded,
              let index = sessions.firstIndex(where: { $0 === s }) else { return }
        // Già sotto gli occhi dell'utente: niente avviso.
        if isOpen && index == selectedIndex { return }
        s.badge = result.succeeded ? "✓" : "✗"
        refreshTabBar()
        if !isOpen {
            let tab = sessions.count > 1 ? s.plainShortTitle : nil
            onCommandNotify?(result, tab) { [weak self, weak s] in
                guard let self, let s, let i = self.sessions.firstIndex(where: { $0 === s }) else { return }
                self.selectTab(i)
                self.open()
            }
        }
    }

    private func sessionExited(_ s: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === s }) else { return }
        if sessions.count > 1 {
            closeTab(at: index)
            return
        }
        // Ultima scheda: la shell riparte sempre, così il pannello non resta "morto".
        s.view.resetToInitialState()
        s.start(config: config, directory: nil)
        if !config.restartShellOnExit { close() }
    }

    /// Riavvia la shell della scheda corrente.
    func restartShell() {
        let s = current
        if s.isRunning {
            // Si sostituisce temporaneamente onExit per ripartire senza chiudere la scheda.
            s.onExit = { [weak self] session in
                guard let self else { return }
                session.onExit = { [weak self] in self?.sessionExited($0) }
                session.view.resetToInitialState()
                session.start(config: self.config, directory: nil)
            }
            s.terminate()
        } else {
            s.view.resetToInitialState()
            s.start(config: config, directory: nil)
        }
    }

    private func refreshTabBar() {
        guard !sessions.isEmpty else { return }
        let titles = sessions.count == 1 ? [current.displayTitle] : sessions.map(\.shortTitle)
        tabBar.update(titles: titles, selected: selectedIndex, tint: foreground)
        tabBar.isHidden = !config.showHeader
        newTabButton.isHidden = !config.showHeader
    }

    // MARK: - Geometria

    private func targetScreen() -> NSScreen { NotchMetrics.targetScreen(config) }

    private var ear: CGFloat { CGFloat(max(0, config.earRadius)) }

    private func layoutForCurrentScreen() {
        let screen = targetScreen()
        metrics = NotchMetrics.of(screen, fallbackWidth: CGFloat(config.fallbackNotchWidth))
        let sf = screen.frame

        func resolve(_ v: Double, _ total: CGFloat) -> CGFloat { v <= 1 ? CGFloat(v) * total : CGFloat(v) }
        let bodyW = min(sf.width - 2 * ear, max(metrics.width + 120, resolve(config.width, sf.width)))
        let bodyH = min(sf.height, max(metrics.height + 80, resolve(config.height, sf.height)))
        let w = bodyW + 2 * ear

        panel.setFrame(NSRect(x: sf.midX - w / 2, y: sf.maxY - bodyH, width: w, height: bodyH), display: false)
        root.frame = NSRect(x: 0, y: 0, width: w, height: bodyH)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()

        let pad = CGFloat(max(0, config.padding))
        let headerH = metrics.height
        terminalFrame = NSRect(x: ear + pad, y: pad * 0.75,
                               width: bodyW - 2 * pad,
                               height: bodyH - headerH - pad * 0.75 - 6)
        for s in sessions { s.view.frame = terminalFrame }

        // Header: schede a sinistra del notch; a destra il mini-player e, in fondo, il "+".
        let leftEdge = ear + pad
        let notchLeft = w / 2 - metrics.width / 2 - 10
        let notchRight = w / 2 + metrics.width / 2 + 12
        let rightEdge = w - ear - pad
        tabBar.frame = NSRect(x: leftEdge, y: bodyH - headerH, width: max(0, notchLeft - leftEdge), height: headerH)
        newTabButton.frame = NSRect(x: rightEdge - 20, y: bodyH - headerH + (headerH - 20) / 2, width: 20, height: 20)
        mediaView.frame = NSRect(x: notchRight, y: bodyH - headerH,
                                 width: max(0, newTabButton.frame.minX - 10 - notchRight), height: headerH)
        refreshTabBar()
        refreshMedia()
    }

    private func expandedPath() -> CGPath {
        let b = root.bounds
        return NotchShape.path(body: CGRect(x: ear, y: 0, width: b.width - 2 * ear, height: b.height),
                               ear: ear, radius: CGFloat(config.cornerRadius))
    }

    private func collapsedPath() -> CGPath {
        let b = root.bounds
        let body = CGRect(x: b.midX - metrics.width / 2, y: b.height - metrics.height,
                          width: metrics.width, height: metrics.height)
        return NotchShape.path(body: body, ear: min(ear, 6), radius: min(metrics.height * 0.35, 12))
    }

    // MARK: - Apri / chiudi

    func toggle() { isOpen ? close() : open() }

    private var fadingViews: [NSView] { [current.view, tabBar, newTabButton, mediaView] }

    // MARK: - Musica

    func updateMedia(track: NowPlayingTrack?, artwork: NSImage?) {
        mediaTrack = track
        mediaArtwork = artwork
        refreshMedia()
    }

    private func refreshMedia() {
        guard let track = mediaTrack, config.media.enabled, config.media.showInHeader, config.showHeader else {
            mediaView.isHidden = true
            return
        }
        mediaView.isHidden = false
        mediaView.update(track: track, artwork: mediaArtwork, tint: foreground)
    }

    func open() {
        guard !isOpen else { return }
        onWillOpen?()
        isOpen = true
        let reopeningMidClose = panel.isVisible
        if !reopeningMidClose { layoutForCurrentScreen() }

        let from = reopeningMidClose ? (root.maskLayer.presentation()?.path ?? collapsedPath()) : collapsedPath()
        if !reopeningMidClose { setPath(collapsedPath()) }

        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(current.view)
        current.refreshDirectory()
        if current.badge != nil { current.badge = nil; refreshTabBar() }
        animateMask(from: from, to: expandedPath(), opening: true, completion: nil)

        for v in fadingViews { v.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.style == "none" ? 0 : config.animation.duration * 0.6
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for v in fadingViews { v.animator().alphaValue = 1 }
        }

        if config.hideOnFocusLoss, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.close()
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }

        let from = root.maskLayer.presentation()?.path ?? expandedPath()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.animation.style == "none" ? 0 : config.animation.duration * 0.35
            for v in fadingViews { v.animator().alphaValue = 0 }
        }
        animateMask(from: from, to: collapsedPath(), opening: false) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
            self.onDidClose?()
        }
    }

    /// Maschera e bordo condividono sempre lo stesso contorno.
    private var shapeLayers: [CAShapeLayer] { [root.maskLayer, root.borderShape] }

    private func setPath(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in shapeLayers { l.path = path }
        CATransaction.commit()
    }

    private func animateMask(from: CGPath, to: CGPath, opening: Bool, completion: (() -> Void)?) {
        ShapeAnimator.animate(shapeLayers, from: from, to: to, opening: opening,
                              animation: config.animation, completion: completion)
    }

    @objc private func panelResignedKey() {
        if config.hideOnFocusLoss { close() }
    }

    @objc private func screensChanged() {
        if isOpen { layoutForCurrentScreen(); setPath(expandedPath()) }
    }

    // MARK: - Scorciatoie dentro il pannello

    /// Usa la barra di ricerca integrata di SwiftTerm (si chiude con Esc).
    private func findAction(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        current.view.performFindPanelAction(item)
    }

    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(e.keyCode)

        // ⌃Tab / ⌃⇧Tab: scheda successiva / precedente
        if code == kVK_Tab, mods == [.control] { cycleTab(1); return true }
        if code == kVK_Tab, mods == [.control, .shift] { cycleTab(-1); return true }

        guard mods.contains(.command) else { return false }

        // ⌘1…⌘8 = scheda n, ⌘9 = ultima
        if mods == [.command], let n = Self.digitKeyCodes[code] {
            selectTab(n == 9 ? sessions.count - 1 : n - 1)
            return true
        }
        // ⌘⇧[ / ⌘⇧] (anche ⌘⇧← / ⌘⇧→): scheda precedente / successiva
        if mods == [.command, .shift] {
            switch code {
            case kVK_ANSI_LeftBracket, kVK_LeftArrow: cycleTab(-1); return true
            case kVK_ANSI_RightBracket, kVK_RightArrow: cycleTab(1); return true
            default: break
            }
        }
        // ⌘⌥← / ⌘⌥→: sposta la scheda
        if mods == [.command, .option] {
            if code == kVK_LeftArrow { moveTab(-1); return true }
            if code == kVK_RightArrow { moveTab(1); return true }
        }

        if mods == [.command, .shift], code == kVK_ANSI_G { findAction(.previous); return true }

        guard mods == [.command], let key = e.charactersIgnoringModifiers?.lowercased() else {
            // ⌘⇧= (⌘+ su molte tastiere)
            if mods == [.command, .shift], e.charactersIgnoringModifiers == "+" {
                fontDelta += 1; applyFontToAll(); return true
            }
            return false
        }
        let terminal = current.view
        switch key {
        case "f": findAction(.showFindPanel); return true
        case "g": findAction(.next); return true
        case "t": newTabAction(); return true
        case "w": closeTab(at: selectedIndex); return true
        case "c": terminal.copy(self); return true
        case "v": terminal.paste(self); return true
        case "a": terminal.selectAll(self); return true
        case "k":
            terminal.clearScrollback()
            terminal.send(txt: "\u{0C}")
            return true
        case "=", "+": fontDelta += 1; applyFontToAll(); return true
        case "-": fontDelta -= 1; applyFontToAll(); return true
        case "0": fontDelta = 0; applyFontToAll(); return true
        case ",": close(); onOpenConfig?(); return true
        default: return false
        }
    }
}
