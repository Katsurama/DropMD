import AppKit

/// 网络图片：设置里打开“显示网络图片”后才下载。下载在后台进行，完成后通知单页重新排版。
enum RemoteImages {
    static let settingKey = "showRemoteImages"
    /// 有图片下载完成，或开关改变：单页需要重新排版
    static let changed = Notification.Name("DropMD.remoteImagesChanged")
    static let maxBytes = 10 << 20
    static let timeout: TimeInterval = 15

    static var enabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    /// 下载中或下载失败的地址：本次运行不再重复下载
    private static var attempted: Set<String> = []
    private static let session = URLSession(configuration: .ephemeral)

    static func isRemote(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//")
    }

    /// 已下载好的图片。开关打开且还没下载时开始下载，先返回 nil（显示占位框）
    static func image(for path: String) -> NSImage? {
        guard enabled, let url = url(for: path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let image = cache[path] { return image }
        guard attempted.insert(path).inserted else { return nil }
        Task.detached(priority: .utility) { await fetch(path, url) }
        return nil
    }

    static func url(for path: String) -> URL? {
        guard let url = URL(string: path.hasPrefix("//") ? "https:" + path : path),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func fetch(_ path: String, _ url: URL) async {
        guard let image = await download(url) else { return }
        lock.lock()
        cache[path] = image
        lock.unlock()
        await MainActor.run { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// 超过大小上限或超时就放弃，返回 nil
    static func download(_ url: URL) async -> NSImage? {
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: timeout))
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false,
                  response.expectedContentLength <= Int64(maxBytes) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            return image
        } catch {
            return nil
        }
    }
}
