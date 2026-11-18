import Foundation

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: URL
    var version: String { tag_name.first?.lowercased() == "v" ? String(tag_name.dropFirst()) : tag_name }

    static func latest() async throws -> Self? {
        let endpoint = URL(string: "https://api.github.com/repos/puppy-ai-project/nova-launch/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NovaLaunchpad", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard release.version.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil,
              release.html_url.scheme == "https", release.html_url.host == "github.com" else {
            throw URLError(.cannotParseResponse)
        }
        return release
    }
}
