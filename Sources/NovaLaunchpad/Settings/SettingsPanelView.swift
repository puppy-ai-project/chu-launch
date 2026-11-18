import AppKit

@MainActor final class SettingsPanelView: NSView {
    private let status = NSTextField(labelWithString: "")
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    var onCheckUpdates: (() -> Void)?

    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        box(self, color: .windowBackgroundColor, radius: 14, border: true)
        layer?.masksToBounds = true

        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 188, height: bounds.height))
        box(sidebar, color: .controlBackgroundColor)
        addSubview(sidebar)
        label("设置", x: 20, y: 363, size: 21, weight: .semibold, in: sidebar)
        let row = NSView(frame: NSRect(x: 12, y: 302, width: 164, height: 38))
        box(row, color: NSColor.systemTeal.withAlphaComponent(0.12), radius: 8)
        sidebar.addSubview(row)
        let indicator = NSView(frame: NSRect(x: 0, y: 11, width: 3, height: 16))
        box(indicator, color: .systemTeal, radius: 1.5)
        row.addSubview(indicator)
        symbol("info.circle.fill", frame: NSRect(x: 13, y: 9, width: 20, height: 20), in: row)
        label("关于", x: 43, y: 7, size: 14, weight: .medium, in: row)

        label("关于", x: 212, y: 363, size: 22, weight: .semibold, in: self)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭设置")!, target: self, action: #selector(closePanel))
        close.isBordered = false
        close.frame = NSRect(x: 628, y: 362, width: 30, height: 30)
        addSubview(close)

        let product = card(y: 235, height: 100)
        symbol("square.grid.3x3.fill", frame: NSRect(x: 18, y: 26, width: 46, height: 46), in: product)
        label("Nova Launchpad", x: 82, y: 53, size: 20, weight: .semibold, in: product)
        label("版本 " + version, x: 82, y: 24, size: 13, weight: .regular, in: product).textColor = .secondaryLabelColor

        let updates = card(y: 52, height: 165)
        label("软件更新", x: 18, y: 119, size: 16, weight: .semibold, in: updates)
        status.stringValue = "检查是否有可用的新版本。"
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.frame = NSRect(x: 18, y: 60, width: 404, height: 54)
        updates.addSubview(status)
        let button = NSButton(title: "检查更新", target: self, action: #selector(check))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 14, y: 16, width: 104, height: 32)
        updates.addSubview(button)
    }

    private func box(_ view: NSView, color: NSColor, radius: CGFloat = 0, border: Bool = false) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = color.cgColor
        if border {
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func card(y: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 212, y: y, width: 444, height: height))
        box(view, color: .controlBackgroundColor, radius: 12, border: true)
        addSubview(view)
        return view
    }

    @discardableResult
    private func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, in parent: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: x, y: y))
        parent.addSubview(field)
        return field
    }

    private func symbol(_ name: String, frame: NSRect, in parent: NSView) {
        let image = NSImageView(frame: frame)
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.contentTintColor = .systemTeal
        parent.addSubview(image)
    }

    private var dragOffset: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        dragOffset = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview, let dragOffset else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        let x = min(max(parent.bounds.minX, point.x - dragOffset.x), max(parent.bounds.minX, parent.bounds.maxX - frame.width))
        let y = min(max(parent.bounds.minY, point.y - dragOffset.y), max(parent.bounds.minY, parent.bounds.maxY - frame.height))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func check() { onCheckUpdates?() }

    @objc private func closePanel() { onClose?() }

    func setStatus(_ text: String) { status.stringValue = text }
}


@MainActor final class SettingsBackdropView: NSView {
    static let shade = NSColor.black.withAlphaComponent(0.10)

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
