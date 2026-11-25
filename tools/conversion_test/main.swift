import Foundation

@main
struct ConversionStopTest {
    @MainActor
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let pdf = dir.appendingPathComponent("source.pdf")
        let ready = dir.appendingPathComponent("ready")
        let release = dir.appendingPathComponent("release")
        let started = dir.appendingPathComponent("converted")
        setenv("DROPMD_ENGINE", dir.appendingPathComponent("engine").path, 1)
        setenv("DROPMD_TEST_STATE", dir.path, 1)
        let model = AppModel()
        precondition(model.mode == .hq)
        model.add([pdf])
        let run = Task { await model.start() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(FileManager.default.fileExists(atPath: ready.path), "status query did not start")
        precondition(model.running)
        model.stop()
        try Data().write(to: release)
        await run.value  // An erroneous download modal blocks here and times out in the test runner.
        precondition(!model.running)
        precondition(model.statusText == String(localized: "已停止"))
        precondition(!FileManager.default.fileExists(atPath: started.path), "stopped run began converting")
        print("ok   状态查询返回缺失模型后，已停止的转换不弹窗、不启动引擎")
    }
}
