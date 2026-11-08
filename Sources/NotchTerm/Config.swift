import AppKit

/// Tutta la configurazione utente. Ogni campo ha un default: nel file JSON
/// basta scrivere solo le chiavi che si vogliono cambiare.
struct Config: Codable, Equatable {
    struct Font: Codable, Equatable {
        /// Nome PostScript o nome famiglia (es. "Menlo", "JetBrainsMono-Regular").
        /// Vuoto = monospace di sistema (SF Mono).
        var name: String = ""
        var size: Double = 13
    }

    struct Animation: Codable, Equatable {
        /// "spring", "ease" oppure "none"
        var style: String = "spring"
        var duration: Double = 0.42
        /// Solo per "spring": 0.5 = molto elastico, 1.0 = nessun rimbalzo.
        var damping: Double = 0.82
    }

    /// Controllo di Spotify / Apple Music.
    struct Media: Codable, Equatable {
        var enabled: Bool = true
        /// Mini-player a destra del notch quando il terminale è aperto.
        var showInHeader: Bool = true
        /// Il notch si allarga per qualche secondo quando cambia brano.
        var peekOnTrackChange: Bool = true
        /// Secondi di permanenza dell'avviso.
        var peekDuration: Double = 4
    }

    /// Avviso dal notch quando termina un comando lungo.
    struct CommandNotify: Codable, Equatable {
        var enabled: Bool = true
        /// Durata minima (secondi) perché un comando meriti l'avviso.
        var minDuration: Double = 10
        /// Avvisa anche quando il comando va a buon fine (non solo in caso di errore).
        var notifyOnSuccess: Bool = true
    }

    /// Colori che sovrascrivono quelli del tema. Formato "#RRGGBB".
    struct Colors: Codable, Equatable {
        var background: String?
        var foreground: String?
        var cursor: String?
        var selection: String?
        /// 16 colori ANSI (0-7 normali, 8-15 brillanti).
        var ansi: [String]?
    }

    /// Scorciatoia globale, es. "ctrl+`", "option+space", "cmd+shift+t", "f12".
    var hotkey: String = "ctrl+`"

    /// Dimensioni del pannello aperto. Valori <= 1 sono frazioni dello schermo.
    var width: Double = 0.55
    var height: Double = 0.45

    /// Raggio degli angoli inferiori.
    var cornerRadius: Double = 22
    /// Raggio delle "orecchie" concave che raccordano il pannello al bordo superiore.
    var earRadius: Double = 10
    /// Margine interno attorno al testo.
    var padding: Double = 14

    /// Nome di un tema incluso (vedi Themes.swift) — "notch", "dracula", "nord", ...
    var theme: String = "notch"
    var colors: Colors = Colors()
    /// Materiale dello sfondo: "solid", "blur", "glass" (Liquid Glass), "glass-clear".
    /// Se assente vale quello del tema.
    var material: String?
    /// Opacità della tinta di sfondo (0...1). Se assente vale quella del tema.
    var opacity: Double?
    /// Intensità del bordo luminoso (0 = nessun bordo). Se assente vale quella del tema.
    var borderOpacity: Double?
    /// Vecchia opzione, equivale a "material": "blur".
    var blur: Bool?

    var font: Font = Font()
    /// "block", "bar", "underline", con suffisso opzionale "-blink" (es. "bar-blink").
    var cursorStyle: String = "block-blink"

    /// Shell da avviare. Vuoto = $SHELL dell'utente.
    var shell: String = ""
    var shellArgs: [String] = ["-l"]
    var workingDirectory: String = "~"
    /// Variabili d'ambiente aggiuntive.
    var env: [String: String] = [:]
    /// Riavvia la shell quando termina (es. dopo `exit`).
    var restartShellOnExit: Bool = true

    var animation: Animation = Animation()
    var media: Media = Media()
    var commandNotify: CommandNotify = CommandNotify()
    /// Integrazione zsh: serve all'avviso a fine comando.
    var shellIntegration: Bool = true
    /// Chiude il pannello quando si clicca altrove.
    var hideOnFocusLoss: Bool = true
    /// Su quale schermo aprire: "notch" (quello col notch, se c'è), "main", "mouse".
    var screen: String = "notch"
    /// Mostra il titolo/cartella corrente accanto al notch.
    var showHeader: Bool = true
    /// Usa Option come tasto Meta (utile in emacs/readline).
    var optionAsMeta: Bool = true
    /// Le nuove schede si aprono nella cartella della scheda corrente.
    var newTabInheritsDirectory: Bool = true
    /// Larghezza massima di una linguetta.
    var maxTabWidth: Double = 170
    /// Larghezza del "notch finto" sugli schermi senza notch.
    var fallbackNotchWidth: Double = 190
}

// MARK: - Caricamento / salvataggio

enum ConfigStore {
    static let directory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/notchterm", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Carica il file utente fondendolo sopra ai default. Restituisce anche
    /// l'eventuale errore di parsing, così l'app può mostrarlo senza crashare.
    static func load() -> (Config, String?) {
        ensureFileExists()
        guard let data = try? Data(contentsOf: fileURL) else { return (Config(), nil) }
        do {
            let user = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let userDict = user as? [String: Any] else {
                return (Config(), "config.json deve contenere un oggetto JSON")
            }
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
            let merged = deepMerge(defaults, userDict)
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            return (try JSONDecoder().decode(Config.self, from: mergedData), nil)
        } catch {
            return (Config(), "Errore in config.json: \(error.localizedDescription)")
        }
    }

    /// Cambia una singola chiave di primo livello preservando il resto del file.
    static func set(_ key: String, _ value: Any) {
        update(set: [key: value], remove: [])
    }

    /// Imposta e rimuove più chiavi di primo livello in una sola scrittura.
    static func update(set values: [String: Any], remove: [String]) {
        ensureFileExists()
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        }
        for (k, v) in values { dict[k] = v }
        for k in remove { dict.removeValue(forKey: k) }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Sceglie un tema togliendo gli override di aspetto, così valgono i default del tema.
    static func selectTheme(_ name: String) {
        update(set: ["theme": name], remove: ["material", "opacity", "borderOpacity", "blur"])
    }

    /// Valori top-level di un Config, per confrontare due versioni e salvare solo le differenze.
    static func dictionary(_ config: Config) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func ensureFileExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(Config()) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            if let b = base[key] as? [String: Any], let o = value as? [String: Any] {
                result[key] = deepMerge(b, o)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// Osserva la cartella di configurazione e richiama `onChange` quando il file cambia.
/// Si osserva la cartella (non il file) perché molti editor salvano sostituendo il file.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        ConfigStore.ensureFileExists()
        let fd = open(ConfigStore.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onChange() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    deinit { source?.cancel() }
}

// MARK: - Utilità colore

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255; a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
