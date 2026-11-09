import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController!
    private var hotKey: HotKey?
    private var watcher: ConfigWatcher?
    private var statusItem: NSStatusItem!
    private var lastError: String?
    private var settings: SettingsWindowController?
    private let nowPlaying = NowPlayingMonitor()
    private var peek: PeekController!
    private var zone: NotchZoneController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, error) = ConfigStore.load()
        lastError = error
        controller = NotchController(config: config)
        controller.onOpenConfig = { [weak self] in self?.showSettings() }
        setUpMedia(config)
        setUpZone(config)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "NotchTerm")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotKey()
        // Permette di aprire/chiudere da script (Raycast, Shortcuts, skhd…):
        // osascript -l JavaScript -e '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("net.sangalli.notchterm.toggle", $(), $(), true)'
        DistributedNotificationCenter.default().addObserver(forName: .init("net.sangalli.notchterm.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("net.sangalli.notchterm.newtab"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.newTab() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("net.sangalli.notchterm.settings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        #if DEBUG
        // Solo nelle build di debug: scrive testo nella scheda corrente (per i test automatici).
        DistributedNotificationCenter.default().addObserver(forName: .init("net.sangalli.notchterm.debug-type"), object: nil, queue: .main) { [weak self] n in
            let text = n.userInfo?["text"] as? String ?? ""
            MainActor.assumeIsolated { self?.controller.debugType(text) }
        }
        #endif
        watcher = ConfigWatcher { [weak self] in self?.reloadConfig(silent: true) }
        if let error { showError(error) }
    }

    private func setUpMedia(_ config: Config) {
        peek = PeekController(config: config)
        nowPlaying.enabled = config.media.enabled
        let np = nowPlaying
        for target in [controller.mediaView.buttons] {
            target.onPlayPause = { np.playPause() }
            target.onNext = { np.next() }
            target.onPrevious = { np.previous() }
        }
        controller.mediaView.onActivate = { np.activatePlayer() }
        peek.onPlayPause = { np.playPause() }
        peek.onNext = { np.next() }
        peek.onPrevious = { np.previous() }
        peek.onActivate = { np.activatePlayer() }

        nowPlaying.onChange = { [weak self] trackChanged in
            guard let self else { return }
            let track = self.nowPlaying.track
            let art = self.nowPlaying.artwork
            self.controller.updateMedia(track: track, artwork: art)
            let media = self.controller.config.media
            if trackChanged, let track, track.isPlaying, media.enabled, media.peekOnTrackChange, !self.controller.isOpen {
                self.peek.show(track: track, artwork: art)
            } else {
                self.peek.refresh(track: track, artwork: art)
            }
        }
        controller.onCommandNotify = { [weak self] result, tab, show in
            self?.peek.show(command: result, tab: tab, onClick: show)
        }
        controller.onWillOpen = { [weak self] in
            self?.peek.hide(immediately: true)
            self?.nowPlaying.refreshIfNeeded()
        }
        // Per provare l'avviso dalle impostazioni o da script.
        DistributedNotificationCenter.default().addObserver(forName: .init("net.sangalli.notchterm.peek"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPeekPreview() }
        }
    }

    private func setUpZone(_ config: Config) {
        zone = NotchZoneController(config: config)
        zone.view.onHover = { [weak self] in self?.controller.open() }
        zone.view.onClick = { [weak self] in
            guard let self, self.zone.clickToOpen else { return }
            self.controller.open()
        }
        zone.view.onDragEnter = { [weak self] in self?.controller.open() }
        // Il pannello copre il notch quando è aperto: la zona si sospende.
        let previousWillOpen = controller.onWillOpen
        controller.onWillOpen = { [weak self] in
            previousWillOpen?()
            self?.zone.setSuspended(true)
        }
        controller.onDidClose = { [weak self] in self?.zone.setSuspended(false) }
    }

    func showPeekPreview() {
        let sample = NowPlayingTrack(source: .spotify, id: "preview", title: "Brano di esempio",
                                     artist: "NotchTerm", album: "", isPlaying: true)
        peek.show(track: nowPlaying.track ?? sample, artwork: nowPlaying.artwork)
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(controller.config.hotkey) { [weak self] in self?.controller.toggle() }
        if hotKey == nil {
            showError("Scorciatoia non valida o già in uso: \"\(controller.config.hotkey)\"")
        }
    }

    private func reloadConfig(silent: Bool) {
        let (config, error) = ConfigStore.load()
        if let error {
            // Config rotto: si tiene quello vecchio e si avvisa.
            if error != lastError { showError(error) }
            lastError = error
            return
        }
        lastError = nil
        let hotkeyChanged = config.hotkey != controller.config.hotkey
        controller.update(config: config)
        peek.config = config
        zone.update(config: config)
        nowPlaying.enabled = config.media.enabled
        settings?.model.externalUpdate(config)
        if hotkeyChanged { registerHotKey() }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "NotchTerm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Apri configurazione")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openConfig() }
    }

    // MARK: - Menu nella barra

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = controller.config

        let toggle = NSMenuItem(title: controller.isOpen ? "Nascondi terminale" : "Mostra terminale",
                                action: #selector(toggleTerminal), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        add(menu, "Nuova scheda", #selector(newTab), "")
        let hk = NSMenuItem(title: "Scorciatoia: \(HotKey.display(cfg.hotkey))", action: nil, keyEquivalent: "")
        hk.isEnabled = false
        menu.addItem(hk)
        menu.addItem(.separator())

        let themeItem = NSMenuItem(title: "Tema", action: nil, keyEquivalent: "")
        let themes = NSMenu()
        for name in Themes.names {
            let it = NSMenuItem(title: name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = cfg.theme.lowercased() == name ? .on : .off
            themes.addItem(it)
        }
        themeItem.submenu = themes
        menu.addItem(themeItem)

        menu.addItem(.separator())
        add(menu, "Impostazioni…", #selector(openSettings), ",")
        add(menu, "Apri config.json", #selector(openConfigAction), "")
        add(menu, "Ricarica configurazione", #selector(reloadAction), "r")
        add(menu, "Riavvia shell della scheda", #selector(restartShell), "")

        menu.addItem(.separator())
        add(menu, "Esci da NotchTerm", #selector(quit), "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    @objc private func toggleTerminal() {
        // Il menu si chiude prima: altrimenti il click verrebbe visto come "focus perso".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.controller.toggle() }
    }

    @objc private func newTab() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.controller.newTab(directory: nil)
            self.controller.open()
        }
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        ConfigStore.selectTheme(sender.representedObject as! String)
        reloadConfig(silent: true)
    }

    @objc private func openSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.showSettings() }
    }

    private func showSettings() {
        if settings == nil {
            let model = SettingsModel(config: controller.config)
            model.onTryAnimation = { [weak self] in self?.controller.toggle() }
            model.onOpenConfigFile = { [weak self] in self?.openConfig() }
            model.onTryPeek = { [weak self] in self?.showPeekPreview() }
            settings = SettingsWindowController(model: model)
        }
        controller.close()
        settings?.show()
    }

    @objc private func openConfigAction() { openConfig() }

    private func openConfig() {
        ConfigStore.ensureFileExists()
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    @objc private func reloadAction() { reloadConfig(silent: false) }
    @objc private func restartShell() { controller.restartShell() }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
