import Foundation

@main struct DockPinRegression {
    static func main() {
        let home = URL(fileURLWithPath: "/Users/example")
        let installed = URL(fileURLWithPath: "/Applications/Chu Launchpad.app")
        precondition(DockPin.isInstalled(installed, home: home))
        precondition(DockPin.isInstalled(home.appendingPathComponent("Applications/Chu Launchpad.app"), home: home))
        precondition(!DockPin.isInstalled(home.appendingPathComponent("Downloads/Chu Launchpad.app"), home: home))
        precondition(!DockPin.isInstalled(URL(fileURLWithPath: "/Applications-Other/Chu Launchpad.app"), home: home))
        let tile = DockPin.tile(for: installed, bundleID: DockPin.bundleID)
        precondition(DockPin.containsApp([tile], bundleID: DockPin.bundleID, url: installed))
        precondition(DockPin.containsApp([tile], bundleID: "other.id", url: installed))
        precondition(!DockPin.containsApp([tile], bundleID: "other.id", url: URL(fileURLWithPath: "/Applications/Other.app")))
        precondition(!DockPin.containsApp([tile], bundleID: DockPin.bundleID, url: URL(fileURLWithPath: "/Users/example/Applications/Chu Launchpad.app")), "another installation with the same bundle ID is not this app")
        let other: [String: Any] = ["tile-data": ["bundle-identifier": "com.example.other", "file-label": "Other"]]
        let remaining = DockPin.removingApp(from: [other, tile], bundleID: DockPin.bundleID, url: installed)
        precondition(remaining.count == 1 && ((remaining[0]["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) == "com.example.other", "removing our tile preserves other items")
        print("Dock pin regression checks passed")
    }
}
