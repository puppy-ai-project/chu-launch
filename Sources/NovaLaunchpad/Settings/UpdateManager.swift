import AppKit
import Foundation

// MARK: - 下载进度快照
struct UpdateDownloadProgress: Equatable, Sendable {
    let bytesWritten: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double

    /// 0.0...1.0；若服务端未提供 Content-Length 则为 nil（不确定进度）
    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(bytesWritten) / Double(totalBytes)))
    }
}

// MARK: - 更新状态机
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case noRelease
    case available(version: String, downloadURL: URL)
    case downloading(version: String, downloadURL: URL, progress: UpdateDownloadProgress)
    case downloaded(version: String, fileURL: URL)
    case installing(version: String, fileURL: URL)
    case failed(message: String, retryURL: URL?, retryVersion: String?)
}

// MARK: - 字节与速率格式化工具
enum UpdateFormat {
    static func byteCount(_ bytes: Int64) -> String {
        let clamped = max(0, bytes)
        let mb = Double(clamped) / 1_048_576.0
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else if clamped >= 1024 {
            return String(format: "%.0f KB", Double(clamped) / 1024.0)
        } else {
            return "\(clamped) B"
        }
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let clamped = max(0, bytesPerSecond)
        let mb = clamped / 1_048_576.0
        if mb >= 1.0 {
            return String(format: "%.1f MB/s", mb)
        } else if clamped >= 1024 {
            return String(format: "%.0f KB/s", clamped / 1024.0)
        } else if clamped > 0 {
            return String(format: "%.0f B/s", clamped)
        } else {
            return "计算中…"
        }
    }
}

// MARK: - 安装包解压与重启替换器
enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case archiveMissing
        case extractionFailed(Int32)
        case appBundleNotFound
        case invalidTargetBundle

        var errorDescription: String? {
            switch self {
            case .archiveMissing: return "未找到已下载的安装包文件。"
            case .extractionFailed(let code): return "解压安装包失败（退出码 \(code)）。"
            case .appBundleNotFound: return "压缩包内未找到有效的 .app 应用程序。"
            case .invalidTargetBundle: return "无法定位当前正在运行的 .app 安装路径。"
            }
        }
    }

    /// 将 zip 安装包解压到指定工作目录，并定位其中的 .app 包
    static func extractAppBundle(from zipURL: URL, workingDirectory: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: zipURL.path) else {
            throw InstallError.archiveMissing
        }
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, workingDirectory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InstallError.extractionFailed(process.terminationStatus)
        }

        guard let appURL = findAppBundle(in: workingDirectory) else {
            throw InstallError.appBundleNotFound
        }
        return appURL
    }

    /// 在解压目录中查找有效的 .app（跳过 __MACOSX）
    static func findAppBundle(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // 优先查找顶层 .app
        for url in entries where url.lastPathComponent != "__MACOSX" {
            if isValidAppBundle(url) { return url }
        }

        // 若压缩包多包了一层文件夹，继续向下一层查找
        for url in entries where url.lastPathComponent != "__MACOSX" {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let nested = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for candidate in nested where isValidAppBundle(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func isValidAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        return fm.fileExists(atPath: infoPlist.path)
    }

    /// 启动独立后台脚本：等待当前应用退出 -> 原子替换 .app -> 清除隔离属性 -> 启动新版
    static func launchInstallAndRelaunch(
        extractedAppURL: URL,
        targetAppURL: URL,
        cleanupDirectory: URL,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard targetAppURL.pathExtension.lowercased() == "app" else {
            throw InstallError.invalidTargetBundle
        }

        let script = """
        PID="$1"
        NEW_APP="$2"
        TARGET_APP="$3"
        CLEANUP_DIR="$4"
        BACKUP_APP="${TARGET_APP}.novabackup-$$"

        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true

        if [ -d "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi

        if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
            xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
            rm -rf "$BACKUP_APP" "$CLEANUP_DIR" 2>/dev/null || true
            /usr/bin/open -n "$TARGET_APP"
        else
            if [ -d "$BACKUP_APP" ]; then
                rm -rf "$TARGET_APP" 2>/dev/null || true
                mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
            fi
            exit 1
        fi
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "nova-updater", String(currentPID), extractedAppURL.path, targetAppURL.path, cleanupDirectory.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
}

// MARK: - URLSession 下载代理（线程安全采样速率与保存文件）
private final class UpdateDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var destinationURL: URL

    var onProgress: (@Sendable (UpdateDownloadProgress) -> Void)?
    var onFinished: (@Sendable (Result<URL, Error>) -> Void)?

    init(destinationURL: URL) {
        self.destinationURL = destinationURL
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        var shouldEmit = false
        var currentSpeed: Double = 0

        lock.lock()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed >= 0.25 || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) {
            if elapsed > 0.01 {
                let delta = max(0, totalBytesWritten - lastSampleBytes)
                let instant = Double(delta) / elapsed
                smoothedSpeed = smoothedSpeed > 0 ? (smoothedSpeed * 0.55 + instant * 0.45) : instant
            }
            lastSampleTime = now
            lastSampleBytes = totalBytesWritten
            currentSpeed = smoothedSpeed
            shouldEmit = true
        }
        lock.unlock()

        if shouldEmit {
            onProgress?(UpdateDownloadProgress(
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                bytesPerSecond: currentSpeed
            ))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            onFinished?(.failure(URLError(.badServerResponse)))
            return
        }

        let fm = FileManager.default
        let target = destinationURL
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: location, to: target)
            onFinished?(.success(target))
        } catch {
            onFinished?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinished?(.failure(error))
        }
    }
}

// MARK: - 应用内更新协调器 (检查 -> 下载 -> 解压 -> 重启安装)
@MainActor final class AppUpdateManager {
    private(set) var state: UpdateState = .idle {
        didSet { onStateChanged?(state) }
    }
    var onStateChanged: ((UpdateState) -> Void)?

    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: UpdateDownloadSessionDelegate?
    private var downloadGeneration = 0

    static var updatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NovaLaunchpad/Updates", isDirectory: true)
    }

    func checkForUpdates() {
        switch state {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }

        state = .checking
        Task {
            do {
                let release = try await GitHubRelease.latest()
                if let release {
                    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
                    if release.version.compare(current, options: .numeric) == .orderedDescending {
                        state = .available(version: release.version, downloadURL: release.downloadURL)
                    } else {
                        state = .upToDate(currentVersion: current)
                    }
                } else {
                    state = .noRelease
                }
            } catch {
                state = .failed(message: "检查更新失败：\(error.localizedDescription)", retryURL: nil, retryVersion: nil)
            }
        }
    }

    func startDownload() {
        let targetVersion: String
        let targetURL: URL
        switch state {
        case .available(let version, let url):
            targetVersion = version
            targetURL = url
        case .failed(_, let retryURL?, let retryVersion?):
            targetVersion = retryVersion
            targetURL = retryURL
        default:
            return
        }

        cancelActiveSession()
        downloadGeneration += 1
        let generation = downloadGeneration

        let fileName = targetURL.lastPathComponent.isEmpty ? "NovaLaunchpad-\(targetVersion).zip" : targetURL.lastPathComponent
        let destinationURL = Self.updatesDirectory.appendingPathComponent(fileName)

        let delegate = UpdateDownloadSessionDelegate(destinationURL: destinationURL)
        delegate.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadGeneration == generation else { return }
                self.state = .downloading(version: targetVersion, downloadURL: targetURL, progress: progress)
            }
        }
        delegate.onFinished = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.downloadGeneration == generation else { return }
                self.cleanupSessionReferences()
                switch result {
                case .success(let savedURL):
                    self.state = .downloaded(version: targetVersion, fileURL: savedURL)
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                        self.state = .available(version: targetVersion, downloadURL: targetURL)
                    } else {
                        self.state = .failed(
                            message: "下载失败：\(error.localizedDescription)",
                            retryURL: targetURL,
                            retryVersion: targetVersion
                        )
                    }
                }
            }
        }

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: targetURL)
        request.setValue("NovaLaunchpad", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)

        downloadDelegate = delegate
        downloadSession = session
        downloadTask = task

        state = .downloading(
            version: targetVersion,
            downloadURL: targetURL,
            progress: UpdateDownloadProgress(bytesWritten: 0, totalBytes: -1, bytesPerSecond: 0)
        )
        task.resume()
    }

    func cancelDownload() {
        guard case .downloading(let version, let url, _) = state else { return }
        downloadGeneration += 1
        cancelActiveSession()
        state = .available(version: version, downloadURL: url)
    }

    func installAndRestart() {
        guard case .downloaded(let version, let zipURL) = state else { return }
        state = .installing(version: version, fileURL: zipURL)

        let targetAppURL = Bundle.main.bundleURL
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaLaunchpad-Install-\(UUID().uuidString)", isDirectory: true)

        Task {
            do {
                let extractedApp = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.extractAppBundle(from: zipURL, workingDirectory: extractDir)
                }.value

                try UpdateInstaller.launchInstallAndRelaunch(
                    extractedAppURL: extractedApp,
                    targetAppURL: targetAppURL,
                    cleanupDirectory: extractDir
                )

                // 短暂延迟确保安装 helper 进程已稳定接管，随后退出当前应用触发替换与重启
                try? await Task.sleep(for: .milliseconds(150))
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: extractDir)
                state = .failed(
                    message: "安装失败：\(error.localizedDescription)",
                    retryURL: nil,
                    retryVersion: nil
                )
            }
        }
    }

    private func cancelActiveSession() {
        downloadTask?.cancel()
        downloadSession?.invalidateAndCancel()
        cleanupSessionReferences()
    }

    private func cleanupSessionReferences() {
        downloadSession?.finishTasksAndInvalidate()
        downloadTask = nil
        downloadSession = nil
        downloadDelegate = nil
    }
}
