import AppKit
import CoreImage
import OSLog
import QuartzCore

// MARK: - 桌面壁纸高斯模糊渲染器
enum WallpaperBlurRenderer {
    static func generate(url: URL, screenSize: NSSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // 缩放到适宜宽度进行平滑高斯模糊，性能极高（约 20ms）且散景平滑细腻
        let targetWidth: CGFloat = 1280
        let targetHeight = targetWidth * (screenSize.height / max(1, screenSize.width))

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let inputCI = CIImage(cgImage: cgImage)

        let scale = max(targetWidth / inputCI.extent.width, targetHeight / inputCI.extent.height)
        let scaled = inputCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let cropRect = CGRect(
            x: max(0, (scaled.extent.width - targetWidth) / 2),
            y: max(0, (scaled.extent.height - targetHeight) / 2),
            width: targetWidth,
            height: targetHeight
        )
        let cropped = scaled.cropped(to: cropRect)
        let centered = cropped.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        let clamped = centered.clampedToExtent()

        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(55.0, forKey: kCIInputRadiusKey)

        guard let outputCI = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight))),
              let outputCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else {
            return nil
        }
        return NSImage(cgImage: outputCG, size: screenSize)
    }
}

// MARK: - 原生毛玻璃背景视图 (桌面壁纸大半径散景模糊 + 磨砂遮罩)
@MainActor final class LauncherBackgroundView: NSView {
    private let wallpaperImageView = NSImageView()
    private let tintOverlay = NSView()
    private let effectView = NSVisualEffectView()
    private var cachedImage: NSImage?
    private var cachedURL: URL?

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
        autoresizingMask = [.width, .height]

        // 1. 底层：当前屏幕桌面壁纸的大光圈高斯模糊（精准还原壁纸原色散景）
        wallpaperImageView.frame = bounds
        wallpaperImageView.autoresizingMask = [.width, .height]
        wallpaperImageView.imageScaling = .scaleAxesIndependently
        addSubview(wallpaperImageView)

        // 2. 中层：半透明暗化磨砂遮罩（降低高光，保证白色文本与应用图标极佳的可读性）
        tintOverlay.frame = bounds
        tintOverlay.autoresizingMask = [.width, .height]
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.32).cgColor
        addSubview(tintOverlay)

        // 3. 顶层：系统毛玻璃质感混合
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .fullScreenUI
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        addSubview(effectView)
    }

    func updateWallpaper(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        if url == cachedURL, let cachedImage {
            wallpaperImageView.image = cachedImage
            return
        }

        if let image = WallpaperBlurRenderer.generate(url: url, screenSize: screen.frame.size) {
            self.cachedImage = image
            self.cachedURL = url
            self.wallpaperImageView.image = image
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
    private var appRecord: AppRecord?
    private var onOpen: ((AppRecord) -> Void)?
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
        // 图标固定 80x80，图标与文字间距固定 8pt，文字高度 18pt
        let iconSize: CGFloat = 80
        let labelHeight: CGFloat = 18
        let spacing: CGFloat = 8
        let totalContentHeight = iconSize + spacing + labelHeight

        // 垂直居中于 Cell
        let startY = max(0, floor((bounds.height - totalContentHeight) / 2))
        let iconX = floor((bounds.width - iconSize) / 2)

        iconImageView.frame = NSRect(x: iconX, y: startY, width: iconSize, height: iconSize)
        nameLabel.frame = NSRect(x: 4, y: startY + iconSize + spacing, width: bounds.width - 8, height: labelHeight)
    }

    func configure(app: AppRecord, icon: NSImage, onOpen: @escaping (AppRecord) -> Void) {
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
            onOpen?(appRecord)
        }
    }

    private func animatePress(down: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconImageView.animator().alphaValue = down ? 0.75 : 1.0
        }
    }
}

// MARK: - 单页网格视图 (7 列 x 5 行)
@MainActor final class PageGridView: NSView {
    private var itemViews: [AppItemView] = []
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

    func populate(apps: [AppRecord], iconCache: NSCache<NSString, NSImage>, onOpen: @escaping (AppRecord) -> Void) {
        for sub in itemViews { sub.removeFromSuperview() }
        itemViews.removeAll()

        for app in apps {
            let key = app.path as NSString
            let icon: NSImage
            if let cached = iconCache.object(forKey: key) {
                icon = cached
            } else {
                let diskIcon = NSWorkspace.shared.icon(forFile: app.path)
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

    override func layout() {
        super.layout()
        guard !itemViews.isEmpty else { return }

        let cols = 7
        let rows = 5

        // 计算 7 列 5 行的布局位置
        let cellWidth = min(190, max(140, (bounds.width - 160) / CGFloat(cols)))
        let cellHeight = min(145, max(115, bounds.height / CGFloat(rows)))

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
    private let pagesTrackView = NSView()
    private var pageViews: [PageGridView] = []

    private(set) var currentPage = 0
    private(set) var pageCount = 1

    var onPageChanged: ((Int) -> Void)?
    var onOpenApp: ((AppRecord) -> Void)?
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

    func reloadPages(apps: [AppRecord], iconCache: NSCache<NSString, NSImage>, targetPage: Int = 0) {
        let pageSize = 35 // 7 列 x 5 行
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
            pageView.populate(apps: pageApps, iconCache: iconCache) { [weak self] app in
                self?.onOpenApp?(app)
            }
            pageView.onBlankAreaClicked = { [weak self] in
                self?.onBlankAreaClicked?()
            }
            pagesTrackView.addSubview(pageView)
            pageViews.append(pageView)
        }

        onPageChanged?(currentPage)
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
    private var layout = Layout()
    private var watcher: AppWatcher?
    private var refreshTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var lastWheelTurn = Date.distantPast
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
        backgroundView.updateWallpaper(for: screen)
        window.contentView = backgroundView

        // 顶部居中胶囊搜索栏
        searchCapsule.onQueryChanged = { [weak self] query in
            self?.filter(query: query)
        }
        searchCapsule.onReturnPressed = { [weak self] in
            guard let self, let first = self.filtered.first else { return }
            self.open(first)
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
        }
        pagedContainer.onOpenApp = { [weak self] app in
            self?.open(app)
        }
        pagedContainer.onBlankAreaClicked = { [weak self] in
            self?.hide()
        }
        backgroundView.addSubview(pagedContainer)

        // 底部分页圆点指示器（原生仅圆点，无箭头）
        pageIndicator.onSelect = { [weak self] index in
            self?.pagedContainer.scrollToPage(index, animated: true)
        }
        backgroundView.addSubview(pageIndicator)

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
        // 键盘监控
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isVisible else { return event }

            // Esc 键
            if event.keyCode == 53 {
                if !self.searchCapsule.stringValue.isEmpty {
                    self.searchCapsule.stringValue = ""
                    self.filter(query: "")
                } else {
                    self.hide()
                }
                return nil
            }
            // 回车键
            if event.keyCode == 36 {
                let page = self.pagedContainer.currentPage
                let index = page * 35
                if index < self.filtered.count {
                    self.open(self.filtered[index])
                    return nil
                }
            }
            // 左右方向键翻页（搜索框为空时）
            if event.keyCode == 123 && self.searchCapsule.stringValue.isEmpty {
                self.pagedContainer.previousPage()
                return nil
            }
            if event.keyCode == 124 && self.searchCapsule.stringValue.isEmpty {
                self.pagedContainer.nextPage()
                return nil
            }
            return event
        }

        // 轻扫手势
        NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self, self.window.isVisible else { return event }
            if event.deltaX > 0 {
                self.pagedContainer.previousPage()
            } else if event.deltaX < 0 {
                self.pagedContainer.nextPage()
            }
            return nil
        }

        // 触控板平滑滑动与滚轮
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window.isVisible, event.window === self.window else { return event }

            if event.hasPreciseScrollingDeltas {
                // 触控板手势实时跟手
                if self.pagedContainer.handleScrollWheel(event: event) {
                    return nil
                }
            } else {
                // 普通外接滚轮（带防抖）
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                guard abs(delta) > 1 else { return nil }
                if Date().timeIntervalSince(self.lastWheelTurn) > 0.3 {
                    if delta < 0 {
                        self.pagedContainer.nextPage()
                    } else {
                        self.pagedContainer.previousPage()
                    }
                    self.lastWheelTurn = Date()
                }
                return nil
            }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isVisible { hide() } else { show() }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        hide()
    }

    private func hide() {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.window.orderOut(nil)
                self?.window.alphaValue = 1.0
            }
        })
    }

    private func show() {
        let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(currentScreen.frame, display: true)
        backgroundView.updateWallpaper(for: currentScreen)

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

        pagedContainer.reloadPages(apps: filtered, iconCache: iconCache, targetPage: pagedContainer.currentPage)
        pageIndicator.count = pagedContainer.pageCount
        pageIndicator.current = pagedContainer.currentPage

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        searchCapsule.makeFirstResponder()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
    }

    @objc private func volumeChanged() { scheduleRefresh() }
    @objc private func manualRefresh() { refresh() }
    @objc private func spaceChanged() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        backgroundView.updateWallpaper(for: screen)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { refresh() }
        }
    }

    private func refresh() {
        scanGeneration += 1
        let generation = scanGeneration
        Task {
            let result = await Task.detached(priority: .utility) { AppScanner.scan() }.value
            guard generation == scanGeneration else { return }
            let oldPaths = layout.paths
            apps = layout.reconcile(result)
            if oldPaths != layout.paths {
                let snapshot = layout
                storageQueue.async { try? LayoutStore.save(snapshot) }
                iconCache.removeAllObjects()
            }
            filter(query: searchCapsule.stringValue)
            logger.debug("Indexed \(result.count) applications")
        }
    }

    private func filter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = trimmed.isEmpty ? apps : apps.filter { $0.name.localizedStandardContains(trimmed) }
        pagedContainer.reloadPages(apps: filtered, iconCache: iconCache, targetPage: 0)
        pageIndicator.count = pagedContainer.pageCount
        pageIndicator.current = pagedContainer.currentPage
    }

    private func open(_ app: AppRecord) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
        hide()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
