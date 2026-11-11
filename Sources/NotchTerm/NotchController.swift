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
    /// Pulsante dell'assistente nell'header, accanto al "+".
    private let aiButton = NSButton()
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
    /// L'ultimo parametro, se c'è, chiede all'AI di spiegare l'errore (etichetta, azione).
    var onCommandNotify: ((CommandResult, String?, @escaping () -> Void, (label: String, action: () -> Void)?) -> Void)?
    /// Un comando è partito o finito in una scheda (per l'indicatore nel notch).
    var onActivityChange: (() -> Void)?
    /// Apre le impostazioni sulla sezione AI.
    var onOpenAISettings: (() -> Void)?
    private var pendingSave: DispatchWorkItem?

    /// Assistente AI in fondo al terminale.
    private let aiOverlay = AIOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    private var aiTask: Task<Void, Never>?
    /// Cresce a ogni richiesta: gli aggiornamenti di richieste superate si scartano.
    private var aiRequestID = 0
    /// Chat con l'assistente: messaggi inviati al modello e come si mostrano.
    private var chatHistory: [AIMessage] = []
    private var chatTurns: [AIOverlayView.ChatTurn] = []

    var tabCount: Int { sessions.count }

    init(config: Config, restoring saved: SavedTabs? = nil) {
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

        aiButton.isBordered = false
        aiButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Assistente AI")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        aiButton.imagePosition = .imageOnly
        aiButton.target = self
        aiButton.action = #selector(aiButtonAction)
        root.addSubview(aiButton)
        root.addSubview(mediaView)
        aiOverlay.isHidden = true
        aiOverlay.onClose = { [weak self] in self?.closeAI() }
        aiOverlay.onResize = { [weak self] in self?.layoutAI() }
        aiOverlay.onInsert = { [weak self] cmd in self?.insertCommand(cmd) }
        aiOverlay.onSubmit = { [weak self] text in self?.runCommandRequest(text) }
        aiOverlay.onChatSubmit = { [weak self] text, attach in self?.sendChat(text, attachOutput: attach) }
        aiOverlay.onNewChat = { [weak self] in self?.newChat() }
        aiOverlay.onOpenSettings = { [weak self] in
            self?.closeAI()
            self?.close()
            self?.onOpenAISettings?()
        }
        root.addSubview(aiOverlay)

        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        applyAppearance()
        if let saved, config.restoreTabs {
            for dir in saved.directories { newTab(directory: dir) }
            selectTab(saved.selected)
        } else {
            newTab(directory: nil)
        }
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
        aiButton.contentTintColor = NSColor(srgbRed: 0.75, green: 0.6, blue: 1, alpha: 0.95)
        aiButton.toolTip = "\(AIProvider.named(config.ai.provider).askLabel) (⌘J)"
        aiOverlay.applyTheme(foreground: foreground, background: bg)
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
        s.onActivityChange = { [weak self] _ in self?.onActivityChange?() }
        // Il terminale va sotto al riquadro dell'assistente.
        root.addSubview(s.view, positioned: .below, relativeTo: aiOverlay)
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
        s.onActivityChange = nil
        s.terminate()
        s.view.removeFromSuperview()
        if selectedIndex >= sessions.count || index < selectedIndex { selectedIndex = max(0, selectedIndex - 1) }
        selectTab(selectedIndex)
        if s.runningCommand != nil { onActivityChange?() }
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

    /// Pilota l'assistente dai test: "ask" con un testo, "explain", "insert".
    func debugAI(action: String, text: String) {
        switch action {
        case "ask":
            askAI()
            aiOverlay.input.stringValue = text
            aiOverlay.input.sendAction(aiOverlay.input.action, to: aiOverlay.input.target)
        case "explain": explainAI()
        case "chat":
            chatAI()
            if !text.isEmpty {
                aiOverlay.input.stringValue = text
                aiOverlay.input.sendAction(aiOverlay.input.action, to: aiOverlay.input.target)
            }
        case "close": closeAI()
        default: break
        }
    }

    /// Salva un'immagine del pannello (per controllare l'aspetto senza catturare lo schermo).
    func debugSnapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
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

    // MARK: - Assistente AI

    private var aiSettings: AISettings {
        AISettings(config.ai, key: AIKeychain.key(for: AIProvider.named(config.ai.provider).id))
    }

    private var aiContext: AIPrompts.Context {
        current.refreshDirectory()
        let shell = config.shell.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : config.shell
        return AIPrompts.Context(shell: (shell as NSString).lastPathComponent, directory: current.cwd)
    }

    /// true se l'assistente si può usare; altrimenti mostra il motivo nel riquadro.
    private func checkAI() -> Bool {
        if !config.ai.enabled {
            aiOverlay.setError("L'assistente AI è disattivato.", offerSettings: true)
            return false
        }
        if let problem = aiSettings.problem {
            aiOverlay.setError(problem, offerSettings: true)
            return false
        }
        return true
    }

    private func showAI() {
        aiOverlay.isHidden = false
        layoutAI()
    }

    func layoutAI() {
        guard !aiOverlay.isHidden else { return }
        let w = terminalFrame.width
        aiOverlay.maxTextHeight = max(60, terminalFrame.height * 0.5)
        let h = min(terminalFrame.height, aiOverlay.preferredHeight(width: w))
        aiOverlay.frame = NSRect(x: terminalFrame.minX, y: terminalFrame.minY, width: w, height: h)
        aiOverlay.needsLayout = true
    }

    func closeAI(refocus: Bool = true) {
        aiTask?.cancel()
        aiTask = nil
        aiRequestID += 1
        aiOverlay.isHidden = true
        if refocus, isOpen { panel.makeFirstResponder(current.view) }
    }

    // MARK: Chat

    @objc private func aiButtonAction() {
        // Secondo clic: chiude la chat.
        if !aiOverlay.isHidden, aiOverlay.mode == .chat { closeAI(); return }
        chatAI()
    }

    /// ⌘J o il pulsante ✦: conversazione libera con l'assistente.
    func chatAI() {
        if !isOpen { open() }
        aiTask?.cancel()
        aiRequestID += 1
        aiOverlay.showChat(title: AIProvider.named(config.ai.provider).isClaude ? "Chat con Claude" : "Chat con l'AI",
                           turns: chatTurns)
        showAI()
        if checkAI() { panel.makeFirstResponder(aiOverlay.input) }
    }

    private func newChat() {
        aiTask?.cancel()
        aiRequestID += 1
        chatHistory = []
        chatTurns = []
        aiOverlay.setChat(turns: [], streaming: nil)
        panel.makeFirstResponder(aiOverlay.input)
    }

    private func sendChat(_ text: String, attachOutput: Bool) {
        guard checkAI() else { return }
        // Una domanda rimasta senza risposta (errore, chat chiusa a metà) si sostituisce con questa.
        if chatHistory.last?.role == "user" {
            chatHistory.removeLast()
            if chatTurns.last?.role == "user" { chatTurns.removeLast() }
        }
        var content = text
        if attachOutput {
            let output = current.recentOutput(lines: aiSettings.contextLines)
            content += "\n\nUltime righe del mio terminale:\n```\n\(output)\n```"
        }
        chatHistory.append(AIMessage(role: "user", content: content))
        chatTurns.append(.init(role: "user", text: text, attachedOutput: attachOutput))
        aiOverlay.setChat(turns: chatTurns, streaming: "")
        let request = AIPrompts.chat(chatHistory, aiContext)
        run(request) { [weak self] reply, finished in
            guard let self else { return }
            if finished {
                self.chatHistory.append(AIMessage(role: "assistant", content: reply))
                self.chatTurns.append(.init(role: "assistant", text: reply))
                self.aiOverlay.setChat(turns: self.chatTurns, streaming: nil)
            } else {
                self.aiOverlay.setChat(turns: self.chatTurns, streaming: reply)
            }
        }
    }

    /// ⌘I: descrivi cosa vuoi fare, ricevi il comando.
    func askAI() {
        if !isOpen { open() }
        aiTask?.cancel()
        aiOverlay.showAsk(title: "\(AIProvider.named(config.ai.provider).askLabel) un comando")
        showAI()
        if checkAI() { panel.makeFirstResponder(aiOverlay.input) }
    }

    private func runCommandRequest(_ text: String) {
        guard checkAI() else { return }
        let request = AIPrompts.command(text, aiContext)
        run(request) { [weak self] reply, finished in
            guard finished else { return }
            let (cmd, explanation) = AIPrompts.parseCommand(reply)
            self?.aiOverlay.setCommand(cmd, explanation: explanation, prompt: text)
        }
    }

    /// ⌘⇧E: spiega il testo selezionato o, senza selezione, l'ultimo comando fallito.
    func explainAI() {
        if let text = current.selectedText {
            startExplain(title: "Spiegazione della selezione", request: AIPrompts.explainText(String(text.prefix(12_000)), aiContext))
        } else if let r = current.lastResult, !r.succeeded {
            explainFailure(r, in: current)
        } else {
            if !isOpen { open() }
            aiOverlay.showExplain(title: "Spiega")
            showAI()
            aiOverlay.setError("Seleziona del testo da spiegare, oppure usa ⌘⇧E dopo un comando fallito.", offerSettings: false)
        }
    }

    /// Spiega l'ultimo comando fallito della scheda di `session` (anche dall'avviso nel notch).
    func explainFailure(_ result: CommandResult, in session: TerminalSession) {
        if let i = sessions.firstIndex(where: { $0 === session }) { selectTab(i) }
        let output = session.recentOutput(lines: aiSettings.contextLines)
        let cmd = result.command.isEmpty ? "(sconosciuto)" : result.command
        startExplain(title: "Perché «\(String(cmd.prefix(60)))» non ha funzionato",
                     request: AIPrompts.explainFailure(command: cmd, exitCode: result.exitCode, output: output, aiContext))
    }

    private func startExplain(title: String, request: AIRequest) {
        if !isOpen { open() }
        aiTask?.cancel()
        aiOverlay.showExplain(title: title)
        showAI()
        guard checkAI() else { return }
        run(request) { [weak self] reply, finished in
            self?.aiOverlay.setExplanation(reply, finished: finished)
        }
    }

    /// Esegue una richiesta in streaming; `update` riceve il testo accumulato.
    private func run(_ request: AIRequest, update: @escaping @MainActor (String, Bool) -> Void) {
        let client = AIClient(settings: aiSettings)
        aiTask?.cancel()
        aiRequestID += 1
        let id = aiRequestID
        aiTask = Task { [weak self] in
            var text = ""
            do {
                let full = try await client.stream(request) { chunk in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            text += chunk
                            if self?.aiRequestID == id { update(text, false) }
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                // Il testo finale si usa dopo gli ultimi aggiornamenti in coda.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if self?.aiRequestID == id { update(full, true) } }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let local = AIProvider.named(self?.config.ai.provider ?? "").needsKey == false
                let hint = local && (error as? URLError)?.code == .cannotConnectToHost
                    ? " Il server locale è avviato?" : ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.aiRequestID == id else { return }
                        self?.aiOverlay.setError(message + hint, offerSettings: error is AIError)
                    }
                }
            }
        }
    }

    /// Scrive il comando nel prompt senza eseguirlo e chiude l'assistente.
    private func insertCommand(_ cmd: String) {
        closeAI()
        current.view.send(txt: cmd)
    }

    // MARK: - Comandi in corso

    private func isIgnored(_ command: String) -> Bool {
        CommandResult.isIgnored(command, list: config.commandNotify.ignore)
    }

    /// Il comando in esecuzione da più tempo (esclusi i programmi interattivi).
    /// `tab` è il titolo della scheda se ce n'è più di una; `count` quanti comandi girano.
    var activity: (command: String, since: Date, tab: String?, count: Int)? {
        let running = sessions.filter { s in
            guard let cmd = s.runningCommand, s.runningSince != nil else { return false }
            return !isIgnored(cmd)
        }
        guard let oldest = running.min(by: { $0.runningSince! < $1.runningSince! }) else { return nil }
        return (oldest.runningCommand ?? "", oldest.runningSince!,
                sessions.count > 1 ? oldest.plainShortTitle : nil, running.count)
    }

    /// Apre il terminale sulla scheda del comando in corso da più tempo.
    func openRunningTab() {
        let running = sessions.enumerated().filter { $0.element.runningSince != nil && !isIgnored($0.element.runningCommand ?? "") }
        if let oldest = running.min(by: { $0.element.runningSince! < $1.element.runningSince! }) {
            selectTab(oldest.offset)
        }
        open()
    }

    // MARK: - Schede salvate

    /// Stato attuale delle schede, con le cartelle lette dal kernel.
    func savedTabs() -> SavedTabs {
        for s in sessions { s.refreshDirectory() }
        return SavedTabs(directories: sessions.map(\.cwd), selected: selectedIndex)
    }

    func saveTabs() {
        pendingSave?.cancel()
        pendingSave = nil
        guard config.restoreTabs else { return }
        TabStore.save(savedTabs())
    }

    private func scheduleSave() {
        guard config.restoreTabs else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveTabs() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Fine comando

    private func commandFinished(_ s: TerminalSession, _ result: CommandResult) {
        let cfg = config.commandNotify
        guard cfg.enabled, result.duration >= cfg.minDuration,
              cfg.notifyOnSuccess || !result.succeeded, !isIgnored(result.command),
              let index = sessions.firstIndex(where: { $0 === s }) else { return }
        // Già sotto gli occhi dell'utente: niente avviso.
        if isOpen && index == selectedIndex { return }
        s.badge = result.succeeded ? "✓" : "✗"
        refreshTabBar()
        if !isOpen {
            let tab = sessions.count > 1 ? s.plainShortTitle : nil
            let show = { [weak self, weak s] in
                guard let self, let s, let i = self.sessions.firstIndex(where: { $0 === s }) else { return }
                self.selectTab(i)
                self.open()
            }
            var ask: (label: String, action: () -> Void)?
            if !result.succeeded, config.ai.enabled {
                ask = (AIProvider.named(config.ai.provider).askLabel, { [weak self, weak s] in
                    guard let self, let s else { return }
                    if !self.isOpen { self.open() }
                    self.explainFailure(result, in: s)
                })
            }
            onCommandNotify?(result, tab, show, ask)
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
        aiButton.isHidden = !config.showHeader || !config.ai.enabled
        scheduleSave()
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
        layoutAI()
        newTabButton.frame = NSRect(x: rightEdge - 20, y: bodyH - headerH + (headerH - 20) / 2, width: 20, height: 20)
        aiButton.frame = NSRect(x: newTabButton.frame.minX - 26, y: newTabButton.frame.minY, width: 20, height: 20)
        let mediaRight = (aiButton.isHidden ? newTabButton.frame.minX : aiButton.frame.minX) - 10
        mediaView.frame = NSRect(x: notchRight, y: bodyH - headerH,
                                 width: max(0, mediaRight - notchRight), height: headerH)
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

    private var fadingViews: [NSView] { [current.view, tabBar, newTabButton, aiButton, mediaView] }

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
        if !aiOverlay.isHidden { closeAI(refocus: false) }
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

        // Esc chiude l'assistente (se è aperto); altrimenti arriva al terminale.
        if code == kVK_Escape, mods.isEmpty, !aiOverlay.isHidden { closeAI(); return true }
        // ⌘I: comando dal linguaggio naturale. ⌘⇧E: spiega selezione o ultimo errore.
        if code == kVK_ANSI_I, mods == [.command] { askAI(); return true }
        if code == kVK_ANSI_J, mods == [.command] { chatAI(); return true }
        if code == kVK_ANSI_E, mods == [.command, .shift] { explainAI(); return true }

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
