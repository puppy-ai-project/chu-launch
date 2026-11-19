import AppKit
import ServiceManagement

if let action = CommandLine.arguments.dropFirst().first, action.hasPrefix("--login-item-") {
    let service = SMAppService.mainApp
    do {
        switch action {
        case "--login-item-status": exit(service.status == .enabled ? 0 : 1)
        case "--login-item-enable":
            if service.status != .enabled { try service.register() }
            guard service.status == .enabled else {
                FileHandle.standardError.write(Data("请在系统设置的登录项中批准 Chu Launchpad。".utf8))
                exit(1)
            }
        case "--login-item-disable":
            if service.status != .notRegistered { try service.unregister() }
        default: exit(2)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(error.localizedDescription.utf8))
        exit(1)
    }
}


#if !DEBUG
if CommandLine.arguments.contains("--setup-dock") {
    DockPin.installOnce(app: Bundle.main.bundleURL)
    exit(0)
}
if !CommandLine.arguments.contains("--background"),
   DockPin.isInstalled(Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser),
   DockPin.bundleID == "com.withqq.chu-launchpad",
   !(UserDefaults(suiteName: DockPin.bundleID) ?? .standard).bool(forKey: DockPin.marker) {
    let setup = Process()
    setup.executableURL = Bundle.main.executableURL
    setup.arguments = ["--setup-dock"]
    setup.standardOutput = FileHandle.nullDevice
    setup.standardError = FileHandle.nullDevice
    try? setup.run()
}
#endif

@MainActor
final class EntryDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(DockPin.appDisplayName).app")
        let configuration = NSWorkspace.OpenConfiguration()
        let background = CommandLine.arguments.contains("--background") || NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        configuration.activates = false
        configuration.arguments = background ? ["--background"] : []
        NSWorkspace.shared.openApplication(at: agent, configuration: configuration) { _, error in
            if let error { NSLog("Cannot open Chu Launchpad agent: %@", error.localizedDescription) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// A warm Dock click only needs IPC. Avoid initializing NSApplication on this path.
let agent = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(DockPin.appDisplayName).app")
let background = CommandLine.arguments.contains("--background")
if !background, let port = CFMessagePortCreateRemote(nil, DockPin.togglePortName(for: agent)),
   CFMessagePortSendRequest(port, 1, nil, 0, 0, nil, nil) == kCFMessagePortSuccess {
    exit(0)
}
if NSRunningApplication.runningApplications(withBundleIdentifier: DockPin.agentBundleID)
    .contains(where: { $0.isFinishedLaunching && $0.bundleURL?.standardizedFileURL == agent.standardizedFileURL }) {
    if !background {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(DockPin.toggleNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}

let delegate = EntryDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
