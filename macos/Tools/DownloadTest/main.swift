// 构建流程用的测试工具：从标准输入读取引擎的 status JSON，
// 用 App 中同一份 ModelDownloader（URLSession）下载缺少的模型。
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let status = try decoder.decode(Engine.Status.self, from: data)
print("需要下载：\(status.missing.map(\.repoId))，保存到 \(status.modelsDir)")

/// 记录并节流打印下载进度，便于 CI 日志实时定位是否卡在某个模型或触发重试
private final class ProgressLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var lastLabel = ""
    private var lastPrint = Date.distantPast
    private var printedDone = false

    init(start: Date) {
        self.start = start
    }

    func log(done: Int64, total: Int64, label: String) {
        let now = Date()
        let shouldPrint: Bool = lock.withLock {
            let finished = total > 0 && done == total
            if finished && printedDone { return false }
            let changed = label != lastLabel
            let elapsed = now.timeIntervalSince(lastPrint) >= 15
            guard changed || elapsed || finished else { return false }
            lastLabel = label
            lastPrint = now
            if finished { printedDone = true }
            return true
        }
        guard shouldPrint else { return }
        let sec = Int(now.timeIntervalSince(start))
        print("[\(sec)s] \(label) \(done)/\(total) 字节")
        fflush(stdout)
    }
}

let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        let start = Date()
        let logger = ProgressLogger(start: start)
        try await ModelDownloader().download(status.missing, modelsDir: URL(fileURLWithPath: status.modelsDir)) { done, total, label in
            logger.log(done: done, total: total, label: label)
        }
        print(String(format: "下载并校验完成，用时 %.0f 秒", Date().timeIntervalSince(start)))
    } catch {
        print("下载失败：\(ModelDownloader.describe(error))  \(error)")
        exitCode = 1
    }
    sema.signal()
}
sema.wait()
exit(exitCode)
