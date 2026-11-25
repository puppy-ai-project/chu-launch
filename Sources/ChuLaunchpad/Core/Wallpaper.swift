import AppKit
import CoreImage

// Background parameters can be overridden in Application Support/ChuLaunchpad/background.json.
struct ChuBackgroundStyle: Codable, Sendable {
    static let defaultBlurRadius: Double = 33
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad/background.json")
    }

    var blurRadius: Double = ChuBackgroundStyle.defaultBlurRadius
    var brightness: Double = -0.22
    var saturation: Double = 1.32
    var overlayColor: String = "000000"
    var overlayOpacity: Double = 0.10
    var tintColor: String = "ffffff"
    var hue: Double? = nil
    var animationDuration: Double = 0.28

    static func load(from url: URL = defaultURL) -> ChuBackgroundStyle {
        guard let data = try? Data(contentsOf: url), let style = try? JSONDecoder().decode(ChuBackgroundStyle.self, from: data),
              (0...150).contains(style.blurRadius), (-1...1).contains(style.brightness),
              (0...2).contains(style.saturation), (-3.1416...3.1416).contains(style.hue ?? 0), (0...1).contains(style.overlayOpacity),
              (0.05...2).contains(style.animationDuration) else { return ChuBackgroundStyle() }
        return style
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// CIContext is thread-safe and reused for all background renders.
struct WallpaperPlacement: Sendable {
    let scaling: UInt
    let clip: Bool
    let red: Double
    let green: Double
    let blue: Double
}

enum WallpaperBlurRenderer {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    private final class SourceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var image: CIImage?

        func load(url: URL) -> CIImage? {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let cacheKey = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
            lock.lock()
            if key == cacheKey, let cached = image {
                lock.unlock()
                return cached
            }
            lock.unlock()
            guard let decoded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), !decoded.extent.isEmpty else { return nil }
            lock.lock()
            key = cacheKey
            image = decoded
            lock.unlock()
            return decoded
        }
    }
    private static let sourceCache = SourceCache()

    static func generate(url: URL, screenSize: CGSize, scaleFactor: CGFloat, placement: WallpaperPlacement, style: ChuBackgroundStyle, maxWidth: CGFloat = 2560) -> CGImage? {
        guard let input = sourceCache.load(url: url) else { return nil }
        let width = min(maxWidth, max(1, screenSize.width * scaleFactor))
        let height = width * screenSize.height / max(1, screenSize.width)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let scaleX = width / source.extent.width, scaleY = height / source.extent.height
        let scaled: CIImage
        if placement.scaling == NSImageScaling.scaleAxesIndependently.rawValue {
            scaled = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        } else {
            let factor = placement.scaling == NSImageScaling.scaleNone.rawValue
                ? width / max(1, screenSize.width)
                : (placement.clip ? max(scaleX, scaleY) : min(scaleX, scaleY))
            scaled = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        let centered = scaled.transformed(by: CGAffineTransform(translationX: (width - scaled.extent.width) / 2, y: (height - scaled.extent.height) / 2))
        let color = CIColor(red: placement.red, green: placement.green, blue: placement.blue, alpha: 1)
        let fill = CIImage(color: color).cropped(to: extent)
        let composed = centered.composited(over: fill).cropped(to: extent)
        let radius = style.blurRadius * width / 1600
        let blurred = composed.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        // Exposure scales dark tones proportionally, preserving detail near black.
        let adjusted = blurred.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: style.brightness * 4])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: style.saturation])
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: style.hue ?? 0])
        return context.createCGImage(adjusted, from: extent)
    }
}

