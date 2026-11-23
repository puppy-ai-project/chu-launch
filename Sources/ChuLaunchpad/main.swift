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

@MainActor enum GooeyRenderer {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func render(
        trailRect: CGRect,
        leadRect: CGRect,
        cornerRadius: CGFloat,
        blurRadius: CGFloat,
        scale: CGFloat,
        isFlipped: Bool
    ) -> (frame: CGRect, image: CGImage)? {
        let pad = ceil(blurRadius * 2.5)
        let union = trailRect.union(leadRect).insetBy(dx: -pad, dy: -pad)
        guard union.width > 0, union.height > 0 else { return nil }

        func toCI(_ rect: CGRect) -> CGRect {
            let x = (rect.minX - union.minX) * scale
            let y = isFlipped ? (union.maxY - rect.maxY) * scale : (rect.minY - union.minY) * scale
            return CGRect(x: x, y: y, width: rect.width * scale, height: rect.height * scale)
        }

        let pxExtent = CGRect(x: 0, y: 0, width: ceil(union.width * scale), height: ceil(union.height * scale))
        guard let r1 = CIFilter(name: "CIRoundedRectangleGenerator"),
              let r2 = CIFilter(name: "CIRoundedRectangleGenerator"),
              let blur = CIFilter(name: "CIGaussianBlur"),
              let matrix = CIFilter(name: "CIColorMatrix") else { return nil }

        r1.setValue(CIVector(cgRect: toCI(trailRect)), forKey: "inputExtent")
        r1.setValue(cornerRadius * scale, forKey: "inputRadius")
        r1.setValue(CIColor.white, forKey: "inputColor")

        r2.setValue(CIVector(cgRect: toCI(leadRect)), forKey: "inputExtent")
        r2.setValue(cornerRadius * scale, forKey: "inputRadius")
        r2.setValue(CIColor.white, forKey: "inputColor")

        guard let img1 = r1.outputImage, let img2 = r2.outputImage else { return nil }
        let combined = img1.composited(over: img2)

        blur.setValue(combined, forKey: kCIInputImageKey)
        blur.setValue(blurRadius * scale, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage else { return nil }

        matrix.setValue(blurred, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 28), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 1, y: 1, z: 1, w: -13), forKey: "inputBiasVector")

        guard let outputCI = matrix.outputImage,
              let cgImage = ciContext.createCGImage(outputCI, from: pxExtent) else { return nil }
        return (union, cgImage)
    }
}

@MainActor final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
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

    var wallpaperURLChanged: ((URL?) -> Void)?

    private func screenKey(_ screen: NSScreen) -> String {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName
        return "\(id)|\(screen.frame.size)@\(screen.backingScaleFactor)"
    }

    func useCachedWallpaper(for screen: NSScreen) -> Bool {
        guard let image = lastByScreen[screenKey(screen)] else { return false }
        if wallpaperImageView.image !== image {
            currentKey = nil
            displayWallpaper(image)
        }
        return true
    }

    func updateWallpaper(for screen: NSScreen, completion: (@MainActor () -> Void)? = nil) {
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        let screenID = screenKey(screen)
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        wallpaperURLChanged?(wallpaperURL)
        guard let url = wallpaperURL else {
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
    private let clearButton = NSButton()
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

        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            // Use a separate control so the clear target never overlaps the text editor.
            cell.cancelButtonCell = nil
        }
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
        setPlaceholder("搜索应用")

        addSubview(searchField)

        clearButton.title = ""
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除搜索")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        clearButton.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearSearch(_:))
        clearButton.setAccessibilityLabel("清除搜索")
        clearButton.isHidden = true
        addSubview(clearButton)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        magnifier.frame = NSRect(x: 12, y: floor(bounds.midY - 8), width: 16, height: 16)
        let height = ceil(searchField.intrinsicContentSize.height)
        searchField.frame = NSRect(x: 36, y: floor(bounds.midY - height / 2), width: max(0, bounds.width - 72), height: height)
        clearButton.frame = NSRect(x: bounds.maxX - 28, y: floor(bounds.midY - 9), width: 18, height: 18)
    }

    func makeFirstResponder() {
        window?.makeFirstResponder(searchField)
    }

    func setPlaceholder(_ text: String) {
        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.48),
            .font: NSFont.systemFont(ofSize: 13, weight: .regular)
        ]
        searchField.placeholderAttributedString = NSAttributedString(string: text, attributes: placeholderAttributes)
    }

    func controlTextDidChange(_ obj: Notification) {
        publishQuery()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearQuery()
        }
    }

    private func publishQuery() {
        let query = searchField.stringValue
        clearButton.isHidden = query.isEmpty
        guard query != lastQuery else { return }
        lastQuery = query
        onQueryChanged?(query)
    }

    @objc private func clearSearch(_ sender: Any?) {
        clearQuery()
    }

    private func clearQuery() {
        guard !searchField.stringValue.isEmpty else { return }
        window?.makeFirstResponder(searchField)
        searchField.stringValue = ""
        publishQuery()
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

@MainActor final class FolderRenameView: NSView, NSTextFieldDelegate {
    let field: NSTextField
    var onFinish: ((String?) -> Void)?

    private let originalName: String
    private let existingNames: Set<String>
    private let cardWrapper = NSView()
    private let cardShell = NSView()
    private let glassView = NSVisualEffectView()
    private let surfaceTintView = NSView()
    private let borderOverlay = NSView()
    private let titleLabel = NSTextField(labelWithString: "重命名分组")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let fieldContainer = NSView()
    private let clearButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private let cancelButton: SettingsActionButton
    private let confirmButton: SettingsActionButton
    private var isClosing = false

    private static let cardWidth: CGFloat = 380
    private static let cardHeight: CGFloat = 272

    init(frame: NSRect, name: String, icon: NSImage, existingNames: Set<String> = []) {
        self.originalName = name
        self.existingNames = existingNames
        self.field = NSTextField(string: name)
        self.cancelButton = SettingsActionButton(frame: NSRect(x: 24, y: 220, width: 160, height: 34), style: .secondary, title: "取消")
        self.confirmButton = SettingsActionButton(frame: NSRect(x: 196, y: 220, width: 160, height: 34), style: .primary, title: "完成")
        super.init(frame: frame)
        setupHierarchy(name: name, icon: icon)
        applyTheme()
        validateInput()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func setupHierarchy(name: String, icon: NSImage) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor

        // 投影外框（不裁剪阴影）
        cardWrapper.wantsLayer = true
        cardWrapper.layer?.shadowColor = NSColor.black.cgColor
        cardWrapper.layer?.shadowOpacity = 0.44
        cardWrapper.layer?.shadowRadius = 26
        cardWrapper.layer?.shadowOffset = CGSize(width: 0, height: -10)
        addSubview(cardWrapper)

        // 圆角裁剪主壳（Flipped 坐标系）
        final class FlippedCard: NSView { override var isFlipped: Bool { true } }
        let flippedShell = FlippedCard(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight))
        flippedShell.wantsLayer = true
        flippedShell.layer?.cornerRadius = 18
        flippedShell.layer?.masksToBounds = true
        cardWrapper.addSubview(flippedShell)

        cardShell.frame = flippedShell.bounds
        cardShell.autoresizingMask = [.width, .height]
        flippedShell.addSubview(cardShell)

        glassView.frame = flippedShell.bounds
        glassView.autoresizingMask = [.width, .height]
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        flippedShell.addSubview(glassView)

        surfaceTintView.frame = flippedShell.bounds
        surfaceTintView.autoresizingMask = [.width, .height]
        surfaceTintView.wantsLayer = true
        flippedShell.addSubview(surfaceTintView)

        // 分组缩略图居中 + 环境阴影
        let iconHolder = NSView(frame: NSRect(x: floor((Self.cardWidth - 68) / 2), y: 22, width: 68, height: 68))
        iconHolder.wantsLayer = true
        iconHolder.layer?.shadowColor = NSColor.black.cgColor
        iconHolder.layer?.shadowOpacity = 0.28
        iconHolder.layer?.shadowRadius = 10
        iconHolder.layer?.shadowOffset = CGSize(width: 0, height: -4)
        let imageView = NSImageView(frame: iconHolder.bounds)
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        iconHolder.addSubview(imageView)
        flippedShell.addSubview(iconHolder)

        // 居中标题与副标题
        titleLabel.font = .systemFont(ofSize: 16.5, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 24, y: 98, width: Self.cardWidth - 48, height: 22)
        flippedShell.addSubview(titleLabel)

        subtitleLabel.stringValue = "输入新的分组名称，按回车确认"
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: 24, y: 122, width: Self.cardWidth - 48, height: 18)
        flippedShell.addSubview(subtitleLabel)

        // 定制圆角输入容器
        fieldContainer.frame = NSRect(x: 24, y: 152, width: Self.cardWidth - 48, height: 38)
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = 10
        fieldContainer.layer?.borderWidth = 1.5
        flippedShell.addSubview(fieldContainer)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = .labelColor
        field.alignment = .left
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        let fieldHeight: CGFloat = 20
        field.frame = NSRect(x: 12, y: floor((38 - fieldHeight) / 2), width: Self.cardWidth - 48 - 44, height: fieldHeight)
        fieldContainer.addSubview(field)

        // 右侧清空按钮
        clearButton.isBordered = false
        clearButton.title = ""
        let clearConfig = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清空名称")?.withSymbolConfiguration(clearConfig)
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearText)
        clearButton.frame = NSRect(x: fieldContainer.bounds.width - 28, y: 9, width: 20, height: 20)
        clearButton.isHidden = name.isEmpty
        fieldContainer.addSubview(clearButton)

        // 重名提示
        errorLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        errorLabel.textColor = .systemOrange
        errorLabel.alignment = .left
        errorLabel.frame = NSRect(x: 26, y: 195, width: Self.cardWidth - 52, height: 16)
        errorLabel.isHidden = true
        flippedShell.addSubview(errorLabel)

        // 底部双按钮
        cancelButton.onTap = { [weak self] in self?.cancel() }
        confirmButton.onTap = { [weak self] in self?.confirm() }
        flippedShell.addSubview(cancelButton)
        flippedShell.addSubview(confirmButton)

        // 玻璃外描边（不拦截事件）
        final class PassBorder: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
        let passBorder = PassBorder(frame: flippedShell.bounds)
        passBorder.autoresizingMask = [.width, .height]
        passBorder.addSubview(borderOverlay)
        borderOverlay.frame = passBorder.bounds
        borderOverlay.autoresizingMask = [.width, .height]
        borderOverlay.wantsLayer = true
        borderOverlay.layer?.cornerRadius = 18
        borderOverlay.layer?.borderWidth = 1
        flippedShell.addSubview(passBorder)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        glassView.material = isDark ? .hudWindow : .popover
        surfaceTintView.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.66)
            : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.76)).cgColor

        fieldContainer.layer?.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.86)).cgColor
        fieldContainer.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.85 : 0.75).cgColor

        borderOverlay.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.11)).cgColor

        cardWrapper.layer?.shadowOpacity = isDark ? 0.48 : 0.24
        cancelButton.updateAppearanceColors()
        confirmButton.updateAppearanceColors()
    }

    override func layout() {
        super.layout()
        let x = floor((bounds.width - Self.cardWidth) / 2)
        let y = floor((bounds.height - Self.cardHeight) / 2)
        cardWrapper.frame = NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
        cardWrapper.layer?.shadowPath = CGPath(roundedRect: cardWrapper.bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
    }

    func present() {
        layoutSubtreeIfNeeded()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        if let layer = cardWrapper.layer {
            let center = CGPoint(x: cardWrapper.bounds.midX, y: cardWrapper.bounds.midY)
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D: AnimationHelper.makeScaleTransform(scale: 0.94, center: center))
            anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            anim.duration = 0.20
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            layer.add(anim, forKey: "renamePresentScale")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func dismiss(result: String?) {
        guard !isClosing else { return }
        isClosing = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            onFinish?(result)
            return
        }
        if let layer = cardWrapper.layer {
            let center = CGPoint(x: cardWrapper.bounds.midX, y: cardWrapper.bounds.midY)
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            anim.toValue = NSValue(caTransform3D: AnimationHelper.makeScaleTransform(scale: 0.96, center: center))
            anim.duration = 0.14
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "renameDismissScale")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.onFinish?(result)
            }
        })
    }

    func controlTextDidChange(_ obj: Notification) {
        validateInput()
    }

    private func validateInput() {
        let raw = field.stringValue
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        clearButton.isHidden = raw.isEmpty

        if trimmed.isEmpty {
            errorLabel.isHidden = true
            confirmButton.isEnabled = false
        } else if trimmed != originalName && existingNames.contains(trimmed) {
            errorLabel.stringValue = "已存在名为“\(trimmed)”的分组"
            errorLabel.isHidden = false
            confirmButton.isEnabled = false
        } else {
            errorLabel.isHidden = true
            confirmButton.isEnabled = true
        }
    }

    @objc private func clearText() {
        field.stringValue = ""
        validateInput()
        window?.makeFirstResponder(field)
    }

    // 拦截点击背景遮罩退出，并阻止事件穿透到底层网格
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !cardWrapper.frame.contains(local) {
            cancel()
        }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    @objc func cancel() { dismiss(result: nil) }
    @objc func confirm() {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(trimmed != originalName && existingNames.contains(trimmed)) else {
            NSSound.beep()
            return
        }
        dismiss(result: trimmed)
    }
}

// MARK: - 单个应用图标项 (App Item View)
@MainActor final class AppItemView: NSView {
    private let iconImageView = NSImageView()
    var folderThumbnailFrame: CGRect {
        let frame = iconImageView.frame
        return frame.insetBy(dx: frame.width * 12 / 128, dy: frame.height * 12 / 128)
    }
    var currentIconImage: NSImage? { iconImageView.image }
    var iconFrameInSelf: NSRect { iconImageView.frame }
    var dropTargetRectInSelf: NSRect {
        iconImageView.frame.union(nameLabel.frame).insetBy(dx: -14, dy: -10)
    }
    private let mergePreviewBox = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private(set) var appRecord: AppRecord?
    private var onOpen: ((AppRecord, AppItemView) -> Void)?
    private var onCreateFolder: ((AppRecord) -> Void)?
    private var onMoveToFolder: ((AppRecord, String?) -> Void)?
    private var availableFolders: [String] = []
    var isInsideFolder = false
    private var isPressed = false
    private var isMergeHighlighted = false

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

        mergePreviewBox.wantsLayer = true
        mergePreviewBox.layer?.cornerRadius = 22
        mergePreviewBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        mergePreviewBox.layer?.borderWidth = 1.2
        mergePreviewBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.36).cgColor
        mergePreviewBox.alphaValue = 0
        mergePreviewBox.isHidden = true
        addSubview(mergePreviewBox)

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
        mergePreviewBox.frame = iconImageView.frame.insetBy(dx: -6, dy: -6)
        mergePreviewBox.layer?.cornerRadius = max(16, (iconSize + 12) * 0.24)
        nameLabel.frame = NSRect(x: 4, y: startY + iconSize + spacing, width: bounds.width - 8, height: labelHeight)
    }

    var highlightRect: NSRect {
        let iconFrame = iconImageView.frame
        let paddingX: CGFloat = 16
        let paddingTop: CGFloat = 10
        let paddingBottom: CGFloat = 10
        let width = min(bounds.width - 6, iconFrame.width + paddingX * 2)
        let top = max(2, iconFrame.minY - paddingTop)
        let bottom = min(bounds.height - 2, nameLabel.frame.maxY + paddingBottom)
        let x = floor((bounds.width - width) / 2)
        return NSRect(x: x, y: top, width: width, height: max(1, bottom - top))
    }

    func setDragSourceHidden(_ hidden: Bool) {
        alphaValue = hidden ? 0 : 1
    }

    func setMergeHighlighted(_ highlighted: Bool) {
        guard isMergeHighlighted != highlighted else { return }
        isMergeHighlighted = highlighted
        if highlighted { mergePreviewBox.isHidden = false }

        let center = CGPoint(x: iconImageView.bounds.midX, y: iconImageView.bounds.midY)
        let targetScale: CGFloat = highlighted ? 0.86 : 1.0
        let targetTransform = highlighted ? AnimationHelper.makeScaleTransform(scale: targetScale, center: center) : CATransform3DIdentity

        let boxCenter = CGPoint(x: mergePreviewBox.bounds.midX, y: mergePreviewBox.bounds.midY)
        let boxScale: CGFloat = highlighted ? 1.08 : 0.92
        let boxTransform = AnimationHelper.makeScaleTransform(scale: boxScale, center: boxCenter)

        let duration: CFTimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        let curve = CAMediaTimingFunction(name: .easeOut)
        if let iconLayer = iconImageView.layer {
            LauncherTransition.set(iconLayer, keyPath: "transform", value: NSValue(caTransform3D: targetTransform), duration: duration, curve: curve)
        }
        if let boxLayer = mergePreviewBox.layer {
            LauncherTransition.set(boxLayer, keyPath: "transform", value: NSValue(caTransform3D: boxTransform), duration: duration, curve: curve)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve
            mergePreviewBox.animator().alphaValue = highlighted ? 1 : 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isMergeHighlighted else { return }
                self.mergePreviewBox.isHidden = true
            }
        })
    }

    func configure(app: AppRecord, icon: NSImage, onOpen: @escaping (AppRecord, AppItemView) -> Void) {
        self.appRecord = app
        self.onOpen = onOpen
        nameLabel.stringValue = app.name
        iconImageView.image = icon
    }

    func configureFolderActions(names: [String], onCreate: @escaping (AppRecord) -> Void, onMove: @escaping (AppRecord, String?) -> Void) {
        availableFolders = names
        onCreateFolder = onCreate
        onMoveToFolder = onMove
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let appRecord else { return nil }
        let menu = NSMenu()
        if !appRecord.path.hasPrefix("chu-folder:") {
            if !isInsideFolder {
                let create = menu.addItem(withTitle: "新建分组", action: #selector(createFolderFromMenu), keyEquivalent: "")
                create.target = self
                MenuSymbols.apply("folder.badge.plus", to: create)
            }

            let move = menu.addItem(withTitle: "移至分组", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let ungroup = submenu.addItem(withTitle: "无分组", action: #selector(moveToUngrouped), keyEquivalent: "")
            ungroup.target = self
            if appRecord.folder == nil { ungroup.state = .on }
            for name in availableFolders {
                let item = submenu.addItem(withTitle: name, action: #selector(moveToNamedFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                if appRecord.folder == name { item.state = .on }
            }
            move.submenu = submenu
            menu.addItem(.separator())
        } else {
            let rename = menu.addItem(withTitle: "重命名分组", action: #selector(renameFolderFromMenu), keyEquivalent: "")
            rename.target = self
            MenuSymbols.apply("pencil", to: rename)
            menu.addItem(.separator())
        }
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

    @objc private func createFolderFromMenu() { if let appRecord { onCreateFolder?(appRecord) } }
    @objc private func moveToUngrouped() { if let appRecord { onMoveToFolder?(appRecord, nil) } }
    @objc private func moveToNamedFolder(_ sender: NSMenuItem) {
        if let appRecord, let name = sender.representedObject as? String { onMoveToFolder?(appRecord, name) }
    }
    @objc private func renameFolderFromMenu() {
        guard let appRecord, appRecord.path.hasPrefix("chu-folder:") else { return }
        onMoveToFolder?(appRecord, "rename:")
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
            if appRecord.path.hasPrefix("chu-folder:"), nameLabel.frame.contains(point) {
                renameFolderFromMenu()
                return
            }
            onOpen?(appRecord, self)
        }
    }

    func cancelPress() {
        guard isPressed else { return }
        isPressed = false
        animatePress(down: false)
    }

    func consumeMouseUpAfterDrag() {
        isPressed = false
        iconImageView.alphaValue = 1
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
    private let hoverHighlightView = FlippedContainerView()
    private let hoverImageLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private weak var hoveredItem: AppItemView?
    private var lastHoverPoint: NSPoint?
    private var hoverDisplayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval = 0
    private var hoverLeadCenter: CGPoint = .zero
    private var hoverTrailCenter: CGPoint = .zero
    private var hoverTargetCenter: CGPoint = .zero
    private var hoverSize: CGSize = .zero
    private var hoverTargetSize: CGSize = .zero
    private var hoverCurrentOpacity: Float = 0
    private var hoverTargetOpacity: Float = 0
    private let hoverMaxOpacity: Float = 0.16
    var columns = 7
    var rows = 5
    var onBlankAreaClicked: (() -> Void)?
    var onBlankDragStart: ((NSEvent) -> Void)?
    var onBlankDragMove: ((NSEvent) -> Void)?
    var onBlankDragEnd: ((NSEvent) -> Void)?
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
        hoverHighlightView.wantsLayer = true
        hoverHighlightView.frame = bounds
        hoverHighlightView.autoresizingMask = [.width, .height]
        hoverHighlightView.layer?.masksToBounds = false
        hoverHighlightView.layer?.opacity = 0

        hoverImageLayer.contentsGravity = .resize
        hoverHighlightView.layer?.addSublayer(hoverImageLayer)
        addSubview(hoverHighlightView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopHoverDisplayLink()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    func populate(apps: [AppRecord], folders: [String: [AppRecord]], iconCache: NSCache<NSString, NSImage>, onOpen: @escaping (AppRecord, AppItemView) -> Void, onCreateFolder: @escaping (AppRecord) -> Void = { _ in }, onMoveToFolder: @escaping (AppRecord, String?) -> Void = { _, _ in }) {
        for sub in itemViews { sub.removeFromSuperview() }
        itemViews.removeAll()
        hoveredItem = nil
        lastHoverPoint = nil
        stopHoverDisplayLink()
        hoverCurrentOpacity = 0
        hoverTargetOpacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverImageLayer.contents = nil
        hoverHighlightView.layer?.opacity = 0
        CATransaction.commit()
        if hoverHighlightView.superview !== self {
            addSubview(hoverHighlightView)
        }

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
            let names = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            itemView.configureFolderActions(names: names, onCreate: onCreateFolder, onMove: onMoveToFolder)
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

    static func folderIcon(apps: [AppRecord], iconCache: NSCache<NSString, NSImage>) -> NSImage {
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
        if let hoveredItem, hoverDisplayLink == nil {
            let targetFrame = targetHighlightFrame(for: hoveredItem)
            hoverTargetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            hoverLeadCenter = hoverTargetCenter
            hoverTrailCenter = hoverTargetCenter
            hoverSize = targetFrame.size
            hoverTargetSize = targetFrame.size
            updateHoverLayers()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point, windowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point, windowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        clearHover(animated: true, exitPoint: point)
        lastHoverPoint = nil
    }

    func clearHover(animated: Bool = false, exitPoint: NSPoint? = nil) {
        guard let oldItem = hoveredItem else {
            if !animated {
                stopHoverDisplayLink()
                hoverCurrentOpacity = 0
                hoverTargetOpacity = 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hoverImageLayer.contents = nil
                hoverHighlightView.layer?.opacity = 0
                CATransaction.commit()
            }
            return
        }
        hoveredItem = nil
        let baseFrame = targetHighlightFrame(for: oldItem)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopHoverDisplayLink()
            hoverCurrentOpacity = 0
            hoverTargetOpacity = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverImageLayer.contents = nil
            hoverHighlightView.layer?.opacity = 0
            CATransaction.commit()
            return
        }
        let targetPoint = exitPoint ?? lastHoverPoint ?? NSPoint(x: oldItem.frame.midX, y: oldItem.frame.midY)
        let offset = directionalOffset(from: NSPoint(x: oldItem.frame.midX, y: oldItem.frame.midY), to: targetPoint, magnitude: 42)
        hoverTargetCenter = CGPoint(x: baseFrame.midX + offset.x, y: baseFrame.midY + offset.y)
        hoverTargetSize = baseFrame.size
        hoverTargetOpacity = 0
        startHoverDisplayLink()
    }

    private func updateHover(at point: NSPoint, windowPoint: NSPoint) {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              let hit = window.contentView?.hitTest(windowPoint), hit.isDescendant(of: self) else {
            clearHover(animated: true, exitPoint: point)
            lastHoverPoint = nil
            return
        }

        let targetItem = itemViews.first { $0.frame.contains(point) }
        guard let targetItem else {
            clearHover(animated: true, exitPoint: point)
            lastHoverPoint = point
            return
        }

        if targetItem === hoveredItem {
            lastHoverPoint = point
            return
        }

        let targetFrame = targetHighlightFrame(for: targetItem)
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let previousItem = hoveredItem
        hoveredItem = targetItem

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopHoverDisplayLink()
            hoverLeadCenter = targetCenter
            hoverTrailCenter = targetCenter
            hoverTargetCenter = targetCenter
            hoverSize = targetFrame.size
            hoverTargetSize = targetFrame.size
            hoverCurrentOpacity = hoverMaxOpacity
            hoverTargetOpacity = hoverMaxOpacity
            updateHoverLayers()
            lastHoverPoint = point
            return
        }

        hoverTargetCenter = targetCenter
        hoverTargetSize = targetFrame.size
        hoverTargetOpacity = hoverMaxOpacity

        if previousItem == nil && hoverCurrentOpacity <= 0.01 {
            // 首次进入：尾部从鼠标进入方向伸展粘附过来
            let center = NSPoint(x: targetItem.frame.midX, y: targetItem.frame.midY)
            let fromPoint = lastHoverPoint ?? point
            let offset: NSPoint
            if lastHoverPoint != nil, hypot(point.x - fromPoint.x, point.y - fromPoint.y) > 1 {
                offset = directionalOffset(from: point, to: fromPoint, magnitude: 30)
            } else {
                offset = directionalOffset(from: center, to: point, magnitude: 30)
            }
            hoverLeadCenter = targetCenter
            hoverTrailCenter = CGPoint(x: targetCenter.x + offset.x, y: targetCenter.y + offset.y)
            hoverSize = targetFrame.size
            hoverCurrentOpacity = 0.01
            updateHoverLayers()
        }
        startHoverDisplayLink()
        lastHoverPoint = point
    }

    private func startHoverDisplayLink() {
        if hoverDisplayLink == nil {
            lastDisplayTimestamp = 0
            let link = displayLink(target: self, selector: #selector(stepHoverAnimation(_:)))
            link.add(to: .main, forMode: .common)
            hoverDisplayLink = link
        }
    }

    private func stopHoverDisplayLink() {
        hoverDisplayLink?.invalidate()
        hoverDisplayLink = nil
        lastDisplayTimestamp = 0
    }

    @objc private func stepHoverAnimation(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CGFloat = lastDisplayTimestamp == 0 ? (1.0 / 60.0) : CGFloat(min(0.05, max(0.001, now - lastDisplayTimestamp)))
        lastDisplayTimestamp = now

        let leadAlpha = 1 - exp(-22.0 * dt)
        hoverLeadCenter.x += (hoverTargetCenter.x - hoverLeadCenter.x) * leadAlpha
        hoverLeadCenter.y += (hoverTargetCenter.y - hoverLeadCenter.y) * leadAlpha

        // 粘滞跟随 + 最大拉丝距离限制，确保毒液颈部不断裂
        let trailAlpha = 1 - exp(-10.5 * dt)
        hoverTrailCenter.x += (hoverTargetCenter.x - hoverTrailCenter.x) * trailAlpha
        hoverTrailCenter.y += (hoverTargetCenter.y - hoverTrailCenter.y) * trailAlpha

        let maxSep = min(hoverSize.width, hoverSize.height) * 1.05
        let dx = hoverTrailCenter.x - hoverLeadCenter.x
        let dy = hoverTrailCenter.y - hoverLeadCenter.y
        let sep = hypot(dx, dy)
        if sep > maxSep && maxSep > 1 {
            hoverTrailCenter.x = hoverLeadCenter.x + dx / sep * maxSep
            hoverTrailCenter.y = hoverLeadCenter.y + dy / sep * maxSep
        }

        let sizeAlpha = 1 - exp(-18.0 * dt)
        hoverSize.width += (hoverTargetSize.width - hoverSize.width) * sizeAlpha
        hoverSize.height += (hoverTargetSize.height - hoverSize.height) * sizeAlpha

        let opacityAlpha = 1 - exp(-16.0 * dt)
        hoverCurrentOpacity += (hoverTargetOpacity - hoverCurrentOpacity) * Float(opacityAlpha)

        let leadDone = hypot(hoverTargetCenter.x - hoverLeadCenter.x, hoverTargetCenter.y - hoverLeadCenter.y) < 0.4
        let trailDone = hypot(hoverTargetCenter.x - hoverTrailCenter.x, hoverTargetCenter.y - hoverTrailCenter.y) < 0.4
        let opacityDone = abs(hoverTargetOpacity - hoverCurrentOpacity) < 0.004

        if leadDone && trailDone && opacityDone {
            hoverLeadCenter = hoverTargetCenter
            hoverTrailCenter = hoverTargetCenter
            hoverSize = hoverTargetSize
            hoverCurrentOpacity = hoverTargetOpacity
            updateHoverLayers()
            stopHoverDisplayLink()
            return
        }

        updateHoverLayers()
    }

    private func updateHoverLayers() {
        let dist = hypot(hoverLeadCenter.x - hoverTrailCenter.x, hoverLeadCenter.y - hoverTrailCenter.y)
        let isGooey = dist >= 0.8
        let s = min(1.0, dist / max(1, min(hoverSize.width, hoverSize.height)))
        let trailScale: CGFloat = isGooey ? (1.0 - 0.16 * s) : 1.0
        let leadScale: CGFloat = isGooey ? (1.0 - 0.04 * s) : 1.0

        let trailRect = CGRect(
            x: hoverTrailCenter.x - (hoverSize.width * trailScale) / 2,
            y: hoverTrailCenter.y - (hoverSize.height * trailScale) / 2,
            width: hoverSize.width * trailScale,
            height: hoverSize.height * trailScale
        )
        let leadRect = CGRect(
            x: hoverLeadCenter.x - (hoverSize.width * leadScale) / 2,
            y: hoverLeadCenter.y - (hoverSize.height * leadScale) / 2,
            width: hoverSize.width * leadScale,
            height: hoverSize.height * leadScale
        )

        let scale = window?.backingScaleFactor ?? 2.0
        let blurT = min(1.0, dist / 42.0)
        let effectiveBlur = max(0.5, 14.0 * blurT * blurT * (3.0 - 2.0 * blurT))
        if isGooey, let rendered = GooeyRenderer.render(
            trailRect: trailRect,
            leadRect: leadRect,
            cornerRadius: 20,
            blurRadius: effectiveBlur,
            scale: scale,
            isFlipped: true
        ) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverHighlightView.layer?.opacity = hoverCurrentOpacity
            hoverImageLayer.backgroundColor = nil
            hoverImageLayer.cornerRadius = 0
            hoverImageLayer.frame = rendered.frame
            hoverImageLayer.contents = rendered.image
            hoverImageLayer.contentsScale = scale
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverHighlightView.layer?.opacity = hoverCurrentOpacity
            hoverImageLayer.contents = nil
            hoverImageLayer.backgroundColor = NSColor.white.cgColor
            hoverImageLayer.cornerRadius = 20
            hoverImageLayer.frame = leadRect
            CATransaction.commit()
        }
    }

    private func targetHighlightFrame(for itemView: AppItemView) -> NSRect {
        itemView.layoutSubtreeIfNeeded()
        let local = itemView.highlightRect
        return convert(local, from: itemView)
    }

    private func directionalOffset(from origin: NSPoint, to target: NSPoint, magnitude: CGFloat) -> NSPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return .zero }
        return NSPoint(x: dx / length * magnitude, y: dy / length * magnitude)
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
    var onScrollProgressChanged: ((CGFloat) -> Void)?
    var onOpenApp: ((AppRecord, AppItemView) -> Void)?
    var onCreateFolder: ((AppRecord) -> Void)?
    var onMoveToFolder: ((AppRecord, String?) -> Void)?
    var onBlankAreaClicked: (() -> Void)?
    var isInsideFolder = false

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

    func reloadPages(apps: [AppRecord], folders: [String: [AppRecord]], iconCache: NSCache<NSString, NSImage>, targetPage: Int = 0, onCreateFolder: @escaping (AppRecord) -> Void = { _ in }, onMoveToFolder: @escaping (AppRecord, String?) -> Void = { _, _ in }) {
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
            pageView.populate(apps: pageApps, folders: folders, iconCache: iconCache, onOpen: { [weak self] app, itemView in
                self?.onOpenApp?(app, itemView)
            }, onCreateFolder: onCreateFolder, onMoveToFolder: onMoveToFolder)
            for item in pageView.items { item.isInsideFolder = isInsideFolder }
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

    /// 命中当前页上可合并为目录的目标应用/目录视图（同时检测指针位置与拖拽图标中心）
    func hitTestDropTarget(atWindowPoints points: [NSPoint], excludingPath: String) -> AppItemView? {
        guard pageViews.indices.contains(currentPage), let referencePoint = points.first else { return nil }
        var bestMatch: AppItemView?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for itemView in pageViews[currentPage].items {
            guard let record = itemView.appRecord, record.path != excludingPath else { continue }
            itemView.layoutSubtreeIfNeeded()
            let iconFrame = itemView.iconFrameInSelf
            let hitRect = iconFrame.insetBy(dx: -iconFrame.width * 0.08, dy: -iconFrame.height * 0.08)
            let matched = points.contains { pt in
                hitRect.contains(itemView.convert(pt, from: nil))
            }
            if matched {
                let localRef = itemView.convert(referencePoint, from: nil)
                let dist = hypot(localRef.x - itemView.iconFrameInSelf.midX, localRef.y - itemView.iconFrameInSelf.midY)
                if dist < bestDistance {
                    bestDistance = dist
                    bestMatch = itemView
                }
            }
        }
        return bestMatch
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

    func clearHover() {
        for pageView in pageViews {
            pageView.clearHover(animated: false)
        }
    }

    // MARK: - 翻页与平滑滑动动画
    func scrollToPage(_ index: Int, animated: Bool = true) {
        guard index >= 0, index < pageCount else { return }
        clearHover()
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
        clearHover()
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
        let progress = max(0, min(CGFloat(pageCount - 1), -position / max(1, bounds.width)))
        onScrollProgressChanged?(progress)
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
            clearHover()
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
            let progress = max(0, min(CGFloat(pageCount - 1), -finalX / max(1, screenWidth)))
            onScrollProgressChanged?(progress)

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
    private let inactiveDiameter: CGFloat = 6
    private let activeWidth: CGFloat = 14
    private let activeHeight: CGFloat = 8

    private var dotLayers: [CALayer] = []
    private let activeLayer = CALayer()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var leadX: CGFloat = 0
    private var trailX: CGFloat = 0
    private var targetX: CGFloat = 0
    private var hasPositioned = false
    private var isDraggingProgress = false

    var current = 0 {
        didSet {
            let clamped = max(0, min(max(0, count - 1), current))
            if clamped != current {
                current = clamped
                return
            }
            if oldValue != current || isDraggingProgress {
                isDraggingProgress = false
                updateActiveDot(animated: true)
            }
        }
    }
    var count = 1 {
        didSet {
            isHidden = (count <= 1)
            if oldValue != count {
                rebuildDots()
            }
        }
    }
    var onSelect: ((Int) -> Void)?

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
        activeLayer.contentsGravity = .resize
        layer?.addSublayer(activeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        }
    }

    private static func effectiveSpacing(count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return 18 }
        let maxTotal = max(1, width - 16)
        return min(18, maxTotal / CGFloat(count - 1))
    }

    private func dotCenterX(for index: CGFloat) -> CGFloat {
        let spacing = Self.effectiveSpacing(count: count, width: bounds.width)
        let totalSpan = CGFloat(max(0, count - 1)) * spacing
        let startCenterX = bounds.midX - totalSpan / 2
        return startCenterX + index * spacing
    }

    private func rebuildDots() {
        for dot in dotLayers { dot.removeFromSuperlayer() }
        dotLayers.removeAll()
        stopDisplayLink()
        hasPositioned = false
        isDraggingProgress = false

        guard count > 1, let rootLayer = layer else {
            activeLayer.isHidden = true
            return
        }
        activeLayer.isHidden = false

        for _ in 0..<count {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.38).cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: inactiveDiameter, height: inactiveDiameter)
            dot.cornerRadius = inactiveDiameter / 2
            rootLayer.insertSublayer(dot, below: activeLayer)
            dotLayers.append(dot)
        }
        layoutDots()
        updateActiveDot(animated: false)
    }

    private func layoutDots() {
        guard count > 1 else { return }
        let centerY = bounds.midY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dotLayers.enumerated() {
            dot.position = CGPoint(x: dotCenterX(for: CGFloat(index)), y: centerY)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutDots()
        if displayLink == nil && !isDraggingProgress {
            updateActiveDot(animated: false)
        }
    }

    func setProgress(_ progress: CGFloat) {
        guard count > 1, bounds.width > 0 else { return }
        stopDisplayLink()
        isDraggingProgress = true
        let clamped = max(0, min(CGFloat(count - 1), progress))
        let cx = dotCenterX(for: clamped)
        let frac = clamped - floor(clamped)
        let spacing = Self.effectiveSpacing(count: count, width: bounds.width)
        let pull = sin(frac * .pi) * (spacing * 0.45)
        let dir: CGFloat = (cx >= leadX) ? 1 : -1
        leadX = cx + dir * pull * 0.35
        trailX = cx - dir * pull * 0.65
        targetX = cx
        hasPositioned = true
        updateActiveShapePath()
    }

    private func updateActiveDot(animated: Bool) {
        guard count > 1, bounds.width > 0 else { return }
        let targetIndex = max(0, min(count - 1, current))
        let toX = dotCenterX(for: CGFloat(targetIndex))

        guard animated,
              hasPositioned,
              !isHidden,
              let window, window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopDisplayLink()
            leadX = toX
            trailX = toX
            targetX = toX
            hasPositioned = true
            updateActiveShapePath()
            return
        }

        targetX = toX
        if abs(targetX - leadX) < 0.3 && abs(targetX - trailX) < 0.3 {
            stopDisplayLink()
            leadX = toX
            trailX = toX
            updateActiveShapePath()
            return
        }
        startDisplayLink()
    }

    private func startDisplayLink() {
        if displayLink == nil {
            lastTimestamp = 0
            let link = displayLink(target: self, selector: #selector(stepAnimation(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    @objc private func stepAnimation(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CGFloat = lastTimestamp == 0 ? (1.0 / 60.0) : CGFloat(min(0.05, max(0.001, now - lastTimestamp)))
        lastTimestamp = now

        let leadAlpha = 1 - exp(-24.0 * dt)
        leadX += (targetX - leadX) * leadAlpha

        let trailAlpha = 1 - exp(-11.0 * dt)
        trailX += (targetX - trailX) * trailAlpha

        let spacing = Self.effectiveSpacing(count: count, width: bounds.width)
        let maxSep = spacing * 0.95
        if abs(leadX - trailX) > maxSep {
            trailX = leadX + (trailX > leadX ? maxSep : -maxSep)
        }

        if abs(targetX - leadX) < 0.25 && abs(targetX - trailX) < 0.25 {
            leadX = targetX
            trailX = targetX
            updateActiveShapePath()
            stopDisplayLink()
            return
        }
        updateActiveShapePath()
    }

    private func updateActiveShapePath() {
        let centerY = bounds.midY
        let dist = abs(leadX - trailX)
        let isGooey = dist >= 0.6
        let spacing = Self.effectiveSpacing(count: count, width: bounds.width)
        let s = min(1.0, dist / max(1, spacing))
        let trailScale: CGFloat = isGooey ? (1.0 - 0.18 * s) : 1.0
        let leadScale: CGFloat = isGooey ? (1.0 - 0.05 * s) : 1.0

        let trailW = activeWidth * trailScale
        let trailH = activeHeight * trailScale
        let leadW = activeWidth * leadScale
        let leadH = activeHeight * leadScale

        let trailRect = CGRect(x: trailX - trailW / 2, y: centerY - trailH / 2, width: trailW, height: trailH)
        let leadRect = CGRect(x: leadX - leadW / 2, y: centerY - leadH / 2, width: leadW, height: leadH)
        let scale = window?.backingScaleFactor ?? 2.0
        let blurT = min(1.0, dist / max(1, spacing * 0.7))
        let effectiveBlur = max(0.3, 3.5 * blurT * blurT * (3.0 - 2.0 * blurT))

        if isGooey, let rendered = GooeyRenderer.render(
            trailRect: trailRect,
            leadRect: leadRect,
            cornerRadius: activeHeight / 2,
            blurRadius: effectiveBlur,
            scale: scale,
            isFlipped: false
        ) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            activeLayer.backgroundColor = nil
            activeLayer.cornerRadius = 0
            activeLayer.frame = rendered.frame
            activeLayer.contents = rendered.image
            activeLayer.contentsScale = scale
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            activeLayer.contents = nil
            activeLayer.backgroundColor = NSColor.white.cgColor
            activeLayer.cornerRadius = activeHeight / 2
            activeLayer.frame = leadRect
            CATransaction.commit()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard count > 1 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let spacing = Self.effectiveSpacing(count: count, width: bounds.width)
        let startCenterX = dotCenterX(for: 0)
        let index = Int(((x - startCenterX) / spacing).rounded())
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
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let panel, panel.frame.contains(point) { return }
        onDismiss?(point)
    }
}

@MainActor final class FolderOverlayController {
    enum State { case closed, opening, opened, closing }
    let appearance = FolderAppearance.load()
    let root = FolderBackdropView()
    let panel = NSView()
    let title = NSTextField(labelWithString: "")
    let searchCapsule = SearchCapsuleView(frame: .zero)
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
        searchCapsule.wantsLayer = true
        searchCapsule.setPlaceholder("搜索当前目录")
        indicator.wantsLayer = true
        pages.columns = 6
        pages.rows = 3
        pages.layer?.masksToBounds = true
        panel.addSubview(title)
        panel.addSubview(searchCapsule)
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
        for layer in [pages.layer, title.layer, searchCapsule.layer, indicator.layer].compactMap({ $0 }) {
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
        guard ["\(DockPin.appDisplayName).app", "ChuLaunchAgent.app"].contains(agent.lastPathComponent), agent.deletingLastPathComponent().lastPathComponent == "Helpers" else { return }
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
        guard let version = installedVersion(outer, identifier: DockPin.bundleID),
              version != runningVersion,
              installedVersion(agent, identifier: DockPin.agentBundleID) == version
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
    private var renamePanel: FolderRenameView?
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
    private var folderSearchCapsule: SearchCapsuleView { folderOverlay.searchCapsule }
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
    private var appDragMonitor: Any?
    private weak var draggingItemView: AppItemView?
    private var draggingApp: AppRecord?
    private var dragFloatingView: NSImageView?
    private var dragPointerOffset: NSPoint = .zero
    private weak var dropTargetItemView: AppItemView?
    private var edgePageTimer: Timer?
    private var edgePageDirection = 0
    private weak var launchingItem: AppItemView?
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

    private var dockTogglePort: CFMessagePort?
    private var wallpaperFileSource: DispatchSourceFileSystemObject?
    private var watchedWallpaper: URL?

    private func watchWallpaperFile(_ url: URL?) {
        guard watchedWallpaper != url else { return }
        wallpaperFileSource?.cancel()
        wallpaperFileSource = nil
        watchedWallpaper = nil
        guard let url else { return }
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, self.watchedWallpaper == url else { return }
            self.watchWallpaperFile(nil)
            self.refreshVisibleWallpaper()
        }
        watchedWallpaper = url
        wallpaperFileSource = source
        source.resume()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleFromDock(_:)),
            name: Notification.Name(DockPin.toggleNotification), object: nil, suspensionBehavior: .deliverImmediately)
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
        pagedContainer.onScrollProgressChanged = { [weak self] progress in
            self?.pageIndicator.setProgress(progress)
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
            self.folderSearchCapsule.stringValue = ""
            self.updateMoreButton()
            self.displayed = self.folderMainItems
            let query = self.pendingQuery ?? self.searchCapsule.stringValue
            self.pendingQuery = nil
            self.filter(query: query, targetPage: self.pagedContainer.currentPage)
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            if self.window.isVisible, self.settingsPanel == nil {
                self.searchCapsule.makeFirstResponder()
            }
        }
        folderSearchCapsule.onQueryChanged = { [weak self] query in
            self?.filterFolder(query: query)
        }
        folderSearchCapsule.onEscapePressed = { [weak self] in
            guard let self else { return }
            if !self.folderSearchCapsule.stringValue.isEmpty {
                self.folderSearchCapsule.stringValue = ""
            } else {
                self.closeFolder()
            }
        }
        folderPages.isInsideFolder = true
        folderPages.onOpenApp = { [weak self] app, itemView in self?.open(app, from: itemView) }
        folderPages.onBlankAreaClicked = { [weak self] in self?.closeFolder() }
        folderPages.onPageChanged = { [weak self] page in self?.folderIndicator.current = page }
        folderPages.onScrollProgressChanged = { [weak self] progress in self?.folderIndicator.setProgress(progress) }
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
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        dockTogglePort = CFMessagePortCreateLocal(nil, DockPin.togglePortName(for: Bundle.main.bundleURL), { _, _, _, info in
            guard let info else { return nil }
            MainActor.assumeIsolated {
                Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().handleDockToggle()
            }
            return nil
        }, &context, nil)
        if let dockTogglePort {
            CFMessagePortSetDispatchQueue(dockTogglePort, .main)
        }
        backgroundView.wallpaperURLChanged = { [weak self] in self?.watchWallpaperFile($0) }
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
        } else {
            refreshVisibleWallpaper()
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
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 6), in: moreButton)
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
        handleDockToggle()
    }

    private func handleDockToggle() {
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
        let quit = appMenu.addItem(withTitle: "退出 \(DockPin.appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            guard let self else { return event }
            if event.type == .leftMouseUp, self.draggingApp != nil {
                self.pointerDown = nil
                self.pointerDragging = false
                self.endAppDrag(event: event)
                return nil
            }
            guard event.window === self.window, self.window.isVisible, self.settingsPanel == nil, self.renamePanel == nil, !self.isLaunching else { return event }
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
                    if let item = self.pointerItem,
                       let app = item.appRecord,
                       (self.openFolder != nil || self.searchCapsule.stringValue.isEmpty),
                       !app.path.hasPrefix("chu-folder:") {
                        self.beginAppDrag(item: item, app: app, downEvent: down, currentEvent: event)
                    } else {
                        self.activePages.beginMouseDrag(down)
                    }
                }
                if self.pointerDragging {
                    if self.draggingApp != nil {
                        self.updateAppDrag(event: event)
                    } else {
                        self.activePages.moveMouseDrag(event)
                    }
                    return nil
                }
                return event
            case .leftMouseUp:
                if self.draggingApp != nil {
                    self.pointerDown = nil
                    self.pointerDragging = false
                    self.pointerItem?.consumeMouseUpAfterDrag()
                    self.endAppDrag(event: event)
                    return nil
                }
                guard let down = self.pointerDown else { return event }
                if !self.pointerDragging, self.openFolder != nil {
                    let downPoint = self.folderTitle.convert(down.locationInWindow, from: nil)
                    let upPoint = self.folderTitle.convert(event.locationInWindow, from: nil)
                    let width = min(self.folderTitle.bounds.width, self.folderTitle.intrinsicContentSize.width + 16)
                    let titleRect = NSRect(x: self.folderTitle.bounds.midX - width / 2, y: 0, width: width, height: self.folderTitle.bounds.height)
                    if titleRect.contains(downPoint) && titleRect.contains(upPoint) {
                        self.pointerDown = nil
                        self.renameOpenFolder()
                        return nil
                    }
                }
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

            if let panel = self.renamePanel {
                if event.keyCode == 53 { panel.cancel(); return nil }
                if event.keyCode == 36 { panel.confirm(); return nil }
                return event
            }
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
                if self.openFolder != nil {
                    if !self.folderSearchCapsule.stringValue.isEmpty {
                        self.folderSearchCapsule.stringValue = ""
                    } else {
                        self.closeFolder()
                    }
                } else if !self.searchCapsule.stringValue.isEmpty {
                    self.searchCapsule.stringValue = ""
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
            // 左右方向键翻页（当前搜索框为空时）
            let activeQueryEmpty = self.openFolder == nil ? self.searchCapsule.stringValue.isEmpty : self.folderSearchCapsule.stringValue.isEmpty
            if event.keyCode == 123 && activeQueryEmpty {
                self.activePages.previousPage()
                return nil
            }
            if event.keyCode == 124 && activeQueryEmpty {
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

    // MARK: - 应用拖拽合并目录 (Drag-to-Folder & Edge Auto-Paging)
    private func beginAppDrag(item: AppItemView, app: AppRecord, downEvent: NSEvent, currentEvent: NSEvent) {
        cancelAppDrag()
        draggingItemView = item
        draggingApp = app

        let downPointInBg = backgroundView.convert(downEvent.locationInWindow, from: nil)
        let iconFrameInBg = item.convert(item.iconFrameInSelf, to: backgroundView)
        dragPointerOffset = NSPoint(x: downPointInBg.x - iconFrameInBg.midX, y: downPointInBg.y - iconFrameInBg.midY)

        let floating = NSImageView(frame: iconFrameInBg)
        floating.image = item.currentIconImage
        floating.imageScaling = .scaleProportionallyUpOrDown
        floating.wantsLayer = true
        floating.layer?.shadowColor = NSColor.black.cgColor
        floating.layer?.shadowOpacity = 0.38
        floating.layer?.shadowRadius = 12
        floating.layer?.shadowOffset = CGSize(width: 0, height: -4)

        backgroundView.addSubview(floating, positioned: openFolder == nil ? .below : .above, relativeTo: folderBackdrop)
        if let layer = floating.layer {
            let center = CGPoint(x: floating.bounds.midX, y: floating.bounds.midY)
            let scale = AnimationHelper.makeScaleTransform(scale: 1.08, center: center)
            LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: scale), duration: 0.12, curve: CAMediaTimingFunction(name: .easeOut))
        }
        dragFloatingView = floating
        item.setDragSourceHidden(true)

        updateAppDrag(event: currentEvent)
    }

    private func currentDropCandidate(windowPoint: NSPoint, draggedPath: String) -> AppItemView? {
        var points: [NSPoint] = []
        if let floating = dragFloatingView {
            let centerInBg = NSPoint(x: floating.frame.midX, y: floating.frame.midY)
            let centerInWindow = backgroundView.convert(centerInBg, to: nil)
            points.append(centerInWindow)
        }
        points.append(windowPoint)
        return pagedContainer.hitTestDropTarget(atWindowPoints: points, excludingPath: draggedPath)
    }

    private func updateAppDrag(event: NSEvent) {
        guard let floating = dragFloatingView, let dragged = draggingApp else { return }
        let pointInBg = backgroundView.convert(event.locationInWindow, from: nil)
        let newOrigin = NSPoint(
            x: pointInBg.x - dragPointerOffset.x - floating.bounds.width / 2,
            y: pointInBg.y - dragPointerOffset.y - floating.bounds.height / 2
        )
        floating.setFrameOrigin(newOrigin)

        if openFolder != nil { return }

        // 边缘自动翻页检测
        let edgeMargin: CGFloat = 56
        if pointInBg.x <= edgeMargin && pagedContainer.currentPage > 0 {
            scheduleEdgePageTurn(direction: -1, event: event)
        } else if pointInBg.x >= backgroundView.bounds.width - edgeMargin && pagedContainer.currentPage + 1 < pagedContainer.pageCount {
            scheduleEdgePageTurn(direction: 1, event: event)
        } else {
            cancelEdgePageTurn()
        }

        // 目标应用 / 目录命中检测（同时覆盖图标中心与指针位置）
        let candidate = currentDropCandidate(windowPoint: event.locationInWindow, draggedPath: dragged.path)
        if candidate !== dropTargetItemView {
            dropTargetItemView?.setMergeHighlighted(false)
            dropTargetItemView = candidate
            dropTargetItemView?.setMergeHighlighted(true)
        }
    }

    private func scheduleEdgePageTurn(direction: Int, event: NSEvent) {
        if edgePageDirection == direction && edgePageTimer != nil { return }
        cancelEdgePageTurn()
        edgePageDirection = direction
        let windowPoint = event.locationInWindow
        edgePageTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.draggingApp != nil else { return }
                self.edgePageTimer = nil
                self.edgePageDirection = 0
                if direction < 0 {
                    self.pagedContainer.previousPage()
                } else {
                    self.pagedContainer.nextPage()
                }
                self.dropTargetItemView?.setMergeHighlighted(false)
                if let dragged = self.draggingApp {
                    let candidate = self.currentDropCandidate(windowPoint: windowPoint, draggedPath: dragged.path)
                    self.dropTargetItemView = candidate
                    candidate?.setMergeHighlighted(true)
                }
            }
        }
    }

    private func cancelEdgePageTurn() {
        edgePageTimer?.invalidate()
        edgePageTimer = nil
        edgePageDirection = 0
    }

    private func endAppDrag(event: NSEvent) {
        cancelEdgePageTurn()
        guard let dragged = draggingApp else {
            cancelAppDrag()
            return
        }

        if openFolder != nil {
            let point = folderPanel.convert(event.locationInWindow, from: nil)
            if !folderPanel.bounds.contains(point) {
                cancelAppDrag()
                move(dragged, to: nil)
            } else {
                cancelAppDrag()
            }
            return
        }

        let targetView = dropTargetItemView ?? currentDropCandidate(windowPoint: event.locationInWindow, draggedPath: dragged.path)
        let targetApp = targetView?.appRecord
        targetView?.setMergeHighlighted(false)
        dropTargetItemView = nil

        if let targetView, let targetApp, let floating = dragFloatingView {
            let targetFrameInBg = targetView.convert(targetView.iconFrameInSelf, to: backgroundView)
            draggingApp = nil
            draggingItemView = nil
            dragFloatingView = nil

            if let layer = floating.layer {
                let center = CGPoint(x: floating.bounds.midX, y: floating.bounds.midY)
                let shrink = AnimationHelper.makeScaleTransform(scale: 0.55, center: center)
                LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: shrink), duration: 0.14, curve: CAMediaTimingFunction(name: .easeIn))
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                floating.animator().setFrameOrigin(targetFrameInBg.origin)
                floating.animator().alphaValue = 0
            }, completionHandler: { [weak floating] in
                Task { @MainActor in
                    floating?.removeFromSuperview()
                }
            })
            mergeAppsIntoFolder(draggedApp: dragged, targetApp: targetApp)
        } else if let floating = dragFloatingView, let sourceView = draggingItemView {
            let homeFrame = sourceView.convert(sourceView.iconFrameInSelf, to: backgroundView)
            draggingApp = nil
            draggingItemView = nil
            dragFloatingView = nil

            if let layer = floating.layer {
                LauncherTransition.set(layer, keyPath: "transform", value: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.18, curve: CAMediaTimingFunction(name: .easeOut))
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                floating.animator().setFrameOrigin(homeFrame.origin)
            }, completionHandler: { [weak floating, weak sourceView] in
                Task { @MainActor in
                    floating?.removeFromSuperview()
                    sourceView?.setDragSourceHidden(false)
                }
            })
        } else {
            cancelAppDrag()
        }
    }

    private func cancelAppDrag() {
        cancelEdgePageTurn()
        dropTargetItemView?.setMergeHighlighted(false)
        dropTargetItemView = nil
        dragFloatingView?.removeFromSuperview()
        dragFloatingView = nil
        draggingItemView?.setDragSourceHidden(false)
        draggingItemView = nil
        draggingApp = nil
        pointerDragging = false
    }

    private func mergeAppsIntoFolder(draggedApp: AppRecord, targetApp: AppRecord) {
        let keepPage = pagedContainer.currentPage
        let folderName = layout.merge(draggedApp: draggedApp, onto: targetApp, allApps: apps)
        for index in apps.indices {
            if apps[index].path == draggedApp.path || (!targetApp.path.hasPrefix("chu-folder:") && apps[index].path == targetApp.path) {
                apps[index].folder = folderName
            }
        }
        if openFolder != nil {
            folderSearchCapsule.stringValue = ""
            closeFolder()
        }
        do {
            try LayoutStore.save(layout)
        } catch {
            logger.error("Could not save merged folder: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }
        filter(query: searchCapsule.stringValue, targetPage: keepPage)
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
        pagedContainer.clearHover()
        folderPages.clearHover()
        cancelAppDrag()
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
        showRequestGeneration += 1
        let request = showRequestGeneration
        launcherTargetVisible = true
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        if backgroundView.useCachedWallpaper(for: screen) {
            showPrepared(on: screen)
        } else {
            backgroundView.updateWallpaper(for: screen) { [weak self] in
                guard let self, self.showRequestGeneration == request, self.launcherTargetVisible else { return }
                self.showPrepared(on: screen)
            }
        }
        updateManager.checkForUpdatesIfNeeded()
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
        let frame = mainWindowFrame(on: currentScreen)
        if window.frame != frame { window.setFrame(frame, display: true) }
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
        launchingItem?.resetLaunchAnimation()
        launchingItem = nil
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
        if menuCover?.frame != rect { menuCover?.setFrame(rect, display: true) }
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
        guard !transitionInProgress, window.isVisible || !launcherTargetVisible else { return }
        let target = window.isVisible ? window.screen : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        guard let screen = target ?? NSScreen.main else { return }
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
            let oldFolders = layout.folders
            apps = layout.reconcile(result)
            applyCurrentSort()
            loadedFolderItems = nil
            if oldPaths != layout.paths || oldFolders != layout.folders {
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
            filter(query: searchCapsule.stringValue, targetPage: pagedContainer.currentPage)
        }
    }

    private func filter(query: String, targetPage: Int = 0) {
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
        reloadDisplayed(targetPage: targetPage)
    }

    private func scheduleBackdropWarmup() {
        // The prepared wallpaper is already cached; opening a folder needs no screen capture.
    }

    private func reloadDisplayed(targetPage: Int = 0) {
        pagedContainer.onCreateFolder = { [weak self] app in self?.createFolder(containing: app) }
        pagedContainer.onMoveToFolder = { [weak self] app, folder in self?.move(app, to: folder) }
        folderPages.onCreateFolder = pagedContainer.onCreateFolder
        folderPages.onMoveToFolder = pagedContainer.onMoveToFolder
        pagedContainer.reloadPages(apps: displayed, folders: folderContents, iconCache: iconCache, targetPage: targetPage, onCreateFolder: { [weak self] in self?.createFolder(containing: $0) }, onMoveToFolder: { [weak self] app, folder in self?.move(app, to: folder) })
        pageIndicator.count = pagedContainer.pageCount
        pageIndicator.current = pagedContainer.currentPage
    }

    private func persistLayoutAndRefresh() {
        do {
            try LayoutStore.save(layout)
        } catch {
            logger.error("Could not save app layout: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }
        for index in apps.indices {
            if let override = layout.folders[apps[index].path] {
                apps[index].folder = override.isEmpty ? nil : override
            }
        }
        if let folder = openFolder {
            folderContents = Dictionary(grouping: apps.filter { $0.folder != nil }, by: { $0.folder! })
            folderContents[folder, default: []] = folderContents[folder] ?? []
            loadedFolderItems = nil
            filterFolder(query: folderSearchCapsule.stringValue)
            return
        }
        filter(query: searchCapsule.stringValue, targetPage: pagedContainer.currentPage)
    }

    private func createFolder(containing app: AppRecord) {
        let alert = NSAlert()
        alert.messageText = "新建分组"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: Layout.nextAvailableFolderName(existingNames: Set(apps.compactMap(\.folder))))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        layout.folders[app.path] = name
        persistLayoutAndRefresh()
    }

    private func showRenameFolder(_ name: String) {
        guard renamePanel == nil else { return }
        let icon = PageGridView.folderIcon(apps: apps.filter { $0.folder == name }, iconCache: iconCache)
        let existingNames = Set(apps.compactMap(\.folder))
        let panel = FolderRenameView(frame: backgroundView.bounds, name: name, icon: icon, existingNames: existingNames)
        panel.autoresizingMask = [.width, .height]
        panel.onFinish = { [weak self, weak panel] newName in
            guard let self else { return }
            panel?.removeFromSuperview()
            self.renamePanel = nil
            if self.settingsPanel == nil {
                self.menuSettingsShade?.isHidden = true
            }
            if let newName {
                self.move(AppRecord(path: "chu-folder:" + name, name: name), to: "rename:" + newName)
            }
        }
        menuSettingsShade?.isHidden = false
        backgroundView.addSubview(panel, positioned: .above, relativeTo: folderBackdrop)
        renamePanel = panel
        panel.present()
        window.makeFirstResponder(panel.field)
        panel.field.currentEditor()?.selectAll(nil)
    }

    private func renameOpenFolder() {
        guard let name = openFolder else { return }
        showRenameFolder(name)
    }

    private func move(_ app: AppRecord, to folder: String?) {
        if app.path.hasPrefix("chu-folder:") {
            guard let folder, folder.hasPrefix("rename:") else { return }
            let oldName = app.name
            if folder == "rename:" { showRenameFolder(oldName); return }
            let newName = String(folder.dropFirst("rename:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != oldName else { return }
            guard !apps.contains(where: { $0.folder == newName }) else {
                NSSound.beep()
                return
            }
            if openFolder == oldName {
                openFolder = newName
                folderTitle.stringValue = newName
            }
            for record in apps where layout.folders[record.path] == oldName || record.folder == oldName {
                layout.folders[record.path] = newName
            }
        } else if let folder {
            layout.folders[app.path] = folder
        } else {
            layout.folders[app.path] = ""
        }
        persistLayoutAndRefresh()
    }

    private func filterFolder(query: String) {
        guard let folder = openFolder, let contents = folderContents[folder] else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = trimmed.isEmpty ? contents : contents.filter { $0.name.localizedStandardContains(trimmed) }
        displayed = matched
        folderPages.reloadPages(apps: matched, folders: folderContents, iconCache: iconCache, targetPage: 0, onCreateFolder: { [weak self] in self?.createFolder(containing: $0) }, onMoveToFolder: { [weak self] app, folder in self?.move(app, to: folder) })
        loadedFolderItems = matched
        folderIndicator.count = folderPages.pageCount
        folderIndicator.current = folderPages.currentPage
    }

    private func activate(_ app: AppRecord, from itemView: AppItemView? = nil) {
        guard app.path.hasPrefix("chu-folder:") else { open(app, from: itemView); return }
        guard let contents = folderContents[app.name] else { return }
        if openFolder != nil {
            if folderClosing && openFolder == app.name {
                animateFolder(opening: true)
                folderSearchCapsule.makeFirstResponder()
            }
            return
        }
        guard let source = itemView ?? pagedContainer.findItemView(for: app) else { return }
        pagedContainer.clearHover()
        pagedContainer.layoutSubtreeIfNeeded()
        backdropWarmup?.cancel()
        folderSourceRect = source.convert(source.folderThumbnailFrame, to: folderBackdrop)
        folderMainItems = displayed
        folderSearchCapsule.stringValue = ""
        openFolder = app.name
        updateMoreButton()
        folderTitle.stringValue = app.name
        displayed = contents

        layoutFolderPanel()
        if loadedFolderItems != contents {
            folderPages.reloadPages(apps: contents, folders: folderContents, iconCache: iconCache, onCreateFolder: { [weak self] in self?.createFolder(containing: $0) }, onMoveToFolder: { [weak self] app, folder in self?.move(app, to: folder) })
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
        folderSearchCapsule.makeFirstResponder()
    }

    private func animateFolder(opening: Bool) {
        folderOverlay.animate(opening: opening)
    }

    private func layoutFolderPanel() {
        let available = folderBackdrop.bounds.insetBy(dx: 36, dy: 40)
        let width = max(1, min(available.width, 1140))
        let height = max(1, min(available.height, min(680, available.height * 0.72)))
        folderPanel.frame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        folderTitle.frame = NSRect(x: 0, y: height - 54, width: width, height: 28)
        let searchWidth = min(240, max(120, width - 40))
        folderSearchCapsule.frame = NSRect(x: floor((width - searchWidth) / 2), y: height - 92, width: searchWidth, height: 30)
        folderPages.frame = NSRect(x: 20, y: 42, width: width - 40, height: max(1, height - 142))
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

        launchingItem = targetItemView
        let finishLaunch: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
            self.window.orderOut(nil)
            self.menuCover?.orderOut(nil)
            self.window.alphaValue = 1.0
            targetItemView?.resetLaunchAnimation()
            self.launchingItem = nil
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
