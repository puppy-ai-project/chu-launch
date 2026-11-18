import Foundation

@main struct UpdateRegression {
    static func main() throws {
        // 1. 字节与速率格式化检查
        precondition(UpdateFormat.byteCount(512) == "512 B")
        precondition(UpdateFormat.byteCount(2048) == "2 KB")
        precondition(UpdateFormat.byteCount(5 * 1_048_576) == "5.0 MB")
        precondition(UpdateFormat.speed(0) == "计算中…")
        precondition(UpdateFormat.speed(512 * 1024) == "512 KB/s")
        precondition(UpdateFormat.speed(3.5 * 1_048_576) == "3.5 MB/s")

        // 2. 构造真实 .app 并打包为 .zip，测试 UpdateInstaller 解压与定位
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ChuUpdateTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let fakeApp = srcDir.appendingPathComponent("SampleUpdate.app", isDirectory: true)
        let contentsDir = fakeApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contentsDir.appendingPathComponent("Info.plist"))

        let zipURL = root.appendingPathComponent("SampleUpdate.zip")
        let zipProc = Process()
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProc.arguments = ["-c", "-k", "--sequesterRsrc", srcDir.path, zipURL.path]
        try zipProc.run()
        zipProc.waitUntilExit()
        precondition(zipProc.terminationStatus == 0, "ditto should create test archive")

        let extractDir = root.appendingPathComponent("extract", isDirectory: true)
        let extractedApp = try UpdateInstaller.extractAppBundle(from: zipURL, workingDirectory: extractDir)
        precondition(extractedApp.lastPathComponent == "SampleUpdate.app", "extracted app should be found")

        // 3. 测试无 .app 的 zip 包会被安全拒绝
        let emptySrc = root.appendingPathComponent("emptySrc", isDirectory: true)
        try fm.createDirectory(at: emptySrc, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: emptySrc.appendingPathComponent("readme.txt"))
        let invalidZip = root.appendingPathComponent("invalid.zip")
        let invalidProc = Process()
        invalidProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        invalidProc.arguments = ["-c", "-k", emptySrc.path, invalidZip.path]
        try invalidProc.run()
        invalidProc.waitUntilExit()

        var rejected = false
        do {
            _ = try UpdateInstaller.extractAppBundle(from: invalidZip, workingDirectory: root.appendingPathComponent("extract2", isDirectory: true))
        } catch {
            rejected = true
        }
        precondition(rejected, "zip without .app bundle should be rejected")

        print("Update regression checks passed")
    }
}
