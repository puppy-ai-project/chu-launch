import AppKit
import CoreImage
import OSLog
import Quartz
import QuartzCore
import UniformTypeIdentifiers

@MainActor private enum MenuSymbols {
    static func apply(_ symbol: String, to item: NSMenuItem) {
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = symbolImage.withSymbolConfiguration(configuration) ?? symbolImage
        let canvasSize = NSSize(width: 18, height: 18)
        let uniformImage = NSImage(size: canvasSize, flipped: false) { rect in
            let scale = min(1.0, min(rect.width / max(1, configured.size.width), rect.height / max(1, configured.size.height)))
            let drawWidth = configured.size.width * scale
            let drawHeight = configured.size.height * scale
            let x = (rect.width - drawWidth) / 2
            let y = (rect.height - drawHeight) / 2
            configured.draw(in: NSRect(x: x, y: y, width: drawWidth, height: drawHeight))
            return true
        }
        uniformImage.isTemplate = true
        item.image = uniformImage
        if item.responds(to: Selector(("setPreferredImageVisibility:"))) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
    }
}

#if DEBUG
@MainActor final class BackgroundDebugPanel: NSWindowController {
    private var style: ChuBackgroundStyle
    private let onChange: (ChuBackgroundStyle) -> Void
    init(style: ChuBackgroundStyle, onChange: @escaping (ChuBackgroundStyle) -> Void) {
        self.style = style
        self.onChange = onChange
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "背景调试"
        panel.level = .init(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.center()
        super.init(window: panel)
        let fields: [(String, Double, Double, Double)] = [
            ("模糊半径", 0, 150, style.blurRadius), ("亮度", -0.5, 0.5, style.brightness),
            ("饱和度", 0, 2, style.saturation), ("色调", -3.14, 3.14, style.hue ?? 0),
            ("背景遮罩透明度", 0, 1, style.overlayOpacity)
        ]
        for (index, field) in fields.enumerated() {
            let y = 211 - CGFloat(index) * 42
            let label = NSTextField(labelWithString: field.0)
            label.frame = NSRect(x: 16, y: y, width: 130, height: 24)
            panel.contentView?.addSubview(label)
            let slider = NSSlider(value: field.3, minValue: field.1, maxValue: field.2, target: self, action: #selector(changed(_:)))
            slider.frame = NSRect(x: 155, y: y, width: 205, height: 24)
            slider.tag = index
            panel.contentView?.addSubview(slider)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed(_ sender: NSSlider) {
        switch sender.tag {
        case 0: style.blurRadius = sender.doubleValue
        case 1: style.brightness = sender.doubleValue
        case 2: style.saturation = sender.doubleValue
        case 3: style.hue = sender.doubleValue
        case 4: style.overlayOpacity = sender.doubleValue
        default: return
        }
        onChange(style)
    }
}
#endif

// MARK: - 动画变换工具 (Animation Transform Helper)
enum AnimationHelper {
    static func makeScaleTransform(scale: CGFloat, center: CGPoint) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, center.x, center.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -center.x, -center.y, 0)
        return t
    }
}

// Model values are set before animations are installed; presentation values make
// a reversal continue from the frame currently on screen.
@MainActor enum LauncherTransition {
    static func set(_ layer: CALayer, keyPath: String, value: Any, duration: CFTimeInterval, curve: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard duration > 0, let from else { layer.removeAnimation(forKey: "launcher." + keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve
        layer.add(animation, forKey: "launcher." + keyPath)
    }
}

// The translucent window reveals the real desktop while the prepared blur fades in.
@MainActor final class LauncherBackgroundView: NSView {
    private(set) var style = ChuBackgroundStyle.load()
    private let wallpaperGroup = NSView()
    private let wallpaperImageView = NSImageView()
    private let opaqueBase = NSView()
    private let fallbackView = NSVisualEffectView()
    private let overlay = NSView()
    private let tint = NSView()
    private var cache: [String: NSImage] = [:]
    private var wallpaperGeneration = 0
    private var usingFallback = false
    private var lastByScreen: [String: NSImage] = [:]
    private var currentKey: String?
    private var refreshTask: Task<Void, Never>?
    private var wallpaperCanvasSize: NSSize?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func color(_ hex: String) -> NSColor {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let rgb = UInt32(text, radix: 16) else { return .clear }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        wallpaperGroup.frame = bounds
        wallpaperGroup.wantsLayer = true
        addSubview(wallpaperGroup)
        opaqueBase.wantsLayer = true
        opaqueBase.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        wallpaperImageView.wantsLayer = true
        wallpaperImageView.imageScaling = .scaleAxesIndependently
        fallbackView.material = .fullScreenUI
        fallbackView.blendingMode = .behindWindow
        fallbackView.state = .active
        fallbackView.wantsLayer = true
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = color(style.overlayColor).cgColor
        tint.wantsLayer = true
        // A neutral white tint adds no cast; non-white values give a subtle color wash.
        tint.layer?.backgroundColor = color(style.tintColor).cgColor
        for view in [opaqueBase, fallbackView, wallpaperImageView, overlay, tint] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            wallpaperGroup.addSubview(view)
        }
        applyStyle()
    }

    private func applyStyle() {
        overlay.layer?.opacity = Float(style.overlayOpacity)
        overlay.layer?.backgroundColor = color(style.overlayColor).cgColor
        tint.layer?.backgroundColor = color(style.tintColor).cgColor
        tint.layer?.opacity = style.tintColor.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")) == "ffffff" ? 0 : 0.06
        fallbackView.layer?.opacity = 0
    }

    var preparedWallpaper: NSImage? { usingFallback ? nil : wallpaperImageView.image }

    func setWallpaperCanvasSize(_ size: NSSize) {
        wallpaperCanvasSize = size
        syncWallpaperGroupFrame()
    }

    override func layout() {
        super.layout()
        syncWallpaperGroupFrame()
    }

    private func syncWallpaperGroupFrame() {
        let size = wallpaperCanvasSize ?? bounds.size
        wallpaperGroup.frame = NSRect(origin: .zero, size: size)
        let groupBounds = wallpaperGroup.bounds
        for subview in wallpaperGroup.subviews {
            subview.frame = groupBounds
        }
    }

    private func displayWallpaper(_ image: NSImage?) {
        if window?.isVisible == true, wallpaperImageView.image !== image,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = wallpaperImageView.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            layer.add(fade, forKey: "wallpaperChange")
        }
        wallpaperImageView.image = image
        usingFallback = image == nil
        wallpaperImageView.isHidden = usingFallback
    }

    func setStyle(_ value: ChuBackgroundStyle) {
        style = value
        applyStyle()
        cache.removeAll()
        currentKey = nil
    }

    func updateWallpaper(for screen: NSScreen, completion: (@MainActor () -> Void)? = nil) {
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        let screenID = String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            currentKey = nil
            displayWallpaper(lastByScreen[screenID])
            completion?(); return
        }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) ?? NSColor(white: 0.18, alpha: 1).usingColorSpace(.sRGB)!
        let placement = WallpaperPlacement(scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue, clip: (options[.allowClipping] as? NSNumber)?.boolValue ?? false, red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
        let style = self.style
        refreshTask?.cancel()
        refreshTask = Task {
            let key = await Task.detached(priority: .utility) { () -> String in
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(url.path)|\(size.width)x\(size.height)@\(scale)|\(modified?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(modified?.fileSize ?? 0)|\(placement.scaling)|\(placement.clip)|\(placement.red),\(placement.green),\(placement.blue)|\(style.blurRadius),\(style.brightness),\(style.saturation),\(style.hue ?? 0)"
            }.value
            guard !Task.isCancelled, generation == wallpaperGeneration else { return }
            if key == currentKey { completion?(); return }
            if let image = cache[key] {
                currentKey = key; displayWallpaper(image)
                lastByScreen[screenID] = image; completion?(); return
            }
            let image = await Task.detached(priority: .utility) {
                WallpaperBlurRenderer.generate(url: url, screenSize: size, scaleFactor: scale, placement: placement, style: style)
            }.value
            guard !Task.isCancelled, generation == wallpaperGeneration else { return }
            if let image {
                let result = NSImage(cgImage: image, size: size)
                if cache.count >= 4 { cache.removeAll() }
                cache[key] = result
                lastByScreen[screenID] = result
                currentKey = key
                displayWallpaper(result)
            } else {
                displayWallpaper(lastByScreen[screenID])
                currentKey = nil
            }
            completion?()
        }
    }

}

// MARK: - 全屏启动器窗口
@MainActor final class LauncherWindow: NSPanel, @MainActor QLPreviewPanelDataSource {
    private var previewURL: NSURL?

    func previewApplication(at url: URL) {
        previewURL = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 胶囊药丸风格搜索框 (Capsule Search Field)
@MainActor final class SearchCapsuleView: NSView, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let magnifier = NSImageView()
    var onMore: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?
    private var lastQuery = ""
    var isEditing: Bool { searchField.currentEditor() != nil }
    var onEscapePressed: (() -> Void)?

    var stringValue: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            publishQuery()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        // 原生 Launchpad 的半透明磨砂胶囊底色
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.45).cgColor

        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = .white
        addSubview(magnifier)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13, weight: .regular)
        searchField.textColor = .white
        searchField.delegate = self
        searchField.frame = NSRect(x: 12, y: 4, width: max(0, bounds.width - 24), height: 24)
        searchField.autoresizingMask = [.width]

        // 占位文字：浅灰白色
        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.48),
            .font: NSFont.systemFont(ofSize: 13, weight: .regular)
        ]
        searchField.placeholderAttributedString = NSAttributedString(string: "搜索应用", attributes: placeholderAttributes)

        addSubview(searchField)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        magnifier.frame = NSRect(x: 12, y: floor(bounds.midY - 8), width: 16, height: 16)
        let height = ceil(searchField.intrinsicContentSize.height)
        searchField.frame = NSRect(x: 36, y: floor(bounds.midY - height / 2), width: max(0, bounds.width - 48), height: height)
    }

    func makeFirstResponder() {
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        publishQuery()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        DispatchQueue.main.async { [weak self] in self?.publishQuery() }
    }

    private func publishQuery() {
        let query = searchField.stringValue
        guard query != lastQuery else { return }
        lastQuery = query
        onQueryChanged?(query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            publishQuery()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscapePressed?()
            return true
        }
        return false
    }
}

// MARK: - 单个应用图标项 (App Item View)
@MainActor final class AppItemView: NSView {
    private let iconImageView = NSImageView()
    var folderThumbnailFrame: CGRect {
        let frame = iconImageView.frame
        return frame.insetBy(dx: frame.width * 12 / 128, dy: frame.height * 12 / 128)
    }
    private let nameLabel = NSTextField(labelWithString: "")
    private(set) var appRecord: AppRecord?
    private var onOpen: ((AppRecord, AppItemView) -> Void)?
    private var isPressed = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.wantsLayer = true
        addSubview(iconImageView)

        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.maximumNumberOfLines = 1

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        nameLabel.shadow = shadow

        addSubview(nameLabel)
    }

    override func layout() {
        super.layout()
        // 图标固定 96x96，图标与文字间距固定 8pt，文字高度 18pt
        let labelHeight: CGFloat = 18
        let spacing: CGFloat = 8
        let iconSize: CGFloat = min(96, max(1, bounds.width - 8), max(1, bounds.height - labelHeight - spacing))
        let totalContentHeight = iconSize + spacing + labelHeight

        // 垂直居中于 Cell
        let startY = max(0, floor((bounds.height - totalContentHeight) / 2))
        let iconX = floor((bounds.width - iconSize) / 2)

        iconImageView.frame = NSRect(x: iconX, y: startY, width: iconSize, height: iconSize)
        nameLabel.frame = NSRect(x: 4, y: startY + iconSize + spacing, width: bounds.width - 8, height: labelHeight)
    }

    func configure(app: AppRecord, icon: NSImage, onOpen: @escaping (AppRecord, AppItemView) -> Void) {
        self.appRecord = app
        self.onOpen = onOpen
        nameLabel.stringValue = app.name
        iconImageView.image = icon
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let appRecord, !appRecord.path.hasPrefix("chu-folder:") else { return nil }
        let menu = NSMenu()
        for (title, action, symbol) in [
            ("打开", #selector(openFromMenu), "macwindow"),
            ("在访达中显示", #selector(revealFromMenu), "folder"),
            ("显示简介", #selector(showInfo), "info.circle"),
            ("快速查看", #selector(previewAppFromMenu), "eye"),
            ("共享…", #selector(shareApp), "square.and.arrow.up")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            MenuSymbols.apply(symbol, to: item)
        }
        return menu
    }

    @objc private func openFromMenu() {
        if let appRecord { onOpen?(appRecord, self) }
    }

    @objc private func revealFromMenu() {
        guard let appRecord else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appRecord.path)])
    }

    @objc private func showInfo() {
        guard let appRecord else { return }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setPropertyList([appRecord.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        if !NSPerformService("Finder/Show Info", pasteboard) { NSSound.beep() }
    }

    @objc private func previewAppFromMenu() {
        guard let appRecord, let launcher = window as? LauncherWindow else { return }
        launcher.previewApplication(at: URL(fileURLWithPath: appRecord.path))
    }

    @objc private func shareApp() {
        guard let appRecord else { return }
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: appRecord.path)])
        picker.show(relativeTo: iconImageView.bounds, of: iconImageView, preferredEdge: .maxX)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let icon = iconImageView.frame.insetBy(dx: -2, dy: -2)
        let labelWidth = min(nameLabel.frame.width, ceil(nameLabel.intrinsicContentSize.width) + 8)
        let label = NSRect(x: nameLabel.frame.midX - labelWidth / 2, y: nameLabel.frame.minY, width: labelWidth, height: nameLabel.frame.height)
        guard icon.contains(local) || label.contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        isPressed = true
        animatePress(down: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        animatePress(down: false)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let appRecord {
            onOpen?(appRecord, self)
        }
    }

    func cancelPress() {
        guard isPressed else { return }
        isPressed = false
        animatePress(down: false)
    }

    private func animatePress(down: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconImageView.animator().alphaValue = down ? 0.75 : 1.0
        }
    }

    // 点击进入应用时的放大启动动画
    func animateLaunch(completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }

        let center = CGPoint(x: iconImageView.bounds.midX, y: iconImageView.bounds.midY)
        let targetTransform = AnimationHelper.makeScaleTransform(scale: 1.25, center: center)

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = CATransform3DIdentity
        anim.toValue = targetTransform
        anim.duration = 0.22
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.85
        fadeAnim.duration = 0.22
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fadeAnim.fillMode = .forwards
        fadeAnim.isRemovedOnCompletion = false

        iconImageView.layer?.add(anim, forKey: "launchScale")
        iconImageView.layer?.add(fadeAnim, forKey: "launchFade")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            nameLabel.animator().alphaValue = 0.0
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            completion()
        }
    }

    func resetLaunchAnimation() {
        iconImageView.layer?.removeAnimation(forKey: "launchScale")
        iconImageView.layer?.removeAnimation(forKey: "launchFade")
        nameLabel.alphaValue = 1.0
        iconImageView.alphaValue = 1.0
    }
}

// MARK: - 单页网格视图 (7 列 x 5 行)
@MainActor final class PageGridView: NSView {
    private static let applicationIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .applicationBundle)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }()
    private var itemViews: [AppItemView] = []
    var columns = 7
    var rows = 5
    var onBlankAreaClicked: (() -> Void)?
    var onBlankDragStart: ((NSEvent) -> Void)?
    var onBlankDragMove: ((NSEvent) -> Void)?
    var onBlankDragEnd: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func populate(apps: [AppRecord], folders: [String: [AppRecord]], iconCache: NSCache<NSString, NSImage>, onOpen: @escaping (AppRecord, AppItemView) -> Void) {
        for sub in itemViews { sub.removeFromSuperview() }
        itemViews.removeAll()

        for app in apps {
            let key = app.path as NSString
            let icon: NSImage
            if app.path.hasPrefix("chu-folder:") {
                icon = Self.folderIcon(apps: folders[app.name] ?? [], iconCache: iconCache)
            } else if let cached = iconCache.object(forKey: key) {
                icon = cached
            } else {
                icon = Self.applicationIcon
            }
            let itemView = AppItemView()
            itemView.configure(app: app, icon: icon, onOpen: onOpen)
            addSubview(itemView)
            itemViews.append(itemView)
        }
        needsLayout = true
    }

    var transitionLayers: [CALayer] { itemViews.compactMap(\.layer) }
    var items: [AppItemView] { itemViews }

    func findItemView(for app: AppRecord) -> AppItemView? {
        itemViews.first { $0.appRecord == app }
    }

    func resetAllItemAnimations() {
        for itemView in itemViews {
            itemView.resetLaunchAnimation()
        }
    }

    private static func folderIcon(apps: [AppRecord], iconCache: NSCache<NSString, NSImage>) -> NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        let glassRect = NSRect(x: 12, y: 12, width: 104, height: 104)
        let background = NSBezierPath(roundedRect: glassRect, xRadius: 26, yRadius: 26)
        NSColor.black.withAlphaComponent(0.13).setFill()
        background.fill()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.10),
                   ending: NSColor.clear)?.draw(in: background, angle: -90)
        NSColor.black.withAlphaComponent(0.28).setStroke()
        background.lineWidth = 0.8
        background.stroke()
        let rim = NSBezierPath(roundedRect: glassRect.insetBy(dx: 0.8, dy: 0.8),
                               xRadius: 25.2, yRadius: 25.2)
        NSColor.white.withAlphaComponent(0.17).setStroke()
        rim.lineWidth = 0.7
        rim.stroke()
        let size: CGFloat = 25
        let gap: CGFloat = 2
        let inset = (128 - 3 * size - 2 * gap) / 2
        for (index, app) in apps.prefix(9).enumerated() {
            let key = app.path as NSString
            let icon = iconCache.object(forKey: key) ?? applicationIcon
            iconCache.setObject(icon, forKey: key)
            let x = inset + CGFloat(index % 3) * (size + gap)
            let y = 128 - inset - size - CGFloat(index / 3) * (size + gap)
            icon.draw(in: NSRect(x: x, y: y, width: size, height: size))
        }
        image.unlockFocus()
        return image
    }

    override func layout() {
        super.layout()
        guard !itemViews.isEmpty else { return }

        let cols = columns
        let rows = self.rows

        // 计算 7 列 5 行的布局位置
        let cellWidth = min(190, max(1, (bounds.width - 40) / CGFloat(cols)))
        let cellHeight = min(180, max(1, bounds.height / CGFloat(rows)))

        let totalGridWidth = cellWidth * CGFloat(cols)
        let totalGridHeight = cellHeight * CGFloat(rows)

        let startX = floor((bounds.width - totalGridWidth) / 2)
        let startY = floor((bounds.height - totalGridHeight) / 2)

        for (index, itemView) in itemViews.prefix(cols * rows).enumerated() {
            let col = index % cols
            let row = index / cols
            let x = startX + CGFloat(col) * cellWidth
            let y = startY + CGFloat(row) * cellHeight
            itemView.frame = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
        }
    }



}

// MARK: - 多页横向全屏平移容器 (Paged Container View)
@MainActor final class PagedContainerView: NSView {
    var columns = 7
    var rows = 5
    var pageSize: Int { columns * rows }
    private let pagesTrackView = NSView()
    private var pageViews: [PageGridView] = []

    private(set) var currentPage = 0
    private(set) var pageCount = 1

    var onPageChanged: ((Int) -> Void)?
    var onOpenApp: ((AppRecord, AppItemView) -> Void)?
    var onBlankAreaClicked: (() -> Void)?

    // 交互式滑动手势状态
    private var isDragging = false
    private var dragStartOriginX: CGFloat = 0
    private var accumulatedDeltaX: CGFloat = 0
    private var isAnimating = false
    private var animationGeneration = 0
    private var mouseStartX: CGFloat = 0
    private var mouseHasDragged = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = false // 允许内容从屏幕边缘全屏滑入滑出

        pagesTrackView.wantsLayer = true
        addSubview(pagesTrackView)
    }

    func reloadPages(apps: [AppRecord], folders: [String: [AppRecord]], iconCache: NSCache<NSString, NSImage>, targetPage: Int = 0) {
        let pageSize = self.pageSize
        let count = max(1, (apps.count + pageSize - 1) / pageSize)
        self.pageCount = count
        self.currentPage = min(targetPage, count - 1)

        for pageView in pageViews { pageView.removeFromSuperview() }
        pageViews.removeAll()

        let screenWidth = bounds.width
        let containerHeight = bounds.height

        pagesTrackView.frame = NSRect(x: -CGFloat(currentPage) * screenWidth, y: 0, width: CGFloat(count) * screenWidth, height: containerHeight)

        for p in 0..<count {
            let startIndex = p * pageSize
            let endIndex = min(startIndex + pageSize, apps.count)
            let pageApps = startIndex < apps.count ? Array(apps[startIndex..<endIndex]) : []

            let pageView = PageGridView(frame: NSRect(x: CGFloat(p) * screenWidth, y: 0, width: screenWidth, height: containerHeight))
            pageView.columns = columns
            pageView.rows = rows
            pageView.populate(apps: pageApps, folders: folders, iconCache: iconCache) { [weak self] app, itemView in
                self?.onOpenApp?(app, itemView)
            }
            pageView.onBlankDragStart = { [weak self] event in self?.beginMouseDrag(event) }
            pageView.onBlankDragMove = { [weak self] event in self?.moveMouseDrag(event) }
            pageView.onBlankDragEnd = { [weak self] event in self?.endMouseDrag(event) }
            pagesTrackView.addSubview(pageView)
            pageViews.append(pageView)
        }

        onPageChanged?(currentPage)
    }

    var visibleItems: [AppItemView] {
        guard pageViews.indices.contains(currentPage) else { return [] }
        return pageViews[currentPage].items
    }

    var visibleItemLayers: [CALayer] {
        guard pageViews.indices.contains(currentPage) else { return [] }
        return pageViews[currentPage].transitionLayers
    }

    func animatePageVisibility(_ visible: Bool, duration: CFTimeInterval) -> CALayer? {
        guard pageViews.indices.contains(currentPage), let layer = pageViews[currentPage].layer else { return nil }
        let scale: CGFloat = 1.04
        var start = CATransform3DMakeScale(scale, scale, 1)
        start.m41 = (0.5 - layer.anchorPoint.x) * layer.bounds.width * (1 - scale)
        start.m42 = (0.5 - layer.anchorPoint.y) * layer.bounds.height * (1 - scale)
        let zoom = CABasicAnimation(keyPath: "transform")
        let key = "launcher.pageZoom"
        let resting = CATransform3DIdentity
        let from = layer.animation(forKey: key) == nil ? nil : layer.presentation()?.transform
        zoom.fromValue = NSValue(caTransform3D: from ?? (visible ? start : resting))
        zoom.toValue = NSValue(caTransform3D: visible ? resting : start)
        zoom.duration = duration
        zoom.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        zoom.fillMode = .forwards
        zoom.isRemovedOnCompletion = visible
        layer.add(zoom, forKey: key)
        return layer
    }

    func clearPageVisibilityAnimations() {
        for pageView in pageViews {
            pageView.layer?.removeAnimation(forKey: "launcher.pageZoom")
        }
    }

    // MARK: - 页面与应用进入动画 (Page & Apps Entrance Animation)
    func animateEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            pagesTrackView.alphaValue = 1.0
            pagesTrackView.layer?.transform = CATransform3DIdentity
            return
        }

        let visibleCenter = CGPoint(x: CGFloat(currentPage) * bounds.width + bounds.midX, y: bounds.midY)
        let initialTransform = AnimationHelper.makeScaleTransform(scale: 0.93, center: visibleCenter)

        pagesTrackView.layer?.transform = CATransform3DIdentity
        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = initialTransform
        scaleAnim.toValue = CATransform3DIdentity
        scaleAnim.duration = 0.24
        scaleAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 0.0
        fadeAnim.toValue = 1.0
        fadeAnim.duration = 0.20
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        pagesTrackView.layer?.add(scaleAnim, forKey: "entranceScale")
        pagesTrackView.layer?.add(fadeAnim, forKey: "entranceFade")
    }

    func findItemView(for app: AppRecord) -> AppItemView? {
        for pageView in pageViews {
            if let found = pageView.findItemView(for: app) {
                return found
            }
        }
        return nil
    }

    func resetAllItemAnimations() {
        for pageView in pageViews {
            pageView.resetAllItemAnimations()
        }
    }

    override func layout() {
        super.layout()
        guard !pageViews.isEmpty else { return }
        let screenWidth = bounds.width
        let containerHeight = bounds.height

        if !isDragging && !isAnimating {
            pagesTrackView.frame = NSRect(x: -CGFloat(currentPage) * screenWidth, y: 0, width: CGFloat(pageCount) * screenWidth, height: containerHeight)
        }

        for (index, pageView) in pageViews.enumerated() {
            pageView.frame = NSRect(x: CGFloat(index) * screenWidth, y: 0, width: screenWidth, height: containerHeight)
        }
    }

    // MARK: - 翻页与平滑滑动动画
    func scrollToPage(_ index: Int, animated: Bool = true) {
        guard index >= 0, index < pageCount else { return }
        let screenWidth = bounds.width
        let targetX = -CGFloat(index) * screenWidth

        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animationGeneration += 1
            pagesTrackView.layer?.removeAnimation(forKey: "pageScroll")
            isAnimating = false
            pagesTrackView.frame.origin.x = targetX
            currentPage = index
            onPageChanged?(currentPage)
            return
        }

        guard let layer = pagesTrackView.layer else {
            pagesTrackView.frame.origin.x = targetX
            currentPage = index
            onPageChanged?(currentPage)
            return
        }
        let startingPosition = layer.presentation()?.position ?? layer.position
        animationGeneration += 1
        let generation = animationGeneration
        isAnimating = true
        currentPage = index
        onPageChanged?(currentPage)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pagesTrackView.frame.origin.x = targetX
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: startingPosition)
        animation.toValue = NSValue(point: layer.position)
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
        layer.add(animation, forKey: "pageScroll")
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.isAnimating = false
        }
    }

    func nextPage() {
        if currentPage + 1 < pageCount {
            scrollToPage(currentPage + 1, animated: true)
        }
    }

    func previousPage() {
        if currentPage > 0 {
            scrollToPage(currentPage - 1, animated: true)
        }
    }

    func beginMouseDrag(_ event: NSEvent) {
        if let layer = pagesTrackView.layer, let position = layer.presentation()?.position, isAnimating {
            animationGeneration += 1
            layer.removeAnimation(forKey: "pageScroll")
            pagesTrackView.frame.origin.x = position.x - layer.bounds.width * layer.anchorPoint.x
        }
        isAnimating = false
        isDragging = true
        mouseHasDragged = true
        mouseStartX = event.locationInWindow.x
        dragStartOriginX = pagesTrackView.frame.origin.x
    }

    func moveMouseDrag(_ event: NSEvent) {
        guard isDragging else { return }
        let delta = event.locationInWindow.x - mouseStartX
        if abs(delta) > 4 { mouseHasDragged = true }
        guard mouseHasDragged else { return }
        let proposed = dragStartOriginX + delta
        let minimum = -CGFloat(pageCount - 1) * bounds.width
        let position = proposed > 0 ? proposed * 0.28 : (proposed < minimum ? minimum + (proposed - minimum) * 0.28 : proposed)
        pagesTrackView.frame.origin.x = position
    }

    func endMouseDrag(_ event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let delta = event.locationInWindow.x - mouseStartX
        if !mouseHasDragged { onBlankAreaClicked?(); return }
        let target = delta < -55 ? min(currentPage + 1, pageCount - 1) : (delta > 55 ? max(currentPage - 1, 0) : currentPage)
        scrollToPage(target, animated: true)
    }

    // MARK: - 触控板交互式手势处理 (跟手平移与弹性吸附)
    func handleScrollWheel(event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else {
            return false
        }

        // 忽略惯性阶段，避免手势抬起后的惯性事件干扰平滑吸附动画
        if event.momentumPhase != [] {
            return true
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let screenWidth = bounds.width

        switch event.phase {
        case .began:
            // 若垂直分量显著大于水平分量，视为垂直手势，不劫持水平翻页
            if abs(deltaX) < abs(deltaY) && abs(deltaY) > 5 {
                return false
            }
            if let layer = pagesTrackView.layer, let position = layer.presentation()?.position, isAnimating {
                animationGeneration += 1
                layer.removeAnimation(forKey: "pageScroll")
                pagesTrackView.frame.origin.x = position.x - layer.bounds.width * layer.anchorPoint.x
            }
            isDragging = true
            isAnimating = false
            dragStartOriginX = pagesTrackView.frame.origin.x
            accumulatedDeltaX = 0

        case .changed:
            guard isDragging else { return false }
            accumulatedDeltaX += deltaX

            let proposedX = dragStartOriginX + accumulatedDeltaX
            let minX = -CGFloat(pageCount - 1) * screenWidth
            let maxX: CGFloat = 0

            var finalX = proposedX
            // 边缘阻尼弹性 (Rubber-banding)
            if proposedX > maxX {
                let overscroll = proposedX - maxX
                finalX = maxX + overscroll * 0.28
            } else if proposedX < minX {
                let overscroll = minX - proposedX
                finalX = minX - overscroll * 0.28
            }

            pagesTrackView.frame.origin.x = finalX

        case .ended, .cancelled:
            guard isDragging else { return false }
            isDragging = false

            // 根据滑动位移和趋势判断目标页面
            let threshold: CGFloat = 55.0
            var targetPage = currentPage

            if accumulatedDeltaX < -threshold && currentPage + 1 < pageCount {
                targetPage = currentPage + 1
            } else if accumulatedDeltaX > threshold && currentPage > 0 {
                targetPage = currentPage - 1
            }

            scrollToPage(targetPage, animated: true)

        default:
            break
        }

        return true
    }
}

// MARK: - 原生分页圆点指示器 (Page Dots Indicator)
@MainActor final class PageIndicator: NSView {
    var current = 0 {
        didSet { if oldValue != current { needsDisplay = true } }
    }
    var count = 1 {
        didSet {
            isHidden = (count <= 1)
            needsDisplay = true
        }
    }
    var onSelect: ((Int) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard count > 1 else { return }

        let dotDiameter: CGFloat = 7
        let spacing: CGFloat = 16
        let totalWidth = CGFloat(count - 1) * spacing + dotDiameter
        let startX = floor(bounds.midX - totalWidth / 2)
        let centerY = floor(bounds.midY)

        for index in 0..<count {
            let x = startX + CGFloat(index) * spacing
            let rect = NSRect(x: x, y: centerY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
            let path = NSBezierPath(ovalIn: rect)

            if index == current {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.38).setFill()
            }
            path.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let spacing: CGFloat = 16
        let dotDiameter: CGFloat = 7
        let totalWidth = CGFloat(count - 1) * spacing + dotDiameter
        let startX = bounds.midX - totalWidth / 2

        let relativeX = x - startX
        let index = Int((relativeX / spacing).rounded())
        if index >= 0 && index < count {
            onSelect?(index)
        }
    }
}

struct FolderAppearance: Codable, Sendable {
    var cornerRadius: Double = 18
    var backgroundOpacity: Double = 0.38
    var backgroundTint: String = "20201e"
    var backdropBlurRadius: Double = 20
    var backdropDimOpacity: Double = 0.16
    var openDuration: Double = 0.26
    var closeDuration: Double = 0.24

    static func load() -> FolderAppearance {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad/folder.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              (0...80).contains(value.cornerRadius), (0...1).contains(value.backgroundOpacity),
              (0...80).contains(value.backdropBlurRadius), (0...1).contains(value.backdropDimOpacity),
              (0.05...2).contains(value.openDuration), (0.05...2).contains(value.closeDuration) else { return Self() }
        return value
    }
    var tint: NSColor {
        let hex = backgroundTint.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return NSColor(white: 0.22, alpha: 1) }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

@MainActor final class FolderBackdropView: NSView {
    var onDismiss: ((NSPoint) -> Void)?
    var panel: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        if let panel, panel.frame.contains(point), let target = panel.hitTest(point) { return target }
        return self
    }
    override func mouseUp(with event: NSEvent) { onDismiss?(convert(event.locationInWindow, from: nil)) }
}

@MainActor final class FolderOverlayController {
    enum State { case closed, opening, opened, closing }
    let appearance = FolderAppearance.load()
    let root = FolderBackdropView()
    let panel = NSView()
    let title = NSTextField(labelWithString: "")
    let pages = PagedContainerView()
    let indicator = PageIndicator()
    var underlyingControls: [NSView] = []
    private(set) var state: State = .closed
    private var generation = 0
    var onClosed: (() -> Void)?

    init() {
        root.wantsLayer = true
        root.isHidden = true
        root.autoresizingMask = [.width, .height]
        panel.wantsLayer = true
        panel.layer?.cornerRadius = appearance.cornerRadius
        panel.layer?.masksToBounds = true
        panel.layer?.backgroundColor = appearance.tint.withAlphaComponent(appearance.backgroundOpacity).cgColor
        root.addSubview(panel)
        root.panel = panel
        title.alignment = .center
        title.font = .systemFont(ofSize: 24, weight: .medium)
        title.textColor = .white
        title.wantsLayer = true
        indicator.wantsLayer = true
        pages.columns = 6
        pages.rows = 3
        pages.layer?.masksToBounds = true
        panel.addSubview(title)
        panel.addSubview(pages)
        panel.addSubview(indicator)
    }

    private var thumbnailFrame = CGRect.zero

    func present(from frame: CGRect) {
        thumbnailFrame = frame
        state = .opening
        // The launcher hide animation may leave this layer transparent even after
        // NSView is unhidden. Reset the model layer before accepting clicks.
        root.layer?.removeAnimation(forKey: "launcher.opacity")
        root.alphaValue = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.layer?.opacity = 1
        CATransaction.commit()
        root.isHidden = false
        animate(opening: true, initial: true)
    }

    func animate(opening: Bool, initial: Bool = false) {
        guard state != .closed else { return }
        generation += 1
        let current = generation
        state = opening ? .opening : .closing
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.12 : (opening ? appearance.openDuration : appearance.closeDuration)
        let curve = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
        let opacity: Float = opening ? 1 : 0
        // Fade the grid as one layer while the panel is still close to full size.
        let contentDuration = reduced || opening ? duration : duration * 0.38
        for layer in [pages.layer, title.layer, indicator.layer].compactMap({ $0 }) {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity,
                                   duration: initial ? 0 : contentDuration, curve: curve)
        }
        for control in underlyingControls {
            if let layer = control.layer {
                let scale: CGFloat = opening && !reduced ? 0.94 : 1
                let anchor = layer.anchorPoint
                var depth = CATransform3DMakeScale(scale, scale, 1)
                depth.m41 = (0.5 - anchor.x) * layer.bounds.width * (1 - scale)
                depth.m42 = (0.5 - anchor.y) * layer.bounds.height * (1 - scale)
                if opening && !reduced { depth.m42 += control.isFlipped ? 10 : -10 }
                LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: depth), duration: duration, curve: curve)
                LauncherTransition.set(layer, keyPath: "opacity", value: Float(opening ? 0 : 1), duration: duration, curve: curve)
            }
        }
        if let layer = panel.layer {
            // Resolve the thumbnail relative to the panel's actual layer pivot.
            let frame = panel.frame
            let anchor = layer.anchorPoint
            var collapsed = CATransform3DMakeScale(thumbnailFrame.width / max(1, frame.width),
                                                   thumbnailFrame.height / max(1, frame.height), 1)
            collapsed.m41 = thumbnailFrame.minX - frame.minX + anchor.x * (thumbnailFrame.width - frame.width)
            collapsed.m42 = thumbnailFrame.minY - frame.minY + anchor.y * (thumbnailFrame.height - frame.height)
            let target = opening || reduced ? CATransform3DIdentity : collapsed
            let motion = CABasicAnimation(keyPath: "transform")
            motion.fromValue = NSValue(caTransform3D: initial && !reduced ? collapsed : (layer.presentation()?.transform ?? CATransform3DIdentity))
            motion.toValue = NSValue(caTransform3D: target)
            motion.duration = duration
            motion.timingFunction = curve
            motion.fillMode = .forwards
            motion.isRemovedOnCompletion = opening
            layer.add(motion, forKey: "folder.zoom")
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
            if initial {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = duration
                fade.timingFunction = curve
                layer.add(fade, forKey: "launcher.opacity")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, current == self.generation else { return }
            if opening { self.state = .opened }
            else { self.reset(); self.onClosed?() }
        }
    }

    func reset() {
        generation += 1
        state = .closed
        root.isHidden = true
        root.alphaValue = 1
        root.layer?.removeAnimation(forKey: "launcher.opacity")
        root.layer?.opacity = 1
        panel.layer?.removeAnimation(forKey: "folder.zoom")
        for control in underlyingControls {
            control.layer?.removeAnimation(forKey: "launcher.transform")
            control.layer?.transform = CATransform3DIdentity
            control.layer?.removeAnimation(forKey: "launcher.opacity")
            control.layer?.opacity = 1
        }
    }
}

// MARK: - 主应用程序代理 (AppDelegate)
private enum AppSortOrder: Int {
    case dateDescending = 0
    case dateAscending = 1
    case name = 2

    static let defaultsKey = "ChuLaunchpad.sortOrderCode"

    static var current: AppSortOrder {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) else { return .dateDescending }
        guard let number = stored as? NSNumber, let order = AppSortOrder(rawValue: number.intValue) else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return .dateDescending
        }
        return order
    }

    var menuIdentifier: String {
        switch self {
        case .dateDescending: "sort-date-descending"
        case .dateAscending: "sort-date-ascending"
        case .name: "sort-name"
        }
    }
}

@MainActor final class MenuBarEventCaptureView: NSView {
    var onBlankClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBlankClick?() }
    override func rightMouseDown(with event: NSEvent) { onBlankClick?() }
    override func otherMouseDown(with event: NSEvent) { onBlankClick?() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: LauncherWindow!
    private let backgroundView = LauncherBackgroundView(frame: .zero)
    private var menuCover: NSWindow?
    private var menuCoverImage: NSImageView?
    private var menuCoverTint: NSView?
    private var menuSettingsShade: NSView?
    private let runningVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var observedReplacement: String?

    private func checkInstalledVersion() {
        let agent = Bundle.main.bundleURL
        guard ["Chu Launchpad.app", "ChuLaunchAgent.app"].contains(agent.lastPathComponent), agent.deletingLastPathComponent().lastPathComponent == "Helpers" else { return }
        let outer = agent.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func installedVersion(_ bundle: URL, identifier: String) -> String? {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["CFBundleIdentifier"] as? String == identifier,
                  let executable = plist["CFBundleExecutable"] as? String,
                  FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/" + executable).path)
            else { return nil }
            return plist["CFBundleShortVersionString"] as? String
        }
        guard let version = installedVersion(outer, identifier: "com.withqq.chu-launchpad"),
              version != runningVersion,
              installedVersion(agent, identifier: "com.withqq.chu-launchpad.agent") == version
        else { observedReplacement = nil; return }
        // Allow Finder to finish copying the bundle before reopening it.
        if observedReplacement == version {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", agent.path] + (launcherTargetVisible ? [] : ["--args", "--background"])
            do { try task.run(); NSApp.terminate(nil) } catch { observedReplacement = nil }
        } else { observedReplacement = version }
    }

    private var wallpaperTimer: Timer?
    private var updateCheckTimer: Timer?
    #if DEBUG
    private var backgroundDebugPanel: BackgroundDebugPanel?
    private var debugRefreshTask: Task<Void, Never>?
    #endif
    private let searchCapsule = SearchCapsuleView(frame: .zero)
    private let moreMenu = NSMenu()
    private var settingsPanel: SettingsPanelView?
    private var dockStatusTimer: Timer?
    private var dockStatusBusy = false
    private let hotKeyManager = GlobalHotKeyManager()
    private let updateManager = AppUpdateManager()
    private let moreButton = NSButton()
    private let updateNoticeButton = NSButton()
    private let pagedContainer = PagedContainerView(frame: .zero)
    private let pageIndicator = PageIndicator()
    private let iconCache = NSCache<NSString, NSImage>()

    private var apps: [AppRecord] = []
    private var filtered: [AppRecord] = []
    private var displayed: [AppRecord] = []
    private var folderContents: [String: [AppRecord]] = [:]
    private var openFolder: String?
    private let folderOverlay = FolderOverlayController()
    private var folderSourceRect = NSRect.zero
    private var folderMainItems: [AppRecord] = []
    private var loadedFolderItems: [AppRecord]?
    private var folderClosing: Bool { folderOverlay.state == .closing }
    private var folderBackdrop: FolderBackdropView { folderOverlay.root }
    private var folderPanel: NSView { folderOverlay.panel }
    private var folderTitle: NSTextField { folderOverlay.title }
    private var folderPages: PagedContainerView { folderOverlay.pages }
    private var folderIndicator: PageIndicator { folderOverlay.indicator }
    private var activePages: PagedContainerView { openFolder == nil ? pagedContainer : folderPages }
    private var layout = Layout()
    private var watcher: AppWatcher?
    private var refreshTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var lastWheelTurn = Date.distantPast
    private var externalClickMonitor: Any?
    private var externalClickGeneration = 0
    private var pointerDown: NSEvent?
    private var pointerDragging = false
    private var pointerIsBlank = false
    private weak var pointerItem: AppItemView?
    private var isLaunching = false
    private var launcherTargetVisible = false
    private var showRequestGeneration = 0
    private var transitionGeneration = 0
    private var transitionInProgress = false
    private var pendingRefresh = false
    private var pendingQuery: String?
    private var backdropWarmup: Task<Void, Never>?
    private let storageQueue = DispatchQueue(label: "com.withqq.chu-launchpad.storage", qos: .utility)
    private let logger = Logger(subsystem: "com.withqq.chu-launchpad.app", category: "launcher")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleFromDock(_:)),
            name: Notification.Name("com.withqq.chu-launchpad.toggle"), object: nil, suspensionBehavior: .deliverImmediately)
        NSApp.applicationIconImage = ChuAppIcon.image()
        setupMenu()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = LauncherWindow(contentRect: mainWindowFrame(on: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        prepareMenuCover(on: screen)

        // 原生桌面壁纸毛玻璃与磨砂背景（按完整屏幕高度对齐绘制，与顶部 menuCover 无缝衔接）
        backgroundView.frame = window.contentView!.bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.setWallpaperCanvasSize(screen.frame.size)
        window.contentView = backgroundView

        // 顶部居中胶囊搜索栏
        searchCapsule.onQueryChanged = { [weak self] query in
            self?.filter(query: query)
            self?.updateMoreButton()
        }
        configureMoreMenu()
        searchCapsule.onEscapePressed = { [weak self] in
            guard let self else { return }
            if !self.searchCapsule.stringValue.isEmpty {
                self.searchCapsule.stringValue = ""
            } else {
                self.hide()
            }
        }
        backgroundView.addSubview(searchCapsule)
        moreButton.title = ""
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多选项")
        moreButton.contentTintColor = .white
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.wantsLayer = true
        moreButton.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.45).cgColor
        moreButton.layer?.cornerRadius = 16
        backgroundView.addSubview(moreButton)
        updateNoticeButton.title = "发现新版本"
        updateNoticeButton.font = .systemFont(ofSize: 12, weight: .semibold)
        updateNoticeButton.contentTintColor = .white
        updateNoticeButton.isBordered = false
        updateNoticeButton.wantsLayer = true
        updateNoticeButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.94).cgColor
        updateNoticeButton.layer?.cornerRadius = 14
        updateNoticeButton.target = self
        updateNoticeButton.action = #selector(openUpdateNotice)
        updateNoticeButton.toolTip = "发现新版本，点击查看并更新"
        updateNoticeButton.setAccessibilityLabel("发现新版本，打开关于与更新")
        updateNoticeButton.isHidden = true
        backgroundView.addSubview(updateNoticeButton)

        // 多页全屏平移容器
        pagedContainer.onPageChanged = { [weak self] page in
            self?.pageIndicator.current = page
            self?.scheduleBackdropWarmup()
        }
        pagedContainer.onOpenApp = { [weak self] app, itemView in
            self?.activate(app, from: itemView)
        }
        pagedContainer.onBlankAreaClicked = { [weak self] in
            if self?.openFolder != nil { self?.closeFolder() } else { self?.hide() }
        }
        backgroundView.addSubview(pagedContainer)
        folderBackdrop.frame = backgroundView.bounds
        folderBackdrop.onDismiss = { [weak self] point in
            guard let self else { return }
            if self.folderClosing && self.folderSourceRect.contains(point) { self.animateFolder(opening: true) }
            else { self.closeFolder() }
        }
        folderOverlay.onClosed = { [weak self] in
            guard let self else { return }
            self.openFolder = nil
            self.updateMoreButton()
            self.displayed = self.folderMainItems
            if let query = self.pendingQuery { self.pendingQuery = nil; self.filter(query: query) }
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
        }
        folderPages.onOpenApp = { [weak self] app, itemView in self?.open(app, from: itemView) }
        folderPages.onBlankAreaClicked = { [weak self] in self?.closeFolder() }
        folderPages.onPageChanged = { [weak self] page in self?.folderIndicator.current = page }
        folderIndicator.onSelect = { [weak self] page in self?.folderPages.scrollToPage(page) }

        // 底部分页圆点指示器（原生仅圆点，无箭头）
        pageIndicator.onSelect = { [weak self] index in
            self?.pagedContainer.scrollToPage(index, animated: true)
        }
        backgroundView.addSubview(pageIndicator)
        backgroundView.addSubview(folderBackdrop, positioned: .above, relativeTo: pageIndicator)

        // 全局键盘与手势监控
        setupEventMonitors()

        // 文件变更监听
        watcher = AppWatcher(roots: AppScanner.defaultRoots) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostAppChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInstalledVersion(); self?.refreshVisibleWallpaper() }
        }

        // 注册全局呼出快捷键（默认 Command + F3）与开机自启路径同步
        hotKeyManager.onTrigger = { [weak self] in
            self?.toggleLauncher()
        }
        updateManager.onStateChanged = { [weak self] state in
            self?.settingsPanel?.applyUpdateState(state)
            self?.updateMoreButton()
        }
        updateManager.checkForUpdatesIfNeeded()
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateManager.checkForUpdatesIfNeeded() }
        }
        let savedHotKey = HotKeyStore.load()
        let hotKeyStatus = hotKeyManager.register(savedHotKey)
        if case .conflict(let key, let code) = hotKeyStatus {
            logger.warning("Failed to register hotkey \(key.displayString, privacy: .public), status=\(code)")
        }
        LaunchAtLoginManager.migrateLegacyLoginItem()

        layout = LayoutStore.load()
        do {
            if let cachedApps = try AppIndexStore.load() {
                apps = layout.reconcile(cachedApps)
                applyCurrentSort()
                filter(query: searchCapsule.stringValue)
                logger.debug("Loaded \(cachedApps.count) cached applications")
            }
        } catch {
            logger.warning("Could not load cached applications: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        if !CommandLine.arguments.contains(LaunchAtLoginManager.backgroundArgument) {
            show()
        }
    }

    private func configureMoreMenu() {
        let settings = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        moreMenu.addItem(settings)
        MenuSymbols.apply("gearshape", to: settings)
        let refreshApps = NSMenuItem(title: "刷新应用", action: #selector(manualRefresh), keyEquivalent: "")
        refreshApps.target = self
        moreMenu.addItem(refreshApps)
        MenuSymbols.apply("arrow.clockwise", to: refreshApps)
        let sort = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, order, symbol) in [
            ("添加日期降序", AppSortOrder.dateDescending, "calendar.badge.clock"),
            ("添加日期升序", .dateAscending, "calendar"),
            ("名称", .name, "textformat.abc")
        ] {
            let item = NSMenuItem(title: title, action: #selector(changeSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            submenu.addItem(item)
            MenuSymbols.apply(symbol, to: item)
        }
        sort.submenu = submenu
        moreMenu.addItem(sort)
        MenuSymbols.apply("arrow.up.arrow.down", to: sort)
        moreMenu.addItem(.separator())
        let update = NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        moreMenu.addItem(update)
        MenuSymbols.apply("arrow.down.circle", to: update)
        let restart = NSMenuItem(title: "重启应用", action: #selector(restartApp), keyEquivalent: "")
        restart.target = self
        moreMenu.addItem(restart)
        MenuSymbols.apply("arrow.clockwise.circle", to: restart)
        let quit = NSMenuItem(title: "退出应用", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        moreMenu.addItem(quit)
        MenuSymbols.apply("power", to: quit)
    }

    @objc private func showMoreMenu() {
        guard searchCapsule.stringValue.isEmpty else { return }
        updateSortMenu()
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }

    private func updateMoreButton() {
        let controlsHidden = openFolder != nil || !searchCapsule.stringValue.isEmpty
        moreButton.isHidden = controlsHidden
        let hasAvailableUpdate: Bool
        if case .available = updateManager.state {
            hasAvailableUpdate = true
        } else {
            hasAvailableUpdate = false
        }
        updateNoticeButton.isHidden = controlsHidden || !hasAvailableUpdate
    }

    private func updateSortMenu() {
        let current = AppSortOrder.current.rawValue
        moreMenu.items.first(where: { $0.title == "排序方式" })?.submenu?.items.forEach { item in
            item.state = (item.representedObject as? Int) == current ? .on : .off
        }
    }

    private func applyCurrentSort() {
        switch AppSortOrder.current {
        case .name:
            apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateAscending:
            apps.sort {
                let left = $0.installedAt ?? .distantPast
                let right = $1.installedAt ?? .distantPast
                return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
            }
        case .dateDescending:
            apps.sort {
                let left = $0.installedAt ?? .distantPast
                let right = $1.installedAt ?? .distantPast
                return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
            }
        }
    }

    @objc private func toggleFromDock(_ notification: Notification) {
        // A Dock click on our own launcher arrives as an external mouse event
        // first; cancel its pending dismissal before toggling the window.
        externalClickGeneration += 1
        toggleLauncher()
    }

    private var outerAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func refreshDockStatus() {
        guard settingsPanel != nil, !dockStatusBusy else { return }
        dockStatusBusy = true
        let app = outerAppURL
        Task {
            let status = await Task.detached(priority: .utility) { try? DockPin.isPinned(app: app) }.value
            dockStatusBusy = false
            settingsPanel?.setDockPin(enabled: status)
        }
    }

    private func changeDockPin(_ enabled: Bool) {
        guard !dockStatusBusy else { return }
        dockStatusBusy = true
        let app = outerAppURL
        Task {
            let result = await Task.detached(priority: .utility) { () -> (Bool?, String?) in
                do { try DockPin.setPinned(enabled, app: app); return (try DockPin.isPinned(app: app), nil) }
                catch { return (try? DockPin.isPinned(app: app), error.localizedDescription) }
            }.value
            dockStatusBusy = false
            settingsPanel?.setDockPin(enabled: result.0, error: result.1)
        }
    }

    private func toggleLauncher() {
        if launcherTargetVisible {
            hide()
        } else {
            show()
        }
    }

    @objc private func openSettings() {
        if case .available = updateManager.state {
            openSettingsPanel(initialTab: .about)
        } else {
            openSettingsPanel(initialTab: .general)
        }
    }

    @objc private func openUpdateNotice() {
        openSettingsPanel(initialTab: .about)
    }

    private func openSettingsPanel(initialTab: SettingsTab) {
        if let existing = settingsPanel {
            existing.selectTab(initialTab)
            existing.setLaunchAtLogin(enabled: LaunchAtLoginManager.isEnabled())
            refreshDockStatus()
            window.makeFirstResponder(nil)
            return
        }

        let bounds = backgroundView.bounds
        let panelHeight: CGFloat = 470
        let panel = SettingsPanelView(frame: NSRect(x: floor(bounds.midX - 340), y: floor(bounds.midY - panelHeight / 2), width: 680, height: panelHeight))
        panel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        panel.onAboutSelected = { [weak self] in self?.updateManager.checkForUpdatesIfNeeded() }
        panel.selectTab(initialTab)
        panel.setHotKeyStatus(hotKeyManager.lastStatus)
        panel.setLaunchAtLogin(enabled: LaunchAtLoginManager.isEnabled())
        panel.applyUpdateState(updateManager.state)

        panel.onCheckUpdates = { [weak self] in self?.updateManager.checkForUpdates() }
        panel.onStartDownload = { [weak self] in self?.updateManager.startDownload() }
        panel.onCancelDownload = { [weak self] in self?.updateManager.cancelDownload() }
        panel.onInstallAndRestart = { [weak self] in self?.updateManager.installAndRestart() }
        panel.onRecordingStateChanged = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.hotKeyManager.suspend()
            } else {
                let status = self.hotKeyManager.resume()
                self.settingsPanel?.setHotKeyStatus(status)
            }
        }
        panel.onHotKeyChanged = { [weak self] newHotKey in
            guard let self else { return }
            HotKeyStore.save(newHotKey)
            let status = self.hotKeyManager.register(newHotKey)
            self.settingsPanel?.setHotKeyStatus(status)
        }
        panel.onDockPinChanged = { [weak self] enabled in self?.changeDockPin(enabled) }
        panel.onLaunchAtLoginChanged = { [weak self] enabled in
            do {
                try LaunchAtLoginManager.setEnabled(enabled)
                self?.settingsPanel?.setLaunchAtLogin(enabled: LaunchAtLoginManager.isEnabled())
            } catch {
                self?.settingsPanel?.setLaunchAtLogin(enabled: LaunchAtLoginManager.isEnabled(), errorMessage: error.localizedDescription)
            }
        }

        let backdrop = SettingsBackdropView(frame: bounds)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = SettingsBackdropView.shade.cgColor
        backdrop.autoresizingMask = [.width, .height]

        var closing = false
        panel.onClose = { [weak self, weak backdrop, weak panel] in
            guard !closing else { return }
            closing = true
            panel?.cancelHotKeyRecording()
            _ = self?.hotKeyManager.resume()
            self?.settingsPanel = nil
            self?.dockStatusTimer?.invalidate()
            self?.dockStatusTimer = nil
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                backdrop?.removeFromSuperview()
                self?.menuSettingsShade?.isHidden = true
                self?.menuSettingsShade?.alphaValue = 1
                return
            }
            if let panel, let layer = panel.layer {
                let center = CGPoint(x: panel.bounds.midX, y: panel.bounds.midY)
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = CATransform3DIdentity
                shrink.toValue = AnimationHelper.makeScaleTransform(scale: 0.96, center: center)
                shrink.duration = 0.14
                shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrink.fillMode = .forwards
                shrink.isRemovedOnCompletion = false
                layer.add(shrink, forKey: "settingsDismissScale")
            }
            let shadeView = self?.menuSettingsShade
            let backdropRef = backdrop
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                backdropRef?.animator().alphaValue = 0
                shadeView?.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak backdropRef] in
                Task { @MainActor in
                    backdropRef?.removeFromSuperview()
                    if self?.settingsPanel == nil {
                        self?.menuSettingsShade?.isHidden = true
                        self?.menuSettingsShade?.alphaValue = 1
                    }
                }
            })
        }

        settingsPanel = panel
        refreshDockStatus()
        dockStatusTimer?.invalidate()
        dockStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDockStatus() }
        }
        backdrop.addSubview(panel)
        backgroundView.addSubview(backdrop, positioned: .above, relativeTo: nil)
        pointerDown = nil

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            backdrop.alphaValue = 0
            menuSettingsShade?.alphaValue = 0
            menuSettingsShade?.isHidden = false
            if let layer = panel.layer {
                let center = CGPoint(x: panel.bounds.midX, y: panel.bounds.midY)
                let pop = CABasicAnimation(keyPath: "transform")
                pop.fromValue = AnimationHelper.makeScaleTransform(scale: 0.94, center: center)
                pop.toValue = CATransform3DIdentity
                pop.duration = 0.22
                pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                layer.add(pop, forKey: "settingsPresentScale")
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                backdrop.animator().alphaValue = 1
                menuSettingsShade?.animator().alphaValue = 1
            }
        } else {
            menuSettingsShade?.alphaValue = 1
            menuSettingsShade?.isHidden = false
        }
        window.makeFirstResponder(nil)
    }

    @objc private func changeSort(_ sender: NSMenuItem) {
        let order: AppSortOrder
        guard let rawValue = sender.representedObject as? Int,
              let selected = AppSortOrder(rawValue: rawValue) else { return }
        order = selected
        UserDefaults.standard.set(order.rawValue, forKey: AppSortOrder.defaultsKey)
        updateSortMenu()
        if !apps.isEmpty {
            applyCurrentSort()
            filter(query: searchCapsule.stringValue)
        }
    }

    @objc private func checkForUpdates() {
        openSettingsPanel(initialTab: .about)
        updateManager.checkForUpdates()
    }

    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        MenuSymbols.apply("gearshape", to: settings)
        let refreshApps = appMenu.addItem(withTitle: "重新扫描应用", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshApps.target = self
        MenuSymbols.apply("arrow.clockwise", to: refreshApps)
        #if DEBUG
        let debug = appMenu.addItem(withTitle: "背景调试…", action: #selector(showBackgroundDebug), keyEquivalent: "d")
        debug.target = self
        MenuSymbols.apply("slider.horizontal.3", to: debug)
        #endif
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "退出 Chu Launchpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        MenuSymbols.apply("power", to: quit)
        NSApp.mainMenu = menu
    }

    private func setupEventMonitors() {
        // A nonactivating panel can remain key when the already-frontmost app
        // is clicked in the Dock, so an activation notification alone is not enough.
        externalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.launcherTargetVisible, self.window.isVisible, !self.isLaunching else { return }
                self.externalClickGeneration += 1
                let generation = self.externalClickGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.externalClickGeneration == generation, self.launcherTargetVisible else { return }
                    self.hide()
                }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, self.window.isVisible, self.settingsPanel == nil, !self.isLaunching else { return event }
            switch event.type {
            case .leftMouseDown:
                self.pointerDown = event
                self.pointerDragging = false
                self.pointerItem = nil
                let point = self.backgroundView.convert(event.locationInWindow, from: nil)
                var target = self.backgroundView.hitTest(point)
                var isControl = false
                while let view = target {
                    if let item = view as? AppItemView { self.pointerItem = item; isControl = true; break }
                    if view is SearchCapsuleView || view is PageIndicator || view === self.moreButton || view === self.updateNoticeButton { isControl = true; break }
                    target = view.superview
                }
                self.pointerIsBlank = !isControl
                return event
            case .leftMouseDragged:
                guard let down = self.pointerDown else { return event }
                let dx = event.locationInWindow.x - down.locationInWindow.x
                let dy = event.locationInWindow.y - down.locationInWindow.y
                if !self.pointerDragging && hypot(dx, dy) >= 6 {
                    self.pointerDragging = true
                    self.pointerItem?.cancelPress()
                    self.activePages.beginMouseDrag(down)
                }
                if self.pointerDragging { self.activePages.moveMouseDrag(event); return nil }
                return event
            case .leftMouseUp:
                guard self.pointerDown != nil else { return event }
                self.pointerDown = nil
                if self.pointerDragging {
                    self.pointerDragging = false
                    self.activePages.endMouseDrag(event)
                    return nil
                }
                if self.pointerIsBlank {
                    if self.openFolder != nil { self.closeFolder() } else { self.hide() }
                    return nil
                }
                return event
            default: return event
            }
        }
        // 键盘监控
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isVisible, self.window.attachedSheet == nil, event.window === self.window, !self.isLaunching else { return event }

            if let panel = self.settingsPanel {
                if panel.isRecordingHotKey {
                    _ = panel.handleRecordingKeyDown(event)
                    return nil
                }
                if event.keyCode == 53 { panel.onClose?(); return nil }
                return event
            }
            // Esc 键
            if event.keyCode == 53 {
                if !self.searchCapsule.stringValue.isEmpty {
                    self.searchCapsule.stringValue = ""
                } else if self.openFolder != nil {
                    self.closeFolder()
                } else {
                    self.hide()
                }
                return nil
            }
            // 回车键
            if event.keyCode == 36 && (self.openFolder != nil || !self.searchCapsule.isEditing) {
                let page = self.activePages.currentPage
                let index = page * self.activePages.pageSize
                if index < self.displayed.count {
                    self.activate(self.displayed[index])
                    return nil
                }
            }
            // 左右方向键翻页（搜索框为空时）
            if event.keyCode == 123 && self.searchCapsule.stringValue.isEmpty {
                self.activePages.previousPage()
                return nil
            }
            if event.keyCode == 124 && self.searchCapsule.stringValue.isEmpty {
                self.activePages.nextPage()
                return nil
            }
            return event
        }

        // 轻扫手势
        NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self, self.window.isVisible, self.settingsPanel == nil else { return event }
            if event.deltaX > 0 {
                self.activePages.previousPage()
            } else if event.deltaX < 0 {
                self.activePages.nextPage()
            }
            return nil
        }

        // 触控板平滑滑动与滚轮
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window.isVisible, self.settingsPanel == nil, event.window === self.window else { return event }

            if event.hasPreciseScrollingDeltas {
                // 触控板手势实时跟手
                if self.activePages.handleScrollWheel(event: event) {
                    return nil
                }
            } else {
                // 普通外接滚轮（带防抖）
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                guard abs(delta) > 1 else { return nil }
                if Date().timeIntervalSince(self.lastWheelTurn) > 0.3 {
                    if delta < 0 {
                        self.activePages.nextPage()
                    } else {
                        self.activePages.previousPage()
                    }
                    self.lastWheelTurn = Date()
                }
                return nil
            }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if launcherTargetVisible { hide() } else { show() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsPanel?.setLaunchAtLogin(enabled: LaunchAtLoginManager.isEnabled())
    }

    func applicationDidResignActive(_ notification: Notification) {
        settingsPanel?.cancelHotKeyRecording()
        hide()
    }

    private func transition(visible: Bool, completion: (@MainActor () -> Void)? = nil) {
        transitionGeneration += 1
        let generation = transitionGeneration
        launcherTargetVisible = visible
        transitionInProgress = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: CFTimeInterval = reduced ? 0.12 : backgroundView.style.animationDuration
        let zoomLayer = reduced ? nil : activePages.animatePageVisibility(visible, duration: duration)
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.transitionInProgress = false
            if !visible {
                self.window.orderOut(nil)
                zoomLayer?.removeAnimation(forKey: "launcher.pageZoom")
                self.menuCover?.orderOut(nil)
                self.isLaunching = false
            }
            completion?()
            if let query = self.pendingQuery { self.pendingQuery = nil; self.filter(query: query) }
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            if visible { self.scheduleBackdropWarmup() }
        }
        if visible { menuCover?.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = visible ? 1 : 0
            menuCover?.animator().alphaValue = visible ? 1 : 0
        } completionHandler: {
            Task { @MainActor in finish() }
        }
    }

    private func hide(completion: (@MainActor () -> Void)? = nil) {
        if !window.isVisible {
            showRequestGeneration += 1
            launcherTargetVisible = false
            completion?()
            return
        }
        guard launcherTargetVisible else { return }
        transition(visible: false, completion: completion)
    }

    private func show() {
        if window.isVisible {
            if !launcherTargetVisible { updateManager.checkForUpdatesIfNeeded() }
            transition(visible: true)
            return
        }
        updateManager.checkForUpdatesIfNeeded()
        showRequestGeneration += 1
        let request = showRequestGeneration
        launcherTargetVisible = true
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        backgroundView.updateWallpaper(for: screen) { [weak self] in
            guard let self, self.showRequestGeneration == request, self.launcherTargetVisible else { return }
            self.menuCoverImage?.image = self.backgroundView.preparedWallpaper
        }
        showPrepared(on: screen)
    }

    private func menuBarHeight(on screen: NSScreen) -> CGFloat {
        min(screen.frame.height, max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    private func mainWindowFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let height = menuBarHeight(on: screen)
        // 主窗口上缘停在系统顶部菜单栏正下方，彻底避免触发 macOS 传统无边框全屏自动隐藏菜单栏规则；
        // 顶部菜单栏区域由 menuCover 在同一坐标系下像素级无缝衔接。
        return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(100, frame.height - height))
    }

    private func showPrepared(on currentScreen: NSScreen) {
        window.setFrame(mainWindowFrame(on: currentScreen), display: true)
        backgroundView.setWallpaperCanvasSize(currentScreen.frame.size)
        prepareMenuCover(on: currentScreen)

        let screenWidth = currentScreen.frame.width
        let screenHeight = currentScreen.frame.height

        // 1. 顶部搜索框：居中药丸，宽 260，高 32，距离屏幕顶部 68pt
        let searchWidth: CGFloat = 260
        let searchHeight: CGFloat = 32
        let searchX = floor((screenWidth - searchWidth) / 2)
        let searchY = screenHeight - 68 - searchHeight
        searchCapsule.frame = NSRect(x: searchX, y: searchY, width: searchWidth, height: searchHeight)
        moreButton.frame = NSRect(x: searchX + searchWidth + 10, y: searchY, width: 32, height: 32)
        updateNoticeButton.frame = NSRect(x: moreButton.frame.maxX + 8, y: searchY + 2, width: 96, height: 28)
        updateMoreButton()

        // 2. 底部分页指示器：居中，高度 20，位于 Dock 上方约 125pt
        let indicatorHeight: CGFloat = 20
        let indicatorY: CGFloat = 125
        let indicatorWidth: CGFloat = 200
        let indicatorX = floor((screenWidth - indicatorWidth) / 2)
        pageIndicator.frame = NSRect(x: indicatorX, y: indicatorY, width: indicatorWidth, height: indicatorHeight)

        // 3. 多页全屏平移网格区：覆盖屏幕全宽，位于指示器上方与搜索栏下方之间
        let gridBottomY = indicatorY + indicatorHeight + 12
        let gridTopY = searchY - 24
        let gridHeight = max(100, gridTopY - gridBottomY)
        pagedContainer.frame = NSRect(x: 0, y: gridBottomY, width: screenWidth, height: gridHeight)

        layoutFolderPanel()
        pagedContainer.layoutSubtreeIfNeeded()
        pagedContainer.resetAllItemAnimations()
        isLaunching = false

        searchCapsule.wantsLayer = true
        pageIndicator.wantsLayer = true
        let wasVisible = window.isVisible
        if !wasVisible {
            window.alphaValue = 0
            menuCover?.alphaValue = 0
            menuCover?.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            if openFolder == nil && settingsPanel == nil { searchCapsule.makeFirstResponder() }
        }
        transition(visible: true)
    }

    // Cover only the menu bar, leaving the main window below the Dock's level.
    private func prepareMenuCover(on screen: NSScreen) {
        let frame = screen.frame
        let height = menuBarHeight(on: screen)
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if menuCover == nil {
            let cover = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.animationBehavior = .none
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            cover.ignoresMouseEvents = false
            cover.isOpaque = false
            cover.backgroundColor = .clear
            cover.hasShadow = false
            cover.hidesOnDeactivate = false
            let clip = MenuBarEventCaptureView(frame: NSRect(origin: .zero, size: rect.size))
            clip.onBlankClick = { [weak self] in
                guard let self, self.settingsPanel == nil else { return }
                if self.openFolder != nil { self.closeFolder() } else { self.hide() }
            }
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
            let image = NSImageView()
            image.imageScaling = .scaleAxesIndependently
            clip.addSubview(image)
            let tint = NSView(frame: clip.bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            clip.addSubview(tint)
            let shade = NSView(frame: clip.bounds)
            shade.autoresizingMask = [.width, .height]
            shade.wantsLayer = true
            shade.layer?.backgroundColor = SettingsBackdropView.shade.cgColor
            shade.isHidden = settingsPanel == nil
            clip.addSubview(shade)
            menuSettingsShade = shade
            cover.contentView = clip
            menuCover = cover
            menuCoverImage = image
            menuCoverTint = tint
        }
        menuCover?.setFrame(rect, display: true)
        menuCoverImage?.frame = NSRect(x: 0, y: height - frame.height, width: frame.width, height: frame.height)
        menuCoverImage?.image = backgroundView.preparedWallpaper
        let hex = backgroundView.style.overlayColor.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let rgb = UInt32(hex, radix: 16) ?? 0
        menuCoverTint?.layer?.backgroundColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: backgroundView.style.overlayOpacity).cgColor
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        guard launcherTargetVisible,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        hide()
    }

    @objc private func volumeChanged() { scheduleRefresh() }
    @objc private func manualRefresh() { refresh() }
    @objc private func spaceChanged() { refreshVisibleWallpaper() }
    @objc private func screenParametersChanged() {
        guard window.isVisible, let screen = window.screen else { return }
        backgroundView.updateWallpaper(for: screen) { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.showPrepared(on: screen)
        }
    }
    private func refreshVisibleWallpaper() {
        guard window.isVisible, launcherTargetVisible, !transitionInProgress, let screen = window.screen else { return }
        backgroundView.updateWallpaper(for: screen) { [weak self] in
            guard let self, self.window.isVisible, self.launcherTargetVisible else { return }
            self.menuCoverImage?.image = self.backgroundView.preparedWallpaper
        }
    }
    #if DEBUG
    @objc private func showBackgroundDebug() {
        if backgroundDebugPanel == nil {
            backgroundDebugPanel = BackgroundDebugPanel(style: backgroundView.style) { [weak self] style in
                guard let self else { return }
                self.debugRefreshTask?.cancel()
                self.debugRefreshTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self.backgroundView.setStyle(style)
                    self.refreshVisibleWallpaper()
                    self.menuCoverTint?.layer?.backgroundColor = NSColor.black.withAlphaComponent(style.overlayOpacity).cgColor
                }
            }
        }
        backgroundDebugPanel?.showWindow(nil)
        backgroundDebugPanel?.window?.makeKeyAndOrderFront(nil)
    }
    #endif

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { refresh() }
        }
    }

    private func refresh() {
        if transitionInProgress || openFolder != nil { pendingRefresh = true; return }
        scanGeneration += 1
        let generation = scanGeneration
        Task {
            let result = await Task.detached(priority: .utility) {
                AppScanner.scan()
            }.value
            guard generation == scanGeneration else { return }
            if transitionInProgress || openFolder != nil { pendingRefresh = true; return }
            let oldPaths = layout.paths
            apps = layout.reconcile(result)
            applyCurrentSort()
            loadedFolderItems = nil
            if oldPaths != layout.paths {
                let snapshot = layout
                storageQueue.async { try? LayoutStore.save(snapshot) }
                iconCache.removeAllObjects()
            }
            filter(query: searchCapsule.stringValue)
            storageQueue.async { [logger] in
                do {
                    try AppIndexStore.save(result)
                } catch {
                    logger.error("Could not save cached applications: \(error.localizedDescription, privacy: .public)")
                }
            }
            logger.debug("Indexed \(result.count) applications")

            let icons = await Task.detached(priority: .utility) {
                var icons: [String: CGImage] = [:]
                for app in result {
                    let image = NSWorkspace.shared.icon(forFile: app.path)
                    var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
                    if let decoded = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        icons[app.path] = decoded
                    }
                }
                return icons
            }.value
            guard generation == scanGeneration else { return }
            if transitionInProgress || openFolder != nil { pendingRefresh = true; return }
            for (path, image) in icons {
                iconCache.setObject(NSImage(cgImage: image, size: NSSize(width: 128, height: 128)), forKey: path as NSString)
            }
            filter(query: searchCapsule.stringValue)
        }
    }

    private func filter(query: String) {
        if transitionInProgress { pendingQuery = query; return }
        if openFolder != nil { pendingQuery = query; closeFolder(); return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        openFolder = nil
        folderBackdrop.isHidden = true
        folderBackdrop.alphaValue = 1
        filtered = trimmed.isEmpty ? apps : apps.filter { $0.name.localizedStandardContains(trimmed) }
        folderContents = [:]
        if trimmed.isEmpty {
            var items: [AppRecord] = []
            for app in filtered {
                if let folder = app.folder {
                    if folderContents[folder] == nil {
                        items.append(AppRecord(path: "chu-folder:" + folder, name: folder))
                        folderContents[folder] = []
                    }
                    folderContents[folder, default: []].append(app)
                } else {
                    items.append(app)
                }
            }
            displayed = items
        } else {
            displayed = filtered
        }
        reloadDisplayed()
    }

    private func scheduleBackdropWarmup() {
        // The prepared wallpaper is already cached; opening a folder needs no screen capture.
    }

    private func reloadDisplayed() {
        pagedContainer.reloadPages(apps: displayed, folders: folderContents, iconCache: iconCache, targetPage: 0)
        pageIndicator.count = pagedContainer.pageCount
        pageIndicator.current = pagedContainer.currentPage
    }

    private func activate(_ app: AppRecord, from itemView: AppItemView? = nil) {
        guard app.path.hasPrefix("chu-folder:") else { open(app, from: itemView); return }
        guard let contents = folderContents[app.name] else { return }
        if openFolder != nil {
            if folderClosing && openFolder == app.name { animateFolder(opening: true) }
            return
        }
        guard let source = itemView ?? pagedContainer.findItemView(for: app) else { return }
        pagedContainer.layoutSubtreeIfNeeded()
        backdropWarmup?.cancel()
        folderSourceRect = source.convert(source.folderThumbnailFrame, to: folderBackdrop)
        folderMainItems = displayed
        openFolder = app.name
        updateMoreButton()
        folderTitle.stringValue = app.name
        displayed = contents

        layoutFolderPanel()
        if loadedFolderItems != contents {
            folderPages.reloadPages(apps: contents, folders: [:], iconCache: iconCache)
            loadedFolderItems = contents
        } else {
            folderPages.scrollToPage(0, animated: false)
        }
        folderPages.layoutSubtreeIfNeeded()
        folderIndicator.count = folderPages.pageCount
        folderIndicator.current = folderPages.currentPage
        folderTitle.wantsLayer = true
        folderIndicator.wantsLayer = true

        folderOverlay.underlyingControls = [pagedContainer, searchCapsule, pageIndicator]
        folderOverlay.present(from: folderSourceRect)
    }

    private func animateFolder(opening: Bool) {
        folderOverlay.animate(opening: opening)
    }

    private func layoutFolderPanel() {
        let available = folderBackdrop.bounds.insetBy(dx: 36, dy: 40)
        let width = max(1, min(available.width, 1140))
        let height = max(1, min(available.height, min(680, available.height * 0.72)))
        folderPanel.frame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        folderTitle.frame = NSRect(x: 0, y: height - 60, width: width, height: 30)
        folderPages.frame = NSRect(x: 20, y: 42, width: width - 40, height: max(1, height - 115))
        folderIndicator.frame = NSRect(x: (width - 200) / 2, y: 10, width: 200, height: 20)
    }

    private func closeFolder() {
        guard openFolder != nil, !folderClosing else { return }
        folderOverlay.animate(opening: false)
    }

    private func open(_ app: AppRecord, from itemView: AppItemView? = nil) {
        guard !isLaunching else { return }
        isLaunching = true

        let targetItemView = itemView ?? activePages.findItemView(for: app)

        let finishLaunch: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
            self.window.orderOut(nil)
            self.menuCover?.orderOut(nil)
            self.window.alphaValue = 1.0
            targetItemView?.resetLaunchAnimation()
            self.isLaunching = false
        }

        if let targetItemView, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            targetItemView.animateLaunch { }
        }
        hide(completion: finishLaunch)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
