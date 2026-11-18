import AppKit
import CoreImage

@main struct BackgroundRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NovaBackground-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallpaper.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        guard let source = context.makeImage(), let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("image") }
        CGImageDestinationAddImage(writer, source, nil)
        precondition(CGImageDestinationFinalize(writer))
        var style = NovaBackgroundStyle()
        style.blurRadius = 0; style.brightness = 0; style.saturation = 1
        let placement = WallpaperPlacement(scaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, clip: false, red: 0, green: 1, blue: 0)
        guard let result = WallpaperBlurRenderer.generate(url: url, screenSize: CGSize(width: 100, height: 100), scaleFactor: 1, placement: placement, style: style), let check = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("render") }
        check.draw(result, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bytes = check.data!.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 { bytes[y * 400 + x * 4 + channel] }
        precondition(pixel(20, 50, 0) > 200 && pixel(80, 50, 2) > 200, "wallpaper colors and positions are preserved")
        precondition(pixel(50, 5, 1) > 200 && pixel(50, 5, 3) == 255, "fit margins use the opaque desktop fill color")
        precondition(WallpaperBlurRenderer.generate(url: directory.appendingPathComponent("missing"), screenSize: CGSize(width: 100, height: 100), scaleFactor: 1, placement: placement, style: style) == nil)
        print("Background regression checks passed")
    }
}
