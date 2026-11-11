import Foundation
import Testing
@testable import NotchTerm

/// Risponde alle richieste con un corpo prestabilito, senza rete.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct AIClientTests {
    func settings(_ provider: String, model: String = "", key: String? = "k", base: String = "") -> AISettings {
        var ai = Config.AI()
        ai.provider = provider
        ai.model = model
        ai.baseURL = base
        return AISettings(ai, key: key)
    }

    func json(_ data: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]) ?? [:]
    }

    // MARK: Impostazioni

    @Test func claudeDefaults() {
        let s = settings("claude")
        #expect(s.model == "claude-opus-5-5")
        #expect(s.baseURL == "https://api.anthropic.com")
        #expect(s.problem == nil)
        #expect(settings("claude", key: nil).problem != nil)
        #expect(settings("claude", key: "").problem != nil)
    }

    @Test func localProvidersNeedModelButNoKey() {
        #expect(settings("ollama", key: nil).problem != nil)               // manca il modello
        #expect(settings("ollama", model: "llama", key: nil).problem == nil)
        #expect(settings("custom", model: "m", key: nil).problem != nil)    // manca l'indirizzo
        #expect(settings("custom", model: "m", key: nil, base: "http://x/v1").problem == nil)
        #expect(settings("nonexistent").provider.id == "claude")
    }

    // MARK: Richieste

    @Test func anthropicRequest() throws {
        let req = try AIClient(settings: settings("claude")).urlRequest(AIRequest(system: "S", user: "U", maxTokens: 100, effort: "low"))
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = json(req.httpBody)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "S")
        #expect(body["stream"] as? Bool == true)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["thinking"] == nil)
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.first?["content"] as? String == "U")
    }

    @Test func olderClaudeModelsSkipNewParameters() throws {
        let req = try AIClient(settings: settings("claude", model: "claude-haiku-4-5")).urlRequest(AIRequest(system: "S", user: "U"))
        let body = json(req.httpBody)
        #expect(body["fallbacks"] == nil)
        #expect(body["output_config"] == nil)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func openAICompatibleRequest() throws {
        let req = try AIClient(settings: settings("ollama", model: "llama", key: nil))
            .urlRequest(AIRequest(system: "S", user: "U"))
        #expect(req.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        let body = json(req.httpBody)
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.map { $0["role"] as? String } == ["system", "user"])

        let withKey = try AIClient(settings: settings("custom", model: "m", base: "https://x.test/v1/"))
            .urlRequest(AIRequest(system: "S", user: "U"))
        #expect(withKey.url?.absoluteString == "https://x.test/v1/chat/completions")
        #expect(withKey.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func ollamaCloudRequest() throws {
        let s = settings("ollama-cloud")
        #expect(s.model == "gemma4:31b")
        #expect(s.problem == nil)
        #expect(settings("ollama-cloud", key: nil).problem != nil)
        let req = try AIClient(settings: s).urlRequest(AIRequest(system: "S", user: "U"))
        #expect(req.url?.absoluteString == "https://ollama.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func ollamaCloudListsModelsFromTags() async throws {
        StubProtocol.status = 200
        StubProtocol.body = #"{"models":[{"name":"gemma4:31b"},{"name":"gpt-oss:120b"}]}"#
        let models = try await AIClient(settings: settings("ollama-cloud"), session: StubProtocol.session).listModels()
        #expect(models == ["gemma4:31b", "gpt-oss:120b"])
        #expect(StubProtocol.lastRequest?.url?.absoluteString == "https://ollama.com/api/tags")
    }

    @Test func missingConfigurationThrows() {
        #expect(throws: AIError.self) {
            try AIClient(settings: settings("claude", key: nil)).urlRequest(AIRequest(system: "", user: ""))
        }
    }

    // MARK: Parsing dello stream

    @Test func parsesAnthropicEvents() {
        #expect(AIClient.parseAnthropic(line: "event: content_block_delta") == nil)
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ciao"}}"#) == .text("Ciao"))
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#) == nil)
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) == .stop("refusal"))
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"message_stop"}"#) == .done)
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .error("Overloaded"))
        #expect(AIClient.parseAnthropic(line: #"data: {"type":"ping"}"#) == nil)
    }

    @Test func parsesOpenAIEvents() {
        #expect(AIClient.parseOpenAI(line: #"data: {"choices":[{"delta":{"content":"ls"},"finish_reason":null}]}"#) == .text("ls"))
        #expect(AIClient.parseOpenAI(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(AIClient.parseOpenAI(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .stop("stop"))
        #expect(AIClient.parseOpenAI(line: "data: [DONE]") == .done)
        #expect(AIClient.parseOpenAI(line: ": keep-alive") == nil)
    }

    @Test func errorMessages() {
        #expect(AIClient.errorMessage(from: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)) == "invalid x-api-key")
        #expect(AIClient.errorMessage(from: Data(#"{"error":"model not found"}"#.utf8)) == "model not found")
        #expect(AIClient.errorMessage(from: Data("Bad Gateway".utf8)) == "Bad Gateway")
        #expect(AIClient.parseModelList(Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)) == ["a", "b"])
    }

    // MARK: Streaming completo (con server finto)

    @Test func streamsAnthropicText() async throws {
        StubProtocol.status = 200
        StubProtocol.body = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"du -sh"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" *"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        var chunks: [String] = []
        let full = try await AIClient(settings: settings("claude"), session: StubProtocol.session)
            .stream(AIRequest(system: "S", user: "U")) { chunks.append($0) }
        #expect(full == "du -sh *")
        #expect(chunks == ["du -sh", " *"])
        #expect(json(StubProtocol.lastBody)["model"] as? String == "claude-opus-5-5")
    }

    @Test func refusalBecomesError() async {
        StubProtocol.status = 200
        StubProtocol.body = """
        data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

        data: {"type":"message_stop"}

        """
        await #expect(throws: AIError.refused) {
            try await AIClient(settings: settings("claude"), session: StubProtocol.session)
                .stream(AIRequest(system: "S", user: "U")) { _ in }
        }
    }

    @Test func httpErrorCarriesMessage() async {
        StubProtocol.status = 401
        StubProtocol.body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        await #expect(throws: AIError.http(401, "invalid x-api-key")) {
            try await AIClient(settings: settings("claude"), session: StubProtocol.session)
                .stream(AIRequest(system: "S", user: "U")) { _ in }
        }
    }

    @Test func streamsOpenAIText() async throws {
        StubProtocol.status = 200
        StubProtocol.body = """
        data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"delta":{"content":"git "}}]}

        data: {"choices":[{"delta":{"content":"status"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let full = try await AIClient(settings: settings("openrouter", model: "x"), session: StubProtocol.session)
            .stream(AIRequest(system: "S", user: "U")) { _ in }
        #expect(full == "git status")
        #expect(StubProtocol.lastRequest?.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    }
}

@Suite struct AIPromptTests {
    @Test func parsesCommandReply() {
        let r = AIPrompts.parseCommand("find . -size +100M\nCerca i file più grandi di 100 MB.")
        #expect(r.command == "find . -size +100M")
        #expect(r.explanation == "Cerca i file più grandi di 100 MB.")
    }

    @Test func parsesCommandInFences() {
        let r = AIPrompts.parseCommand("```sh\n$ ls -la\n```\nElenca i file.")
        #expect(r.command == "ls -la")
        #expect(r.explanation == "Elenca i file.")
        #expect(AIPrompts.parseCommand("`pwd`\nCartella.").command == "pwd")
    }

    @Test func impossibleRequest() {
        let r = AIPrompts.parseCommand("# Serve un'app grafica\n")
        #expect(r.command == nil)
        #expect(r.explanation == "Serve un'app grafica")
        #expect(AIPrompts.parseCommand("").command == nil)
    }

    @Test func suggestedFix() {
        let reply = "Manca il pacchetto.\n\n$ npm install express\n"
        #expect(AIPrompts.suggestedCommand(in: reply) == "npm install express")
        #expect(AIPrompts.displayText(reply, hidingSuggestion: true) == "Manca il pacchetto.")
        #expect(AIPrompts.displayText(reply, hidingSuggestion: false) == reply)
        #expect(AIPrompts.suggestedCommand(in: "Nessun comando.\nSolo testo.") == nil)
        #expect(AIPrompts.suggestedCommand(in: "Prova:\n`$ make clean`") == "make clean")
    }

    @Test func chatSendsWholeConversation() throws {
        var ai = Config.AI()
        ai.provider = "claude"
        let history = [AIMessage(role: "user", content: "ciao"), AIMessage(role: "assistant", content: "Ciao!"),
                       AIMessage(role: "user", content: "come elenco i file?")]
        let c = AIPrompts.Context(shell: "zsh", directory: "/tmp", language: "italiano (it)")
        let r = AIPrompts.chat(history, c)
        #expect(r.user == "come elenco i file?")
        let req = try AIClient(settings: AISettings(ai, key: "k")).urlRequest(r)
        let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
        let msgs = body["messages"] as? [[String: String]]
        #expect(msgs?.map { $0["role"] ?? "" } == ["user", "assistant", "user"])
        #expect(msgs?.last?["content"] == "come elenco i file?")

        ai.provider = "ollama"
        ai.model = "m"
        let oreq = try AIClient(settings: AISettings(ai, key: nil)).urlRequest(r)
        let obody = (try? JSONSerialization.jsonObject(with: oreq.httpBody ?? Data()) as? [String: Any]) ?? [:]
        let omsgs = obody["messages"] as? [[String: String]]
        #expect(omsgs?.map { $0["role"] ?? "" } == ["system", "user", "assistant", "user"])
    }

    @Test func findsAllSuggestedCommands() {
        let reply = "Puoi usare:\n$ ls -la\noppure\n`$ tree -L 2`\nNiente altro."
        #expect(AIPrompts.suggestedCommands(in: reply) == ["ls -la", "tree -L 2"])
        #expect(AIPrompts.suggestedCommands(in: "Nessun comando.").isEmpty)
    }

    @Test func promptsCarryContext() {
        let c = AIPrompts.Context(shell: "zsh", directory: "/tmp/x", language: "italiano (it)")
        let cmd = AIPrompts.command("elenca", c)
        #expect(cmd.system.contains("/tmp/x") && cmd.system.contains("zsh") && cmd.system.contains("italiano"))
        #expect(cmd.user == "elenca")
        let fail = AIPrompts.explainFailure(command: "make", exitCode: 2, output: "error: x", c)
        #expect(fail.user.contains("make") && fail.user.contains("2") && fail.user.contains("error: x"))
    }
}
