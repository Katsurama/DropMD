import Foundation

/// 安装新版本：从安装包（.zip 或 .dmg）中取出新 App，等旧 App 退出后替换并重新打开。
/// 只依赖 Foundation，可单独测试（tools/test_update.sh）。
enum AppUpdateInstaller {
    enum InstallError: Error {
        case badPackage
    }

    /// 从安装包取出 .app 复制到 staged，检查是同一个 App 且版本正确。
    /// .zip 直接解压（访达里不会出现任何东西）；.dmg 需要挂载（旧版本的发布只有 .dmg）。
    static func stage(package: URL, to staged: URL, bundleID: String?, version: String?) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("DropMD-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try? fm.removeItem(at: staged)
        if package.pathExtension.lowercased() == "zip" {
            try run("/usr/bin/ditto", ["-x", "-k", package.path, work.path])
            try copyApp(from: work, to: staged)
        } else {
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                         "-mountpoint", work.path, package.path])
            defer { try? run("/usr/bin/hdiutil", ["detach", work.path, "-force"]) }
            try copyApp(from: work, to: staged)
        }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        let id = info?["CFBundleIdentifier"] as? String
        let v = info?["CFBundleShortVersionString"] as? String
        guard id != nil, id == bundleID, version == nil || v == version else {
            try? fm.removeItem(at: staged)
            throw InstallError.badPackage
        }
    }

    private static func copyApp(from dir: URL, to staged: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        guard let source = items.first(where: { $0.pathExtension == "app" }) else { throw InstallError.badPackage }
        try run("/usr/bin/ditto", [source.path, staged.path])
    }

    /// 启动一个后台脚本：等进程 pid 退出后，用 staged 替换 app，再重新打开。
    /// 2 分钟内退出才重新打开（用户取消退出、稍后再退出时，只替换不打开）。
    /// 替换失败时恢复旧版本。
    static func replaceAfterExit(pid: Int32, app: URL, staged: URL, relaunch: Bool) throws {
        let script = """
        pid="$1"; app="$2"; new="$3"; relaunch="$4"; n=0
        while kill -0 "$pid" 2>/dev/null; do sleep 0.5; n=$((n+1)); done
        rm -rf "$app.old"
        if mv "$app" "$app.old" && mv "$new" "$app"; then rm -rf "$app.old"; else [ -d "$app" ] || mv "$app.old" "$app"; fi
        if [ "$relaunch" = 1 ] && [ "$n" -le 240 ]; then open "$app"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(pid), app.path, staged.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.badPackage }
    }
}
