import Foundation

/// Integrazione con la shell: fa sì che la shell segnali l'inizio e la fine di ogni
/// comando (testo, codice d'uscita, durata) con la sequenza OSC 7501
/// ("program status"), che SwiftTerm inoltra all'app, e la cartella corrente con OSC 7.
///
/// Ogni shell si aggancia senza toccare i file dell'utente:
/// - zsh: ZDOTDIR punta a una cartella di NotchTerm il cui `.zshenv` ripristina
///   subito il ZDOTDIR originale e carica i file dell'utente (come Ghostty/kitty).
/// - bash: si avvia con `--rcfile` su uno script che carica prima i file
///   dell'utente (.bash_profile/.profile per le shell di login, altrimenti .bashrc).
/// - fish: si aggiunge una cartella a XDG_DATA_DIRS, così fish carica da solo
///   lo script in `fish/vendor_conf.d`; lo script poi la toglie.
enum ShellIntegration {
    /// Id del record OSC 7501 usato dagli hook.
    static let recordID = "notchterm"

    enum Kind: String { case zsh, bash, fish }

    /// Come avviare la shell: argomenti e variabili d'ambiente da aggiungere.
    struct Launch: Equatable {
        var args: [String]
        var env: [String]
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTerm/shell-integration", isDirectory: true)
    }

    static func kind(ofShell shell: String) -> Kind? {
        Kind(rawValue: (shell as NSString).lastPathComponent)
    }

    /// Argomenti e ambiente per avviare `shell` con l'integrazione. Se la shell non è
    /// supportata (o gli script non si possono scrivere) restituisce gli argomenti invariati.
    static func prepare(shell: String, args: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        directory: URL = directory) -> Launch {
        let unchanged = Launch(args: args, env: [])
        guard let kind = kind(ofShell: shell) else { return unchanged }
        // Con "-c" la shell esegue un comando e non è interattiva: niente da agganciare.
        if args.contains("-c") { return unchanged }
        guard let script = install(kind, in: directory) else { return unchanged }

        switch kind {
        case .zsh:
            var env = ["ZDOTDIR=\(script.deletingLastPathComponent().path)"]
            if let orig = environment["ZDOTDIR"] { env.append("NOTCHTERM_ORIG_ZDOTDIR=\(orig)") }
            return Launch(args: args, env: env)

        case .bash:
            // --rcfile vale solo per le shell non di login: il login lo simula lo script.
            let login = args.contains("-l") || args.contains("--login")
            let rest = args.filter { $0 != "-l" && $0 != "--login" }
            return Launch(args: ["--rcfile", script.path] + rest,
                          env: login ? ["NOTCHTERM_BASH_LOGIN=1"] : [])

        case .fish:
            let xdg = directory.appendingPathComponent("fish-xdg").path
            var env = ["NOTCHTERM_FISH_XDG=\(xdg)"]
            if let orig = environment["XDG_DATA_DIRS"] {
                env.append("NOTCHTERM_ORIG_XDG_DATA_DIRS=\(orig)")
                env.append("XDG_DATA_DIRS=\(xdg):\(orig)")
            } else {
                // Valore predefinito della specifica XDG, perché fish continui a trovare le sue cartelle.
                env.append("XDG_DATA_DIRS=\(xdg):/usr/local/share:/usr/share")
            }
            return Launch(args: args, env: env)
        }
    }

    /// Percorso dello script per ogni shell, relativo alla cartella dell'integrazione.
    static func scriptPath(_ kind: Kind) -> String {
        switch kind {
        case .zsh: return "zsh/.zshenv"
        case .bash: return "bash/notchterm.bash"
        case .fish: return "fish-xdg/fish/vendor_conf.d/notchterm.fish"
        }
    }

    static func script(_ kind: Kind) -> String {
        switch kind {
        case .zsh: return zsh
        case .bash: return bash
        case .fish: return fish
        }
    }

    /// Scrive (o aggiorna) lo script. Restituisce il suo percorso, o nil se non è possibile.
    static func install(_ kind: Kind, in directory: URL) -> URL? {
        let file = directory.appendingPathComponent(scriptPath(kind))
        let content = script(kind)
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == content { return file }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            NSLog("NotchTerm: impossibile installare l'integrazione \(kind.rawValue): \(error)")
            return nil
        }
    }

    // MARK: - Script

    static let zsh = #"""
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

      # OSC 7: cartella corrente (titoli delle schede, link relativi, nuove schede).
      _notchterm_osc7() {
        local p=${PWD//\%/%25}
        p=${p// /%20}
        printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$p"
      }

      _notchterm_precmd() {
        local ec=$?
        _notchterm_osc7
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
      add-zsh-hook chpwd _notchterm_osc7
    fi
    """#

    /// Compatibile con il bash 3.2 di macOS. Il "preexec" si ottiene con la trap DEBUG:
    /// si arma alla fine di PROMPT_COMMAND e scatta sul primo comando digitato.
    static let bash = #"""
    # NotchTerm — integrazione bash (generato automaticamente, non modificare).
    # Carica i file dell'utente come farebbe bash da solo.
    if [[ -n "$NOTCHTERM_BASH_LOGIN" ]]; then
      unset NOTCHTERM_BASH_LOGIN
      [[ -r /etc/profile ]] && . /etc/profile
      for _notchterm_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [[ -r "$_notchterm_f" ]]; then . "$_notchterm_f"; break; fi
      done
      unset _notchterm_f
    else
      [[ -r "$HOME/.bashrc" ]] && . "$HOME/.bashrc"
    fi

    if [[ $- == *i* && -z "$_notchterm_loaded" ]]; then
      _notchterm_loaded=1

      _notchterm_b64() { printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n'; }

      # Microsecondi: EPOCHREALTIME esiste da bash 5, prima si usa SECONDS.
      _notchterm_now() {
        if [[ -n "$EPOCHREALTIME" ]]; then
          _notchterm_t=${EPOCHREALTIME/[.,]/}
        else
          _notchterm_t=$(( SECONDS * 1000000 ))
        fi
      }

      _notchterm_osc7() {
        local p=${PWD//\%/%25}
        p=${p// /%20}
        printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$p"
      }

      _notchterm_preexec() {
        [[ -n "$_notchterm_armed" && -z "$COMP_LINE" ]] || return 0
        case "$BASH_COMMAND" in _notchterm_*) return 0 ;; esac
        _notchterm_armed=
        _notchterm_now
        _notchterm_start=$_notchterm_t
        _notchterm_cmd=${BASH_COMMAND:0:120}
        printf '\033]7501;id=notchterm:state=working:title=%s\a' "$(_notchterm_b64 "$_notchterm_cmd")"
        return 0
      }

      _notchterm_precmd() {
        local ec=$?
        _notchterm_armed=
        _notchterm_osc7
        if [[ -n "$_notchterm_start" ]]; then
          _notchterm_now
          local d=$(( _notchterm_t - _notchterm_start )) st=done
          (( ec != 0 )) && st=error
          local secs
          secs=$(printf '%d.%06d' $(( d / 1000000 )) $(( d % 1000000 )))
          printf '\033]7501;id=notchterm:state=%s:title=%s:msg=%s\a' "$st" \
            "$(_notchterm_b64 "$_notchterm_cmd")" "$(_notchterm_b64 "$ec $secs")"
          _notchterm_start=
        fi
        return $ec
      }

      # Ultimo passo del prompt: da qui il prossimo comando è quello dell'utente.
      _notchterm_arm() { local ec=$?; _notchterm_armed=1; return $ec; }

      # Una trap DEBUG già presente (es. bash-preexec) non si sovrascrive.
      if [[ -z "$(trap -p DEBUG)" ]]; then
        trap '_notchterm_preexec' DEBUG
      fi
      if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(_notchterm_precmd "${PROMPT_COMMAND[@]}" _notchterm_arm)
      else
        _notchterm_pc=$PROMPT_COMMAND
        while [[ "$_notchterm_pc" == *";" || "$_notchterm_pc" == *" " ]]; do
          _notchterm_pc=${_notchterm_pc%?}
        done
        PROMPT_COMMAND="_notchterm_precmd${_notchterm_pc:+; $_notchterm_pc}; _notchterm_arm"
        unset _notchterm_pc
      fi
    fi
    """#

    static let fish = #"""
    # NotchTerm — integrazione fish (generato automaticamente, non modificare).
    # Toglie la cartella di NotchTerm da XDG_DATA_DIRS.
    if set -q NOTCHTERM_FISH_XDG
        if set -q NOTCHTERM_ORIG_XDG_DATA_DIRS
            set -gx XDG_DATA_DIRS $NOTCHTERM_ORIG_XDG_DATA_DIRS
            set -e NOTCHTERM_ORIG_XDG_DATA_DIRS
        else
            set -e XDG_DATA_DIRS
        end
        set -e NOTCHTERM_FISH_XDG
    end

    if status is-interactive; and not set -q __notchterm_loaded
        set -g __notchterm_loaded 1

        function __notchterm_b64
            printf '%s' $argv[1] | /usr/bin/base64 | /usr/bin/tr -d '\n'
        end

        function __notchterm_osc7 --on-variable PWD
            set -l p (string replace -a '%' '%25' -- $PWD)
            set p (string replace -a ' ' '%20' -- $p)
            printf '\e]7;file://%s%s\a' $hostname $p
        end

        function __notchterm_preexec --on-event fish_preexec
            set -l line (string split -m1 \n -- $argv[1])
            set -g __notchterm_cmd (string sub -l 120 -- $line[1])
            printf '\e]7501;id=notchterm:state=working:title=%s\a' (__notchterm_b64 "$__notchterm_cmd")
        end

        function __notchterm_postexec --on-event fish_postexec
            set -l ec $status
            set -q __notchterm_cmd; or return
            set -l st done
            test $ec -ne 0; and set st error
            set -l dur (math -s3 "$CMD_DURATION / 1000")
            printf '\e]7501;id=notchterm:state=%s:title=%s:msg=%s\a' $st \
                (__notchterm_b64 "$__notchterm_cmd") (__notchterm_b64 "$ec $dur")
            set -e __notchterm_cmd
        end

        __notchterm_osc7
    end
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

    /// "1:05", "12:40", "1:02:03": tempo trascorso compatto per l'indicatore.
    static func clock(_ d: TimeInterval) -> String {
        let s = max(0, Int(d))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Legge il campo "msg" degli hook: "<codice> <secondi>". Accetta anche la virgola
    /// come separatore decimale (alcune shell seguono la lingua del sistema).
    static func parse(message: String, failed: Bool) -> (exitCode: Int, duration: TimeInterval) {
        let parts = message.split(separator: " ")
        let code = parts.first.flatMap { Int($0) } ?? (failed ? 1 : 0)
        let duration = parts.count > 1
            ? (Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0) : 0
        return (code, duration)
    }

    /// true se la riga di comando avvia uno dei programmi da ignorare (editor, pager, ssh…).
    /// Salta assegnazioni di variabili e prefissi come `sudo`, `env`, `time`.
    static func isIgnored(_ command: String, list: [String]) -> Bool {
        guard !list.isEmpty else { return false }
        let prefixes: Set<String> = ["sudo", "env", "time", "nice", "nohup", "command", "exec", "builtin", "noglob"]
        for word in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let w = String(word)
            if w.contains("=") && !w.hasPrefix("=") { continue }
            if prefixes.contains(w) || w.hasPrefix("-") { continue }
            let name = (w as NSString).lastPathComponent
            return list.contains(name)
        }
        return false
    }
}
