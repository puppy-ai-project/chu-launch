import Foundation

@main struct Regression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NovaTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Example.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let first = AppScanner.scan(roots: [root])
        precondition(first.count == 1 && first[0].name == "Example", "installed application is found")
        var layout = Layout()
        precondition(layout.reconcile(first).count == 1)
        let layoutURL = root.appendingPathComponent("layout.json")
        try LayoutStore.save(layout, to: layoutURL)
        precondition(LayoutStore.load(from: layoutURL).paths == [app.path])
        try fm.removeItem(at: app)
        let afterRemoval = AppScanner.scan(roots: [root])
        precondition(layout.reconcile(afterRemoval).isEmpty && layout.paths.isEmpty, "uninstalled application is removed")
        try Data("invalid".utf8).write(to: layoutURL)
        precondition(LayoutStore.load(from: layoutURL).paths.isEmpty)
        let files = try fm.contentsOfDirectory(atPath: root.path)
        precondition(files.contains { $0.hasPrefix("layout.corrupt-") })
        print("Regression checks passed")
    }
}
