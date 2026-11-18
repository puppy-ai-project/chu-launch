import AppKit
import Carbon.HIToolbox
import QuartzCore

// MARK: - 设置面板标签页
enum SettingsTab {
    case general
    case about
}

// MARK: - 语义化渐变图标徽章 (Gradient Icon Badge)
@MainActor private final class GradientBadgeView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let glossLayer = CALayer()
    private let iconView = NSImageView()

    init(frame: NSRect, symbolName: String, symbolPointSize: CGFloat, colors: [NSColor], cornerRadius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.frame = bounds
        layer?.addSublayer(gradientLayer)

        // 顶部柔和玻璃高光内描边
        glossLayer.frame = bounds
        glossLayer.cornerRadius = cornerRadius
        glossLayer.borderWidth = 1
        glossLayer.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.addSublayer(glossLayer)

        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = .white
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        iconView.frame = bounds
        addSubview(iconView)
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        glossLayer.frame = bounds
        iconView.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 侧边栏导航项 (Sidebar Tab Item)
@MainActor private final class SidebarTabButton: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    var isSelected = false {
        didSet { updateColors(animated: true) }
    }
    var onSelect: (() -> Void)?

    override var isFlipped: Bool { true }

    init(frame: NSRect, title: String, symbolName: String, badgeColors: [NSColor]) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        let badge = GradientBadgeView(
            frame: NSRect(x: 8, y: 7, width: 22, height: 22),
            symbolName: symbolName,
            symbolPointSize: 11.5,
            colors: badgeColors,
            cornerRadius: 6
        )
        addSubview(badge)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: 39, y: floor((frame.height - titleLabel.frame.height) / 2)))
        addSubview(titleLabel)

        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    func updateColors(animated: Bool = false) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor
        let bg: NSColor
        let border: NSColor

        if isSelected {
            bg = accent.withAlphaComponent(isDark ? 0.18 : 0.12)
            border = accent.withAlphaComponent(isDark ? 0.30 : 0.22)
            titleLabel.textColor = .labelColor
        } else if isHovered {
            bg = isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.045)
            border = .clear
            titleLabel.textColor = .labelColor
        } else {
            bg = .clear
            border = .clear
            titleLabel.textColor = .secondaryLabelColor
        }

        let apply = {
            self.layer?.backgroundColor = bg.cgColor
            self.layer?.borderColor = border.cgColor
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

// MARK: - 交互式圆角按钮 (悬停 / 按压 / 加载态)
@MainActor private final class SettingsActionButton: NSControl {
    enum Style {
        case primary
        case secondary
        case success
        case circleIcon
    }

    private var style: Style
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    var isLoading = false {
        didSet {
            isEnabled = !isLoading
            titleLabel.stringValue = isLoading ? loadingTitle : defaultTitle
            updateAppearanceColors()
        }
    }
    override var isEnabled: Bool {
        didSet { updateAppearanceColors() }
    }
    var defaultTitle: String
    var loadingTitle: String = "检查中…"
    var onTap: (() -> Void)?

    init(frame: NSRect, style: Style, title: String = "", symbolName: String? = nil, accessibilityLabel: String? = nil, pointSize: CGFloat = 11) {
        self.style = style
        self.defaultTitle = title
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = style == .circleIcon ? frame.height / 2 : 8
        layer?.masksToBounds = true

        if style != .circleIcon {
            titleLabel.stringValue = title
            titleLabel.alignment = .center
            titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            titleLabel.textColor = .white
            titleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
        } else if let symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?.withSymbolConfiguration(config)
            iconView.imageAlignment = .alignCenter
            iconView.imageScaling = .scaleNone
            addSubview(iconView)
        }

        updateAppearanceColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(style newStyle: Style, title: String, loading: Bool = false, loadingText: String = "检查中…") {
        style = newStyle
        defaultTitle = title
        loadingTitle = loadingText
        isLoading = loading
        titleLabel.stringValue = loading ? loadingText : title
        updateAppearanceColors(animated: true)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = style == .circleIcon ? bounds.height / 2 : 8
        if style != .circleIcon {
            let textHeight = ceil(titleLabel.intrinsicContentSize.height)
            titleLabel.frame = NSRect(x: 6, y: floor((bounds.height - textHeight) / 2), width: bounds.width - 12, height: textHeight)
        } else {
            iconView.frame = bounds
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearanceColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearanceColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateAppearanceColors(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        updateAppearanceColors(animated: true)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onTap?()
        }
    }

    func updateAppearanceColors(animated: Bool = false) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor
        let border: NSColor

        switch style {
        case .primary:
            let accent = NSColor.controlAccentColor
            if isLoading || !isEnabled {
                bg = accent.withAlphaComponent(isDark ? 0.35 : 0.45)
                border = NSColor.clear
                titleLabel.textColor = NSColor.white.withAlphaComponent(0.82)
            } else if isPressed {
                bg = accent.blended(withFraction: 0.22, of: .black) ?? accent
                border = NSColor.white.withAlphaComponent(0.14)
                titleLabel.textColor = .white
            } else if isHovered {
                bg = accent.blended(withFraction: 0.12, of: .white) ?? accent
                border = NSColor.white.withAlphaComponent(0.24)
                titleLabel.textColor = .white
            } else {
                bg = accent
                border = NSColor.white.withAlphaComponent(0.16)
                titleLabel.textColor = .white
            }
        case .success:
            let green = NSColor(srgbRed: 0.12, green: 0.72, blue: 0.45, alpha: 1)
            if isLoading || !isEnabled {
                bg = green.withAlphaComponent(isDark ? 0.35 : 0.45)
                border = NSColor.clear
                titleLabel.textColor = NSColor.white.withAlphaComponent(0.82)
            } else if isPressed {
                bg = green.blended(withFraction: 0.20, of: .black) ?? green
                border = NSColor.white.withAlphaComponent(0.14)
                titleLabel.textColor = .white
            } else if isHovered {
                bg = green.blended(withFraction: 0.10, of: .white) ?? green
                border = NSColor.white.withAlphaComponent(0.24)
                titleLabel.textColor = .white
            } else {
                bg = green
                border = NSColor.white.withAlphaComponent(0.18)
                titleLabel.textColor = .white
            }
        case .secondary:
            if !isEnabled {
                bg = isDark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.03)
                border = isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05)
                titleLabel.textColor = .tertiaryLabelColor
            } else if isPressed {
                bg = isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)
                border = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)
                titleLabel.textColor = .labelColor
            } else if isHovered {
                bg = isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.08)
                border = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.10)
                titleLabel.textColor = .labelColor
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
                border = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
                titleLabel.textColor = .labelColor
            }
        case .circleIcon:
            if !isEnabled {
                bg = isDark ? NSColor.white.withAlphaComponent(0.03) : NSColor.black.withAlphaComponent(0.025)
                border = isDark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.03)
                iconView.contentTintColor = .quaternaryLabelColor
            } else if isPressed {
                bg = isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.16)
                border = isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
                iconView.contentTintColor = isDark ? .white : .labelColor
            } else if isHovered {
                bg = isDark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.10)
                border = isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
                iconView.contentTintColor = isDark ? .white : .labelColor
            } else {
                bg = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
                border = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
                iconView.contentTintColor = .secondaryLabelColor
            }
        }

        let apply = {
            self.layer?.backgroundColor = bg.cgColor
            self.layer?.borderWidth = 0.5
            self.layer?.borderColor = border.cgColor
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

// MARK: - 精致渐变圆角下载进度条
@MainActor private final class UpdateProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CAGradientLayer()
    private var fraction: Double? = 0
    private var isAnimatingIndeterminate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        trackLayer.cornerRadius = frameRect.height / 2
        trackLayer.masksToBounds = true
        layer?.addSublayer(trackLayer)

        fillLayer.colors = [
            NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1).cgColor,
            NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor
        ]
        fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fillLayer.cornerRadius = frameRect.height / 2
        trackLayer.addSublayer(fillLayer)

        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        trackLayer.frame = bounds
        trackLayer.cornerRadius = radius
        fillLayer.cornerRadius = radius
        updateFillFrame(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        trackLayer.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.11)
            : NSColor.black.withAlphaComponent(0.09)).cgColor
    }

    func setProgress(_ value: Double?) {
        fraction = value
        if value == nil {
            startIndeterminateAnimation()
        } else {
            stopIndeterminateAnimation()
            updateFillFrame(animated: true)
        }
    }

    private func updateFillFrame(animated: Bool) {
        guard let fraction else { return }
        let clamped = min(1.0, max(0.0, fraction))
        let width = bounds.width * CGFloat(clamped)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        fillLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }

    private func startIndeterminateAnimation() {
        guard !isAnimatingIndeterminate else { return }
        isAnimatingIndeterminate = true
        let barWidth = max(60, bounds.width * 0.28)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: -barWidth, y: 0, width: barWidth, height: bounds.height)
        CATransaction.commit()

        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -barWidth / 2
        slide.toValue = bounds.width + barWidth / 2
        slide.duration = 1.15
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fillLayer.add(slide, forKey: "indeterminateSlide")
    }

    private func stopIndeterminateAnimation() {
        guard isAnimatingIndeterminate else { return }
        isAnimatingIndeterminate = false
        fillLayer.removeAnimation(forKey: "indeterminateSlide")
    }
}

// MARK: - 快捷键键帽录制控件 (Hotkey Recorder Control)
@MainActor private final class HotKeyRecorderControl: NSView {
    private let stackView = NSStackView()
    private let promptLabel = NSTextField(labelWithString: "")
    private var capViews: [NSView] = []
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false

    private(set) var hotKey: LaunchHotKey?
    private(set) var isRecording = false

    var onToggleRecording: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        promptLabel.alignment = .center
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        promptLabel.lineBreakMode = .byTruncatingTail
        addSubview(promptLabel)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        renderContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let h = ceil(promptLabel.intrinsicContentSize.height)
        promptLabel.frame = NSRect(x: 6, y: floor((bounds.height - h) / 2), width: bounds.width - 12, height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        setRecording(!isRecording, notify: true)
    }

    func setHotKey(_ newHotKey: LaunchHotKey?) {
        hotKey = newHotKey
        renderContent()
    }

    func setRecording(_ recording: Bool, notify: Bool = false) {
        guard isRecording != recording else { return }
        isRecording = recording
        renderContent()
        if notify {
            onToggleRecording?(recording)
        }
    }

    private func renderContent() {
        for view in capViews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        capViews.removeAll()

        if isRecording {
            stackView.isHidden = true
            promptLabel.isHidden = false
            promptLabel.stringValue = "请按下快捷键…"
        } else if let hotKey {
            stackView.isHidden = false
            promptLabel.isHidden = true
            for token in hotKey.keyCapTokens {
                let cap = makeKeyCap(token)
                stackView.addArrangedSubview(cap)
                capViews.append(cap)
            }
        } else {
            stackView.isHidden = true
            promptLabel.isHidden = false
            promptLabel.stringValue = "点击录制"
        }

        needsLayout = true
        updateColors()
    }

    private func makeKeyCap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.sizeToFit()

        let width = max(22, ceil(label.frame.width) + 10)
        let height: CGFloat = 21
        let cap = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 0.5

        label.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: width),
            cap.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor)
        ])
        return cap
    }

    func updateColors(animated: Bool = false) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor

        let bg: NSColor
        let border: NSColor
        let borderWidth: CGFloat

        if isRecording {
            bg = accent.withAlphaComponent(isDark ? 0.20 : 0.12)
            border = accent
            borderWidth = 1.5
            promptLabel.textColor = isDark ? (accent.blended(withFraction: 0.35, of: .white) ?? accent) : accent
        } else if isHovered {
            bg = isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.055)
            border = isDark ? NSColor.white.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.18)
            borderWidth = 1
            promptLabel.textColor = .secondaryLabelColor
        } else {
            bg = isDark ? NSColor.black.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.035)
            border = isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.11)
            borderWidth = 1
            promptLabel.textColor = .tertiaryLabelColor
        }

        let capBg = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.92)
        let capBorder = isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)

        let apply = {
            self.layer?.backgroundColor = bg.cgColor
            self.layer?.borderColor = border.cgColor
            self.layer?.borderWidth = borderWidth
            for cap in self.capViews {
                cap.layer?.backgroundColor = capBg.cgColor
                cap.layer?.borderColor = capBorder.cgColor
                if let label = cap.subviews.first as? NSTextField {
                    label.textColor = .labelColor
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

// MARK: - 可点击的悬停卡片行 (用于项目外链)
@MainActor private final class InteractiveCardView: NSView {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    var onTap: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateColors(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateColors(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        updateColors(animated: true)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onTap?()
        }
    }

    func updateColors(animated: Bool = false) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor
        let border: NSColor

        if isDark {
            if isPressed {
                bg = NSColor.white.withAlphaComponent(0.11)
            } else if isHovered {
                bg = NSColor.white.withAlphaComponent(0.085)
            } else {
                bg = NSColor.white.withAlphaComponent(0.055)
            }
            border = NSColor.white.withAlphaComponent(isHovered ? 0.16 : 0.09)
        } else {
            if isPressed {
                bg = NSColor.black.withAlphaComponent(0.06)
            } else if isHovered {
                bg = NSColor.white.withAlphaComponent(0.86)
            } else {
                bg = NSColor.white.withAlphaComponent(0.68)
            }
            border = NSColor.black.withAlphaComponent(isHovered ? 0.12 : 0.07)
        }

        let apply = {
            self.layer?.backgroundColor = bg.cgColor
            self.layer?.borderColor = border.cgColor
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

// MARK: - 内部 Flipped 容器视图
@MainActor private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 顶部玻璃高光描边覆盖层（不拦截事件）
@MainActor private final class PassthroughBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 设置面板 (SettingsPanelView)
@MainActor final class SettingsPanelView: NSView {
    private let shellView = FlippedView()
    private let glassView = NSVisualEffectView()
    private let surfaceTintView = NSView()
    private let sidebarView = FlippedView()
    private let sidebarDivider = NSView()
    private let borderOverlay = PassthroughBorderView()

    private let generalTabButton: SidebarTabButton
    private let aboutTabButton: SidebarTabButton
    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let closeButton: SettingsActionButton

    // MARK: 通用页组件
    private let generalPage = FlippedView()
    private let hotKeyCard = FlippedView()
    private let hotKeyDivider = NSView()
    private let hotKeyRecorder = HotKeyRecorderControl(frame: NSRect(x: 258, y: 24, width: 132, height: 32))
    private let resetHotKeyButton: SettingsActionButton
    private let hotKeyStatusIcon = NSImageView()
    private let hotKeyStatusLabel = NSTextField(wrappingLabelWithString: "")

    private let loginCard = FlippedView()
    private let loginDivider = NSView()
    private let loginSwitch = NSSwitch()
    private let loginStatusIcon = NSImageView()
    private let loginStatusLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: 关于页组件
    private let aboutPage = FlippedView()
    private let productCard = FlippedView()
    private let versionBadge = FlippedView()
    private let versionBadgeLabel = NSTextField(labelWithString: "")

    private let updatesCard = FlippedView()
    private let updatesDivider = NSView()
    private let checkButton: SettingsActionButton
    private let primaryActionButton: SettingsActionButton
    private let statusSpinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    // 下载中进度与速率区域
    private let progressContainer = FlippedView()
    private let progressDetailLabel = NSTextField(labelWithString: "")
    private let progressSpeedLabel = NSTextField(labelWithString: "")
    private let progressBar = UpdateProgressBarView(frame: NSRect(x: 0, y: 28, width: 404, height: 6))

    // 下载完成路径展示区域
    private let savedPathBox = FlippedView()
    private let savedPathLabel = NSTextField(wrappingLabelWithString: "")
    private let revealFileButton: SettingsActionButton
    private var downloadedFileURL: URL?

    private let projectCard = InteractiveCardView(frame: .zero)

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private static let repositoryURL = URL(string: "https://github.com/puppy-ai-project/nova-launch")!

    private(set) var currentTab: SettingsTab = .general
    private var lastHotKeyStatus: HotKeyRegistrationStatus = .registered(.defaultHotKey)
    private var currentUpdateState: UpdateState = .idle

    var isRecordingHotKey: Bool { hotKeyRecorder.isRecording }

    var onCheckUpdates: (() -> Void)?
    var onStartDownload: (() -> Void)?
    var onCancelDownload: (() -> Void)?
    var onInstallAndRestart: (() -> Void)?
    var onClose: (() -> Void)?
    var onHotKeyChanged: ((LaunchHotKey?) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?

    private var dragStartMouseInParent: NSPoint?
    private var dragStartOrigin: NSPoint?

    override init(frame: NSRect) {
        self.generalTabButton = SidebarTabButton(
            frame: NSRect(x: 12, y: 62, width: 168, height: 36),
            title: "通用",
            symbolName: "gearshape.fill",
            badgeColors: [
                NSColor(srgbRed: 0.49, green: 0.53, blue: 0.60, alpha: 1),
                NSColor(srgbRed: 0.35, green: 0.38, blue: 0.45, alpha: 1)
            ]
        )
        self.aboutTabButton = SidebarTabButton(
            frame: NSRect(x: 12, y: 104, width: 168, height: 36),
            title: "关于",
            symbolName: "info",
            badgeColors: [
                NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1),
                NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
            ]
        )
        self.resetHotKeyButton = SettingsActionButton(
            frame: NSRect(x: 396, y: 26, width: 28, height: 28),
            style: .circleIcon,
            symbolName: "arrow.counterclockwise",
            accessibilityLabel: "恢复默认快捷键",
            pointSize: 11.5
        )
        self.checkButton = SettingsActionButton(
            frame: NSRect(x: 334, y: 20, width: 88, height: 30),
            style: .primary,
            title: "检查更新"
        )
        self.primaryActionButton = SettingsActionButton(
            frame: NSRect(x: 338, y: 20, width: 84, height: 30),
            style: .primary,
            title: "下载新版"
        )
        self.revealFileButton = SettingsActionButton(
            frame: NSRect(x: 372, y: 7, width: 26, height: 26),
            style: .circleIcon,
            symbolName: "folder",
            accessibilityLabel: "在访达中显示安装包",
            pointSize: 11
        )
        self.closeButton = SettingsActionButton(
            frame: NSRect(x: 440, y: 15, width: 28, height: 28),
            style: .circleIcon,
            symbolName: "xmark",
            accessibilityLabel: "关闭设置",
            pointSize: 11
        )
        super.init(frame: frame)
        setupHierarchy()
        applyTheme()
        selectTab(.general)
        setHotKeyStatus(.registered(.defaultHotKey))
        setLaunchAtLogin(enabled: false)
        applyUpdateState(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupHierarchy() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 26
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)

        // 圆角裁剪主壳
        shellView.frame = bounds
        shellView.autoresizingMask = [.width, .height]
        shellView.wantsLayer = true
        shellView.layer?.cornerRadius = 18
        shellView.layer?.masksToBounds = true
        addSubview(shellView)

        // 毛玻璃底板（穿透窗口内背景壁纸）
        glassView.frame = shellView.bounds
        glassView.autoresizingMask = [.width, .height]
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        shellView.addSubview(glassView)

        // 柔和底色微调层
        surfaceTintView.frame = shellView.bounds
        surfaceTintView.autoresizingMask = [.width, .height]
        surfaceTintView.wantsLayer = true
        shellView.addSubview(surfaceTintView)

        // 左侧导航栏 (192pt)
        let sidebarWidth: CGFloat = 192
        sidebarView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        sidebarView.wantsLayer = true
        shellView.addSubview(sidebarView)

        sidebarDivider.frame = NSRect(x: sidebarWidth - 1, y: 0, width: 1, height: bounds.height)
        sidebarDivider.wantsLayer = true
        shellView.addSubview(sidebarDivider)

        makeLabel("设置", x: 22, y: 18, size: 18, weight: .bold, color: .labelColor, in: sidebarView)

        generalTabButton.onSelect = { [weak self] in self?.selectTab(.general) }
        aboutTabButton.onSelect = { [weak self] in self?.selectTab(.about) }
        sidebarView.addSubview(generalTabButton)
        sidebarView.addSubview(aboutTabButton)

        makeLabel("Nova Launchpad", x: 22, y: bounds.height - 34, size: 11, weight: .medium, color: .tertiaryLabelColor, in: sidebarView)

        // 右侧内容区 (488pt)
        let contentArea = FlippedView(frame: NSRect(x: sidebarWidth, y: 0, width: bounds.width - sidebarWidth, height: bounds.height))
        shellView.addSubview(contentArea)

        headerTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.frame = NSRect(x: 24, y: 19, width: 240, height: 24)
        contentArea.addSubview(headerTitleLabel)

        closeButton.onTap = { [weak self] in
            self?.cancelHotKeyRecording()
            self?.onClose?()
        }
        contentArea.addSubview(closeButton)

        let pageFrame = NSRect(x: 0, y: 58, width: contentArea.bounds.width, height: contentArea.bounds.height - 58)
        generalPage.frame = pageFrame
        aboutPage.frame = pageFrame
        contentArea.addSubview(generalPage)
        contentArea.addSubview(aboutPage)

        setupGeneralPage()
        setupAboutPage()

        // 最外层玻璃内描边（穿透点击）
        borderOverlay.frame = shellView.bounds
        borderOverlay.autoresizingMask = [.width, .height]
        borderOverlay.wantsLayer = true
        borderOverlay.layer?.cornerRadius = 18
        borderOverlay.layer?.borderWidth = 1
        shellView.addSubview(borderOverlay)
    }

    // MARK: - 构建“通用”页面
    private func setupGeneralPage() {
        // 卡片 1：呼出快捷键
        hotKeyCard.frame = NSRect(x: 24, y: 4, width: 440, height: 152)
        hotKeyCard.wantsLayer = true
        hotKeyCard.layer?.cornerRadius = 14
        hotKeyCard.layer?.borderWidth = 1
        generalPage.addSubview(hotKeyCard)

        let hotKeyBadge = GradientBadgeView(
            frame: NSRect(x: 18, y: 24, width: 32, height: 32),
            symbolName: "command",
            symbolPointSize: 14,
            colors: [
                NSColor(srgbRed: 0.45, green: 0.42, blue: 0.96, alpha: 1),
                NSColor(srgbRed: 0.30, green: 0.48, blue: 0.96, alpha: 1)
            ],
            cornerRadius: 8
        )
        hotKeyCard.addSubview(hotKeyBadge)

        makeLabel("呼出快捷键", x: 62, y: 21, size: 14.5, weight: .semibold, color: .labelColor, in: hotKeyCard)
        makeLabel("在任意界面按下以显示或隐藏启动器", x: 62, y: 42, size: 11.5, weight: .regular, color: .tertiaryLabelColor, in: hotKeyCard)

        hotKeyRecorder.onToggleRecording = { [weak self] recording in
            guard let self else { return }
            self.onRecordingStateChanged?(recording)
            if recording {
                self.renderHotKeyStatus(
                    icon: "record.circle",
                    color: .controlAccentColor,
                    text: "请按下新的组合键（如 ⌘F3、⌥Space），按 Esc 取消，按 ⌫ 停用。",
                    emphasized: true
                )
            } else {
                self.setHotKeyStatus(self.lastHotKeyStatus)
            }
        }
        hotKeyCard.addSubview(hotKeyRecorder)

        resetHotKeyButton.toolTip = "恢复默认快捷键 (\(LaunchHotKey.defaultHotKey.displayString))"
        resetHotKeyButton.onTap = { [weak self] in
            guard let self else { return }
            self.cancelHotKeyRecording()
            self.onHotKeyChanged?(.defaultHotKey)
        }
        hotKeyCard.addSubview(resetHotKeyButton)

        hotKeyDivider.frame = NSRect(x: 18, y: 80, width: 404, height: 1)
        hotKeyDivider.wantsLayer = true
        hotKeyCard.addSubview(hotKeyDivider)

        hotKeyStatusIcon.frame = NSRect(x: 18, y: 108, width: 16, height: 16)
        hotKeyStatusIcon.imageAlignment = .alignCenter
        hotKeyStatusIcon.imageScaling = .scaleProportionallyDown
        hotKeyCard.addSubview(hotKeyStatusIcon)

        hotKeyStatusLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        hotKeyStatusLabel.textColor = .secondaryLabelColor
        hotKeyStatusLabel.maximumNumberOfLines = 2
        hotKeyStatusLabel.lineBreakMode = .byWordWrapping
        hotKeyStatusLabel.frame = NSRect(x: 42, y: 98, width: 380, height: 38)
        hotKeyCard.addSubview(hotKeyStatusLabel)

        // 卡片 2：登录时自动启动
        loginCard.frame = NSRect(x: 24, y: 170, width: 440, height: 142)
        loginCard.wantsLayer = true
        loginCard.layer?.cornerRadius = 14
        loginCard.layer?.borderWidth = 1
        generalPage.addSubview(loginCard)

        let loginBadge = GradientBadgeView(
            frame: NSRect(x: 18, y: 24, width: 32, height: 32),
            symbolName: "power",
            symbolPointSize: 14,
            colors: [
                NSColor(srgbRed: 0.13, green: 0.77, blue: 0.56, alpha: 1),
                NSColor(srgbRed: 0.06, green: 0.62, blue: 0.66, alpha: 1)
            ],
            cornerRadius: 8
        )
        loginCard.addSubview(loginBadge)

        makeLabel("登录时自动启动", x: 62, y: 21, size: 14.5, weight: .semibold, color: .labelColor, in: loginCard)
        makeLabel("开机后在后台静默待命，随时按快捷键呼出", x: 62, y: 42, size: 11.5, weight: .regular, color: .tertiaryLabelColor, in: loginCard)

        loginSwitch.controlSize = .regular
        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchToggled)
        let switchSize = loginSwitch.intrinsicContentSize
        loginSwitch.frame = NSRect(
            x: 424 - switchSize.width,
            y: floor(40 - switchSize.height / 2),
            width: switchSize.width,
            height: switchSize.height
        )
        loginCard.addSubview(loginSwitch)

        loginDivider.frame = NSRect(x: 18, y: 78, width: 404, height: 1)
        loginDivider.wantsLayer = true
        loginCard.addSubview(loginDivider)

        loginStatusIcon.frame = NSRect(x: 18, y: 102, width: 16, height: 16)
        loginStatusIcon.imageAlignment = .alignCenter
        loginStatusIcon.imageScaling = .scaleProportionallyDown
        loginCard.addSubview(loginStatusIcon)

        loginStatusLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.lineBreakMode = .byWordWrapping
        loginStatusLabel.frame = NSRect(x: 42, y: 92, width: 380, height: 38)
        loginCard.addSubview(loginStatusLabel)

        // 底部轻量化操作提示
        let hint = NSTextField(labelWithString: "按 Esc 关闭设置 · 拖动窗口空白处可移动位置")
        hint.font = .systemFont(ofSize: 11.5, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 24, y: 328, width: 440, height: 18)
        generalPage.addSubview(hint)
    }

    // MARK: - 构建“关于”页面
    private func setupAboutPage() {
        // 卡片 1 - 应用名片卡
        productCard.frame = NSRect(x: 24, y: 4, width: 440, height: 92)
        productCard.wantsLayer = true
        productCard.layer?.cornerRadius = 14
        productCard.layer?.borderWidth = 1
        aboutPage.addSubview(productCard)

        let appIconBadge = GradientBadgeView(
            frame: NSRect(x: 18, y: 18, width: 56, height: 56),
            symbolName: "square.grid.3x3.fill",
            symbolPointSize: 25,
            colors: [
                NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1),
                NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1),
                NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1)
            ],
            cornerRadius: 14
        )
        let iconShadowHolder = NSView(frame: appIconBadge.frame)
        iconShadowHolder.wantsLayer = true
        iconShadowHolder.layer?.shadowColor = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor
        iconShadowHolder.layer?.shadowOpacity = 0.35
        iconShadowHolder.layer?.shadowRadius = 10
        iconShadowHolder.layer?.shadowOffset = CGSize(width: 0, height: -4)
        appIconBadge.frame = iconShadowHolder.bounds
        iconShadowHolder.addSubview(appIconBadge)
        productCard.addSubview(iconShadowHolder)

        let titleField = makeLabel("Nova Launchpad", x: 90, y: 20, size: 18, weight: .bold, color: .labelColor, in: productCard)

        // 版本号胶囊徽章（与主标题垂直中心对齐）
        versionBadgeLabel.stringValue = "v\(version)"
        versionBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        versionBadgeLabel.sizeToFit()
        let badgeWidth = ceil(versionBadgeLabel.frame.width) + 14
        let badgeHeight: CGFloat = 20
        let badgeY = round(titleField.frame.midY - badgeHeight / 2)
        versionBadge.frame = NSRect(x: titleField.frame.maxX + 10, y: badgeY, width: badgeWidth, height: badgeHeight)
        versionBadge.wantsLayer = true
        versionBadge.layer?.cornerRadius = badgeHeight / 2
        versionBadge.layer?.borderWidth = 0.5
        versionBadgeLabel.frame = NSRect(x: 7, y: floor((badgeHeight - versionBadgeLabel.frame.height) / 2), width: badgeWidth - 14, height: versionBadgeLabel.frame.height)
        versionBadge.addSubview(versionBadgeLabel)
        productCard.addSubview(versionBadge)

        makeLabel("轻量、纯粹的 macOS 原生离线应用启动器", x: 90, y: 50, size: 12.5, weight: .regular, color: .secondaryLabelColor, in: productCard)

        // 卡片 2 - 软件更新卡（按状态自适应高度：常规态紧凑，下载中/完成平滑展开）
        updatesCard.frame = NSRect(x: 24, y: 108, width: 440, height: 120)
        updatesCard.wantsLayer = true
        updatesCard.layer?.cornerRadius = 14
        updatesCard.layer?.borderWidth = 1
        aboutPage.addSubview(updatesCard)

        let updateIconBadge = GradientBadgeView(
            frame: NSRect(x: 18, y: 19, width: 32, height: 32),
            symbolName: "arrow.triangle.2.circlepath",
            symbolPointSize: 14,
            colors: [
                NSColor(srgbRed: 0.08, green: 0.72, blue: 0.65, alpha: 1),
                NSColor(srgbRed: 0.06, green: 0.58, blue: 0.82, alpha: 1)
            ],
            cornerRadius: 8
        )
        updatesCard.addSubview(updateIconBadge)

        makeLabel("软件更新", x: 62, y: 16, size: 14.5, weight: .semibold, color: .labelColor, in: updatesCard)
        makeLabel("GitHub Releases 正式版", x: 62, y: 37, size: 11.5, weight: .regular, color: .tertiaryLabelColor, in: updatesCard)

        checkButton.onTap = { [weak self] in
            self?.onCheckUpdates?()
        }
        updatesCard.addSubview(checkButton)

        primaryActionButton.isHidden = true
        primaryActionButton.onTap = { [weak self] in
            self?.handlePrimaryUpdateActionTap()
        }
        updatesCard.addSubview(primaryActionButton)

        updatesDivider.frame = NSRect(x: 18, y: 70, width: 404, height: 1)
        updatesDivider.wantsLayer = true
        updatesCard.addSubview(updatesDivider)

        // 常规状态行
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.frame = NSRect(x: 18, y: 87, width: 16, height: 16)
        statusSpinner.isHidden = true
        updatesCard.addSubview(statusSpinner)

        statusIcon.frame = NSRect(x: 18, y: 87, width: 16, height: 16)
        statusIcon.imageAlignment = .alignCenter
        statusIcon.imageScaling = .scaleProportionallyDown
        updatesCard.addSubview(statusIcon)

        statusLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.frame = NSRect(x: 42, y: 85, width: 380, height: 20)
        updatesCard.addSubview(statusLabel)

        // 下载进度与速率容器
        progressContainer.frame = NSRect(x: 18, y: 84, width: 404, height: 34)
        progressContainer.isHidden = true
        updatesCard.addSubview(progressContainer)

        progressDetailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressDetailLabel.textColor = .labelColor
        progressDetailLabel.lineBreakMode = .byTruncatingTail
        progressDetailLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
        progressContainer.addSubview(progressDetailLabel)

        progressSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        progressSpeedLabel.textColor = .controlAccentColor
        progressSpeedLabel.alignment = .right
        progressSpeedLabel.frame = NSRect(x: 304, y: 0, width: 100, height: 18)
        progressContainer.addSubview(progressSpeedLabel)

        progressBar.frame = NSRect(x: 0, y: 24, width: 404, height: 6)
        progressContainer.addSubview(progressBar)

        // 下载完成后完整保存路径展示卡片
        savedPathBox.frame = NSRect(x: 18, y: 110, width: 404, height: 42)
        savedPathBox.wantsLayer = true
        savedPathBox.layer?.cornerRadius = 8
        savedPathBox.layer?.borderWidth = 0.5
        savedPathBox.isHidden = true
        updatesCard.addSubview(savedPathBox)

        savedPathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        savedPathLabel.textColor = .secondaryLabelColor
        savedPathLabel.maximumNumberOfLines = 2
        savedPathLabel.lineBreakMode = .byCharWrapping
        savedPathLabel.frame = NSRect(x: 10, y: 6, width: 356, height: 30)
        savedPathBox.addSubview(savedPathLabel)

        revealFileButton.toolTip = "在访达中显示安装包"
        revealFileButton.onTap = { [weak self] in
            if let fileURL = self?.downloadedFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        savedPathBox.addSubview(revealFileButton)

        // 卡片 3 - 开源项目与提示卡（位置随更新卡片高度联动）
        projectCard.frame = NSRect(x: 24, y: updatesCard.frame.maxY + 12, width: 440, height: 58)
        projectCard.onTap = {
            NSWorkspace.shared.open(Self.repositoryURL)
        }
        aboutPage.addSubview(projectCard)

        let codeBadge = GradientBadgeView(
            frame: NSRect(x: 18, y: 13, width: 32, height: 32),
            symbolName: "chevron.left.forwardslash.chevron.right",
            symbolPointSize: 13,
            colors: [
                NSColor(srgbRed: 0.48, green: 0.41, blue: 0.93, alpha: 1),
                NSColor(srgbRed: 0.35, green: 0.30, blue: 0.78, alpha: 1)
            ],
            cornerRadius: 8
        )
        projectCard.addSubview(codeBadge)

        makeLabel("开源仓库 · GitHub", x: 62, y: 11, size: 13.5, weight: .medium, color: .labelColor, in: projectCard)
        makeLabel("puppy-ai-project/nova-launch · 按 Esc 关闭设置", x: 62, y: 31, size: 11.5, weight: .regular, color: .tertiaryLabelColor, in: projectCard)

        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let externalArrow = NSImageView(frame: NSRect(x: 404, y: 20, width: 18, height: 18))
        externalArrow.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "打开仓库")?.withSymbolConfiguration(arrowConfig)
        externalArrow.contentTintColor = .tertiaryLabelColor
        externalArrow.imageAlignment = .alignCenter
        projectCard.addSubview(externalArrow)
    }

    // MARK: - 标签页切换
    func selectTab(_ tab: SettingsTab) {
        if currentTab != tab {
            cancelHotKeyRecording()
        }
        currentTab = tab
        generalTabButton.isSelected = (tab == .general)
        aboutTabButton.isSelected = (tab == .about)
        generalPage.isHidden = (tab != .general)
        aboutPage.isHidden = (tab != .about)
        headerTitleLabel.stringValue = (tab == .general) ? "通用" : "关于"
    }

    // MARK: - 快捷键录制事件处理
    func cancelHotKeyRecording() {
        if hotKeyRecorder.isRecording {
            hotKeyRecorder.setRecording(false, notify: true)
        }
    }

    /// 处于快捷键录制状态时处理键盘按下事件；返回 true 表示已消费
    func handleRecordingKeyDown(_ event: NSEvent) -> Bool {
        guard hotKeyRecorder.isRecording else { return false }

        let keyCode = UInt32(event.keyCode)
        let modifiers = LaunchHotKey.carbonModifiers(from: event.modifierFlags)

        // Esc（无修饰键）：取消录制
        if keyCode == UInt32(kVK_Escape) && modifiers == 0 {
            hotKeyRecorder.setRecording(false, notify: true)
            return true
        }

        // Delete / ForwardDelete（无修饰键）：停用全局快捷键
        if (keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete)) && modifiers == 0 {
            hotKeyRecorder.setRecording(false, notify: true)
            onHotKeyChanged?(nil)
            return true
        }

        // 校验组合键是否合法
        guard LaunchHotKey.isValid(keyCode: keyCode, modifiers: modifiers) else {
            renderHotKeyStatus(
                icon: "exclamationmark.circle",
                color: .systemOrange,
                text: "请搭配 ⌘、⌥ 或 ⌃ 修饰键，或直接使用功能键 F1–F12。",
                emphasized: false
            )
            return true
        }

        let newHotKey = LaunchHotKey(keyCode: keyCode, modifiers: modifiers)
        hotKeyRecorder.setRecording(false, notify: true)
        onHotKeyChanged?(newHotKey)
        return true
    }

    // MARK: - 外部状态同步接口
    func setHotKeyStatus(_ status: HotKeyRegistrationStatus) {
        lastHotKeyStatus = status
        switch status {
        case .registered(let hotKey):
            hotKeyRecorder.setHotKey(hotKey)
            resetHotKeyButton.isEnabled = (hotKey != .defaultHotKey)
            renderHotKeyStatus(
                icon: "checkmark.circle.fill",
                color: .systemGreen,
                text: "已启用，在任意界面按下 \(hotKey.displayString) 即可呼出或隐藏启动器。",
                emphasized: false
            )
        case .conflict(let hotKey, _):
            hotKeyRecorder.setHotKey(hotKey)
            resetHotKeyButton.isEnabled = (hotKey != .defaultHotKey)
            renderHotKeyStatus(
                icon: "exclamationmark.triangle.fill",
                color: .systemOrange,
                text: "快捷键 \(hotKey.displayString) 已被系统或其他应用占用，请点击右侧更换。",
                emphasized: false
            )
        case .disabled:
            hotKeyRecorder.setHotKey(nil)
            resetHotKeyButton.isEnabled = true
            renderHotKeyStatus(
                icon: "info.circle",
                color: .tertiaryLabelColor,
                text: "已停用全局快捷键，点击右侧输入框重新设置或恢复默认。",
                emphasized: false
            )
        }
    }

    func setLaunchAtLogin(enabled: Bool, errorMessage: String? = nil) {
        loginSwitch.state = enabled ? .on : .off
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        let text: String

        if let errorMessage {
            loginStatusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            loginStatusIcon.contentTintColor = .systemOrange
            loginStatusLabel.textColor = .secondaryLabelColor
            text = "设置失败：\(errorMessage)"
        } else if enabled {
            loginStatusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            loginStatusIcon.contentTintColor = .systemGreen
            loginStatusLabel.textColor = .labelColor
            text = "已开启，下次登录 macOS 时将在后台自动启动。"
        } else {
            loginStatusIcon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            loginStatusIcon.contentTintColor = .tertiaryLabelColor
            loginStatusLabel.textColor = .secondaryLabelColor
            text = "未开启，开机后需手动打开 Nova Launchpad。"
        }

        loginStatusLabel.stringValue = text
        layoutStatusLabel(loginStatusLabel, text: text, centerY: 110)
    }

    private func renderHotKeyStatus(icon: String, color: NSColor, text: String, emphasized: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        hotKeyStatusIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        hotKeyStatusIcon.contentTintColor = color
        hotKeyStatusLabel.stringValue = text
        hotKeyStatusLabel.textColor = emphasized ? .labelColor : .secondaryLabelColor
        layoutStatusLabel(hotKeyStatusLabel, text: text, centerY: 116)
    }

    private func layoutStatusLabel(_ label: NSTextField, text: String, centerY: CGFloat) {
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: 380, height: 42),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12.5)]
        )
        let textHeight = min(38, ceil(textBounds.height) + 2)
        label.frame = NSRect(x: 42, y: floor(centerY - textHeight / 2), width: 380, height: textHeight)
    }

    @objc private func loginSwitchToggled() {
        onLaunchAtLoginChanged?(loginSwitch.state == .on)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
    }

    private func applyTheme() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        glassView.material = isDark ? .hudWindow : .popover
        surfaceTintView.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.62)
            : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.72)).cgColor

        sidebarView.layer?.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.035)).cgColor

        let dividerColor = isDark
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.08)
        for divider in [sidebarDivider, hotKeyDivider, loginDivider, updatesDivider] {
            divider.layer?.backgroundColor = dividerColor.cgColor
        }

        let cardFill = isDark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.white.withAlphaComponent(0.68)
        let cardBorder = isDark
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.07)

        for card in [hotKeyCard, loginCard, productCard, updatesCard] {
            card.layer?.backgroundColor = cardFill.cgColor
            card.layer?.borderColor = cardBorder.cgColor
        }

        let accent = NSColor.controlAccentColor
        versionBadge.layer?.backgroundColor = accent.withAlphaComponent(isDark ? 0.20 : 0.12).cgColor
        versionBadge.layer?.borderColor = accent.withAlphaComponent(isDark ? 0.35 : 0.22).cgColor
        versionBadgeLabel.textColor = isDark
            ? accent.blended(withFraction: 0.35, of: .white) ?? accent
            : accent

        borderOverlay.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.11)).cgColor

        savedPathBox.layer?.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(0.24)
            : NSColor.black.withAlphaComponent(0.04)).cgColor
        savedPathBox.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)).cgColor

        layer?.shadowOpacity = isDark ? 0.48 : 0.24

        generalTabButton.updateColors()
        aboutTabButton.updateColors()
        hotKeyRecorder.updateColors()
        resetHotKeyButton.updateAppearanceColors()
        checkButton.updateAppearanceColors()
        primaryActionButton.updateAppearanceColors()
        revealFileButton.updateAppearanceColors()
        progressBar.updateColors()
        closeButton.updateAppearanceColors()
        projectCard.updateColors()
    }

    @discardableResult
    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, in parent: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: x, y: y))
        parent.addSubview(field)
        return field
    }

    // MARK: - 更新主操作按钮分发（下载新版 / 取消下载 / 重启安装 / 重试下载）
    private func handlePrimaryUpdateActionTap() {
        switch currentUpdateState {
        case .available:
            onStartDownload?()
        case .downloading:
            onCancelDownload?()
        case .downloaded:
            onInstallAndRestart?()
        case .failed(_, let retryURL, _):
            if retryURL != nil {
                onStartDownload?()
            }
        case .idle, .checking, .upToDate, .noRelease, .installing:
            break
        }
    }

    /// 排布顶部“检查更新”与主操作按钮（“检查更新”除下载中外始终显示）
    private func layoutUpdateButtons(
        showCheckButton: Bool,
        checkLoading: Bool = false,
        checkEnabled: Bool = true,
        primaryStyle: SettingsActionButton.Style? = nil,
        primaryTitle: String? = nil,
        primaryLoading: Bool = false,
        primaryLoadingText: String = "处理中…"
    ) {
        if let primaryStyle, let primaryTitle {
            primaryActionButton.isHidden = false
            primaryActionButton.frame = NSRect(x: 338, y: 20, width: 84, height: 30)
            primaryActionButton.configure(style: primaryStyle, title: primaryTitle, loading: primaryLoading, loadingText: primaryLoadingText)

            checkButton.isHidden = !showCheckButton
            if showCheckButton {
                checkButton.frame = NSRect(x: 252, y: 20, width: 78, height: 30)
                checkButton.configure(style: .secondary, title: "检查更新", loading: checkLoading, loadingText: "检查中…")
                checkButton.isEnabled = checkEnabled && !checkLoading
            }
        } else {
            primaryActionButton.isHidden = true
            checkButton.isHidden = !showCheckButton
            if showCheckButton {
                checkButton.frame = NSRect(x: 334, y: 20, width: 88, height: 30)
                checkButton.configure(style: .primary, title: "检查更新", loading: checkLoading, loadingText: "检查中…")
                checkButton.isEnabled = checkEnabled && !checkLoading
            }
        }
    }

    /// 根据状态动态调整更新卡片高度并联动下方开源仓库卡片位置
    private func setUpdatesCardHeight(_ targetHeight: CGFloat) {
        let shouldAnimate = window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && abs(updatesCard.frame.height - targetHeight) > 0.5
        let newCardFrame = NSRect(x: 24, y: 108, width: 440, height: targetHeight)
        let newProjectFrame = NSRect(x: 24, y: newCardFrame.maxY + 12, width: 440, height: 58)

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                updatesCard.animator().frame = newCardFrame
                projectCard.animator().frame = newProjectFrame
            }
        } else {
            updatesCard.frame = newCardFrame
            projectCard.frame = newProjectFrame
        }
    }

    // MARK: - 完整更新状态机 UI 同步
    func applyUpdateState(_ state: UpdateState) {
        currentUpdateState = state
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)

        switch state {
        case .idle:
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: false,
                icon: "info.circle",
                iconColor: .tertiaryLabelColor,
                text: "点击“检查更新”查看是否有可用的新版本。",
                emphasized: false
            )
            layoutUpdateButtons(showCheckButton: true)

        case .checking:
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: true,
                icon: nil,
                iconColor: .secondaryLabelColor,
                text: "正在检查更新…",
                emphasized: false
            )
            layoutUpdateButtons(showCheckButton: true, checkLoading: true)

        case .upToDate(let currentVersion):
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: false,
                icon: "checkmark.circle.fill",
                iconColor: .systemGreen,
                text: "当前已是最新版本（v\(currentVersion)）",
                emphasized: true
            )
            layoutUpdateButtons(showCheckButton: true)

        case .noRelease:
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: false,
                icon: "info.circle",
                iconColor: .tertiaryLabelColor,
                text: "暂无公开的正式版本。",
                emphasized: false
            )
            layoutUpdateButtons(showCheckButton: true)

        case .available(let newVersion, _):
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: false,
                icon: "arrow.down.circle.fill",
                iconColor: .controlAccentColor,
                text: "发现新版本 v\(newVersion)，点击“下载新版”开始下载。",
                emphasized: true
            )
            layoutUpdateButtons(showCheckButton: true, primaryStyle: .primary, primaryTitle: "下载新版")

        case .downloading(let newVersion, _, let progress):
            downloadedFileURL = nil
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusIcon.isHidden = true
            statusLabel.isHidden = true
            savedPathBox.isHidden = true
            progressContainer.isHidden = false

            if let fraction = progress.fraction {
                let percent = Int((fraction * 100).rounded())
                progressDetailLabel.stringValue = "正在下载 v\(newVersion) · \(percent)% (\(UpdateFormat.byteCount(progress.bytesWritten)) / \(UpdateFormat.byteCount(progress.totalBytes)))"
            } else {
                progressDetailLabel.stringValue = "正在下载 v\(newVersion) · 已下载 \(UpdateFormat.byteCount(progress.bytesWritten))"
            }
            progressSpeedLabel.stringValue = UpdateFormat.speed(progress.bytesPerSecond)
            progressBar.setProgress(progress.fraction)
            // 下载中隐藏“检查更新”，只显示“取消下载”
            layoutUpdateButtons(showCheckButton: false, primaryStyle: .secondary, primaryTitle: "取消下载")
            setUpdatesCardHeight(132)

        case .downloaded(let newVersion, let fileURL):
            downloadedFileURL = fileURL
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            progressContainer.isHidden = true
            statusIcon.isHidden = false
            statusLabel.isHidden = false
            savedPathBox.isHidden = false

            statusIcon.frame = NSRect(x: 18, y: 84, width: 16, height: 16)
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            statusIcon.contentTintColor = .systemGreen

            #if DOWNLOAD_PREVIEW
            let doneText = "ChuImage 下载验证完成"
            #else
            let doneText = "v\(newVersion) 下载完成，点击“重启安装”自动解压并更新"
            #endif
            statusLabel.stringValue = doneText
            statusLabel.textColor = .labelColor
            layoutStatusLabel(statusLabel, text: doneText, centerY: 92)

            savedPathLabel.stringValue = "保存路径：\(fileURL.path)"
            savedPathLabel.toolTip = fileURL.path
            #if DOWNLOAD_PREVIEW
            layoutUpdateButtons(showCheckButton: true)
            #else
            layoutUpdateButtons(showCheckButton: true, primaryStyle: .success, primaryTitle: "重启安装")
            #endif
            setUpdatesCardHeight(166)

        case .installing(let newVersion, let fileURL):
            downloadedFileURL = fileURL
            progressContainer.isHidden = true
            savedPathBox.isHidden = false
            statusIcon.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.frame = NSRect(x: 18, y: 84, width: 16, height: 16)
            statusSpinner.startAnimation(nil)
            statusLabel.isHidden = false

            let text = "正在解压 v\(newVersion) 并准备重启安装…"
            statusLabel.stringValue = text
            statusLabel.textColor = .labelColor
            layoutStatusLabel(statusLabel, text: text, centerY: 92)

            savedPathLabel.stringValue = "保存路径：\(fileURL.path)"
            savedPathLabel.toolTip = fileURL.path
            layoutUpdateButtons(
                showCheckButton: true,
                checkEnabled: false,
                primaryStyle: .success,
                primaryTitle: "重启安装",
                primaryLoading: true,
                primaryLoadingText: "安装中…"
            )
            setUpdatesCardHeight(166)

        case .failed(let message, let retryURL, _):
            downloadedFileURL = nil
            showSimpleStatus(
                spinner: false,
                icon: "exclamationmark.triangle.fill",
                iconColor: .systemOrange,
                text: message,
                emphasized: false
            )
            if retryURL != nil {
                layoutUpdateButtons(showCheckButton: true, primaryStyle: .primary, primaryTitle: "重试下载")
            } else {
                layoutUpdateButtons(showCheckButton: true)
            }
        }
    }

    private func showSimpleStatus(spinner: Bool, icon: String?, iconColor: NSColor, text: String, emphasized: Bool) {
        progressContainer.isHidden = true
        savedPathBox.isHidden = true
        statusLabel.isHidden = false

        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: 380, height: 42),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: statusLabel.font ?? NSFont.systemFont(ofSize: 12.5)]
        )
        let textHeight = min(38, ceil(textBounds.height) + 2)
        // 紧凑均衡的上下留白（单行约上下各 14pt，总卡片高 118pt）
        let bottomSectionHeight = max(46, textHeight + 28)
        let centerY = floor(71 + bottomSectionHeight / 2)

        if spinner {
            statusIcon.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.frame = NSRect(x: 18, y: centerY - 8, width: 16, height: 16)
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusIcon.isHidden = false
            statusIcon.frame = NSRect(x: 18, y: centerY - 8, width: 16, height: 16)
            if let icon {
                let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
                statusIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                statusIcon.contentTintColor = iconColor
            }
        }

        statusLabel.stringValue = text
        statusLabel.textColor = emphasized ? .labelColor : .secondaryLabelColor
        statusLabel.frame = NSRect(x: 42, y: floor(centerY - textHeight / 2), width: 380, height: textHeight)
        setUpdatesCardHeight(71 + bottomSectionHeight)
    }

    // MARK: - 交互命中与面板拖动
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var cursor: NSView? = hit
        while let current = cursor, current !== self {
            if current is NSControl || current is InteractiveCardView || current is SidebarTabButton || current is HotKeyRecorderControl {
                return current
            }
            cursor = current.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // 点击空白处退出快捷键录制态
        cancelHotKeyRecording()
        guard let parent = superview else { return }
        dragStartMouseInParent = parent.convert(event.locationInWindow, from: nil)
        dragStartOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview, let startMouse = dragStartMouseInParent, let startOrigin = dragStartOrigin else { return }
        let current = parent.convert(event.locationInWindow, from: nil)
        let rawX = startOrigin.x + (current.x - startMouse.x)
        let rawY = startOrigin.y + (current.y - startMouse.y)
        let x = min(max(parent.bounds.minX, rawX), max(parent.bounds.minX, parent.bounds.maxX - frame.width))
        let y = min(max(parent.bounds.minY, rawY), max(parent.bounds.minY, parent.bounds.maxY - frame.height))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseInParent = nil
        dragStartOrigin = nil
    }
}

// MARK: - 设置弹窗背景遮罩 (SettingsBackdropView)
@MainActor final class SettingsBackdropView: NSView {
    static let shade = NSColor.black.withAlphaComponent(0.24)

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
