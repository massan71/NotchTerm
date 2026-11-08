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

    /// Comando in esecuzione (dagli hook della shell), se c'è.
    private(set) var runningCommand: String?
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
        if config.shellIntegration { env += ShellIntegration.environment(forShell: shell) }

        var dir = directory ?? (config.workingDirectory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            dir = FileManager.default.homeDirectoryForCurrentUser.path
        }
        cwd = dir
        shellTitle = ""
        view.startProcess(executable: shell, args: config.shellArgs, environment: env,
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
    var plainShortTitle: String {
        if !shellTitle.isEmpty {
            // "utente@host:~/progetti/app" → "app"
            if shellTitle.contains("@"), let colon = shellTitle.lastIndex(of: ":") {
                let path = String(shellTitle[shellTitle.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if path == "~" || path.isEmpty { return "~" }
                return (path as NSString).lastPathComponent
            }
            return shellTitle
        }
        let t = displayTitle
        return t == "~" ? t : ((t as NSString).lastPathComponent)
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
        case .done, .error:
            // Si avvisa solo nel passaggio da "in esecuzione" a "terminato".
            guard runningCommand != nil else { return }
            runningCommand = nil
            let parts = (r.message ?? "").split(separator: " ")
            let code = parts.first.flatMap { Int($0) } ?? (r.state == .error ? 1 : 0)
            let duration = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
            onCommandFinished?(self, CommandResult(command: r.title ?? "", exitCode: code, duration: duration))
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
