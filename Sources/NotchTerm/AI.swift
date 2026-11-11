import Foundation
import Security

// MARK: - Fornitori

/// Un fornitore di modelli. Claude usa la sua API nativa (Messages API); tutti gli
/// altri il formato "chat completions" di OpenAI, che molti servizi hanno adottato.
struct AIProvider: Equatable {
    enum API: Equatable { case anthropic, openAICompatible }

    let id: String
    let name: String
    let api: API
    /// Indirizzo base (senza "/chat/completions" o "/v1/messages").
    let defaultBaseURL: String
    /// Modello usato se il campo è vuoto. nil = va indicato.
    let defaultModel: String?
    let needsKey: Bool
    /// Dove si ottiene la chiave, per l'aiuto nelle impostazioni.
    let keyURL: String?
    /// Elenco dei modelli, se non è il solito "<base>/models".
    var modelsURL: String? = nil

    static let all: [AIProvider] = [
        AIProvider(id: "claude", name: "Claude (Anthropic)", api: .anthropic,
                   defaultBaseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5-5",
                   needsKey: true, keyURL: "https://console.anthropic.com/settings/keys"),
        AIProvider(id: "openai", name: "OpenAI", api: .openAICompatible,
                   defaultBaseURL: "https://api.openai.com/v1", defaultModel: nil,
                   needsKey: true, keyURL: "https://platform.openai.com/api-keys"),
        AIProvider(id: "gemini", name: "Google Gemini", api: .openAICompatible,
                   defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: nil,
                   needsKey: true, keyURL: "https://aistudio.google.com/apikey"),
        AIProvider(id: "openrouter", name: "OpenRouter", api: .openAICompatible,
                   defaultBaseURL: "https://openrouter.ai/api/v1", defaultModel: nil,
                   needsKey: true, keyURL: "https://openrouter.ai/keys"),
        AIProvider(id: "ollama-cloud", name: "Ollama Cloud", api: .openAICompatible,
                   defaultBaseURL: "https://ollama.com/v1", defaultModel: "gemma4:31b",
                   needsKey: true, keyURL: "https://ollama.com/settings/keys",
                   modelsURL: "https://ollama.com/api/tags"),
        AIProvider(id: "ollama", name: "Ollama (locale)", api: .openAICompatible,
                   defaultBaseURL: "http://localhost:11434/v1", defaultModel: nil,
                   needsKey: false, keyURL: nil),
        AIProvider(id: "lmstudio", name: "LM Studio (locale)", api: .openAICompatible,
                   defaultBaseURL: "http://localhost:1234/v1", defaultModel: nil,
                   needsKey: false, keyURL: nil),
        AIProvider(id: "custom", name: "Personalizzato (compatibile OpenAI)", api: .openAICompatible,
                   defaultBaseURL: "", defaultModel: nil, needsKey: false, keyURL: nil),
    ]

    static func named(_ id: String) -> AIProvider {
        all.first { $0.id == id.lowercased() } ?? all[0]
    }

    var isClaude: Bool { api == .anthropic }
    /// Nome breve per i pulsanti ("Chiedi a Claude" / "Chiedi all'AI").
    var askLabel: String { isClaude ? "Chiedi a Claude" : "Chiedi all'AI" }
}

/// Impostazioni AI risolte: fornitore, indirizzo e modello effettivi, chiave.
struct AISettings: Equatable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var key: String?
    var contextLines: Int

    init(_ ai: Config.AI, key: String?) {
        provider = AIProvider.named(ai.provider)
        let base = ai.baseURL.trimmingCharacters(in: .whitespaces)
        baseURL = base.isEmpty ? provider.defaultBaseURL : base
        let m = ai.model.trimmingCharacters(in: .whitespaces)
        model = m.isEmpty ? (provider.defaultModel ?? "") : m
        self.key = key?.isEmpty == true ? nil : key
        contextLines = max(5, min(500, ai.contextLines))
    }

    /// Cosa manca per poter fare richieste, o nil se è tutto a posto.
    var problem: String? {
        if baseURL.isEmpty { return "Indica l'indirizzo del servizio nelle Impostazioni → AI." }
        if model.isEmpty { return "Indica il modello da usare nelle Impostazioni → AI." }
        if provider.needsKey && key == nil { return "Inserisci la chiave API di \(provider.name) nelle Impostazioni → AI." }
        return nil
    }
}

// MARK: - Portachiavi

/// Chiavi API nel Portachiavi di macOS, una per fornitore.
enum AIKeychain {
    static let service = "net.sangalli.notchterm.ai"

    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    static func key(for provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Salva la chiave; una stringa vuota la cancella.
    @discardableResult
    static func setKey(_ key: String, for provider: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query(provider) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = query(provider)
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrLabel as String] = "NotchTerm — chiave API \(AIProvider.named(provider).name)"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func hasKey(for provider: String) -> Bool { key(for: provider) != nil }
}

// MARK: - Richieste

/// Una domanda al modello.
/// Un messaggio della conversazione ("user" o "assistant").
struct AIMessage: Equatable {
    var role: String
    var content: String
}

/// Una domanda al modello: istruzioni di sistema e conversazione.
struct AIRequest: Equatable {
    var system: String
    var messages: [AIMessage]
    var maxTokens: Int = 2048
    /// Solo Claude: "low" per le risposte brevi, "medium" per le spiegazioni.
    var effort: String = "medium"

    init(system: String, messages: [AIMessage], maxTokens: Int = 2048, effort: String = "medium") {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.effort = effort
    }

    /// Domanda singola.
    init(system: String, user: String, maxTokens: Int = 2048, effort: String = "medium") {
        self.init(system: system, messages: [AIMessage(role: "user", content: user)], maxTokens: maxTokens, effort: effort)
    }

    /// Ultimo messaggio dell'utente.
    var user: String { messages.last { $0.role == "user" }?.content ?? "" }
}

enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return why
        case .http(let code, let message):
            switch code {
            case 401, 403: return "Chiave API non valida o senza permessi (\(code)). \(message)"
            case 404: return "Indirizzo o modello non trovato (404). \(message)"
            case 429: return "Troppe richieste o credito esaurito (429). \(message)"
            case 529, 503: return "Il servizio è sovraccarico, riprova tra poco (\(code))."
            default: return "Errore \(code). \(message)"
            }
        case .refused: return "Il modello ha rifiutato la richiesta."
        case .truncated: return "La risposta è stata interrotta perché troppo lunga."
        case .badResponse: return "Risposta del servizio non valida."
        }
    }
}

/// Un evento letto dallo stream (Server-Sent Events) di uno dei due formati.
enum AIStreamEvent: Equatable {
    case text(String)
    /// Motivo di fine ("end_turn", "stop", "refusal", "max_tokens", "length"…).
    case stop(String)
    case error(String)
    case done
}

/// Client minimale per i due formati, con risposta in streaming.
final class AIClient {
    let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// Modelli Claude che accettano `fallbacks: "default"` (riprova su un altro modello
    /// se i filtri di sicurezza rifiutano una richiesta legittima).
    private static let fallbackModels: Set<String> = [
        "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
    ]

    /// Modelli Claude che accettano `output_config.effort`.
    static func supportsEffort(_ model: String) -> Bool {
        let prefixes = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5",
                        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return prefixes.contains { model.hasPrefix($0) }
    }

    func urlRequest(_ r: AIRequest) throws -> URLRequest {
        if let problem = settings.problem { throw AIError.notConfigured(problem) }
        let base = settings.baseURL.hasSuffix("/") ? String(settings.baseURL.dropLast()) : settings.baseURL
        var body: [String: Any]
        var req: URLRequest

        switch settings.provider.api {
        case .anthropic:
            guard let url = URL(string: base + "/v1/messages") else { throw AIError.notConfigured("Indirizzo non valido.") }
            req = URLRequest(url: url)
            req.setValue(settings.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = ["model": settings.model, "max_tokens": r.maxTokens, "stream": true,
                    "system": r.system,
                    "messages": r.messages.map { ["role": $0.role, "content": $0.content] }]
            if Self.supportsEffort(settings.model) {
                body["output_config"] = ["effort": r.effort]
            }
            if Self.fallbackModels.contains(settings.model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }

        case .openAICompatible:
            guard let url = URL(string: base + "/chat/completions") else { throw AIError.notConfigured("Indirizzo non valido.") }
            req = URLRequest(url: url)
            if let key = settings.key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": settings.model, "stream": true, "max_tokens": r.maxTokens,
                    "messages": [["role": "system", "content": r.system]]
                        + r.messages.map { ["role": $0.role, "content": $0.content] }]
        }

        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Invia la richiesta e passa il testo a `onText` man mano che arriva.
    /// Restituisce il testo completo.
    @discardableResult
    func stream(_ r: AIRequest, onText: @escaping (String) -> Void) async throws -> String {
        let req = try urlRequest(r)
        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 16_000 { break } }
            throw AIError.http(status, Self.errorMessage(from: data))
        }
        var full = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard let event = settings.provider.api == .anthropic
                    ? Self.parseAnthropic(line: line) : Self.parseOpenAI(line: line) else { continue }
            switch event {
            case .text(let t):
                full += t
                onText(t)
            case .stop(let reason):
                stopReason = reason
            case .error(let message):
                throw AIError.http(0, message)
            case .done:
                break
            }
            if case .done = event { break }
        }
        switch stopReason {
        case "refusal", "content_filter": throw AIError.refused
        case "max_tokens", "length": if full.isEmpty { throw AIError.truncated }
        default: break
        }
        return full
    }

    /// Elenco dei modelli del fornitore (GET /models), per aiutare a sceglierne uno.
    func listModels() async throws -> [String] {
        let base = settings.baseURL.hasSuffix("/") ? String(settings.baseURL.dropLast()) : settings.baseURL
        let path = settings.provider.api == .anthropic ? "/v1/models?limit=100" : "/models"
        // Con l'indirizzo predefinito si usa l'elenco proprio del fornitore, se ne ha uno.
        let custom = settings.baseURL == settings.provider.defaultBaseURL ? settings.provider.modelsURL : nil
        guard let url = URL(string: custom ?? base + path) else { throw AIError.notConfigured("Indirizzo non valido.") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        if settings.provider.api == .anthropic {
            req.setValue(settings.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else if let key = settings.key {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIError.http(status, Self.errorMessage(from: data)) }
        return Self.parseModelList(data)
    }

    // MARK: Parsing (statico, per i test)

    /// Una riga dello stream Anthropic: interessano solo le righe "data:".
    static func parseAnthropic(line: String) -> AIStreamEvent? {
        guard let obj = jsonData(line) else { return nil }
        switch obj["type"] as? String {
        case "content_block_delta":
            // Solo testo: i blocchi di ragionamento ("thinking_delta") non si mostrano.
            guard let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                return .stop(reason)
            }
            return nil
        case "message_stop":
            return .done
        case "error":
            let err = obj["error"] as? [String: Any]
            return .error(err?["message"] as? String ?? "Errore del servizio.")
        default:
            return nil
        }
    }

    /// Una riga dello stream "chat completions".
    static func parseOpenAI(line: String) -> AIStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "data: [DONE]" || trimmed == "data:[DONE]" { return .done }
        guard let obj = jsonData(line) else { return nil }
        if let err = obj["error"] as? [String: Any] {
            return .error(err["message"] as? String ?? "Errore del servizio.")
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return nil }
        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
            return .text(text)
        }
        if let reason = choice["finish_reason"] as? String { return .stop(reason) }
        return nil
    }

    private static func jsonData(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Messaggio leggibile da una risposta d'errore JSON ({"error": {"message": …}} o simili).
    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
            if let err = obj["error"] as? String { return err }
            if let m = obj["message"] as? String { return m }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// Elenco dei modelli: formato OpenAI/Anthropic ({"data": [{"id"}]}) o Ollama ({"models": [{"name"}]}).
    static func parseModelList(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let list = obj["data"] as? [[String: Any]] { return list.compactMap { $0["id"] as? String } }
        if let list = obj["models"] as? [[String: Any]] {
            return list.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        return []
    }
}

// MARK: - Richieste di NotchTerm

/// I tre usi dell'assistente: comando da una descrizione, spiegazione di un errore,
/// spiegazione del testo selezionato.
enum AIPrompts {
    struct Context {
        var shell: String
        var directory: String
        var language: String = AIPrompts.userLanguage
    }

    /// Lingua per le risposte (quella del sistema).
    static var userLanguage: String {
        let code = Locale.preferredLanguages.first ?? "it"
        let base = String(code.prefix(2))
        return Locale(identifier: "it").localizedString(forLanguageCode: base).map { "\($0) (\(base))" } ?? code
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static func command(_ request: String, _ c: Context) -> AIRequest {
        AIRequest(system: """
            You turn a request into one shell command for a terminal on macOS \(macOSVersion).
            Shell: \(c.shell). Current directory: \(c.directory).
            Reply with exactly two lines and nothing else:
            line 1: the command alone, on one line, ready to run (no backticks, no prompt sign, no comments); \
            join steps with && or pipes if needed and prefer tools that ship with macOS.
            line 2: a short explanation in \(c.language).
            If the explanation concerns a command that deletes, overwrites or changes system settings, start it with "⚠️".
            If no single command can do it, write "#" followed by the reason on line 1 and leave line 2 empty.
            """, user: request, maxTokens: 1024, effort: "low")
    }

    static func explainFailure(command: String, exitCode: Int, output: String, _ c: Context) -> AIRequest {
        AIRequest(system: """
            You help someone understand why a command failed in their terminal on macOS \(macOSVersion).
            Be brief: the likely cause in one or two sentences, then how to fix it. Plain text, no headings.
            If a single shell command fixes it, write it alone on the last line, prefixed with "$ ".
            Answer in \(c.language).
            """, user: """
            Shell: \(c.shell)
            Directory: \(c.directory)
            Command: \(command)
            Exit code: \(exitCode)

            Last lines of the terminal:
            ```
            \(output)
            ```
            """, maxTokens: 2048, effort: "medium")
    }

    /// Conversazione libera con l'assistente del terminale.
    static func chat(_ history: [AIMessage], _ c: Context) -> AIRequest {
        AIRequest(system: """
            You are the assistant built into NotchTerm, a terminal on macOS \(macOSVersion). \
            The user talks to you from the terminal. Shell: \(c.shell). Current directory: \(c.directory).
            Answer concisely and concretely, in \(c.language) unless the user writes in another language. \
            Plain text; use `code` for names and short commands, no headings.
            When you suggest a command to run, put it alone on its own line prefixed with "$ " \
            (one command per line, ready to paste). Warn clearly before anything that deletes data or changes system settings.
            You cannot see the terminal unless the user attaches its output to a message.
            """, messages: history, maxTokens: 4096, effort: "medium")
    }

    /// Comandi suggeriti in una risposta (righe che iniziano con "$ ").
    static func suggestedCommands(in reply: String) -> [String] {
        reply.components(separatedBy: .newlines).compactMap { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("`") && t.hasSuffix("`") && t.count > 1 { t = String(t.dropFirst().dropLast()) }
            guard t.hasPrefix("$ ") else { return nil }
            let c = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        }
    }

    static func explainText(_ text: String, _ c: Context) -> AIRequest {
        AIRequest(system: """
            You explain text copied from a terminal on macOS \(macOSVersion) (shell: \(c.shell)): \
            output, logs, errors or commands. Be brief and concrete. Plain text, no headings.
            If it is a command, say what it does and point out anything risky.
            If a single shell command is the natural next step, write it alone on the last line, prefixed with "$ ".
            Answer in \(c.language).
            """, user: "```\n\(text)\n```", maxTokens: 2048, effort: "medium")
    }

    /// Risposta alla richiesta di comando: (comando, spiegazione). Comando nil se il modello
    /// ha risposto con "#" (non si può fare con un comando solo).
    static func parseCommand(_ reply: String) -> (command: String?, explanation: String) {
        var lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard !lines.isEmpty else { return (nil, "") }
        var first = lines.removeFirst()
        if first.hasPrefix("$ ") { first.removeFirst(2) }
        if first.hasPrefix("`") && first.hasSuffix("`") && first.count > 1 { first = String(first.dropFirst().dropLast()) }
        if first.hasPrefix("#") {
            let why = first.dropFirst().trimmingCharacters(in: .whitespaces)
            return (nil, ([why] + lines).filter { !$0.isEmpty }.joined(separator: " "))
        }
        return (first, lines.joined(separator: " "))
    }

    /// Comando suggerito in fondo a una spiegazione ("$ comando"), se c'è.
    static func suggestedCommand(in reply: String) -> String? {
        for line in reply.components(separatedBy: .newlines).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("```") { continue }
            var cmd = t
            if cmd.hasPrefix("`") && cmd.hasSuffix("`") && cmd.count > 1 { cmd = String(cmd.dropFirst().dropLast()) }
            guard cmd.hasPrefix("$ ") else { return nil }
            let c = cmd.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        }
        return nil
    }

    /// Testo da mostrare: senza la riga del comando suggerito (ha il suo pulsante).
    static func displayText(_ reply: String, hidingSuggestion: Bool) -> String {
        guard hidingSuggestion, suggestedCommand(in: reply) != nil else { return reply }
        var lines = reply.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty
                || last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
