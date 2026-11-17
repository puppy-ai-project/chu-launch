import Foundation

struct AppRecord: Codable, Hashable, Sendable {
    let path: String
    let name: String
}

enum AppScanner {
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
                let bundle = Bundle(url: url)
                let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                found[path] = AppRecord(path: path, name: name)
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct Layout: Codable, Sendable {
    var version = 1
    var paths: [String] = []

    mutating func reconcile(_ apps: [AppRecord]) -> [AppRecord] {
        let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        paths = paths.filter { byPath[$0] != nil && seen.insert($0).inserted }
        paths.append(contentsOf: apps.map(\.path).filter { seen.insert($0).inserted })
        return paths.compactMap { byPath[$0] }
    }
}

enum LayoutStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NovaLaunchpad/layout.json")
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
