import AppKit

@MainActor
final class EntryDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ChuLaunchAgent.app")
        let configuration = NSWorkspace.OpenConfiguration()
        let background = CommandLine.arguments.contains("--background")
        configuration.activates = false
        configuration.arguments = background ? ["--background"] : []
        NSWorkspace.shared.openApplication(at: agent, configuration: configuration) { _, error in
            if let error { NSLog("Cannot open Chu Launchpad agent: %@", error.localizedDescription) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// A warm Dock click only needs IPC. Avoid initializing NSApplication on this path.
let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ChuLaunchAgent.app")
let background = CommandLine.arguments.contains("--background")
if NSRunningApplication.runningApplications(withBundleIdentifier: "com.withqq.chu-launchpad.agent")
    .contains(where: { $0.isFinishedLaunching && $0.bundleURL?.standardizedFileURL == agent.standardizedFileURL }) {
    if !background {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.withqq.chu-launchpad.toggle"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}

let delegate = EntryDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
