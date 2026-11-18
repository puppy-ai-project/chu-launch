import Foundation

// MARK: - 开机自启管理器 (用户级 LaunchAgent，适配本地未签名应用)
enum LaunchAtLoginManager {
    static let label = "com.withqq.chu-launchpad"
    static let backgroundArgument = "--background"

    static var defaultPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var defaultExecutablePath: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
    }

    /// 检查开机启动是否已启用
    static func isEnabled(plistURL: URL = defaultPlistURL) -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              !args.isEmpty else {
            return false
        }
        return (plist["RunAtLoad"] as? Bool) ?? true
    }

    /// 开启或关闭开机自动启动
    static func setEnabled(
        _ enabled: Bool,
        executablePath: String = defaultExecutablePath,
        plistURL: URL = defaultPlistURL
    ) throws {
        let fm = FileManager.default
        if enabled {
            guard !executablePath.isEmpty else {
                throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法定位当前应用可执行文件路径"])
            }
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath, backgroundArgument],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else {
            if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
            }
        }
    }

    /// 若用户移动了 .app 位置且已开启开机启动，自动静默同步新路径
    static func syncExecutablePathIfNeeded(
        executablePath: String = defaultExecutablePath,
        plistURL: URL = defaultPlistURL
    ) {
        guard isEnabled(plistURL: plistURL),
              !executablePath.isEmpty,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.first != executablePath else {
            return
        }
        try? setEnabled(true, executablePath: executablePath, plistURL: plistURL)
    }
}
