import AppKit
import CoreImage

enum NovaAppIcon {
    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        // Match the visible bounds of standard macOS icons in the Dock.
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.105, dy: size * 0.105),
                                xRadius: size * 0.205, yRadius: size * 0.205)
        NSGradient(colors: [
            NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1),
            NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1)
        ])?.draw(in: path, angle: 45)
        let colors: [NSColor] = [
            NSColor(srgbRed: 0.18, green: 0.88, blue: 0.42, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.68, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.64, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.34, blue: 0.39, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.72, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.94, green: 0.34, blue: 0.68, alpha: 1),
            NSColor(srgbRed: 0.74, green: 0.38, blue: 0.92, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.76, blue: 0.93, alpha: 1),
            NSColor(srgbRed: 0.12, green: 0.82, blue: 0.67, alpha: 1)
        ]
        // Keep the tiles comfortably inset so the grid reads clearly at Dock size.
        let cellSize = size * 0.125
        let gap = size * 0.06
        let gridSize = cellSize * 3 + gap * 2
        let origin = CGPoint(x: (size - gridSize) / 2, y: (size - gridSize) / 2)
        for row in 0..<3 {
            for column in 0..<3 {
                let index = row * 3 + column
                let cell = NSRect(x: origin.x + CGFloat(column) * (cellSize + gap),
                                  y: origin.y + CGFloat(2 - row) * (cellSize + gap),
                                  width: cellSize, height: cellSize)
                let cellPath = NSBezierPath(roundedRect: cell, xRadius: cellSize * 0.28, yRadius: cellSize * 0.28)
                colors[index].setFill()
                cellPath.fill()
                NSColor.white.withAlphaComponent(0.24).setStroke()
                cellPath.lineWidth = max(1, size * 0.006)
                cellPath.stroke()
            }
        }
        image.unlockFocus()
        return image
    }

    static func pngData(size: Int) -> Data? {
        guard let cgImage = image(size: CGFloat(size)).cgImage(forProposedRect: nil, context: nil, hints: nil),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(destinationData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }
}
