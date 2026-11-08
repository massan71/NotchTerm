import AppKit
import SwiftTerm

struct Theme {
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var ansi: [String]
    var material: String = "solid"
    var opacity: Double = 1
    var borderOpacity: Double = 0
}

/// Aspetto effettivo dello sfondo: tema + override del config.
struct Surface {
    var material: String
    var opacity: Double
    var borderOpacity: Double

    static func resolve(_ config: Config) -> Surface {
        let t = Themes.resolve(config)
        var material = config.material ?? (config.blur == true ? "blur" : t.material)
        if !["solid", "blur", "glass", "glass-clear"].contains(material) { material = "solid" }
        return Surface(material: material,
                       opacity: max(0, min(1, config.opacity ?? t.opacity)),
                       borderOpacity: max(0, min(1, config.borderOpacity ?? t.borderOpacity)))
    }
}

enum Themes {
    /// Ordine con cui compaiono nel menu.
    static let names = ["notch", "glass", "glass-clear", "dracula", "nord", "gruvbox", "tokyo-night", "catppuccin", "solarized-dark", "paper"]

    static let all: [String: Theme] = [
        // Nero puro: il pannello si fonde con il notch hardware.
        "notch": Theme(
            background: "#000000", foreground: "#E8E8EA", cursor: "#FF9F0A", selection: "#3A3A48",
            ansi: ["#1C1C1E", "#FF453A", "#32D74B", "#FFD60A", "#0A84FF", "#BF5AF2", "#64D2FF", "#D1D1D6",
                   "#48484A", "#FF6961", "#5EF080", "#FFE45C", "#409CFF", "#DA8FFF", "#8BE1FF", "#FFFFFF"]),
        // Liquid Glass: il desktop si vede attraverso il pannello, rifratto e sfocato.
        "glass": Theme(
            background: "#14141C", foreground: "#F5F5F7", cursor: "#FFFFFF", selection: "#FFFFFF40",
            ansi: ["#3A3A44", "#FF6B6B", "#5BE49B", "#FFD86B", "#6BB8FF", "#D69BFF", "#6BE4F0", "#E8E8EE",
                   "#8A8A96", "#FF8F8F", "#85F0B5", "#FFE699", "#99CFFF", "#E5B8FF", "#99F0F7", "#FFFFFF"],
            material: "glass", opacity: 0.35, borderOpacity: 0.55),
        // Vetro più trasparente: tinta più scura per leggere bene il testo.
        "glass-clear": Theme(
            background: "#000000", foreground: "#FFFFFF", cursor: "#FFFFFF", selection: "#FFFFFF4D",
            ansi: ["#4A4A55", "#FF7A7A", "#6BF0A8", "#FFE07A", "#7AC2FF", "#DDA8FF", "#7AEDF7", "#F0F0F5",
                   "#9A9AA6", "#FF9C9C", "#94F5C0", "#FFEBA3", "#A6D6FF", "#EAC4FF", "#A6F5FA", "#FFFFFF"],
            material: "glass-clear", opacity: 0.45, borderOpacity: 0.6),
        "dracula": Theme(
            background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
            ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                   "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        "nord": Theme(
            background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
            ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                   "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        "gruvbox": Theme(
            background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
            ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                   "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
        "tokyo-night": Theme(
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selection: "#33467C",
            ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                   "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
        "catppuccin": Theme(
            background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#45475A",
            ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                   "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        "solarized-dark": Theme(
            background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                   "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        "paper": Theme(
            background: "#F7F5EF", foreground: "#2B2B2B", cursor: "#D9480F", selection: "#D8E2F0",
            ansi: ["#2B2B2B", "#C92A2A", "#2B8A3E", "#B07B00", "#1864AB", "#862E9C", "#0B7285", "#868E96",
                   "#495057", "#E03131", "#37B24D", "#F08C00", "#1C7ED6", "#AE3EC9", "#1098AD", "#ADB5BD"]),
    ]

    /// Tema scelto + override dei colori dal config.
    static func resolve(_ config: Config) -> Theme {
        var t = all[config.theme.lowercased()] ?? all["notch"]!
        let c = config.colors
        if let v = c.background { t.background = v }
        if let v = c.foreground { t.foreground = v }
        if let v = c.cursor { t.cursor = v }
        if let v = c.selection { t.selection = v }
        if let v = c.ansi, v.count == 16 { t.ansi = v }
        return t
    }
}

extension SwiftTerm.Color {
    static func hex(_ s: String) -> SwiftTerm.Color {
        let c = (NSColor(hex: s) ?? .gray).usingColorSpace(.sRGB) ?? .gray
        return SwiftTerm.Color(red8: UInt16(c.redComponent * 255),
                               green8: UInt16(c.greenComponent * 255),
                               blue8: UInt16(c.blueComponent * 255))
    }
}
