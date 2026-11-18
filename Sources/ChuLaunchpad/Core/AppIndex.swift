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

    mutating func reconcile(_ apps: [AppRecord]) -> [AppRecord] {
        var seen = Set<String>()
        let ordered = apps.filter { seen.insert($0.path).inserted }
        paths = ordered.map(\.path)
        return ordered
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
