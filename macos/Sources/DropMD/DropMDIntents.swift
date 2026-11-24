import AppKit
import AppIntents
import Foundation
import UniformTypeIdentifiers

enum DropMDIntentError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let message):
            return message
        }
    }
}

/// 在 DropMD 中新建一篇 Markdown 文档（支持传入标题与初始正文）
struct CreateMarkdownDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "新建 Markdown 文档"
    static let description = IntentDescription("在 DropMD 中新建一篇 Markdown 文档。")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "标题")
    var docTitle: String?

    @Parameter(title: "正文")
    var content: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        var parts: [String] = []
        if let t = docTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            parts.append("# \(t)")
        }
        if let c = content?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            parts.append(c)
        }
        let initial = parts.joined(separator: "\n\n")

        try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        if !initial.isEmpty {
            // 等待新建窗口完成首帧挂载后再写入初始内容
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string.isEmpty {
                let text = initial.hasSuffix("\n") ? initial : initial + "\n"
                if tv.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: text) {
                    tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
                    tv.didChangeText()
                }
            }
        }
        return .result()
    }
}

/// 向指定的 Markdown 文件末尾追加一段文字
struct AppendToMarkdownFileIntent: AppIntent {
    static let title: LocalizedStringResource = "向 Markdown 文档追加文字"
    static let description = IntentDescription("在指定的 Markdown 文件末尾追加一段文字。")

    @Parameter(title: "文件")
    var file: IntentFile

    @Parameter(title: "追加内容")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let addition = text.trimmingCharacters(in: .newlines)
        if let url = file.fileURL, FileManager.default.isWritableFile(atPath: url.path) {
            let existing = (try? Data(contentsOf: url)).map(MarkdownDocument.decode) ?? ""
            let updated = append(addition, to: existing)
            try Data(updated.utf8).write(to: url, options: .atomic)
            let name = url.lastPathComponent
            return .result(value: IntentFile(data: Data(updated.utf8), filename: name, type: .markdownText))
        }
        let existing = MarkdownDocument.decode(file.data)
        let updated = append(addition, to: existing)
        let name = file.filename.isEmpty ? "document.md" : file.filename
        return .result(value: IntentFile(data: Data(updated.utf8), filename: name, type: .markdownText))
    }

    private func append(_ addition: String, to existing: String) -> String {
        guard !addition.isEmpty else { return existing }
        if existing.isEmpty { return addition + "\n" }
        let separator = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + addition + "\n"
    }
}

/// 通过内嵌转换引擎将 PDF、Word、Excel、PowerPoint 或网页文件转换为 Markdown
struct ConvertFileToMarkdownIntent: AppIntent {
    static let title: LocalizedStringResource = "将文件转换为 Markdown"
    static let description = IntentDescription("将 PDF、Word、Excel、PowerPoint 或网页文件转换为 Markdown。")

    @Parameter(title: "文件")
    var file: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("DropMD-Intent-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let inputName = file.filename.isEmpty ? "input" : file.filename
        let srcURL: URL
        if let original = file.fileURL, fm.fileExists(atPath: original.path) {
            srcURL = original
        } else {
            let localCopy = workDir.appendingPathComponent(inputName)
            try file.data.write(to: localCopy)
            srcURL = localCopy
        }

        let baseName = srcURL.deletingPathExtension().lastPathComponent
        let dstURL = workDir.appendingPathComponent("\(baseName).md")

        let payload: [String: Any] = [
            "jobs": [["src": srcURL.path, "dst": dstURL.path]],
            "options": [
                "mode": "fast",
                "word_engine": "pandoc",
                "ocr_engine": "rapidocr",
                "vision_lang": "zh-Hans",
                "formulas": false,
            ],
        ]
        let reqData = try JSONSerialization.data(withJSONObject: payload)
        let status = try await Engine().run(["convert"], input: reqData) { _ in }
        guard status == 0, fm.fileExists(atPath: dstURL.path),
              let mdData = try? Data(contentsOf: dstURL) else {
            throw DropMDIntentError.conversionFailed(String(localized: "转换失败，请检查文件格式是否受支持。"))
        }
        return .result(value: IntentFile(data: mdData, filename: "\(baseName).md", type: .markdownText))
    }
}

/// 注册到系统「快捷指令」和 Siri 的常用动作
struct DropMDShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateMarkdownDocumentIntent(),
            phrases: [
                "用 \(.applicationName) 新建 Markdown 文档",
                "Create a Markdown document in \(.applicationName)",
            ],
            shortTitle: "新建 Markdown 文档",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: ConvertFileToMarkdownIntent(),
            phrases: [
                "用 \(.applicationName) 将文件转换为 Markdown",
                "Convert a file to Markdown with \(.applicationName)",
            ],
            shortTitle: "将文件转换为 Markdown",
            systemImageName: "arrow.down.doc"
        )
        AppShortcut(
            intent: AppendToMarkdownFileIntent(),
            phrases: [
                "用 \(.applicationName) 向 Markdown 文档追加文字",
                "Append text to a Markdown document in \(.applicationName)",
            ],
            shortTitle: "向 Markdown 文档追加文字",
            systemImageName: "text.append"
        )
    }
}
