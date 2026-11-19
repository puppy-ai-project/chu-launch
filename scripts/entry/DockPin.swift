import Foundation
import Darwin
import CryptoKit

enum DockPin {
#if CHU_DEVELOPMENT
    static let bundleID = "com.withqq.chu-launchpad.dev"
    static let agentBundleID = "com.withqq.chu-launchpad.agent.dev"
    static let appDisplayName = "Chu Launchpad dev"
    static let toggleNotification = "com.withqq.chu-launchpad.toggle.dev"
#else
    static let bundleID = "com.withqq.chu-launchpad"
    static let agentBundleID = "com.withqq.chu-launchpad.agent"
    static let appDisplayName = "Chu Launchpad"
    static let toggleNotification = "com.withqq.chu-launchpad.toggle"
#endif
    static func togglePortName(for agent: URL) -> CFString {
        let digest = SHA256.hash(data: Data(agent.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(agentBundleID).\(getuid()).\(suffix)" as CFString
    }

    static let marker = "dockPinAttemptedV1"

    static func isInstalled(_ app: URL, home: URL) -> Bool {
        let path = app.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        return roots.contains { path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
    }

    static func containsApp(_ items: [[String: Any]], bundleID: String, url: URL) -> Bool {
        items.contains { item in
            guard let data = item["tile-data"] as? [String: Any] else { return false }
            // A different installation can share our bundle identifier. Only the
            // tile's actual application path establishes whether this copy is pinned.
            guard let file = data["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String,
                  let existing = URL(string: raw), existing.isFileURL else { return false }
            return existing.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    static func removingApp(from items: [[String: Any]], bundleID: String, url: URL) -> [[String: Any]] {
        items.filter { !containsApp([$0], bundleID: bundleID, url: url) }
    }

    static func tile(for url: URL, bundleID: String) -> [String: Any] {
        ["tile-type": "file-tile", "tile-data": [
            "bundle-identifier": bundleID,
            "file-label": appDisplayName,
            "file-type": 41,
            "file-data": ["_CFURLString": url.absoluteURL.absoluteString, "_CFURLStringType": 15]
        ]]
    }

    private static func command(_ executable: String, _ arguments: [String]) -> (Int32, Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch { return nil }
    }

    private static func dockPreferences() throws -> [String: Any] {
        guard let (status, data) = command("/usr/bin/defaults", ["export", "com.apple.dock", "-"]), status == 0,
              let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw NSError(domain: bundleID, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 Dock 状态"])
        }
        return preferences
    }

    static func isPinned(app: URL) throws -> Bool {
        let preferences = try dockPreferences()
        return containsApp(preferences["persistent-apps"] as? [[String: Any]] ?? [], bundleID: bundleID, url: app)
    }

    static func setPinned(_ enabled: Bool, app: URL) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("dock-pin.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw NSError(domain: bundleID, code: 2, userInfo: [NSLocalizedDescriptionKey: "无法访问 Dock 设置"]) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw NSError(domain: bundleID, code: 3, userInfo: [NSLocalizedDescriptionKey: "无法锁定 Dock 设置"]) }
        defer { flock(lock, LOCK_UN) }
        let preferences = try dockPreferences()
        guard preferences["contents-immutable"] as? Bool != true, preferences["static-only"] as? Bool != true else {
            throw NSError(domain: bundleID, code: 4, userInfo: [NSLocalizedDescriptionKey: "Dock 布局已被锁定或由设备管理"])
        }
        let items = preferences["persistent-apps"] as? [[String: Any]] ?? []
        let currentlyPinned = containsApp(items, bundleID: bundleID, url: app)
        if currentlyPinned != enabled {
            let result: (Int32, Data)?
            if enabled {
                let data = try PropertyListSerialization.data(fromPropertyList: tile(for: app, bundleID: bundleID), format: .xml, options: 0)
                result = command("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", String(decoding: data, as: UTF8.self)])
            } else {
                let remaining = removingApp(from: items, bundleID: bundleID, url: app)
                let data = try PropertyListSerialization.data(fromPropertyList: remaining, format: .xml, options: 0)
                result = command("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", String(decoding: data, as: UTF8.self)])
            }
            guard result?.0 == 0, try isPinned(app: app) == enabled else {
                throw NSError(domain: bundleID, code: 5, userInfo: [NSLocalizedDescriptionKey: "无法更新 Dock 图标"])
            }
            _ = command("/usr/bin/killall", ["Dock"])
        }
        let shared = UserDefaults(suiteName: bundleID) ?? .standard
        shared.set(true, forKey: marker)
        shared.synchronize()
    }

    static func installOnce(app: URL, defaults: UserDefaults = UserDefaults(suiteName: bundleID) ?? .standard) {
        guard isInstalled(app, home: FileManager.default.homeDirectoryForCurrentUser), !defaults.bool(forKey: marker) else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        let lock = open(directory.appendingPathComponent("dock-pin.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(lock, LOCK_UN) }
        guard !defaults.bool(forKey: marker),
              let (status, data) = command("/usr/bin/defaults", ["export", "com.apple.dock", "-"]), status == 0,
              let preferences = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let items = preferences["persistent-apps"] as? [[String: Any]] else { return }
        if containsApp(items, bundleID: bundleID, url: app) {
            defaults.set(true, forKey: marker)
            defaults.synchronize()
            return
        }
        // Respect managed or user-locked Dock layouts.
        guard preferences["contents-immutable"] as? Bool != true, preferences["static-only"] as? Bool != true,
              let xml = try? PropertyListSerialization.data(fromPropertyList: tile(for: app, bundleID: bundleID), format: .xml, options: 0),
              let value = String(data: xml, encoding: .utf8),
              let (writeStatus, _) = command("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", value]), writeStatus == 0 else { return }
        guard let (verifyStatus, verifyData) = command("/usr/bin/defaults", ["export", "com.apple.dock", "-"]), verifyStatus == 0,
              let updated = (try? PropertyListSerialization.propertyList(from: verifyData, format: nil)) as? [String: Any],
              let updatedItems = updated["persistent-apps"] as? [[String: Any]],
              containsApp(updatedItems, bundleID: bundleID, url: app) else { return }
        defaults.set(true, forKey: marker)
        defaults.synchronize()
        // Dock doesn't observe external changes to this preference immediately.
        _ = command("/usr/bin/killall", ["Dock"])
    }
}
