// 构建流程用的测试工具：从标准输入读取引擎的 status JSON，
// 用 App 中同一份 ModelDownloader（URLSession）下载缺少的模型。
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let status = try decoder.decode(Engine.Status.self, from: data)
print("需要下载：\(status.missing.map(\.repoId))，保存到 \(status.modelsDir)")

let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        let start = Date()
        try await ModelDownloader().download(status.missing, modelsDir: URL(fileURLWithPath: status.modelsDir)) { done, total, label in
            if total > 0, done == total { print("完成 \(label) \(done) 字节") }
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
