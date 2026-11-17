import AppKit
import CoreImage
import OSLog
import QuartzCore

// Background parameters can be overridden in Application Support/NovaLaunchpad/background.json.
struct NovaBackgroundStyle: Codable, Sendable {
    var blurRadius: Double = 48
    var brightness: Double = -0.04
    var saturation: Double = 0.86
    var overlayColor: String = "182338"
    var overlayOpacity: Double = 0.06
    var tintColor: String = "ffffff"
    var animationDuration: Double = 0.30

    static func load() -> NovaBackgroundStyle {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NovaLaunchpad/background.json")
        guard let data = try? Data(contentsOf: url), let style = try? JSONDecoder().decode(NovaBackgroundStyle.self, from: data),
              (0...150).contains(style.blurRadius), (-1...1).contains(style.brightness),
              (0...2).contains(style.saturation), (0...1).contains(style.overlayOpacity),
              (0.05...2).contains(style.animationDuration) else { return NovaBackgroundStyle() }
        return style
    }
}

// CIContext is thread-safe and reused for all background renders.
enum WallpaperBlurRenderer {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    static func generate(url: URL, screenSize: CGSize, style: NovaBackgroundStyle) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width: CGFloat = 1600
        let height = width * screenSize.height / max(1, screenSize.width)
        let input = CIImage(cgImage: cgImage)
        let scale = max(width / input.extent.width, height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: max(0, (scaled.extent.width - width) / 2), y: max(0, (scaled.extent.height - height) / 2), width: width, height: height)
        let centered = scaled.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let blurred = centered.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: style.blurRadius]).cropped(to: extent)
        let adjusted = blurred.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: style.brightness, kCIInputSaturationKey: style.saturation])
        return context.createCGImage(adjusted, from: extent)
    }
}

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
    let style = NovaBackgroundStyle.load()
    private let wallpaperImageView = NSImageView()
    private let fallbackView = NSVisualEffectView()
    private let overlay = NSView()
    private let tint = NSView()
    private var cache: [String: NSImage] = [:]
    private var wallpaperGeneration = 0
    private var usingFallback = false

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
        for view in [fallbackView, wallpaperImageView, overlay, tint] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    var transitionLayers: [CALayer] {
        [wallpaperImageView.layer, fallbackView.layer, overlay.layer, tint.layer].compactMap { $0 }
    }
    func targetOpacity(for layer: CALayer) -> Float {
        if layer === wallpaperImageView.layer { return usingFallback ? 0 : 1 }
        if layer === fallbackView.layer { return usingFallback ? 1 : 0 }
        if layer === overlay.layer { return Float(style.overlayOpacity) }
        if layer === tint.layer { return style.tintColor.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")) == "ffffff" ? 0 : 0.06 }
        return 1
    }

    func updateWallpaper(for screen: NSScreen, completion: (@MainActor () -> Void)? = nil) {
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            usingFallback = true; wallpaperImageView.image = nil; completion?(); return
        }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
        let key = "\(url.path)|\(size.width)x\(size.height)@\(scale)|\(modified?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(modified?.fileSize ?? 0)"
        if let image = cache[key] {
            usingFallback = false; wallpaperImageView.image = image; completion?(); return
        }
        let style = self.style
        Task {
            let image = await Task.detached(priority: .utility) {
                WallpaperBlurRenderer.generate(url: url, screenSize: size, style: style)
            }.value
            guard generation == wallpaperGeneration else { return }
            if let image {
                let result = NSImage(cgImage: image, size: size)
                if cache.count >= 4 { cache.removeAll() }
                cache[key] = result
                wallpaperImageView.image = result
                usingFallback = false
            } else {
                wallpaperImageView.image = nil
                usingFallback = true
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
        searchField.frame = NSRect(x: 12, y: floor((bounds.height - 24) / 2), width: max(0, bounds.width - 24), height: 24)
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitItem = itemViews.first { $0.frame.contains(point) }
        if hitItem == nil {
            onBlankAreaClicked?()
        } else {
            super.mouseDown(with: event)
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
            pageView.onBlankAreaClicked = { [weak self] in
                self?.onBlankAreaClicked?()
            }
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
            pagesTrackView.frame.origin.x = targetX
            currentPage = index
            onPageChanged?(currentPage)
            return
        }

        isAnimating = true
        currentPage = index
        onPageChanged?(currentPage)

        NSAnimationContext.runAnimationGroup { context in
            // Launchpad 原生平滑阻尼过渡曲线
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            pagesTrackView.animator().frame.origin.x = targetX
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isAnimating = false
            }
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

    override func mouseDown(with event: NSEvent) {
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
    var cornerRadius: Double = 24
    var backgroundOpacity: Double = 0.88
    var backgroundTint: String = "383a40"
    var backdropBlurRadius: Double = 16
    var backdropDimOpacity: Double = 0.20
    var openDuration: Double = 0.20
    var closeDuration: Double = 0.22

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
    override func mouseDown(with event: NSEvent) { onDismiss?(convert(event.locationInWindow, from: nil)) }
}

@MainActor final class FolderOverlayController {
    enum State { case closed, opening, opened, closing }
    let appearance = FolderAppearance.load()
    let root = FolderBackdropView()
    let panel = NSView()
    let title = NSTextField(labelWithString: "")
    let pages = PagedContainerView()
    let indicator = PageIndicator()
    private let snapshot = NSImageView()
    private let fallback = NSVisualEffectView()
    private let dim = NSView()
    private(set) var state: State = .closed
    private var generation = 0
    private var snapshotReady = false
    private var cachedBackdrop: CGImage?
    private var cacheGeneration = 0
    var onClosed: (() -> Void)?

    init() {
        root.wantsLayer = true
        root.isHidden = true
        root.autoresizingMask = [.width, .height]
        snapshot.wantsLayer = true
        snapshot.imageScaling = .scaleAxesIndependently
        fallback.material = .hudWindow
        fallback.blendingMode = .withinWindow
        fallback.state = .active
        fallback.wantsLayer = true
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).cgColor
        for view in [fallback, snapshot, dim] as [NSView] {
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
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

    func invalidateSnapshot() {
        cacheGeneration += 1
        cachedBackdrop = nil
    }

    // Called while the main grid is idle, never from a folder click.
    func prewarmSnapshot(from view: NSView) {
        guard state == .closed, view.window?.isVisible == true else { return }
        cacheGeneration += 1
        let current = cacheGeneration
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return }
        let radius = appearance.backdropBlurRadius * (view.window?.backingScaleFactor ?? 1)
        Task {
            let result = await Task.detached(priority: .utility) { () -> CGImage? in
                let original = CIImage(cgImage: image)
                let scale = min(1, 960 / max(1, original.extent.width))
                let source = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let adjusted = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale]).cropped(to: source.extent)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.88, kCIInputBrightnessKey: -0.025])
                return WallpaperBlurRenderer.context.createCGImage(adjusted, from: source.extent)
            }.value
            guard current == self.cacheGeneration else { return }
            self.cachedBackdrop = result
        }
    }

    func prepareSnapshot(from view: NSView) {
        generation += 1
        state = .opening
        snapshotReady = false
        finishPreparing(cachedBackdrop, generation: generation)
    }

    private func finishPreparing(_ image: CGImage?, generation current: Int) {
        guard current == generation, state == .opening else { return }
        let size = root.bounds.size
        for view in [fallback, snapshot, dim] as [NSView] { view.frame = root.bounds }
        snapshot.image = image.map { NSImage(cgImage: $0, size: size) }
        fallback.isHidden = image != nil
        snapshot.isHidden = image == nil
        snapshotReady = true
        let instant = CAMediaTimingFunction(name: .linear)
        for layer in [snapshot.layer, fallback.layer, dim.layer, panel.layer, title.layer, indicator.layer].compactMap({ $0 }) + pages.visibleItemLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: Float(0), duration: 0, curve: instant)
        }
        if let layer = panel.layer {
            LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(0.94, 0.94, 1)), duration: 0, curve: instant)
        }
        root.isHidden = false
        animate(opening: true)
    }

    func animate(opening: Bool) {
        guard state != .closed else { return }
        if !opening && !snapshotReady { reset(); onClosed?(); return }
        guard snapshotReady else { return }
        generation += 1
        let current = generation
        state = opening ? .opening : .closing
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.12 : (opening ? appearance.openDuration : appearance.closeDuration)
        let curve = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
        let opacity: Float = opening ? 1 : 0
        for layer in [snapshot.layer, fallback.layer].compactMap({ $0 }) {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
        }
        if let layer = dim.layer {
            LauncherTransition.set(layer, keyPath: "opacity", value: opening ? Float(appearance.backdropDimOpacity) : 0, duration: duration, curve: curve)
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
        snapshotReady = false
        root.isHidden = true
        root.alphaValue = 1
        snapshot.image = nil
    }
}

// MARK: - 主应用程序代理 (AppDelegate)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: LauncherWindow!
    private let backgroundView = LauncherBackgroundView(frame: .zero)
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
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Nova Launchpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }

    private func setupEventMonitors() {
        // Allow the same folder icon to reverse a closing transition, even while
        // the shrinking panel is still covering its original hit target.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if self.openFolder != nil && self.folderBackdrop.isHidden { return nil }
            guard self.folderClosing else { return event }
            let point = self.folderBackdrop.convert(event.locationInWindow, from: nil)
            guard self.folderSourceRect.contains(point) else { return event }
            self.animateFolder(opening: true)
            return nil
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
        for layer in backgroundView.transitionLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: visible ? backgroundView.targetOpacity(for: layer) : 0, duration: duration, curve: curve)
        }
        for layer in pagedContainer.visibleItemLayers {
            LauncherTransition.set(layer, keyPath: "opacity", value: opacity, duration: duration, curve: curve)
            let scale: CGFloat = visible || reduced ? 1 : 1.15
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
                    LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DMakeScale(1.15, 1.15, 1)), duration: 0, curve: instant)
                }
            }
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            searchCapsule.makeFirstResponder()
        }
        transition(visible: true)
    }

    @objc private func volumeChanged() { scheduleRefresh() }
    @objc private func manualRefresh() { refresh() }
    @objc private func spaceChanged() {
        // Refresh the background on the next presentation, after the current transition.
    }

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
        backdropWarmup?.cancel()
        folderOverlay.invalidateSnapshot()
        backdropWarmup = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.openFolder == nil,
                  !self.transitionInProgress, self.window.isVisible else { return }
            self.folderOverlay.prewarmSnapshot(from: self.backgroundView)
        }
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
        folderPages.reloadPages(apps: contents, folders: [:], iconCache: iconCache)
        folderPages.layoutSubtreeIfNeeded()
        folderIndicator.count = folderPages.pageCount
        folderIndicator.current = folderPages.currentPage
        folderTitle.wantsLayer = true
        folderIndicator.wantsLayer = true

        folderOverlay.prepareSnapshot(from: backgroundView)
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
