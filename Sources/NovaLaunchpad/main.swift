import AppKit
import CoreImage
import OSLog
import QuartzCore

#if DEBUG
@MainActor final class BackgroundDebugPanel: NSWindowController {
    private var style: NovaBackgroundStyle
    private let onChange: (NovaBackgroundStyle) -> Void
    init(style: NovaBackgroundStyle, onChange: @escaping (NovaBackgroundStyle) -> Void) {
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
    private(set) var style = NovaBackgroundStyle.load()
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

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func color(_ hex: String) -> NSColor {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let rgb = UInt32(text, radix: 16) else { return .clear }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private func setup() {
        wantsLayer = true
        autoresizingMask = [.width, .height]
        wallpaperGroup.frame = bounds
        wallpaperGroup.autoresizingMask = [.width, .height]
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

    var transitionLayers: [CALayer] { [wallpaperGroup.layer].compactMap { $0 } }
    func targetOpacity(for layer: CALayer) -> Float { 1 }

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

    func setStyle(_ value: NovaBackgroundStyle) {
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
@MainActor final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 胶囊药丸风格搜索框 (Capsule Search Field)
@MainActor final class SearchCapsuleView: NSView, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let magnifier = NSImageView()
    var onQueryChanged: ((String) -> Void)?
    var onReturnPressed: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    var stringValue: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
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
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onReturnPressed?()
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let icon = iconImageView.frame.insetBy(dx: -2, dy: -2)
        let labelWidth = min(nameLabel.frame.width, ceil(nameLabel.intrinsicContentSize.width) + 8)
        let label = NSRect(x: nameLabel.frame.midX - labelWidth / 2, y: nameLabel.frame.minY, width: labelWidth, height: nameLabel.frame.height)
        guard icon.contains(local) || label.contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
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
            if app.path.hasPrefix("nova-folder:") {
                icon = Self.folderIcon(apps: folders[app.name] ?? [], iconCache: iconCache)
            } else if let cached = iconCache.object(forKey: key) {
                icon = cached
            } else {
                let diskIcon = app.path.hasPrefix("nova-folder:") ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: app.path)
                diskIcon.size = NSSize(width: 128, height: 128)
                iconCache.setObject(diskIcon, forKey: key)
                icon = diskIcon
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
        let background = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 124, height: 124), xRadius: 31, yRadius: 31)
        NSColor(white: 0.32, alpha: 0.9).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        background.lineWidth = 1
        background.stroke()
        let size: CGFloat = 27
        let gap: CGFloat = 7
        for (index, app) in apps.prefix(9).enumerated() {
            let key = app.path as NSString
            let icon = iconCache.object(forKey: key) ?? NSWorkspace.shared.icon(forFile: app.path)
            iconCache.setObject(icon, forKey: key)
            let x = 16 + CGFloat(index % 3) * (size + gap)
            let y = 128 - 16 - size - CGFloat(index / 3) * (size + gap)
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
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NovaLaunchpad/folder.json")
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

    func present() {
        state = .opening
        let instant = CAMediaTimingFunction(name: .linear)
        for layer in [panel.layer, title.layer, indicator.layer].compactMap({ $0 }) + pages.visibleItemLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: Float(0), duration: 0, curve: instant)
        }
        if let layer = panel.layer {
            LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(0.94, 0.94, 1)), duration: 0, curve: instant)
        }
        // The launcher hide animation may leave this layer transparent even after
        // NSView is unhidden. Reset the model layer before accepting clicks.
        root.layer?.removeAnimation(forKey: "launcher.opacity")
        root.alphaValue = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.layer?.opacity = 1
        CATransaction.commit()
        root.isHidden = false
        animate(opening: true)
    }

    func animate(opening: Bool) {
        guard state != .closed else { return }
        generation += 1
        let current = generation
        state = opening ? .opening : .closing
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.12 : (opening ? appearance.openDuration : appearance.closeDuration)
        let curve = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
        let opacity: Float = opening ? 1 : 0
        for control in underlyingControls {
            if let layer = control.layer {
                LauncherTransition.set(layer, keyPath: "opacity", value: Float(opening ? 0 : 1), duration: duration, curve: curve)
            }
        }
        if let layer = panel.layer {
            let scale: CGFloat = opening || reduced ? 1 : 0.94
            LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1)), duration: duration, curve: curve)
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
        }
        for layer in pages.visibleItemLayers + [title.layer, indicator.layer].compactMap({ $0 }) {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
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
        for control in underlyingControls {
            control.layer?.removeAnimation(forKey: "launcher.opacity")
            control.layer?.opacity = 1
        }
    }
}

// MARK: - 主应用程序代理 (AppDelegate)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: LauncherWindow!
    private let backgroundView = LauncherBackgroundView(frame: .zero)
    private var menuCover: NSWindow?
    private var menuCoverImage: NSImageView?
    private var menuCoverTint: NSView?
    private var wallpaperTimer: Timer?
    #if DEBUG
    private var backgroundDebugPanel: BackgroundDebugPanel?
    private var debugRefreshTask: Task<Void, Never>?
    #endif
    private let searchCapsule = SearchCapsuleView(frame: .zero)
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
    private let storageQueue = DispatchQueue(label: "org.novalaunchpad.storage", qos: .utility)
    private let logger = Logger(subsystem: "org.novalaunchpad.app", category: "launcher")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = LauncherWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear

        // 原生桌面壁纸毛玻璃与磨砂背景
        backgroundView.frame = window.contentView!.bounds
        backgroundView.autoresizingMask = [.width, .height]
        window.contentView = backgroundView

        // 顶部居中胶囊搜索栏
        searchCapsule.onQueryChanged = { [weak self] query in
            self?.filter(query: query)
        }
        searchCapsule.onReturnPressed = { [weak self] in
            guard let self, let first = self.displayed.first else { return }
            self.activate(first)
        }
        searchCapsule.onEscapePressed = { [weak self] in
            guard let self else { return }
            if !self.searchCapsule.stringValue.isEmpty {
                self.searchCapsule.stringValue = ""
                self.filter(query: "")
            } else {
                self.hide()
            }
        }
        backgroundView.addSubview(searchCapsule)

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
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibleWallpaper() }
        }

        Task {
            layout = await Task.detached(priority: .utility) { LayoutStore.load() }.value
            refresh()
        }
        show()
    }

    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "重新扫描应用", action: #selector(manualRefresh), keyEquivalent: "r").target = self
        #if DEBUG
        appMenu.addItem(withTitle: "背景调试…", action: #selector(showBackgroundDebug), keyEquivalent: "d").target = self
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Nova Launchpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }

    private func setupEventMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, self.window.isVisible, !self.isLaunching else { return event }
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
                    if view is SearchCapsuleView || view is PageIndicator { isControl = true; break }
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
            guard let self, self.window.isVisible, !self.isLaunching else { return event }

            // Esc 键
            if event.keyCode == 53 {
                if !self.searchCapsule.stringValue.isEmpty {
                    self.searchCapsule.stringValue = ""
                    self.filter(query: "")
                } else if self.openFolder != nil {
                    self.closeFolder()
                } else {
                    self.hide()
                }
                return nil
            }
            // 回车键
            if event.keyCode == 36 {
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
            guard let self, self.window.isVisible else { return event }
            if event.deltaX > 0 {
                self.activePages.previousPage()
            } else if event.deltaX < 0 {
                self.activePages.nextPage()
            }
            return nil
        }

        // 触控板平滑滑动与滚轮
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window.isVisible, event.window === self.window else { return event }

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

    func applicationDidResignActive(_ notification: Notification) {
        hide()
    }

    private func transition(visible: Bool, completion: (@MainActor () -> Void)? = nil) {
        transitionGeneration += 1
        let generation = transitionGeneration
        launcherTargetVisible = visible
        transitionInProgress = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: CFTimeInterval = reduced ? 0.12 : backgroundView.style.animationDuration * (visible ? 1 : 5.0 / 6.0)
        let curve = CAMediaTimingFunction(controlPoints: visible ? 0.18 : 0.4, visible ? 0.8 : 0.0, 0.3, 1.0)
        let opacity: Float = visible ? 1 : 0
        if let cover = menuCover {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = curve
                cover.animator().alphaValue = visible ? 1 : 0
            }
        }
        for layer in backgroundView.transitionLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: visible ? backgroundView.targetOpacity(for: layer) : 0, duration: duration, curve: curve)
        }
        for layer in pagedContainer.visibleItemLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
            let scale: CGFloat = visible || reduced ? 1 : 1.08
            LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1)), duration: duration, curve: curve)
        }
        for layer in [searchCapsule.layer, pageIndicator.layer].compactMap({ $0 }) {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
        }
        if !folderBackdrop.isHidden, let layer = folderBackdrop.layer {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.transitionInProgress = false
            if !visible {
                self.window.orderOut(nil)
                self.menuCover?.orderOut(nil)
                self.isLaunching = false
                if self.openFolder != nil {
                    self.resetFolderLayers()
                    self.openFolder = nil
                    self.folderBackdrop.isHidden = true
                    self.folderBackdrop.alphaValue = 1
                    self.folderPanel.layer?.removeAllAnimations()
                    self.folderPanel.layer?.transform = CATransform3DIdentity
                    self.filter(query: self.searchCapsule.stringValue)
                }
            }
            completion?()
            if let query = self.pendingQuery { self.pendingQuery = nil; self.filter(query: query) }
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            if visible { self.scheduleBackdropWarmup() }
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
        if window.isVisible { transition(visible: true); return }
        showRequestGeneration += 1
        let request = showRequestGeneration
        launcherTargetVisible = true
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        backgroundView.updateWallpaper(for: screen) { [weak self] in
            guard let self, self.showRequestGeneration == request, self.launcherTargetVisible else { return }
            self.showPrepared(on: screen)
        }
    }

    private func showPrepared(on currentScreen: NSScreen) {
        window.setFrame(currentScreen.frame, display: true)
        prepareMenuCover(on: currentScreen)

        let screenWidth = currentScreen.frame.width
        let screenHeight = currentScreen.frame.height

        // 1. 顶部搜索框：居中药丸，宽 260，高 32，距离屏幕顶部 68pt
        let searchWidth: CGFloat = 260
        let searchHeight: CGFloat = 32
        let searchX = floor((screenWidth - searchWidth) / 2)
        let searchY = screenHeight - 68 - searchHeight
        searchCapsule.frame = NSRect(x: searchX, y: searchY, width: searchWidth, height: searchHeight)

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

        let panelWidth = min(screenWidth - 80, 1140)
        let panelHeight = min(screenHeight - 100, 730)
        folderPanel.frame = NSRect(x: (screenWidth - panelWidth) / 2, y: (screenHeight - panelHeight) / 2, width: panelWidth, height: panelHeight)
        folderTitle.frame = NSRect(x: 0, y: panelHeight - 65, width: panelWidth, height: 30)
        folderPages.frame = NSRect(x: 20, y: 45, width: panelWidth - 40, height: panelHeight - 125)
        folderIndicator.frame = NSRect(x: (panelWidth - 200) / 2, y: 12, width: 200, height: 20)
        pagedContainer.layoutSubtreeIfNeeded()
        pagedContainer.resetAllItemAnimations()
        isLaunching = false

        searchCapsule.wantsLayer = true
        pageIndicator.wantsLayer = true
        let wasVisible = window.isVisible
        if !wasVisible {
            let instant = CAMediaTimingFunction(name: .linear)
            for layer in backgroundView.transitionLayers + pagedContainer.visibleItemLayers + [searchCapsule.layer, pageIndicator.layer].compactMap({ $0 }) {
                LauncherTransition.set(layer, keyPath: "opacity", value: Float(0), duration: 0, curve: instant)
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for layer in pagedContainer.visibleItemLayers {
                    LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(1.08, 1.08, 1)), duration: 0, curve: instant)
                }
            }
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            menuCover?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            searchCapsule.makeFirstResponder()
        }
        transition(visible: true)
    }

    // Cover only the menu bar, leaving the main window below the Dock's level.
    private func prepareMenuCover(on screen: NSScreen) {
        let frame = screen.frame
        let height = min(frame.height, max(NSStatusBar.system.thickness, frame.maxY - screen.visibleFrame.maxY))
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if menuCover == nil {
            let cover = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            cover.ignoresMouseEvents = true
            cover.isOpaque = false
            cover.backgroundColor = .clear
            cover.hasShadow = false
            let clip = NSView(frame: NSRect(origin: .zero, size: rect.size))
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
        menuCover?.alphaValue = 0
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
            let (result, icons) = await Task.detached(priority: .utility) {
                let result = AppScanner.scan()
                var icons: [String: CGImage] = [:]
                for app in result {
                    let image = NSWorkspace.shared.icon(forFile: app.path)
                    var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
                    if let decoded = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        icons[app.path] = decoded
                    }
                }
                return (result, icons)
            }.value
            guard generation == scanGeneration else { return }
            if transitionInProgress || openFolder != nil { pendingRefresh = true; return }
            let oldPaths = layout.paths
            apps = layout.reconcile(result)
            loadedFolderItems = nil
            if oldPaths != layout.paths {
                let snapshot = layout
                storageQueue.async { try? LayoutStore.save(snapshot) }
                iconCache.removeAllObjects()
            }
            for (path, image) in icons {
                iconCache.setObject(NSImage(cgImage: image, size: NSSize(width: 128, height: 128)), forKey: path as NSString)
            }
            filter(query: searchCapsule.stringValue)
            logger.debug("Indexed \(result.count) applications")
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
                        items.append(AppRecord(path: "nova-folder:" + folder, name: folder))
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
        guard app.path.hasPrefix("nova-folder:") else { open(app, from: itemView); return }
        guard let contents = folderContents[app.name] else { return }
        if openFolder != nil {
            if folderClosing && openFolder == app.name { animateFolder(opening: true) }
            return
        }
        guard let source = itemView ?? pagedContainer.findItemView(for: app) else { return }
        pagedContainer.layoutSubtreeIfNeeded()
        backdropWarmup?.cancel()
        folderSourceRect = source.convert(source.bounds, to: folderBackdrop)
        folderMainItems = displayed
        openFolder = app.name
        folderTitle.stringValue = app.name
        displayed = contents

        // Determine the destination before exposing the panel. Coordinates here are
        // in the unflipped backdrop; the source view can belong to any page.
        let available = folderBackdrop.bounds.insetBy(dx: 36, dy: 40)
        let width = max(1, min(available.width, 1140))
        let height = max(1, min(available.height, min(680, available.height * 0.72)))
        folderPanel.frame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        folderTitle.frame = NSRect(x: 0, y: height - 60, width: width, height: 30)
        folderPages.frame = NSRect(x: 20, y: 42, width: width - 40, height: max(1, height - 115))
        folderIndicator.frame = NSRect(x: (width - 200) / 2, y: 10, width: 200, height: 20)
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
        folderOverlay.present()
    }

    private func animateFolder(opening: Bool) {
        folderOverlay.animate(opening: opening)
    }

    private func resetFolderLayers() {
        folderOverlay.reset()
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
            if self.openFolder != nil {
                self.resetFolderLayers()
                self.openFolder = nil
                self.folderBackdrop.isHidden = true
                self.folderBackdrop.alphaValue = 1.0
                self.folderPanel.layer?.removeAllAnimations()
                self.folderPanel.layer?.transform = CATransform3DIdentity
                self.filter(query: self.searchCapsule.stringValue)
            }
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
