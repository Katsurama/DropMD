import Foundation

/// 本机转换引擎（PyInstaller 打包的 dropmd-engine）的调用封装。
/// 引擎在标准输出中逐行输出 JSON；本类不进行任何网络访问。
final class Engine: @unchecked Sendable {
    enum EngineError: LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "找不到转换引擎，程序可能不完整，请重新下载安装。"
            case .failed(let m): return m
            }
        }
    }

    struct Missing: Decodable, Identifiable, Sendable {
        let key: String
        let title: String
        let source: String
        let sizeMb: Int
        let repoId: String
        let revision: String
        let folder: String
        let marker: String
        /// 内置的固定版本文件清单（有则不需要在运行时查询 Hugging Face 接口）
        let files: [ManifestFile]?
        var id: String { key }
    }

    struct ManifestFile: Decodable, Sendable {
        let path: String
        let size: Int64
        let sha256: String?
        let blobId: String?
    }

    struct Status: Decodable, Sendable {
        let version: String
        let pandoc: Bool
        let ocrEngines: [String]
        let defaultOcr: String
        let modelsDir: String
        let missing: [Missing]
    }

    struct Event: Decodable, Sendable {
        let event: String?
        let index: Int?
        let ok: Bool?
        let info: String?
        let i: Int?
        let n: Int?
        let title: String?
        let error: String?
    }

    private let lock = NSLock()
    private var process: Process?

    private func locked(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    /// 引擎位置：DropMD.app/Contents/Resources/engine/dropmd-engine
    /// 开发时可用环境变量 DROPMD_ENGINE 指定。
    static var executableURL: URL? {
        if let env = ProcessInfo.processInfo.environment["DROPMD_ENGINE"] {
            return URL(fileURLWithPath: env)
        }
        let url = Bundle.main.resourceURL?.appendingPathComponent("engine/dropmd-engine")
        if let url, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        return nil
    }

    /// 引擎的日志（标准错误）写入 ~/Library/Logs/DropMD/engine.log，仅保存在本机。
    private static func logHandle() -> FileHandle {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DropMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        return (try? FileHandle(forWritingTo: file)) ?? FileHandle.nullDevice
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// 运行引擎命令，每输出一行 JSON 就回调一次。返回进程退出码。
    @discardableResult
    func run(_ args: [String], input: Data? = nil, onLine: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        guard let exe = Engine.executableURL else { throw EngineError.notFound }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--engine"] + args
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = Engine.logHandle()
        try p.run()
        locked { process = p }
        if let input {
            inp.fileHandleForWriting.write(input)
        }
        try? inp.fileHandleForWriting.close()
        for try await line in out.fileHandleForReading.bytes.lines {
            onLine(Data(line.utf8))
        }
        p.waitUntilExit()
        locked { process = nil }
        return p.terminationStatus
    }

    func status(formulas: Bool) async throws -> Status {
        let box = Box<Status>()
        try await run(["status"] + (formulas ? ["--formula"] : [])) { data in
            if let s = try? Engine.decoder.decode(Status.self, from: data) { box.value = s }
        }
        guard let s = box.value else { throw EngineError.failed("转换引擎没有正常响应。") }
        return s
    }

    static func decodeEvent(_ data: Data) -> Event? {
        try? decoder.decode(Event.self, from: data)
    }

    /// 结束正在运行的引擎（用于“停止”）。
    func terminate() {
        locked { process?.terminate() }
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}
