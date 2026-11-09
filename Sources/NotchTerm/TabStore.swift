import Foundation

/// Schede aperte, salvate per ricrearle al prossimo avvio.
struct SavedTabs: Codable, Equatable {
    /// Cartella di ogni scheda, nell'ordine della barra.
    var directories: [String]
    var selected: Int

    /// Scarta le cartelle sparite nel frattempo e corregge l'indice selezionato.
    func validated(fileExists: (String) -> Bool) -> SavedTabs? {
        var dirs: [String] = []
        var sel = 0
        for (i, d) in directories.enumerated() where fileExists(d) {
            if i <= selected { sel = dirs.count }
            dirs.append(d)
        }
        return dirs.isEmpty ? nil : SavedTabs(directories: dirs, selected: sel)
    }
}

enum TabStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTerm/tabs.json")
    }

    static func load(from url: URL = fileURL) -> SavedTabs? {
        guard let data = try? Data(contentsOf: url),
              let tabs = try? JSONDecoder().decode(SavedTabs.self, from: data) else { return nil }
        return tabs.validated { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    static func save(_ tabs: SavedTabs, to url: URL = fileURL) {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
