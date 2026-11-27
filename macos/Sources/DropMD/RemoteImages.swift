import AppKit

/// 在线图片：设置里打开“显示在线图片”后才下载。下载在后台进行，完成后通知单页重新排版。
enum RemoteImages {
    static let settingKey = "showRemoteImages"
    /// 有图片下载完成，或开关改变：单页需要重新排版
    static let changed = Notification.Name("DropMD.remoteImagesChanged")
    static let maxBytes = 10 << 20
    static let timeout: TimeInterval = 15

    static var enabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    private static let lock = NSLock()
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 100 << 20
        return c
    }()
    /// 下载中或下载失败的地址：开关切换前不再重复下载
    private static var attempted: Set<String> = []
    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    static func isRemote(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//")
    }

    /// 已下载好的图片。开关打开且还没下载时开始下载，先返回 nil（显示占位框）
    static func image(for path: String) -> NSImage? {
        guard enabled, let url = url(for: path) else { return nil }
        if let image = cache.object(forKey: path as NSString) { return image }
        lock.lock()
        let fresh = attempted.insert(path).inserted
        lock.unlock()
        if fresh { Task.detached(priority: .utility) { await fetch(path, url) } }
        return nil
    }

    /// 开关切换：清掉失败记录（下次重试）；关闭时清空缓存
    static func settingChanged() {
        lock.lock()
        attempted.removeAll()
        if !enabled { cache.removeAllObjects() }
        lock.unlock()
    }

    static func url(for path: String) -> URL? {
        guard let url = URL(string: path.hasPrefix("//") ? "https:" + path : path),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func fetch(_ path: String, _ url: URL) async {
        guard let (image, bytes) = await download(url) else { return }
        // 下载期间关掉了开关：丢掉，不显示（和关开关清缓存用同一把锁，不会清完又放回去）
        let keep = lock.withLock {
            if enabled { cache.setObject(image, forKey: path as NSString, cost: bytes) }
            return enabled
        }
        guard keep else { return }
        await MainActor.run { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// 超过大小上限、超时或不是图片就放弃，返回 nil
    static func download(_ url: URL) async -> (NSImage, Int)? {
        do {
            // 边下边数：声明的大小不可信（可能没有或是假的），超过上限马上停
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: timeout))
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false,
                  response.expectedContentLength <= Int64(maxBytes) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            return (image, data.count)
        } catch {
            return nil
        }
    }

    /// 只跟随到 http / https 的重定向
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let scheme = request.url?.scheme?.lowercased()
            completionHandler(scheme == "http" || scheme == "https" ? request : nil)
        }
    }
}
