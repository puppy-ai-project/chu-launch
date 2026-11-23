import Foundation

struct AppRecord: Codable, Hashable, Sendable {
    let path: String
    let name: String
    var folder: String? = nil
    var installedAt: Date? = nil
}

enum AppScanner {
    static func displayName(for url: URL, languages: [String] = Locale.preferredLanguages) -> String {
        let bundle = Bundle(url: url)
        if let bundle {
            let preferred = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages)
            for language in preferred {
                guard let resource = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language),
                      let data = try? Data(contentsOf: resource),
                      let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = values[key] as? String, !name.isEmpty { return name }
                }
            }
        }
        let fileName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        return fileName.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    static func isInsideApplicationDirectory(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return defaultRoots.contains { root in
            let prefix = root.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(prefix) else { return false }
            return url.path.dropFirst(prefix.count).contains("/")
        }
    }

    static func scan(roots: [URL] = defaultRoots) -> [AppRecord] {
        let fm = FileManager.default
        var found: [String: AppRecord] = [:]
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                let path = url.standardizedFileURL.path
                let name = displayName(for: url)
                let relative = url.path.dropFirst(root.standardizedFileURL.path.count).split(separator: "/")
                let folder = relative.count > 1 ? fm.displayName(atPath: root.appendingPathComponent(String(relative[0])).path) : nil
                let dates = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
                found[path] = AppRecord(path: path, name: name, folder: folder, installedAt: dates?.addedToDirectoryDate ?? dates?.creationDate)
            }
        }
        return found.values.sorted { a, b in
            if a.installedAt != b.installedAt { return (a.installedAt ?? .distantPast) > (b.installedAt ?? .distantPast) }
            let comparison = a.name.localizedStandardCompare(b.name)
            return comparison == .orderedSame ? a.path < b.path : comparison == .orderedAscending
        }
    }
}

struct Layout: Codable, Sendable {
    var version = 1
    var paths: [String] = []
    /// 自定义目录归属映射：app.path -> 目录名称
    var folders: [String: String] = [:]
    var ungroupedPaths: Set<String> = []
    private(set) var needsMigration = false

    enum CodingKeys: String, CodingKey {
        case version, paths, folders, ungroupedPaths
    }

    init(version: Int = 1, paths: [String] = [], folders: [String: String] = [:]) {
        self.version = version
        self.paths = paths
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        folders = try container.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
        ungroupedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .ungroupedPaths) ?? []
        let legacyUngrouped = folders.filter { $0.value.isEmpty }.map(\.key)
        needsMigration = !legacyUngrouped.isEmpty
        ungroupedPaths.formUnion(legacyUngrouped)
        folders = folders.filter { !$0.value.isEmpty }
    }

    mutating func reconcile(_ apps: [AppRecord]) -> [AppRecord] {
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.path).inserted }
        let byPath = Dictionary(uniqueKeysWithValues: unique.map { ($0.path, $0) })
        let preservedPaths = paths.filter { byPath[$0] != nil }
        let preservedSet = Set(preservedPaths)
        let newPaths = unique.map(\.path).filter { !preservedSet.contains($0) }
        paths = preservedPaths + newPaths
        var ordered = paths.compactMap { byPath[$0] }
        folders = folders.filter { seen.contains($0.key) }
        ungroupedPaths = ungroupedPaths.filter { seen.contains($0) && byPath[$0]?.folder != nil && folders[$0] == nil }
        for index in ordered.indices {
            if let override = folders[ordered[index].path] {
                ordered[index].folder = override
            } else if ungroupedPaths.contains(ordered[index].path) {
                ordered[index].folder = nil
            }
        }
        return ordered
    }

    /// 生成不与现有目录名冲突的新目录名称
    static func nextAvailableFolderName(existingNames: Set<String>, baseName: String = "新建文件夹") -> String {
        if !existingNames.contains(baseName) { return baseName }
        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    /// 将拖拽应用合并到目标应用或已有目录中；返回最终使用的目录名
    @discardableResult
    mutating func merge(draggedApp: AppRecord, onto targetApp: AppRecord, allApps: [AppRecord]) -> String {
        let folderName: String
        if targetApp.path.hasPrefix("chu-folder:") {
            folderName = targetApp.name
        } else if let existingTargetFolder = folders[targetApp.path] ?? targetApp.folder {
            folderName = existingTargetFolder
        } else {
            var existingNames = Set(folders.values)
            for app in allApps {
                if let folder = app.folder { existingNames.insert(folder) }
            }
            folderName = Self.nextAvailableFolderName(existingNames: existingNames)
            folders[targetApp.path] = folderName
        }
        folders[draggedApp.path] = folderName
        ungroupedPaths.remove(draggedApp.path)
        ungroupedPaths.remove(targetApp.path)
        return folderName
    }
}

struct AppIndexSnapshot: Codable, Sendable {
    var version = 1
    var apps: [AppRecord]
}

enum AppIndexStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad/apps.json")
    }

    static func load(from url: URL = defaultURL) throws -> [AppRecord]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(AppIndexSnapshot.self, from: Data(contentsOf: url))
        return snapshot.version == 1 ? snapshot.apps : nil
    }

    static func save(_ apps: [AppRecord], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(AppIndexSnapshot(apps: apps)).write(to: url, options: .atomic)
    }
}

enum LayoutStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuLaunchpad/layout.json")
    }
    static func load(from url: URL = defaultURL) -> Layout {
        guard FileManager.default.fileExists(atPath: url.path) else { return Layout() }
        do {
            let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
            guard layout.version == 1 else { return Layout() }
            return layout
        } catch {
            let backup = url.deletingLastPathComponent().appendingPathComponent("layout.corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return Layout()
        }
    }
    static func save(_ layout: Layout, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(layout).write(to: url, options: .atomic)
    }
}
