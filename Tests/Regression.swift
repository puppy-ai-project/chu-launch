import Foundation

@main struct Regression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ChuTests-\(UUID().uuidString)")
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
        precondition(oldLayout.reconcile(ordered).map(\.path) == ["old", "new"], "saved grid order is preserved")
        precondition(oldLayout.reconcile([ordered[0]]).map(\.path) == ["new"], "removed apps are pruned while remaining saved apps retain order")
        var layout = Layout()
        precondition(layout.reconcile(first).count == 1)
        let layoutURL = root.appendingPathComponent("layout.json")
        try LayoutStore.save(layout, to: layoutURL)
        precondition(LayoutStore.load(from: layoutURL).paths == [app.path])
        let indexURL = root.appendingPathComponent("apps.json")
        try AppIndexStore.save(first, to: indexURL)
        let cachedApps = try AppIndexStore.load(from: indexURL)
        let missingApps = try AppIndexStore.load(from: root.appendingPathComponent("missing.json"))
        precondition(cachedApps == first, "application index cache round-trips")
        precondition(missingApps == nil, "missing application index cache is empty")
        try fm.removeItem(at: app)
        let afterRemoval = AppScanner.scan(roots: [root])
        precondition(layout.reconcile(afterRemoval).isEmpty && layout.paths.isEmpty, "uninstalled application is removed")
        try Data("invalid".utf8).write(to: layoutURL)
        precondition(LayoutStore.load(from: layoutURL).paths.isEmpty)
        let files = try fm.contentsOfDirectory(atPath: root.path)
        precondition(files.contains { $0.hasPrefix("layout.corrupt-") })

        // 验证旧版 layout.json（无 folders 字段）向后兼容解码
        let legacyJSON = #"{"version":1,"paths":["/Applications/A.app","/Applications/B.app"]}"#
        try Data(legacyJSON.utf8).write(to: layoutURL)
        let decodedLegacy = LayoutStore.load(from: layoutURL)
        precondition(decodedLegacy.paths == ["/Applications/A.app", "/Applications/B.app"] && decodedLegacy.folders.isEmpty, "legacy layout without folders decodes cleanly")

        let oldFolderJSON = #"{"version":1,"folders":{"/Applications/A.app":"","/Applications/Utilities/B.app":"","/Applications/C.app":"Group"}}"#
        try Data(oldFolderJSON.utf8).write(to: layoutURL)
        var migrated = LayoutStore.load(from: layoutURL)
        let scanned = [AppRecord(path: "/Applications/A.app", name: "A"), AppRecord(path: "/Applications/Utilities/B.app", name: "B", folder: "Utilities"), AppRecord(path: "/Applications/C.app", name: "C")]
        let migratedApps = migrated.reconcile(scanned)
        precondition(migrated.folders == ["/Applications/C.app": "Group"])
        precondition(migrated.ungroupedPaths == ["/Applications/Utilities/B.app"])
        precondition(migratedApps[1].folder == nil && migratedApps[2].folder == "Group")
        try LayoutStore.save(migrated, to: layoutURL)
        var restored = LayoutStore.load(from: layoutURL)
        precondition(restored.reconcile(scanned)[1].folder == nil, "ungrouped system app stays on the main page after reload")
        let destination = AppRecord(path: "chu-folder:Group", name: "Group")
        restored.merge(draggedApp: scanned[1], onto: destination, allApps: scanned)
        precondition(!restored.ungroupedPaths.contains(scanned[1].path), "regrouping removes the exception")

        // 验证拖动应用合并创建目录、加入已有目录及卸载清理
        var folderLayout = Layout()
        let appA = AppRecord(path: "/Applications/A.app", name: "App A")
        let appB = AppRecord(path: "/Applications/B.app", name: "App B")
        let appC = AppRecord(path: "/Applications/C.app", name: "App C")
        let appD = AppRecord(path: "/Applications/D.app", name: "App D")
        let allApps = [appA, appB, appC, appD]

        let created1 = folderLayout.merge(draggedApp: appA, onto: appB, allApps: allApps)
        precondition(created1 == "新建文件夹", "first merged folder uses base name")
        precondition(folderLayout.folders[appA.path] == created1 && folderLayout.folders[appB.path] == created1, "both apps assigned to created folder")

        // 拖入已有目录
        let folderProxy = AppRecord(path: "chu-folder:\(created1)", name: created1)
        let mergedIntoExisting = folderLayout.merge(draggedApp: appC, onto: folderProxy, allApps: allApps)
        precondition(mergedIntoExisting == created1 && folderLayout.folders[appC.path] == created1, "app merges into existing folder")

        // 再次用两个未分组应用（如先移除 B 再创建第二个文件夹，或测试名称递增）
        let created2 = Layout.nextAvailableFolderName(existingNames: [created1])
        precondition(created2 == "新建文件夹 2", "second folder increments suffix")

        try LayoutStore.save(folderLayout, to: layoutURL)
        let loadedFolderLayout = LayoutStore.load(from: layoutURL)
        precondition(loadedFolderLayout.folders == folderLayout.folders, "folder assignments persist across save/load")

        let reconciledWithFolders = folderLayout.reconcile([appA, appC, appD])
        precondition(folderLayout.folders[appB.path] == nil, "uninstalled app is pruned from folders")
        precondition(reconciledWithFolders.first(where: { $0.path == appA.path })?.folder == created1, "custom folder applies on reconcile")

        print("Regression checks passed")
    }
}
