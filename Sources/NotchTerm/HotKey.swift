import Carbon.HIToolbox
import AppKit

/// Scorciatoia globale tramite Carbon `RegisterEventHotKey`: funziona
/// anche quando l'app non è in primo piano e non richiede permessi di accessibilità.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let action: @MainActor () -> Void

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init?(_ spec: String, action: @escaping @MainActor () -> Void) {
        guard let (code, mods) = HotKey.parse(spec) else { return nil }
        self.action = action
        let id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installHandlerOnce()

        let hkID = EventHotKeyID(signature: OSType(0x4E544D52) /* NTMR */, id: id)
        let status = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.instances[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.instances = HotKey.instances.filter { $0.value !== self }
    }

    private static var handlerInstalled = false

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id; DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.instances[id]?.action() } }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    // MARK: Parsing "ctrl+shift+t"

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "")
            .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "ctrl++" → ultimo pezzo vuoto significa il tasto "+"
        var keys = parts
        if spec.hasSuffix("++") { keys = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = keys.last, !keyName.isEmpty else { return nil }
        var mods: UInt32 = 0
        for m in keys.dropLast() {
            switch m {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] else { return nil }
        return (UInt32(code), mods)
    }

    /// Codici tasto (layout ANSI/posizione fisica).
    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave, "backtick": kVK_ANSI_Grave,
            "§": kVK_ISO_Section, "section": kVK_ISO_Section,
            "\\": kVK_ANSI_Backslash, "<": kVK_ISO_Section,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "+": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, k) in fkeys.enumerated() { m["f\(i + 1)"] = k }
        return m
    }()

    /// Nomi canonici per tradurre un tasto premuto in testo per il config.
    private static let canonicalNames: [String] = {
        var n = (Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init))
        n += ["`", "§", "\\", "-", "=", "[", "]", ";", "'", ",", ".", "/",
              "space", "return", "tab", "escape", "delete", "up", "down", "left", "right",
              "home", "end", "pageup", "pagedown"]
        n += (1...20).map { "f\($0)" }
        return n
    }()

    /// Converte un evento tastiera in una stringa come "ctrl+shift+t".
    /// Richiede almeno un modificatore, tranne per i tasti funzione.
    static func spec(from event: NSEvent) -> String? {
        let code = Int(event.keyCode)
        guard let name = canonicalNames.first(where: { keyCodes[$0] == code }) else { return nil }
        let f = event.modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("option") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        let modifierless = parts.isEmpty || parts == ["shift"]
        if modifierless && !name.hasPrefix("f") { return nil }
        if modifierless && name.count == 1 { return nil }   // la "f" lettera
        return (parts + [name]).joined(separator: "+")
    }

    /// Rappresentazione leggibile per il menu (es. "⌃`").
    static func display(_ spec: String) -> String {
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        var out = ""
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": out += "⌃"
            case "opt", "option", "alt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            default: out += p
            }
        }
        let key = parts.last ?? ""
        return out + (key.count == 1 ? key.uppercased() : key.capitalized)
    }
}
