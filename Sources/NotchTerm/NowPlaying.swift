import AppKit

/// Il brano in riproduzione su Spotify o Apple Music.
struct NowPlayingTrack: Equatable {
    enum Source: String {
        case spotify, music

        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var appName: String { self == .spotify ? "Spotify" : "Music" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    var source: Source
    /// Identifica il brano: serve a capire quando cambia.
    var id: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

/// Segue Spotify e Apple Music tramite le notifiche che entrambe le app pubblicano
/// a ogni cambio di brano o di stato (nessun permesso richiesto). I comandi
/// (play/pausa, avanti, indietro) passano invece da AppleScript: la prima volta
/// macOS chiede il permesso di Automazione.
@MainActor
final class NowPlayingMonitor {
    private(set) var track: NowPlayingTrack?
    private(set) var artwork: NSImage?

    /// `trackChanged` è vero quando è iniziato un brano diverso.
    var onChange: ((_ trackChanged: Bool) -> Void)?

    var enabled = true {
        didSet { if !enabled { track = nil; artwork = nil; onChange?(false) } }
    }

    private var artworkCache: [String: NSImage] = [:]
    private var didInitialRefresh = false
    private let scriptQueue = DispatchQueue(label: "notchterm.applescript")

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(.spotify, info) }
        }
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(.music, info) }
        }
    }

    // MARK: - Notifiche

    private func handle(_ source: NowPlayingTrack.Source, _ info: [AnyHashable: Any]) {
        guard enabled else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        let title = info["Name"] as? String ?? ""

        if state == "stopped" || title.isEmpty {
            // Si toglie il brano solo se lo stop arriva dalla sorgente mostrata.
            if track?.source == source { update(nil) }
            return
        }
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        var id = info["Track ID"] as? String ?? ""
        if id.isEmpty, let pid = info["PersistentID"] { id = "\(pid)" }
        if id.isEmpty { id = "\(source.rawValue):\(title)|\(artist)|\(album)" }

        let new = NowPlayingTrack(source: source, id: id, title: title, artist: artist, album: album,
                                  isPlaying: state == "playing")
        // Se un'altra sorgente è in pausa, vince quella che sta suonando.
        if let cur = track, cur.source != source, cur.isPlaying, !new.isPlaying { return }
        update(new)
    }

    private func update(_ new: NowPlayingTrack?) {
        let changed = new?.id != track?.id
        track = new
        if changed {
            artwork = new.flatMap { artworkCache[$0.id] }
            if let new, artwork == nil { loadArtwork(for: new) }
        }
        onChange?(changed)
    }

    /// Stato iniziale, se il lettore era già aperto prima di NotchTerm.
    /// Si chiama alla prima apertura del pannello, non all'avvio,
    /// così l'eventuale richiesta di permesso arriva in un momento comprensibile.
    func refreshIfNeeded() {
        guard enabled, !didInitialRefresh, track == nil else { return }
        didInitialRefresh = true
        for source in [NowPlayingTrack.Source.spotify, .music] where source.isRunning {
            let script = """
            tell application "\(source.appName)"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                set tid to ""
                try
                    set tid to (id of t) as string
                end try
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & tid
            end tell
            """
            run(script) { [weak self] result in
                guard let self, let text = result?.stringValue else { return }
                let parts = text.components(separatedBy: "\n")
                guard parts.count >= 4, parts[0] != "stopped" else { return }
                var info: [String: Any] = ["Player State": parts[0].capitalized, "Name": parts[1],
                                           "Artist": parts[2], "Album": parts[3]]
                if source == .spotify, parts.count > 4 { info["Track ID"] = parts[4] }
                self.handle(source, info)
            }
        }
    }

    // MARK: - Comandi

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func activatePlayer() {
        guard let source = track?.source,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).first else { return }
        app.activate()
    }

    private func send(_ command: String) {
        guard let source = track?.source, source.isRunning else { return }   // non si avvia mai il lettore
        run("tell application \"\(source.appName)\" to \(command)") { _ in }
    }

    private func run(_ source: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("NotchTerm AppleScript: \(error)") }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    // MARK: - Copertine

    private func loadArtwork(for track: NowPlayingTrack) {
        switch track.source {
        case .spotify:
            // oEmbed pubblico di Spotify: restituisce l'URL della copertina, senza permessi.
            guard track.id.hasPrefix("spotify:track:") || track.id.hasPrefix("spotify:episode:") else { return }
            let parts = track.id.split(separator: ":")
            guard parts.count == 3 else { return }
            var comps = URLComponents(string: "https://open.spotify.com/oembed")!
            comps.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
            fetch(comps.url!) { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let thumb = obj["thumbnail_url"] as? String, let url = URL(string: thumb) else { return }
                self.fetch(url) { data in self.setArtwork(NSImage(data: data), for: track.id) }
            }
        case .music:
            guard track.source.isRunning else { return }
            run("tell application \"Music\" to get data of artwork 1 of current track") { [weak self] result in
                guard let data = result?.data, let image = NSImage(data: data) else { return }
                self?.setArtwork(image, for: track.id)
            }
        }
    }

    private func fetch(_ url: URL, _ completion: @escaping @MainActor (Data) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(data) } }
        }.resume()
    }

    private func setArtwork(_ image: NSImage?, for id: String) {
        guard let image else { return }
        artworkCache[id] = image
        if artworkCache.count > 50 { artworkCache.removeAll() }
        if track?.id == id {
            artwork = image
            onChange?(false)
        }
    }
}
