import AppKit
import AppIntents
import CoreSpotlight
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
        if !initial.isEmpty {
            PendingDraftStore.store(initial.hasSuffix("\n") ? initial : initial + "\n")
        }
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            _ = PendingDraftStore.consume()
            throw error
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
            let rawData = try Data(contentsOf: url)
            var doc = rawData.isEmpty ? MarkdownDocument(text: "") : try MarkdownDocument(data: rawData)
            doc.text = append(addition, to: doc.text)
            let outData = doc.data()
            try outData.write(to: url, options: .atomic)
            let name = url.lastPathComponent
            return .result(value: IntentFile(data: outData, filename: name, type: .markdownText))
        }
        var doc = file.data.isEmpty ? MarkdownDocument(text: "") : try MarkdownDocument(data: file.data)
        doc.text = append(addition, to: doc.text)
        let outData = doc.data()
        let name = file.filename.isEmpty ? "document.md" : file.filename
        return .result(value: IntentFile(data: outData, filename: name, type: .markdownText))
    }

    private func append(_ addition: String, to existing: String) -> String {
        guard !addition.isEmpty else { return existing }
        if existing.isEmpty { return addition + "\n" }
        let separator = existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + addition + "\n"
    }
}

private final class IntentErrorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func record(_ info: String?) {
        guard let info, !info.isEmpty else { return }
        lock.withLock { message = info }
    }

    var latest: String? {
        lock.withLock { message }
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

        let rawLast = (file.filename as NSString).lastPathComponent
        let safeName = (rawLast.isEmpty || rawLast == "." || rawLast == "..") ? "input" : rawLast
        let srcURL: URL
        if let original = file.fileURL, fm.fileExists(atPath: original.path) {
            srcURL = original
        } else {
            let localCopy = workDir.appendingPathComponent(safeName)
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let errorHolder = IntentErrorHolder()
        let status = try await Engine().run(["convert"], input: reqData) { lineData in
            if let ev = try? decoder.decode(Engine.Event.self, from: lineData),
               ev.event == "result", ev.ok == false {
                errorHolder.record(ev.info)
            }
        }
        guard status == 0, fm.fileExists(atPath: dstURL.path),
              let mdData = try? Data(contentsOf: dstURL) else {
            let reason = errorHolder.latest ?? String(localized: "转换失败，请检查文件格式是否受支持。")
            throw DropMDIntentError.conversionFailed(reason)
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

/// 供 Siri 与系统聚焦搜索语义检索的 Markdown 文档实体（macOS 15+）
@available(macOS 15.0, *)
struct MarkdownDocumentEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Markdown 文档")
    static let defaultQuery = MarkdownDocumentQuery()

    var id: String

    @Property(title: "标题")
    var title: String

    @Property(title: "文件名")
    var displayName: String

    @Property(title: "关键词")
    var keywords: [String]

    @Property(title: "摘要片段")
    var excerpt: String

    init(record: IndexedDocumentRecord) {
        self.id = record.path
        self.title = record.title
        self.displayName = record.displayName
        self.keywords = record.keywords
        self.excerpt = record.excerpt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: displayName)
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attr = CSSearchableItemAttributeSet(contentType: .markdownText)
        attr.title = title
        attr.displayName = displayName
        attr.contentURL = URL(fileURLWithPath: id)
        attr.keywords = keywords
        attr.textContent = excerpt
        return attr
    }
}

@available(macOS 15.0, *)
struct MarkdownDocumentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MarkdownDocumentEntity] {
        IndexedDocumentStore.records(forPaths: identifiers).map(MarkdownDocumentEntity.init)
    }

    func entities(matching string: String) async throws -> [MarkdownDocumentEntity] {
        IndexedDocumentStore.search(string).map(MarkdownDocumentEntity.init)
    }

    func suggestedEntities() async throws -> [MarkdownDocumentEntity] {
        Array(IndexedDocumentStore.allRecords().prefix(10)).map(MarkdownDocumentEntity.init)
    }
}

/// 通过 Siri 或聚焦搜索直接打开已索引的 Markdown 文档
@available(macOS 15.0, *)
struct OpenMarkdownDocumentIntent: OpenIntent {
    static let title: LocalizedStringResource = "打开 Markdown 文档"

    @Parameter(title: "文档")
    var target: MarkdownDocumentEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: target.id)
        try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        return .result()
    }
}

/// 将文档更新回调绑定到 AppIntents 语义实体索引
enum DropMDEntityIndexer {
    static func registerHook() {
        guard #available(macOS 15.0, *) else { return }
        SpotlightAndActivity.onIndexDocument = { record in
            let entity = MarkdownDocumentEntity(record: record)
            Task.detached(priority: .utility) {
                try? await CSSearchableIndex.default().indexAppEntities([entity])
            }
        }
    }
}
