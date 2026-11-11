import AppKit
import Darwin
import SwiftTerm

/// Una scheda: una vista terminale con la sua shell.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    private(set) var shellTitle = ""
    private(set) var cwd = ""

    var onChange: ((TerminalSession) -> Void)?
    var onExit: ((TerminalSession) -> Void)?
    var onCommandFinished: ((TerminalSession, CommandResult) -> Void)?
    /// Un comando è partito o è finito.
    var onActivityChange: ((TerminalSession) -> Void)?

    /// Comando in esecuzione (dagli hook della shell), se c'è.
    private(set) var runningCommand: String?
    /// Da quando è in esecuzione.
    private(set) var runningSince: Date?
    /// Ultimo comando terminato (per "spiega l'errore").
    private(set) var lastResult: CommandResult?
    /// Esito non ancora visto (scheda in secondo piano): "✓" o "✗".
    var badge: String?

    init(frame: NSRect) {
        view = LocalProcessTerminalView(frame: frame)
        super.init()
        view.wantsLayer = true
        view.processDelegate = self
    }

    var isRunning: Bool { view.process?.running == true }

    func start(config: Config, directory: String?) {
        let shell = config.shell.isEmpty
            ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            : (config.shell as NSString).expandingTildeInPath
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("TERM_PROGRAM=NotchTerm")
        env.append("COLORTERM=truecolor")
        if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=en_US.UTF-8") }
        for (k, v) in config.env { env.append("\(k)=\(v)") }
        var args = config.shellArgs
        if config.shellIntegration {
            let launch = ShellIntegration.prepare(shell: shell, args: args)
            args = launch.args
            env += launch.env
        }

        var dir = directory ?? (config.workingDirectory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            dir = FileManager.default.homeDirectoryForCurrentUser.path
        }
        cwd = dir
        shellTitle = ""
        if runningCommand != nil {
            runningCommand = nil
            runningSince = nil
            onActivityChange?(self)
        }
        view.startProcess(executable: shell, args: args, environment: env,
                          execName: nil, currentDirectory: dir)
        onChange?(self)
    }

    func terminate() {
        if isRunning { view.process?.terminate() }
    }

    /// Cartella corrente reale della shell, letta dal kernel: funziona anche
    /// se la shell non invia le sequenze OSC 7.
    func refreshDirectory() {
        guard isRunning, let pid = view.process?.shellPid, pid > 0 else { return }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !path.isEmpty, path != cwd {
            cwd = path
            onChange?(self)
        }
    }

    /// Titolo da mostrare: quello impostato dalla shell, altrimenti la cartella.
    var displayTitle: String {
        if !shellTitle.isEmpty { return shellTitle }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    /// Titolo breve per la linguetta della scheda.
    var shortTitle: String {
        let base = plainShortTitle
        return badge.map { "\($0) \(base)" } ?? base
    }

    /// Titolo breve senza il segno ✓/✗.
    var plainShortTitle: String { Self.tabTitle(shellTitle: shellTitle, displayTitle: displayTitle) }

    static func tabTitle(shellTitle: String, displayTitle: String) -> String {
        if !shellTitle.isEmpty {
            // "utente@host:~/progetti/app" → "app"
            if shellTitle.contains("@"), let colon = shellTitle.lastIndex(of: ":") {
                let path = String(shellTitle[shellTitle.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if path == "~" || path.isEmpty { return "~" }
                return (path as NSString).lastPathComponent
            }
            return shellTitle
        }
        return displayTitle == "~" ? displayTitle : ((displayTitle as NSString).lastPathComponent)
    }

    /// Testo selezionato nel terminale, se c'è.
    var selectedText: String? {
        guard let s = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Ultime `count` righe del terminale (senza le righe vuote in fondo, sotto al cursore).
    func recentOutput(lines count: Int) -> String {
        let text = String(decoding: view.getBufferAsData(), as: UTF8.self)
        var rows = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.last == " " { l.removeLast() }
            return l
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return Self.compactSpaces(rows.suffix(count).joined(separator: "\n"))
    }

    /// Riduce le lunghe file di spazi (prompt allineati a destra, tabelle) a due spazi.
    static func compactSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: " {3,}", with: "  ", options: .regularExpression)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        shellTitle = title
        onChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        cwd = URL(string: directory)?.path ?? directory
        onChange?(self)
    }

    /// Gli hook zsh riportano lo stato con OSC 7501 (vedi ShellIntegration).
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        guard let r = records.first(where: { $0.id == ShellIntegration.recordID }) else { return }
        switch r.state {
        case .working:
            runningCommand = r.title ?? ""
            runningSince = Date()
            onActivityChange?(self)
        case .done, .error:
            // Si avvisa solo nel passaggio da "in esecuzione" a "terminato".
            guard runningCommand != nil else { return }
            runningCommand = nil
            runningSince = nil
            let (code, duration) = CommandResult.parse(message: r.message ?? "", failed: r.state == .error)
            let result = CommandResult(command: r.title ?? "", exitCode: code, duration: duration)
            lastResult = result
            onCommandFinished?(self, result)
            onActivityChange?(self)
        default:
            break
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onExit?(self)
        }
    }
}
