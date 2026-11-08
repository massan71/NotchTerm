import Foundation

/// Integrazione con la shell: fa sì che zsh segnali l'inizio e la fine di ogni
/// comando (testo, codice d'uscita, durata) con la sequenza OSC 7501
/// ("program status"), che SwiftTerm inoltra all'app.
///
/// Funziona come in Ghostty/kitty: si avvia zsh con ZDOTDIR puntato a una cartella
/// di NotchTerm il cui `.zshenv` ripristina subito il ZDOTDIR originale, carica
/// il `.zshenv` dell'utente e registra due hook. Gli altri file di avvio
/// (.zprofile, .zshrc…) vengono poi letti normalmente dalla cartella dell'utente.
enum ShellIntegration {
    /// Id del record OSC 7501 usato dagli hook.
    static let recordID = "notchterm"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTerm/shell-integration/zsh", isDirectory: true)
    }

    /// Variabili d'ambiente da aggiungere per attivare l'integrazione, o [] se la shell non è supportata.
    static func environment(forShell shell: String) -> [String] {
        guard (shell as NSString).lastPathComponent == "zsh", install() else { return [] }
        var env = ["ZDOTDIR=\(directory.path)"]
        if let orig = ProcessInfo.processInfo.environment["ZDOTDIR"] {
            env.append("NOTCHTERM_ORIG_ZDOTDIR=\(orig)")
        }
        return env
    }

    /// Scrive (o aggiorna) lo script. Restituisce false se non è possibile.
    private static func install() -> Bool {
        let fm = FileManager.default
        let file = directory.appendingPathComponent(".zshenv")
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == zshenv { return true }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try zshenv.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("NotchTerm: impossibile installare l'integrazione shell: \(error)")
            return false
        }
    }

    static let zshenv = #"""
    # NotchTerm — integrazione zsh (generato automaticamente, non modificare).
    # Ripristina il ZDOTDIR originale: gli altri file di avvio si leggono da lì.
    if [[ -n "${NOTCHTERM_ORIG_ZDOTDIR+x}" ]]; then
      export ZDOTDIR="$NOTCHTERM_ORIG_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    unset NOTCHTERM_ORIG_ZDOTDIR

    if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
      source "${ZDOTDIR:-$HOME}/.zshenv"
    fi

    if [[ -o interactive ]]; then
      zmodload zsh/datetime 2>/dev/null
      autoload -Uz add-zsh-hook

      _notchterm_b64() { printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n' }

      _notchterm_preexec() {
        _notchterm_start=$EPOCHREALTIME
        _notchterm_cmd="${1[1,120]}"
        printf '\e]7501;id=notchterm:state=working:title=%s\a' "$(_notchterm_b64 "$_notchterm_cmd")"
      }

      _notchterm_precmd() {
        local ec=$?
        [[ -z "$_notchterm_start" ]] && return
        local dur=$(( EPOCHREALTIME - _notchterm_start ))
        local st=done
        (( ec != 0 )) && st=error
        printf '\e]7501;id=notchterm:state=%s:title=%s:msg=%s\a' "$st" \
          "$(_notchterm_b64 "$_notchterm_cmd")" "$(_notchterm_b64 "$ec $dur")"
        unset _notchterm_start _notchterm_cmd
      }

      add-zsh-hook preexec _notchterm_preexec
      add-zsh-hook precmd _notchterm_precmd
    fi
    """#
}

/// Un comando terminato, come riportato dagli hook della shell.
struct CommandResult {
    var command: String
    var exitCode: Int
    var duration: TimeInterval
    var succeeded: Bool { exitCode == 0 }

    /// "45 s", "2 min 13 s", "1 h 4 min"
    static func format(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}
