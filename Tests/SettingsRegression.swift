import AppKit
import Carbon.HIToolbox
import Foundation

@main struct SettingsRegression {
    static func main() throws {
        // 1. 默认快捷键应为 Command + F3
        let def = LaunchHotKey.defaultHotKey
        precondition(def.keyCode == UInt32(kVK_F3), "default keyCode should be F3")
        precondition(def.modifiers == UInt32(cmdKey), "default modifiers should be Command")
        precondition(def.keyCapTokens == ["⌘", "F3"], "default key caps should be [⌘, F3]")
        precondition(def.displayString == "⌘ F3", "default displayString should be '⌘ F3'")

        // 2. 合法性校验
        precondition(LaunchHotKey.isValid(keyCode: UInt32(kVK_F3), modifiers: UInt32(cmdKey)), "⌘F3 should be valid")
        precondition(LaunchHotKey.isValid(keyCode: UInt32(kVK_F5), modifiers: 0), "standalone F5 should be valid")
        precondition(LaunchHotKey.isValid(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)), "⌥Space should be valid")
        precondition(!LaunchHotKey.isValid(keyCode: UInt32(kVK_ANSI_A), modifiers: 0), "plain 'A' should be rejected")
        precondition(!LaunchHotKey.isValid(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)), "Shift+A alone should be rejected")
        precondition(!LaunchHotKey.isValid(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)), "modifier-only key should be rejected")

        // 3. 快捷键持久化测试（使用独立测试 suite）
        let suiteName = "com.withqq.chu-launchpad.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        precondition(HotKeyStore.load(from: defaults) == .defaultHotKey, "fresh store returns default Command+F3")

        let custom = LaunchHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey))
        precondition(custom.keyCapTokens == ["⌥", "⌘", "Space"], "modifier ordering should follow macOS convention")
        HotKeyStore.save(custom, to: defaults)
        precondition(HotKeyStore.load(from: defaults) == custom, "saved custom hotkey is restored")

        HotKeyStore.save(nil, to: defaults)
        precondition(HotKeyStore.load(from: defaults) == nil, "disabled hotkey persists as nil")

        HotKeyStore.save(.defaultHotKey, to: defaults)
        precondition(HotKeyStore.load(from: defaults) == .defaultHotKey, "restored default hotkey persists")

        // 4. 开机自启 LaunchAgent 读写与路径同步测试
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ChuLaunchLoginTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }
        let plistURL = tempDir.appendingPathComponent("com.withqq.chu-launchpad.plist")

        precondition(!LaunchAtLoginManager.isEnabled(plistURL: plistURL), "launch at login defaults to disabled")

        try LaunchAtLoginManager.setEnabled(true, executablePath: "/tmp/Old/ChuLaunchpad", plistURL: plistURL)
        precondition(LaunchAtLoginManager.isEnabled(plistURL: plistURL), "launch at login enabled after write")

        // 校验写入的 plist 包含 --background 参数和 RunAtLoad
        let data = try Data(contentsOf: plistURL)
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let args = dict?["ProgramArguments"] as? [String]
        precondition(args == ["/tmp/Old/ChuLaunchpad", "--background"], "launch agent passes --background argument")
        precondition((dict?["RunAtLoad"] as? Bool) == true, "RunAtLoad should be true")

        // 校验移动 App 路径后自动同步
        LaunchAtLoginManager.syncExecutablePathIfNeeded(executablePath: "/Applications/Chu Launchpad.app/Contents/MacOS/ChuLaunchpad", plistURL: plistURL)
        let syncedData = try Data(contentsOf: plistURL)
        let syncedDict = try PropertyListSerialization.propertyList(from: syncedData, format: nil) as? [String: Any]
        let syncedArgs = syncedDict?["ProgramArguments"] as? [String]
        precondition(syncedArgs?.first == "/Applications/Chu Launchpad.app/Contents/MacOS/ChuLaunchpad", "moved executable path is synced")

        // 校验关闭开机自启后 plist 被清理
        try LaunchAtLoginManager.setEnabled(false, plistURL: plistURL)
        precondition(!LaunchAtLoginManager.isEnabled(plistURL: plistURL), "launch at login disabled after removal")
        precondition(!fm.fileExists(atPath: plistURL.path), "plist file should be removed when disabled")

        print("Settings regression checks passed")
    }
}
