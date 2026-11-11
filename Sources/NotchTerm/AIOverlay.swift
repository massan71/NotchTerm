import AppKit

/// Riquadro dell'assistente in fondo al terminale.
/// - Modalità "chiedi": un campo in cui si descrive cosa fare; la risposta è un
///   comando che si inserisce nel prompt (senza eseguirlo) con Invio.
/// - Modalità "spiega": la spiegazione di un errore o del testo selezionato,
///   che arriva man mano; se contiene un comando suggerito, lo si inserisce con un pulsante.
/// - Modalità "chat": una conversazione libera con l'assistente, con l'output del
///   terminale allegato a richiesta.
@MainActor
final class AIOverlayView: NSView, NSTextFieldDelegate {
    enum Mode { case ask, explain, chat }

    /// Un turno della chat come lo si mostra.
    struct ChatTurn: Equatable {
        var role: String
        var text: String
        var attachedOutput = false
    }

    var onSubmit: ((String) -> Void)?
    /// Chat: testo e se allegare l'output del terminale.
    var onChatSubmit: ((String, Bool) -> Void)?
    var onNewChat: (() -> Void)?
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// L'altezza preferita è cambiata (testo arrivato, errore…): il controller ridispone.
    var onResize: (() -> Void)?

    private(set) var mode = Mode.ask
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton()
    let input = NSTextField()
    private let scroll = NSScrollView()
    /// TextKit 1: serve a misurare l'altezza del testo in modo affidabile.
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let insertButton = NSButton()
    private let copyButton = NSButton()
    private let settingsButton = NSButton()
    private let newChatButton = NSButton()
    private let attachCheckbox = NSButton(checkboxWithTitle: "Allega l'output del terminale", target: nil, action: nil)
    private var chatTurns: [ChatTurn] = []
    private var chatStreaming: String?
    private var chatError: String?

    private var tint: NSColor = .white
    private var command: String?
    /// Testo della richiesta a cui si riferisce il comando mostrato.
    private var answeredPrompt: String?
    private var rawText = ""
    private var working = false

    private let pad: CGFloat = 10
    private let headerH: CGFloat = 22
    private let inputH: CGFloat = 26
    private let buttonsH: CGFloat = 24
    var maxTextHeight: CGFloat = 200

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Chiudi")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        closeButton.toolTip = "Chiudi (Esc)"

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 13)
        input.delegate = self
        input.target = self
        input.action = #selector(inputAction)
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.wantsLayer = true
        input.layer?.cornerRadius = 7

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        for (b, title, sel) in [(insertButton, "Inserisci", #selector(insertAction)),
                                (copyButton, "Copia", #selector(copyAction)),
                                (settingsButton, "Impostazioni…", #selector(settingsAction)),
                                (newChatButton, "Nuova chat", #selector(newChatAction))] {
            b.title = title
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5, weight: .medium)
            b.target = self
            b.action = sel
        }
        insertButton.toolTip = "Scrive il comando nel prompt senza eseguirlo"
        attachCheckbox.controlSize = .small
        attachCheckbox.font = .systemFont(ofSize: 11)
        attachCheckbox.toolTip = "Aggiunge al messaggio le ultime righe del terminale"

        for v in [icon, titleLabel, spinner, closeButton, input, scroll, insertButton, copyButton, settingsButton,
                  newChatButton, attachCheckbox] as [NSView] {
            addSubview(v)
        }
        reset()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme(foreground: NSColor, background: NSColor) {
        tint = foreground
        layer?.backgroundColor = background.blended(withFraction: 0.12, of: foreground)?
            .withAlphaComponent(0.92).cgColor
        layer?.borderColor = foreground.withAlphaComponent(0.18).cgColor
        icon.contentTintColor = NSColor(srgbRed: 0.75, green: 0.6, blue: 1, alpha: 1)
        titleLabel.textColor = foreground.withAlphaComponent(0.75)
        closeButton.contentTintColor = foreground.withAlphaComponent(0.5)
        input.textColor = foreground
        input.layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        attachCheckbox.attributedTitle = NSAttributedString(
            string: attachCheckbox.title,
            attributes: [.foregroundColor: foreground.withAlphaComponent(0.7), .font: NSFont.systemFont(ofSize: 11)])
        updatePlaceholder()
        render()
    }

    private func updatePlaceholder() {
        let text = mode == .chat ? "Scrivi un messaggio… (Invio per inviare)"
                                 : "Descrivi cosa vuoi fare, es. «trova i file più grandi di 100 MB»"
        input.placeholderAttributedString = NSAttributedString(
            string: text, attributes: [.foregroundColor: tint.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 13)])
    }

    // MARK: Stati

    private func reset() {
        command = nil
        answeredPrompt = nil
        rawText = ""
        working = false
        spinner.stopAnimation(nil)
        insertButton.isHidden = true
        copyButton.isHidden = true
        settingsButton.isHidden = true
        newChatButton.isHidden = mode != .chat
        attachCheckbox.isHidden = mode != .chat
        chatError = nil
        render()
    }

    func showAsk(title: String) {
        mode = .ask
        updatePlaceholder()
        titleLabel.stringValue = title
        input.isHidden = false
        input.stringValue = ""
        reset()
    }

    func showExplain(title: String) {
        mode = .explain
        updatePlaceholder()
        titleLabel.stringValue = title
        input.isHidden = true
        reset()
        setWorking(true)
    }

    /// Apre la chat mostrando la conversazione già fatta.
    func showChat(title: String, turns: [ChatTurn]) {
        mode = .chat
        titleLabel.stringValue = title
        input.isHidden = false
        updatePlaceholder()
        chatTurns = turns
        chatStreaming = nil
        reset()
        updateChatButtons()
        scrollToEnd()
    }

    /// Stato della chat: turni completati e risposta in arrivo (nil se non c'è).
    func setChat(turns: [ChatTurn], streaming: String?) {
        chatTurns = turns
        chatStreaming = streaming
        chatError = nil
        setWorking(streaming != nil)
        updateChatButtons()
        render()
        scrollToEnd()
    }

    /// Comando suggerito nell'ultima risposta della chat.
    private var lastChatCommand: String? {
        guard let last = chatTurns.last, last.role == "assistant" else { return nil }
        return AIPrompts.suggestedCommands(in: last.text).last
    }

    private func updateChatButtons() {
        guard mode == .chat else { return }
        command = working ? nil : lastChatCommand
        insertButton.title = "Inserisci il comando"
        insertButton.isHidden = command == nil
        newChatButton.isHidden = false
        newChatButton.isEnabled = !chatTurns.isEmpty
        attachCheckbox.isHidden = false
    }

    private func scrollToEnd() {
        DispatchQueue.main.async { [weak self] in self?.textView.scrollToEndOfDocument(nil) }
    }

    func setWorking(_ working: Bool) {
        self.working = working
        working ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        if working {
            insertButton.isHidden = true
            copyButton.isHidden = true
            settingsButton.isHidden = true
        }
    }

    /// Testo della spiegazione (anche parziale, durante lo streaming).
    func setExplanation(_ text: String, finished: Bool) {
        rawText = text
        if finished {
            setWorking(false)
            command = AIPrompts.suggestedCommand(in: text)
            insertButton.title = "Inserisci il comando"
            insertButton.isHidden = command == nil
            copyButton.isHidden = text.isEmpty
        }
        render()
    }

    /// Risposta alla richiesta di comando.
    func setCommand(_ cmd: String?, explanation: String, prompt: String) {
        setWorking(false)
        command = cmd
        answeredPrompt = prompt
        rawText = explanation
        insertButton.title = "Inserisci ⏎"
        insertButton.isHidden = cmd == nil
        copyButton.isHidden = cmd == nil
        render()
    }

    func setError(_ message: String, offerSettings: Bool) {
        setWorking(false)
        if mode == .chat {
            chatStreaming = nil
            chatError = "⚠︎ " + message
            updateChatButtons()
            settingsButton.isHidden = !offerSettings
            render()
            return
        }
        command = nil
        rawText = "⚠︎ " + message
        settingsButton.isHidden = !offerSettings
        render()
    }

    // MARK: Testo

    private func render() {
        let body = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        if mode == .chat {
            renderChat(into: body, para: para)
            textView.textStorage?.setAttributedString(body)
            needsLayout = true
            onResize?()
            return
        }
        if mode == .ask, let command {
            body.append(NSAttributedString(string: command + "\n", attributes: [
                .font: mono, .foregroundColor: NSColor(srgbRed: 0.35, green: 0.86, blue: 0.5, alpha: 1),
                .paragraphStyle: para]))
        }
        // A risposta finita il comando suggerito si toglie dal testo e si mostra a parte, in verde.
        let finishedWithCommand = mode == .explain && !working && command != nil
        let shown = mode == .explain ? AIPrompts.displayText(rawText, hidingSuggestion: finishedWithCommand) : rawText
        if !shown.isEmpty {
            body.append(Self.inlineMarkdown(shown, font: .systemFont(ofSize: 12.5),
                                            color: tint.withAlphaComponent(mode == .ask ? 0.7 : 0.9), para: para))
        }
        if finishedWithCommand, let command {
            body.append(NSAttributedString(string: "\n\n$ " + command, attributes: [
                .font: mono, .foregroundColor: NSColor(srgbRed: 0.35, green: 0.86, blue: 0.5, alpha: 1),
                .paragraphStyle: para]))
        }
        textView.textStorage?.setAttributedString(body)
        needsLayout = true
        onResize?()
    }

    private func renderChat(into body: NSMutableAttributedString, para: NSParagraphStyle) {
        let gap = NSMutableParagraphStyle()
        gap.lineSpacing = 2
        gap.paragraphSpacingBefore = 8
        var turns = chatTurns.map { ($0.role, $0.text, $0.attachedOutput) }
        if let s = chatStreaming { turns.append(("assistant", s.isEmpty ? "…" : s, false)) }
        if turns.isEmpty {
            body.append(NSAttributedString(string: "Chiedi qualsiasi cosa sul terminale, sui comandi o sull'output. "
                + "Se l'assistente propone un comando, lo puoi inserire nel prompt con un clic.",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: tint.withAlphaComponent(0.5),
                             .paragraphStyle: para]))
        }
        for (i, (role, text, attached)) in turns.enumerated() {
            let style = i == 0 ? para : gap
            if role == "user" {
                var t = "› " + text
                if attached { t += "  📎" }
                body.append(NSAttributedString(string: t + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: tint.withAlphaComponent(0.6), .paragraphStyle: style]))
            } else {
                body.append(Self.replyText(text, tint: tint, para: style))
                if i < turns.count - 1 || chatError != nil { body.append(NSAttributedString(string: "\n")) }
            }
        }
        if let chatError {
            body.append(NSAttributedString(string: chatError, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.systemOrange, .paragraphStyle: gap]))
        }
    }

    /// Risposta dell'assistente: testo con markdown in linea, righe "$ comando" in verde.
    static func replyText(_ text: String, tint: NSColor, para: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // Le righe vuote diventano un piccolo spazio tra paragrafi invece di una riga intera.
        let spaced = (para.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        spaced.paragraphSpacing = 6
        let para = spaced
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isCommand = trimmed.hasPrefix("$ ") || (trimmed.hasPrefix("`$ ") && trimmed.hasSuffix("`"))
            if isCommand {
                let cmd = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                out.append(NSAttributedString(string: cmd, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: NSColor(srgbRed: 0.35, green: 0.86, blue: 0.5, alpha: 1), .paragraphStyle: para]))
            } else {
                out.append(inlineMarkdown(line, font: .systemFont(ofSize: 12.5), color: tint.withAlphaComponent(0.9), para: para))
            }
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para])) }
        }
        return out
    }

    /// Grassetto, corsivo e `codice` in linea; il resto resta testo.
    static func inlineMarkdown(_ text: String, font: NSFont, color: NSColor, para: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        guard let parsed = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .medium)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let d = font.fontDescriptor.withSymbolicTraits(traits)
                        attrs[.font] = NSFont(descriptor: d, size: font.pointSize) ?? font
                    }
                }
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    // MARK: Geometria

    private var textHeight: CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              textView.textStorage?.length ?? 0 > 0 else { return 0 }
        tc.containerSize = NSSize(width: max(50, bounds.width - 2 * pad), height: .greatestFiniteMagnitude)
        _ = lm.glyphRange(for: tc)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height) + 4
    }

    private var showsButtons: Bool {
        mode == .chat || !insertButton.isHidden || !copyButton.isHidden || !settingsButton.isHidden
    }

    /// Altezza per la larghezza attuale.
    func preferredHeight(width: CGFloat) -> CGFloat {
        if bounds.width != width { setFrameSize(NSSize(width: width, height: bounds.height)) }
        if mode == .chat {
            let t = min(maxTextHeight, textHeight)
            return pad + headerH + (t > 0 ? 8 + t : 0) + 8 + inputH + 8 + buttonsH + pad
        }
        var h = pad + headerH
        if mode == .ask { h += 6 + inputH }
        let t = min(maxTextHeight, textHeight)
        if t > 0 { h += 8 + t }
        if showsButtons { h += 8 + buttonsH }
        return h + pad
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y = pad
        icon.frame = NSRect(x: pad, y: y + 3, width: 16, height: 16)
        closeButton.frame = NSRect(x: w - pad - 18, y: y + 2, width: 18, height: 18)
        spinner.frame = NSRect(x: closeButton.frame.minX - 22, y: y + 3, width: 16, height: 16)
        titleLabel.frame = NSRect(x: icon.frame.maxX + 6, y: y + 3, width: max(0, spinner.frame.minX - icon.frame.maxX - 12), height: 16)
        y += headerH
        if mode == .chat {
            layoutChat(from: y, width: w)
            return
        }
        if mode == .ask {
            y += 6
            input.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: inputH)
            y += inputH
        }
        let t = min(maxTextHeight, textHeight)
        scroll.isHidden = t == 0
        if t > 0 {
            y += 8
            scroll.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: t)
            textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(t, textView.frame.height))
            y += t
        }
        if showsButtons {
            y += 8
            var x = w - pad
            for b in [insertButton, copyButton, settingsButton] where !b.isHidden {
                b.sizeToFit()
                let bw = max(70, b.frame.width + 8)
                x -= bw
                b.frame = NSRect(x: x, y: y, width: bw, height: buttonsH)
                x -= 6
            }
        }
    }

    /// Chat: conversazione, poi il campo di testo, poi la riga di pulsanti.
    private func layoutChat(from top: CGFloat, width w: CGFloat) {
        var y = top
        let t = min(maxTextHeight, textHeight)
        scroll.isHidden = t == 0
        if t > 0 {
            y += 8
            scroll.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: t)
            textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(t, textView.frame.height))
            y += t
        }
        y += 8
        input.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: inputH)
        y += inputH + 8
        attachCheckbox.sizeToFit()
        attachCheckbox.frame = NSRect(x: pad, y: y + (buttonsH - attachCheckbox.frame.height) / 2,
                                      width: attachCheckbox.frame.width, height: attachCheckbox.frame.height)
        var x = w - pad
        for b in [insertButton, newChatButton, settingsButton] where !b.isHidden {
            b.sizeToFit()
            let bw = max(70, b.frame.width + 8)
            x -= bw
            b.frame = NSRect(x: x, y: y, width: bw, height: buttonsH)
            x -= 6
        }
    }

    // MARK: Azioni

    @objc private func inputAction() {
        let text = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if mode == .chat {
            guard !working else { return }
            input.stringValue = ""
            let attach = attachCheckbox.state == .on
            attachCheckbox.state = .off
            onChatSubmit?(text, attach)
            return
        }
        // Invio sulla stessa richiesta già risposta: inserisce il comando.
        if let command, text == answeredPrompt {
            onInsert?(command)
            return
        }
        setWorking(true)
        rawText = ""
        command = nil
        render()
        onSubmit?(text)
    }

    @objc private func insertAction() {
        if let command { onInsert?(command) }
    }

    @objc private func copyAction() {
        let text = mode == .ask ? (command ?? "") : rawText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = "Copiato"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = "Copia" }
    }

    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func newChatAction() { onNewChat?() }
    @objc private func closeAction() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
