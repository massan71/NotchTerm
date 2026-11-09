import Foundation
import Testing
@testable import NotchTerm

/// Prova gli script veri: avvia ogni shell in una HOME vuota, le passa qualche
/// comando e controlla le sequenze OSC 7501 e OSC 7 che emette.
@Suite(.serialized) struct ShellIntegrationTests {
    struct Record: Equatable {
        var state: String
        var title: String
        var exitCode: Int?
    }

    let base: URL
    let home: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notchterm-tests-\(UUID().uuidString)")
        base = tmp.appendingPathComponent("integration")
        home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: Argomenti di avvio

    @Test func bashLoginBecomesRcfile() {
        let l = ShellIntegration.prepare(shell: "/bin/bash", args: ["-l"], environment: [:], directory: base)
        #expect(l.args == ["--rcfile", base.appendingPathComponent("bash/notchterm.bash").path])
        #expect(l.env == ["NOTCHTERM_BASH_LOGIN=1"])
    }

    @Test func bashNonLoginKeepsOtherArgs() {
        let l = ShellIntegration.prepare(shell: "/opt/homebrew/bin/bash", args: ["--norc-not-really"], environment: [:], directory: base)
        #expect(l.args.suffix(1) == ["--norc-not-really"])
        #expect(l.env.isEmpty)
    }

    @Test func zshKeepsOriginalZdotdir() {
        let l = ShellIntegration.prepare(shell: "/bin/zsh", args: ["-l"], environment: ["ZDOTDIR": "/x"], directory: base)
        #expect(l.args == ["-l"])
        #expect(l.env.contains("ZDOTDIR=\(base.appendingPathComponent("zsh").path)"))
        #expect(l.env.contains("NOTCHTERM_ORIG_ZDOTDIR=/x"))
    }

    @Test func fishPrependsDataDir() {
        let xdg = base.appendingPathComponent("fish-xdg").path
        let unset = ShellIntegration.prepare(shell: "fish", args: [], environment: [:], directory: base)
        #expect(unset.env.contains("XDG_DATA_DIRS=\(xdg):/usr/local/share:/usr/share"))
        #expect(!unset.env.contains { $0.hasPrefix("NOTCHTERM_ORIG_XDG_DATA_DIRS=") })
        let set = ShellIntegration.prepare(shell: "fish", args: [], environment: ["XDG_DATA_DIRS": "/d"], directory: base)
        #expect(set.env.contains("XDG_DATA_DIRS=\(xdg):/d"))
        #expect(set.env.contains("NOTCHTERM_ORIG_XDG_DATA_DIRS=/d"))
    }

    @Test func unsupportedShellAndDashCAreUntouched() {
        let sh = ShellIntegration.prepare(shell: "/bin/sh", args: ["-l"], environment: [:], directory: base)
        #expect(sh == .init(args: ["-l"], env: []))
        let c = ShellIntegration.prepare(shell: "/bin/zsh", args: ["-c", "ls"], environment: [:], directory: base)
        #expect(c == .init(args: ["-c", "ls"], env: []))
    }

    // MARK: Script veri

    @Test func zshReportsCommands() throws {
        try checkShell("/bin/zsh", args: ["-i"])
    }

    @Test func bashReportsCommands() throws {
        try checkShell("/bin/bash", args: ["-i"])
    }

    @Test func bashLoginLoadsProfile() throws {
        try "export NOTCHTERM_TEST_PROFILE=loaded\n".write(to: home.appendingPathComponent(".bash_profile"),
                                                            atomically: true, encoding: .utf8)
        let out = try run("/bin/bash", args: ["-l", "-i"], input: "echo \"profile=$NOTCHTERM_TEST_PROFILE\"\nexit\n")
        #expect(out.contains("profile=loaded"))
    }

    @Test func bashKeepsExistingPromptCommand() throws {
        try "PROMPT_COMMAND='echo from-user-prompt;'\n".write(to: home.appendingPathComponent(".bashrc"),
                                                              atomically: true, encoding: .utf8)
        let out = try run("/bin/bash", args: ["-i"], input: "true\nexit\n")
        #expect(out.contains("from-user-prompt"))
        // Il comando dell'utente nel prompt non va scambiato per un comando digitato.
        #expect(!records(out).contains { $0.title.contains("echo from-user-prompt") })
        #expect(records(out).contains(Record(state: "done", title: "true", exitCode: 0)))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish")
                       || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/fish")))
    func fishReportsCommands() throws {
        let fish = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish")
            ? "/opt/homebrew/bin/fish" : "/usr/local/bin/fish"
        // fish lancia gli eventi dei comandi solo su un terminale vero: serve una pty.
        try checkShell(fish, args: ["-i"], pty: true)
        let out = try run(fish, args: ["-i"], input: "echo \"[$XDG_DATA_DIRS]\"\nexit\n", pty: true)
        #expect(out.contains("[]"), "XDG_DATA_DIRS non ripristinata")
    }

    /// Esegue un comando riuscito, uno fallito e un cambio di cartella.
    private func checkShell(_ shell: String, args: [String], pty: Bool = false) throws {
        let out = try run(shell, args: args, input: "true\nfalse\ncd /usr\nexit\n", pty: pty)
        let recs = records(out)
        #expect(recs.contains(Record(state: "working", title: "true", exitCode: nil)), "\(shell): \(recs)")
        #expect(recs.contains(Record(state: "done", title: "true", exitCode: 0)), "\(shell): \(recs)")
        #expect(recs.contains(Record(state: "error", title: "false", exitCode: 1)), "\(shell): \(recs)")
        #expect(out.contains("\u{1B}]7;file://") && out.contains("/usr\u{07}"), "\(shell): manca OSC 7")
    }

    private func run(_ shell: String, args: [String], input: String, pty: Bool = false) throws -> String {
        let launch = ShellIntegration.prepare(shell: shell, args: args, environment: [:], directory: base)
        let p = Process()
        if pty {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", shell] + launch.args
        } else {
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = launch.args
        }
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb",
                   "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                   "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path]
        for kv in launch.env {
            let parts = kv.split(separator: "=", maxSplits: 1)
            env[String(parts[0])] = String(parts[1])
        }
        p.environment = env
        p.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        try p.run()
        if pty {
            // Una riga alla volta, lasciando alla shell il tempo di mostrare il prompt.
            Thread.sleep(forTimeInterval: 1)
            for line in input.split(separator: "\n") {
                stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
                Thread.sleep(forTimeInterval: 0.4)
            }
        } else {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func records(_ output: String) -> [Record] {
        var result: [Record] = []
        var rest = Substring(output)
        while let start = rest.range(of: "\u{1B}]7501;") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\u{07}") else { break }
            var fields: [String: String] = [:]
            for f in rest[..<end].split(separator: ":") {
                let kv = f.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
            }
            rest = rest[rest.index(after: end)...]
            guard fields["id"] == "notchterm" else { continue }
            func b64(_ s: String?) -> String {
                guard let s, let d = Data(base64Encoded: s) else { return "" }
                return String(decoding: d, as: UTF8.self)
            }
            let msg = b64(fields["msg"])
            result.append(Record(state: fields["state"] ?? "", title: b64(fields["title"]),
                                 exitCode: msg.isEmpty ? nil : CommandResult.parse(message: msg, failed: false).exitCode))
        }
        return result
    }
}
