import AppKit
import SwiftUI
import ServiceManagement

/// Stato della finestra Impostazioni. Ogni modifica viene scritta in config.json
/// (solo le chiavi cambiate): il watcher del file la applica subito al pannello.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet { if !applyingExternal { scheduleSave() } }
    }
    @Published var recordingHotkey = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onTryAnimation: (() -> Void)?
    var onTryPeek: (() -> Void)?
    var onOpenConfigFile: (() -> Void)?

    private var lastSaved: Config
    private var applyingExternal = false
    private var pendingSave: DispatchWorkItem?

    init(config: Config) {
        self.config = config
        lastSaved = config
    }

    /// Il file è cambiato da fuori (editor, menu): si aggiorna la UI senza riscrivere.
    func externalUpdate(_ new: Config) {
        guard new != config else { lastSaved = new; return }
        applyingExternal = true
        config = new
        lastSaved = new
        applyingExternal = false
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func save() {
        let old = ConfigStore.dictionary(lastSaved)
        let new = ConfigStore.dictionary(config)
        var set: [String: Any] = [:]
        var remove: [String] = []
        for (k, v) in new where !((old[k] as AnyObject?)?.isEqual(v) ?? false) {
            set[k] = v
        }
        for k in old.keys where new[k] == nil { remove.append(k) }
        guard !set.isEmpty || !remove.isEmpty else { return }
        lastSaved = config
        ConfigStore.update(set: set, remove: remove)
    }

    // MARK: Azioni

    func selectTheme(_ name: String) {
        var c = config
        c.theme = name
        c.material = nil
        c.opacity = nil
        c.borderOpacity = nil
        c.blur = nil
        config = c
    }

    func resetToDefaults() {
        config = Config()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var recorder: Any?

    func startRecording() {
        recordingHotkey = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                self.stopRecording()   // Esc annulla
                return nil
            }
            if let spec = HotKey.spec(from: event) {
                self.config.hotkey = spec
                self.stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stopRecording() {
        if let r = recorder { NSEvent.removeMonitor(r) }
        recorder = nil
        recordingHotkey = false
    }

    // MARK: Binding di comodo per i valori opzionali (default dal tema)

    var surface: Surface { Surface.resolve(config) }

    var materialBinding: Binding<String> {
        Binding(get: { self.surface.material }, set: { self.config.material = $0; self.config.blur = nil })
    }
    var opacityBinding: Binding<Double> {
        Binding(get: { self.surface.opacity }, set: { self.config.opacity = ($0 * 100).rounded() / 100 })
    }
    var borderBinding: Binding<Double> {
        Binding(get: { self.surface.borderOpacity }, set: { self.config.borderOpacity = ($0 * 100).rounded() / 100 })
    }

    /// Larghezza/altezza come frazione dello schermo (anche se nel file sono in pixel).
    func fractionBinding(_ keyPath: WritableKeyPath<Config, Double>, total: CGFloat) -> Binding<Double> {
        Binding(get: {
            let v = self.config[keyPath: keyPath]
            return v <= 1 ? v : min(1, v / Double(total))
        }, set: { self.config[keyPath: keyPath] = ($0 * 100).rounded() / 100 })
    }

    static let monospacedFamilies: [String] = {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { family in
            guard let f = NSFont(name: family, size: 12) ?? fm.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return f.isFixedPitch || f.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }.sorted()
    }()
}

// MARK: - Finestra

@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) { self.model = model }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Impostazioni NotchTerm"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 620, height: 600))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Viste SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("Generale", systemImage: "gearshape") }
            AppearanceTab(model: model).tabItem { Label("Aspetto", systemImage: "paintpalette") }
            AnimationTab(model: model).tabItem { Label("Animazione", systemImage: "wand.and.rays") }
            MusicTab(model: model).tabItem { Label("Musica", systemImage: "music.note") }
            ShellTab(model: model).tabItem { Label("Shell", systemImage: "terminal") }
        }
        .padding(.top, 8)
        .frame(width: 620, height: 600)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Apri config.json") { model.onOpenConfigFile?(); return }
                Spacer()
                Button("Ripristina predefiniti") { model.resetToDefaults() }
            }
            .padding(12)
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Scorciatoia globale") {
                HStack {
                    Text(HotKey.display(model.config.hotkey))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    Spacer()
                    if model.recordingHotkey {
                        Text("Premi la combinazione… (Esc annulla)").foregroundStyle(.secondary)
                        Button("Annulla") { model.stopRecording() }
                    } else {
                        Button("Registra…") { model.startRecording() }
                    }
                }
            }
            Section("Comportamento") {
                Picker("Schermo", selection: $model.config.screen) {
                    Text("Con il notch").tag("notch")
                    Text("Principale").tag("main")
                    Text("Sotto il mouse").tag("mouse")
                }
                Toggle("Nascondi quando clicchi altrove", isOn: $model.config.hideOnFocusLoss)
                Toggle("Mostra titolo e schede accanto al notch", isOn: $model.config.showHeader)
                Toggle("Le nuove schede si aprono nella cartella corrente", isOn: $model.config.newTabInheritsDirectory)
                Toggle("Avvia al login", isOn: Binding(get: { model.launchAtLogin },
                                                       set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceTab: View {
    @ObservedObject var model: SettingsModel
    private var screen: CGSize { NSScreen.screens.first?.frame.size ?? CGSize(width: 1512, height: 982) }

    var body: some View {
        Form {
            Section("Tema") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(Themes.names, id: \.self) { name in
                        ThemeSwatch(name: name, selected: model.config.theme.lowercased() == name)
                            .onTapGesture { model.selectTheme(name) }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Sfondo") {
                Picker("Materiale", selection: model.materialBinding) {
                    Text("Pieno").tag("solid")
                    Text("Sfocato").tag("blur")
                    Text("Liquid Glass").tag("glass")
                    Text("Liquid Glass trasparente").tag("glass-clear")
                }
                LabeledSlider(title: "Opacità tinta", value: model.opacityBinding, range: 0...1, format: percent)
                LabeledSlider(title: "Bordo luminoso", value: model.borderBinding, range: 0...1, format: percent)
            }
            Section("Testo") {
                Picker("Font", selection: $model.config.font.name) {
                    Text("Sistema (SF Mono)").tag("")
                    Divider()
                    ForEach(SettingsModel.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !model.config.font.name.isEmpty && !SettingsModel.monospacedFamilies.contains(model.config.font.name) {
                        Text(model.config.font.name).tag(model.config.font.name)
                    }
                }
                Stepper(value: $model.config.font.size, in: 8...32, step: 1) {
                    Text("Dimensione: \(Int(model.config.font.size)) pt")
                }
                Picker("Cursore", selection: $model.config.cursorStyle) {
                    Text("Blocco").tag("block")
                    Text("Blocco lampeggiante").tag("block-blink")
                    Text("Barra").tag("bar")
                    Text("Barra lampeggiante").tag("bar-blink")
                    Text("Sottolineato").tag("underline")
                    Text("Sottolineato lampeggiante").tag("underline-blink")
                }
            }
            Section("Forma e dimensioni") {
                LabeledSlider(title: "Larghezza", value: model.fractionBinding(\.width, total: screen.width), range: 0.25...1, format: percent)
                LabeledSlider(title: "Altezza", value: model.fractionBinding(\.height, total: screen.height), range: 0.2...1, format: percent)
                LabeledSlider(title: "Angoli in basso", value: $model.config.cornerRadius, range: 0...48, format: points)
                LabeledSlider(title: "Raccordi in alto", value: $model.config.earRadius, range: 0...24, format: points)
                LabeledSlider(title: "Margine interno", value: $model.config.padding, range: 0...40, format: points)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AnimationTab: View {
    @ObservedObject var model: SettingsModel

    private var styleBinding: Binding<String> {
        Binding(get: { model.config.animation.style }, set: { model.config.animation.style = $0 })
    }
    private var durationBinding: Binding<Double> {
        Binding(get: { model.config.animation.duration }, set: { model.config.animation.duration = ($0 * 100).rounded() / 100 })
    }
    private var dampingBinding: Binding<Double> {
        Binding(get: { model.config.animation.damping }, set: { model.config.animation.damping = ($0 * 100).rounded() / 100 })
    }

    var body: some View {
        Form {
            Section("Apertura e chiusura") {
                Picker("Stile", selection: styleBinding) {
                    Text("Elastica").tag("spring")
                    Text("Morbida").tag("ease")
                    Text("Nessuna").tag("none")
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Durata", value: durationBinding, range: 0.1...1.2, format: seconds)
                    .disabled(model.config.animation.style == "none")
                LabeledSlider(title: "Smorzamento", value: dampingBinding, range: 0.4...1, format: twoDecimals)
                    .disabled(model.config.animation.style != "spring")
                Text("Valori bassi di smorzamento = più rimbalzo.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Prova l'animazione") { tryAnimation() }
            }
        }
        .formStyle(.grouped)
    }

    private func tryAnimation() { model.onTryAnimation?() }
}

private struct MusicTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Controlla Spotify e Apple Music", isOn: $model.config.media.enabled)
            } footer: {
                Text("Per comandare la riproduzione macOS chiede una volta il permesso di Automazione. Il lettore non viene mai avviato da NotchTerm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dove") {
                Toggle("Mini-player a destra del notch", isOn: $model.config.media.showInHeader)
                Toggle("Mostra il brano quando cambia", isOn: $model.config.media.peekOnTrackChange)
                LabeledSlider(title: "Durata avviso", value: $model.config.media.peekDuration, range: 2...10,
                              format: { v in "\(Int(v.rounded())) s" })
                    .disabled(!model.config.media.peekOnTrackChange)
                Button("Prova l'avviso") { tryPeek() }
            }
            .disabled(!model.config.media.enabled)
        }
        .formStyle(.grouped)
    }

    private func tryPeek() { model.onTryPeek?() }
}

private struct ShellTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Shell") {
                TextField("Programma", text: $model.config.shell, prompt: Text(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"))
                TextField("Argomenti", text: Binding(
                    get: { model.config.shellArgs.joined(separator: " ") },
                    set: { model.config.shellArgs = $0.split(separator: " ").map(String.init) }))
                TextField("Cartella iniziale", text: $model.config.workingDirectory)
                Toggle("Riavvia la shell quando termina", isOn: $model.config.restartShellOnExit)
                Toggle("Option come tasto Meta", isOn: $model.config.optionAsMeta)
            }
            Section {
                Text("Le variabili d'ambiente (\"env\") si impostano in config.json. Cambiare shell o argomenti riavvia la scheda corrente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Componenti

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
private func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }
private func twoDecimals(_ v: Double) -> String { String(format: "%.2f", v) }

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

private struct ThemeSwatch: View {
    let name: String
    let selected: Bool

    var body: some View {
        let t = Themes.all[name]!
        let glass = t.material.hasPrefix("glass")
        VStack(spacing: 5) {
            ZStack {
                if glass {
                    LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 0.95), Color(red: 0.85, green: 0.45, blue: 0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(.ultraThinMaterial)
                    Color(nsColor: NSColor(hex: t.background) ?? .black).opacity(t.opacity)
                } else {
                    Color(nsColor: NSColor(hex: t.background) ?? .black)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ ls").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: NSColor(hex: t.foreground) ?? .white))
                    HStack(spacing: 3) {
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                            Circle().fill(Color(nsColor: NSColor(hex: t.ansi[i]) ?? .gray)).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
            Text(name).font(.caption2).lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}
