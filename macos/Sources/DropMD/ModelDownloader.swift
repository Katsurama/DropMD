import CryptoKit
import Foundation

private final class TaskHolder: @unchecked Sendable {
    weak var task: URLSessionTask?
}

/// 用 macOS 系统网络（URLSession）从 Hugging Face 下载高精度模型。
///
/// - 与 Safari 使用相同的网络设置：系统 DNS、HTTP/HTTPS/SOCKS 代理、PAC 自动代理配置。
/// - 只在用户同意后调用；使用临时会话，不保存 Cookie 和缓存。
/// - 版本固定为具体提交号；每个文件下载后校验完整性
///   （大文件校验官方提供的 SHA-256，小文件校验 Git 文件哈希）。
final class ModelDownloader: @unchecked Sendable {
    struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
        let blobId: String?
        let lfs: LFS?

        struct LFS: Decodable {
            let sha256: String
            let size: Int64
        }

        var byteCount: Int64 { lfs?.size ?? size ?? 0 }
    }

    struct ModelInfo: Decodable {
        let sha: String?
        let siblings: [Sibling]
    }

    enum DownloadError: LocalizedError {
        case http(Int, String)
        case integrity(String)
        case missingMarker(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let what):
                if code == 401 || code == 403 { return "服务器拒绝访问（HTTP \(code)）：\(what)" }
                if code == 404 { return "服务器上找不到文件（HTTP 404）：\(what)" }
                if code == 429 { return "请求过于频繁（HTTP 429），请稍后再试。" }
                if code >= 500 { return "Hugging Face 服务器暂时出错（HTTP \(code)），请稍后再试。" }
                return "下载失败（HTTP \(code)）：\(what)"
            case .integrity(let f): return "文件校验失败，可能下载不完整：\(f)。请重试。"
            case .missingMarker(let t): return "\(t) 下载后缺少必要文件，请重试。"
            case .badResponse(let what): return "服务器返回了无法识别的数据：\(what)"
            }
        }
    }

    private let session: URLSession
    private let lock = NSLock()
    private var currentTask: URLSessionTask?
    private var cancelled = false

    init() {
        let config = URLSessionConfiguration.ephemeral // 不保存 Cookie、缓存、凭据
        config.httpAdditionalHeaders = ["User-Agent": "DropMD/1.1 (macOS)"]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = currentTask
        lock.unlock()
        t?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func encodePath(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }

    /// 对限流（429）、服务器临时错误（5xx）和网络波动自动重试，最多 4 次
    private func withRetry<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                attempt += 1
                if isCancelled || attempt >= 4 { throw error }
                var delay = Double(attempt * attempt) * 5 // 5s、20s、45s
                switch error {
                case DownloadError.http(let code, _) where code == 429 || code >= 500:
                    if code == 429 { delay = max(delay, 30) }
                case let e as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(e.code):
                    break
                default:
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func fetchInfo(repo: String, revision: String) async throws -> ModelInfo {
        let url = URL(string: "https://huggingface.co/api/models/\(Self.encodePath(repo))/revision/\(revision)?blobs=true")!
        let (data, resp) = try await session.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DownloadError.http(code, repo) }
        do {
            return try JSONDecoder().decode(ModelInfo.self, from: data)
        } catch {
            throw DownloadError.badResponse(repo)
        }
    }

    /// 下载单个文件到 dest，期间回调已接收字节数
    private func downloadFile(_ url: URL, to dest: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let holder = TaskHolder()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
            timer.setEventHandler {
                if let task = holder.task { onBytes(task.countOfBytesReceived) }
            }
            let task = session.downloadTask(with: url) { tmp, resp, error in
                timer.cancel()
                if let error { return cont.resume(throwing: error) }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let tmp else {
                    return cont.resume(throwing: DownloadError.http(code, url.lastPathComponent))
                }
                do {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            holder.task = task
            lock.lock()
            currentTask = task
            let stop = cancelled
            lock.unlock()
            timer.resume()
            if stop { task.cancel() } else { task.resume() }
        }
    }

    private static func verify(_ file: URL, sibling: Sibling) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw DownloadError.integrity(sibling.rfilename) }
        defer { try? handle.close() }
        if let lfs = sibling.lfs {
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == lfs.sha256.lowercased() else { throw DownloadError.integrity(sibling.rfilename) }
        } else if let blobId = sibling.blobId {
            // Git 文件哈希：SHA-1("blob <大小>\0" + 内容)，仅用于完整性校验
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == blobId.lowercased() else { throw DownloadError.integrity(sibling.rfilename) }
        }
    }

    /// 下载缺少的模型组件。progress(已下载字节, 总字节, 当前说明)
    func download(_ components: [Engine.Missing], modelsDir: URL,
                  progress: @escaping @Sendable (Int64, Int64, String) -> Void) async throws {
        // 1. 先取得所有文件清单，计算总大小
        var plans: [(Engine.Missing, [Sibling])] = []
        for c in components {
            if let files = c.files, !files.isEmpty {
                // 使用程序内置的固定版本清单（文件名、大小、哈希），无需查询接口
                plans.append((c, files.map { f in
                    Sibling(rfilename: f.path, size: f.size, blobId: f.blobId,
                            lfs: f.sha256.map { Sibling.LFS(sha256: $0, size: f.size) })
                }))
            } else {
                progress(0, 0, "正在获取文件清单：\(c.title)")
                let info = try await withRetry(c.repoId) { try await fetchInfo(repo: c.repoId, revision: c.revision) }
                plans.append((c, info.siblings.filter { !$0.rfilename.hasPrefix(".") }))
            }
        }
        let total = plans.flatMap { $0.1 }.reduce(Int64(0)) { $0 + $1.byteCount }
        var done: Int64 = 0

        // 2. 逐个下载到临时文件夹，校验后再移到正式位置
        for (index, (c, files)) in plans.enumerated() {
            let partial = modelsDir.appendingPathComponent(c.folder + ".partial", isDirectory: true)
            let final = modelsDir.appendingPathComponent(c.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            for f in files {
                if isCancelled { throw CancellationError() }
                let dest = partial.appendingPathComponent(f.rfilename)
                // 断点续传（按文件）：已存在且校验通过的文件不再下载
                if FileManager.default.fileExists(atPath: dest.path), (try? Self.verify(dest, sibling: f)) != nil {
                    done += f.byteCount
                    progress(done, total, "(\(index + 1)/\(plans.count)) \(c.title)")
                    continue
                }
                let url = URL(string: "https://huggingface.co/\(Self.encodePath(c.repoId))/resolve/\(c.revision)/\(Self.encodePath(f.rfilename))")!
                let base = done
                let label = "(\(index + 1)/\(plans.count)) \(c.title)"
                try await withRetry(f.rfilename) {
                    try await downloadFile(url, to: dest) { received in
                        progress(base + received, total, label)
                    }
                }
                try Self.verify(dest, sibling: f)
                done += f.byteCount
                progress(done, total, label)
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            guard FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(c.marker).path) else {
                throw DownloadError.missingMarker(c.title)
            }
        }
    }

    /// 把网络错误转换为中文说明
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "已取消下载。" }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return "已取消下载。"
            case .notConnectedToInternet: return "没有连接到互联网，请检查网络。"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析 huggingface.co 的地址（DNS 失败）。请检查网络连接或 DNS 设置。"
            case .cannotConnectToHost: return "无法连接到 huggingface.co，所在网络可能限制了访问。"
            case .timedOut: return "连接超时，网络较慢或无法访问 huggingface.co。"
            case .networkConnectionLost: return "网络连接中断，请重试（已下载完成的文件不会重复下载）。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "安全连接（SSL 证书）验证失败。可能是网络中有拦截 HTTPS 的设备或安全软件。"
            case .internationalRoamingOff, .dataNotAllowed: return "当前网络不允许使用数据连接。"
            default: return "网络错误：\(e.localizedDescription)（代码 \(e.code.rawValue)）"
            }
        }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace { return "磁盘空间不足，请清理空间后重试。" }
        return error.localizedDescription
    }
}
