import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController!
    private var hotKey: HotKey?
    private var watcher: ConfigWatcher?
    private var statusItem: NSStatusItem!
    private var lastError: String?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, error) = ConfigStore.load()
        lastError = error
        controller = NotchController(config: config)
        controller.onOpenConfig = { [weak self] in self?.showSettings() }

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
        watcher = ConfigWatcher { [weak self] in self?.reloadConfig(silent: true) }
        if let error { showError(error) }
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
