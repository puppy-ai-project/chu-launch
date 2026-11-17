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
        let localizedApp = root.appendingPathComponent("Localized.app")
        let resources = localizedApp.appendingPathComponent("Contents/Resources/zh-Hans.lproj")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.localized", "CFBundleName": "Example", "CFBundleLocalizations": ["en", "zh-Hans"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: localizedApp.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "示例"], format: .binary, options: 0).write(to: resources.appendingPathComponent("InfoPlist.strings"))
        precondition(AppScanner.displayName(for: localizedApp, languages: ["zh-Hans-CN"]) == "示例", "localized bundle name wins over file name")
        let wechat = URL(fileURLWithPath: "/Applications/WeChat.app")
        if fm.fileExists(atPath: wechat.path) {
            precondition(AppScanner.displayName(for: wechat, languages: ["zh-Hans-CN"]) == "微信")
        }
        try fm.removeItem(at: localizedApp)
        var oldLayout = Layout(paths: ["old", "new"])
        let ordered = [AppRecord(path: "new", name: "New"), AppRecord(path: "old", name: "Old")]
        precondition(oldLayout.reconcile(ordered).map(\.path) == ["new", "old"], "saved order must not override scan order")
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
