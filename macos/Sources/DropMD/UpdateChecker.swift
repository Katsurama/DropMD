import AppKit
import CryptoKit
import Foundation

/// 版本号比较（语义化版本：1.2.0 > 1.2.0-beta.2 > 1.2.0-beta.1 > 1.1.1）
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]   // 例如 ["beta", "1"]；正式版为空
    let description: String

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = parts[0].split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        numbers = nums.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        description = s
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.numbers.count, b.numbers.count)
        for i in 0..<n {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        // 数字相同时：测试版 < 正式版
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            if let xi = Int(x), let yi = Int(y) { return xi < yi }
            if (Int(x) != nil) != (Int(y) != nil) { return Int(x) != nil }   // 数字标识小于文字标识
            return x < y
        }
        return a.prerelease.count < b.prerelease.count
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// GitHub Releases 中的一个版本
struct ReleaseInfo: Decodable, Identifiable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int64
    }

    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let htmlUrl: URL
    let publishedAt: String?
    let assets: [Asset]

    var id: String { tagName }
    var version: AppVersion? { AppVersion(tagName) }
    var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    /// App 内更新用的 zip（解压即可，不用挂载磁盘）；旧版本的发布没有
    var zip: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
    func checksum(for asset: Asset) -> Asset? {
        assets.first { $0.name == asset.name + ".sha256" }
    }
}

/// 软件更新：查询 GitHub Releases 上的新版本，下载安装包并校验。
/// 只有用户开启“自动检查”或手动点击“检查更新”时才会联网，不发送任何文件或个人信息。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing          // 正在解开安装包、准备新版本
        case readyToRestart      // 新版本已放好，重启后生效
        case downloaded(URL)     // 无法自动替换时：已打开安装包，由用户拖到“应用程序”
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var latest: ReleaseInfo?
    @Published var progress: Double = 0
    @Published var lastChecked: Date?

    private let defaults = UserDefaults.standard
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "autoCheckUpdates") } }
    @Published var includeBeta: Bool { didSet { defaults.set(includeBeta, forKey: "includeBetaUpdates") } }

    private var downloadTask: Task<Void, Never>?

    /// 发布安装包的 GitHub 仓库（Info.plist 中的 DropMDUpdateRepository，格式 owner/repo）
    static var repository: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "DropMDUpdateRepository") as? String
        guard let value, value.split(separator: "/").count == 2 else { return nil }
        return value
    }

    static var currentVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    static var currentVersion: AppVersion? { AppVersion(currentVersionText) }

    private init() {
        autoCheck = defaults.bool(forKey: "autoCheckUpdates")
        if defaults.object(forKey: "includeBetaUpdates") != nil {
            includeBeta = defaults.bool(forKey: "includeBetaUpdates")
        } else {
            includeBeta = UpdateChecker.currentVersion?.isPrerelease ?? false
        }
        lastChecked = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    // MARK: - 启动时

    /// App 启动时调用：首次启动询问是否自动检查；已开启时每天最多检查一次
    func launchCheck() {
        cleanUpOldFiles()
        guard Self.repository != nil else { return }
        if !defaults.bool(forKey: "askedAutoUpdate") {
            defaults.set(true, forKey: "askedAutoUpdate")
            let a = NSAlert()
            a.messageText = "是否自动检查更新？"
            a.informativeText = """
            每天最多查询一次，不发送任何文件或个人信息。可随时在“检查更新…”中更改。
            """
            a.addButton(withTitle: "自动检查")
            a.addButton(withTitle: "暂不")
            autoCheck = a.runModal() == .alertFirstButtonReturn
        }
        guard autoCheck else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task {
            await check()
            if state == .available, let latest {
                notifyAvailable(latest)
            }
        }
    }

    private func notifyAvailable(_ release: ReleaseInfo) {
        let a = NSAlert()
        a.messageText = "DropMD 有新版本：\(release.version?.description ?? release.tagName)"
        a.informativeText = "当前版本：\(Self.currentVersionText)"
        a.addButton(withTitle: "查看")
        a.addButton(withTitle: "以后再说")
        if a.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .showUpdates, object: nil)
        }
    }

    // MARK: - 检查

    func check() async {
        guard let repo = Self.repository else {
            state = .failed("此版本没有配置更新来源。")
            return
        }
        guard state != .checking && state != .downloading && state != .installing && state != .readyToRestart else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            authorize(&request)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                throw UpdateError.http(http.statusCode)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let releases = try decoder.decode([ReleaseInfo].self, from: data)
            let candidates = releases.filter { !$0.draft && $0.version != nil && (includeBeta || !$0.prerelease) }
            let newest = candidates.max { ($0.version!) < ($1.version!) }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: "lastUpdateCheck")
            latest = newest
            if let newest, let v = newest.version, let current = Self.currentVersion, current < v {
                state = .available
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    // MARK: - 下载

    /// 下载安装包，校验 SHA-256 后准备好新版本，用户点击“重新启动”后替换。
    /// App 所在位置不能写入时（如没有权限），改为打开安装包，由用户拖到“应用程序”。
    func downloadLatest() {
        let staged = Self.stagingURL
        // 能自动替换时优先下载 zip；只能手动安装时下载 dmg
        guard let release = latest, let package = (staged != nil ? release.zip : nil) ?? release.dmg else {
            if let url = latest?.htmlUrl { NSWorkspace.shared.open(url) }
            return
        }
        state = .downloading
        progress = 0
        downloadTask = Task {
            do {
                let file = try await download(package)
                if let checksum = release.checksum(for: package) {
                    let expected = try await fetchChecksum(checksum)
                    let actual = try await Task.detached { try UpdateChecker.sha256(of: file) }.value
                    guard expected == actual else {
                        try? FileManager.default.removeItem(at: file)
                        throw UpdateError.checksum
                    }
                }
                try Task.checkCancellation()
                if let staged {
                    state = .installing
                    let expected = release.version?.description
                    do {
                        try await Task.detached {
                            try AppUpdateInstaller.stage(package: file, to: staged, bundleID: Bundle.main.bundleIdentifier, version: expected)
                        }.value
                        try? FileManager.default.removeItem(at: file)
                        state = .readyToRestart
                        return
                    } catch {
                        // 自动准备失败时退回手动安装
                    }
                }
                let target = try moveToDownloads(file, name: package.name)
                state = .downloaded(target)
                NSWorkspace.shared.open(target)
            } catch is CancellationError {
                state = .available
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - 替换并重启

    /// 正在运行的 App
    private static var appURL: URL { Bundle.main.bundleURL }

    /// 新版本先放在 App 旁边（同一磁盘，替换时只需改名）；不能写入时返回 nil
    private static var stagingURL: URL? {
        let app = appURL
        let dir = app.deletingLastPathComponent()
        // 从“下载”等位置直接打开时，系统会把 App 放在临时的只读位置，不能替换
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: dir.path),
              FileManager.default.isWritableFile(atPath: app.path) else { return nil }
        return dir.appendingPathComponent(".DropMD-update.app")
    }

    /// 退出 DropMD，用新版本替换旧版本后重新打开。
    /// 有未保存的文档时，系统会先询问是否保存；用户取消退出则不替换。
    func restartToUpdate() {
        guard let staged = Self.stagingURL, FileManager.default.fileExists(atPath: staged.path) else {
            state = .failed("新版本文件不见了，请重新下载。")
            return
        }
        do {
            try AppUpdateInstaller.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                    app: Self.appURL, staged: staged, relaunch: true)
        } catch {
            state = .failed("无法启动更新：\(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// 启动时清理更新留下的文件：没用上的新版本、临时下载。
    /// 刚更新到新版本时，再把“下载”里的旧安装包移到废纸篓（可以从废纸篓恢复）。
    func cleanUpOldFiles() {
        let fm = FileManager.default
        if let staged = Self.stagingURL { try? fm.removeItem(at: staged) }
        let temp = fm.temporaryDirectory
        for item in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("DropMD-update-") || item.lastPathComponent.contains("-DropMD-macOS-") {
            try? fm.removeItem(at: item)
        }
        let current = Self.currentVersionText
        guard defaults.string(forKey: "lastLaunchedVersion") != current else { return }
        defaults.set(current, forKey: "lastLaunchedVersion")
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        for item in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        where Self.isOldPackage(item.lastPathComponent) {
            try? fm.trashItem(at: item, resultingItemURL: nil)
        }
    }

    /// DropMD 的安装包：DropMD-macOS-AppleSilicon.dmg，或重名时的“… 2.dmg”
    private static func isOldPackage(_ name: String) -> Bool {
        name.range(of: #"^DropMD-macOS-AppleSilicon( \d+)?\.(dmg|zip)$"#, options: .regularExpression) != nil
    }

    private func moveToDownloads(_ file: URL, name: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let target = uniqueURL(downloads.appendingPathComponent(name))
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func download(_ asset: ReleaseInfo.Asset) async throws -> URL {
        let capture = TaskCapture()
        // 定时读取下载进度（下载本身由系统在后台进行，不占用主线程）
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let t = capture.task { self?.progress = t.progress.fractionCompleted }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { ticker.cancel() }
        let (temp, response) = try await URLSession.shared.download(for: assetRequest(asset), delegate: capture)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temp)
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(asset.name)")
        try FileManager.default.moveItem(at: temp, to: target)
        progress = 1
        return target
    }

    /// 给发往 GitHub 的请求加上版本信息（GitHub 要求有 User-Agent）
    private func authorize(_ request: inout URLRequest) {
        request.setValue("DropMD/\(Self.currentVersionText)", forHTTPHeaderField: "User-Agent")
    }

    private func assetRequest(_ asset: ReleaseInfo.Asset) -> URLRequest {
        var request = URLRequest(url: asset.browserDownloadUrl)
        authorize(&request)
        return request
    }

    private func fetchChecksum(_ asset: ReleaseInfo.Asset) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: assetRequest(asset), delegate: TaskCapture())
        let text = String(decoding: data, as: UTF8.self)
        guard let hex = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              hex.count == 64 else { throw UpdateError.checksum }
        return hex.lowercased()
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - 错误

    enum UpdateError: Error {
        case http(Int)
        case checksum
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError {
            switch e {
            case .http(403), .http(429): return "GitHub 暂时拒绝了访问，请稍后再试。"
            case .http(404): return "找不到发布页面。"
            case .http(let code): return "服务器返回错误（\(code)）。"
            case .checksum: return "安装包校验失败，请重新下载。"
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "没有连接到互联网。"
            case .timedOut: return "连接超时。"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址。"
            case .cannotConnectToHost: return "无法连接到服务器。"
            default: return e.localizedDescription
            }
        }
        if error is DecodingError { return "无法读取版本信息。" }
        return error.localizedDescription
    }
}

/// 取得 URLSession 创建的下载任务，用来读取进度
private final class TaskCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        self.task = task
    }
}

extension Notification.Name {
    static let showUpdates = Notification.Name("DropMD.showUpdates")
}
