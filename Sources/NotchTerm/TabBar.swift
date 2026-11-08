import AppKit

/// Linguetta di una scheda: titolo + "×" che compare al passaggio del mouse.
@MainActor
final class TabPill: NSView {
    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var isSelected = false { didSet { refresh() } }
    var showsPill = true { didSet { refresh() } }
    var tint: NSColor = .white { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingHead
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Chiudi scheda")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onSelect?() }
    }

    override func otherMouseUp(with event: NSEvent) {
        // clic centrale = chiudi, come nei browser
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeTapped() { onClose?() }

    private func refresh() {
        let showClose = showsPill && (hovering || isSelected) && bounds.width > 44
        closeButton.isHidden = !showClose
        closeButton.contentTintColor = tint.withAlphaComponent(0.7)
        label.textColor = tint
        label.alphaValue = (!showsPill || isSelected) ? 0.9 : (hovering ? 0.75 : 0.5)
        let bgAlpha: CGFloat = showsPill ? (isSelected ? 0.16 : (hovering ? 0.08 : 0)) : 0
        layer?.backgroundColor = tint.withAlphaComponent(bgAlpha).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let inset: CGFloat = showsPill ? 8 : 0
        let closeW: CGFloat = closeButton.isHidden ? 0 : 14
        closeButton.frame = NSRect(x: bounds.width - inset - 12, y: (h - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: inset, y: (h - 15) / 2, width: max(0, bounds.width - 2 * inset - closeW), height: 15)
    }
}

/// Barra delle schede nello spazio a sinistra del notch.
/// Con una sola scheda mostra solo il titolo, senza linguette.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var maxTabWidth: CGFloat = 170

    private var pills: [TabPill] = []
    private var titles: [String] = []
    private var selected = 0
    private var tint: NSColor = .white

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(titles: [String], selected: Int, tint: NSColor) {
        self.titles = titles
        self.selected = selected
        self.tint = tint
        while pills.count < titles.count {
            let p = TabPill(frame: .zero)
            addSubview(p)
            pills.append(p)
        }
        while pills.count > titles.count { pills.removeLast().removeFromSuperview() }

        let single = titles.count == 1
        for (i, p) in pills.enumerated() {
            p.label.stringValue = titles[i]
            p.label.alignment = single ? .left : .center
            p.label.lineBreakMode = single ? .byTruncatingHead : .byTruncatingTail
            p.toolTip = titles[i]
            p.tint = tint
            p.showsPill = !single
            p.isSelected = i == selected
            p.onSelect = { [weak self] in self?.onSelect?(i) }
            p.onClose = { [weak self] in self?.onClose?(i) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !pills.isEmpty else { return }
        let gap: CGFloat = 4
        let h = min(bounds.height, 22)
        let y = (bounds.height - h) / 2
        if pills.count == 1 {
            pills[0].frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            return
        }
        let n = CGFloat(pills.count)
        let w = max(26, min(maxTabWidth, (bounds.width - gap * (n - 1)) / n))
        for (i, p) in pills.enumerated() {
            let x = CGFloat(i) * (w + gap)
            p.frame = NSRect(x: x, y: y, width: w, height: h)
            // Le schede che non ci stanno vengono nascoste: si raggiungono con ⌘1-9 / ⌃Tab.
            p.isHidden = x + w > bounds.width + 0.5
        }
    }
}
