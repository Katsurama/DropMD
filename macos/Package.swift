// swift-tools-version:5.9
// DropMD macOS 版界面（SwiftUI）。转换工作交给随 App 打包的本机引擎 dropmd-engine。
import PackageDescription

let package = Package(
    name: "DropMD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DropMD",
            path: "Sources/DropMD"
        ),
        // 构建流程用：验证 App 内的模型下载器（与 App 共用同一份源文件）
        .executableTarget(
            name: "DownloadTest",
            path: "Tools/DownloadTest"
        ),
    ]
)
