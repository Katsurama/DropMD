import AppKit
import CoreSpotlight
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 全语言文档默认命名建议（兼容 macOS 14–27）
enum DocumentTitleSuggester {
    /// 清洗为合法、简短的 macOS 文件名（不含扩展名）
    static func sanitizeFileName(_ raw: String, maxLength: Int = 40) -> String? {
        var s = raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|\0").union(.controlCharacters)
        s = s.unicodeScalars.map { invalid.contains($0) ? " " : String($0) }.joined()
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉前导点号避免变成隐藏文件
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        let trailingPunctuation = CharacterSet(charactersIn: "。，、；：！？.,:;!?")
        s = s.trimmingCharacters(in: trailingPunctuation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.trimmingCharacters(in: trailingPunctuation)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? nil : s
    }

    /// 跨语言通用兜底：一次分析截取片段，返回建议标题与是否含显式标题
    static func analyze(from markdown: String) -> (title: String?, hasHeading: Bool) {
        let head = String(markdown.prefix(4000))
        if let heading = extractHeadings(head).first?.title,
           let clean = sanitizeFileName(heading) {
            return (clean, true)
        }
        for block in MarkdownCodec.parse(head) {
            guard case .line(let line) = block else { continue }
            switch line.kind {
            case .body, .heading, .quote, .bullet, .ordered, .task:
                let plain = line.runs.filter { !$0.literal }.map(\.text).joined()
                if let clean = sanitizeFileName(plain) { return (clean, false) }
            }
        }
        return (nil, false)
    }

    /// 跨语言通用兜底：优先提取首个 Markdown 标题，否则提取第一行自然正文
    static func fallbackTitle(from markdown: String) -> String? {
        analyze(from: markdown).title
    }

    /// macOS 26+：当文章没有现成标题时，用系统端侧大模型生成简短摘要文件名
    @available(macOS 26.0, *)
    static func aiTitle(from markdown: String) async -> String? {
        #if canImport(FoundationModels)
        guard SiriAIManager.isLanguageModelAvailable else { return nil }
        let nonWhitespace = markdown.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard nonWhitespace >= 30 else { return nil }
        let excerpt = String(markdown.prefix(2000))
        let instructions = """
        Generate a short, natural document filename title in the exact same language as the document text.
        Maximum 15 characters for Chinese/Japanese or 6 words for English.
        Output only the plain title without quotes, file extension, or trailing punctuation.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: excerpt)
            return sanitizeFileName(response.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// 一次性传递待填入新文档的草稿（用于快捷指令等从外部传入初始正文）
enum PendingDraftStore {
    private static let lock = NSLock()
    private static var pending: String?

    static func store(_ text: String) {
        lock.withLock { pending = text }
    }

    static func consume() -> String? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}

/// 可供 Siri 与快捷指令语义检索的最近文档记录
struct IndexedDocumentRecord: Codable, Sendable, Equatable {
    let path: String
    let title: String
    let displayName: String
    let keywords: [String]
    let excerpt: String
    let updatedAt: Date
}

/// 持久化管理已索引的 Markdown 文档元数据（与 AppIntents 实体解耦，便于单元测试复用）
enum IndexedDocumentStore {
    static let defaultKey = "dropmd.indexedDocuments.v1"
    private static let lock = NSLock()
    private static let maxEntries = 100

    static func upsert(_ record: IndexedDocumentRecord, defaults: UserDefaults = .standard, key: String = defaultKey) {
        lock.withLock {
            var records = loadUnlocked(defaults: defaults, key: key)
            records.removeAll { $0.path == record.path }
            records.insert(record, at: 0)
            if records.count > maxEntries {
                records = Array(records.prefix(maxEntries))
            }
            saveUnlocked(records, defaults: defaults, key: key)
        }
    }

    static func allRecords(defaults: UserDefaults = .standard, key: String = defaultKey, verifyExists: Bool = true) -> [IndexedDocumentRecord] {
        lock.withLock {
            let records = loadUnlocked(defaults: defaults, key: key)
            guard verifyExists else { return records }
            let fm = FileManager.default
            let valid = records.filter { fm.fileExists(atPath: $0.path) }
            if valid.count != records.count {
                saveUnlocked(valid, defaults: defaults, key: key)
            }
            return valid
        }
    }

    static func records(forPaths paths: [String], defaults: UserDefaults = .standard, key: String = defaultKey, verifyExists: Bool = true) -> [IndexedDocumentRecord] {
        let wanted = Set(paths)
        return allRecords(defaults: defaults, key: key, verifyExists: verifyExists).filter { wanted.contains($0.path) }
    }

    static func search(_ query: String, defaults: UserDefaults = .standard, key: String = defaultKey, verifyExists: Bool = true) -> [IndexedDocumentRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = allRecords(defaults: defaults, key: key, verifyExists: verifyExists)
        guard !q.isEmpty else { return records }
        let terms = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return records.filter { rec in
            let haystack = ([rec.title, rec.displayName, rec.excerpt] + rec.keywords).joined(separator: "\n").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private static func loadUnlocked(defaults: UserDefaults, key: String) -> [IndexedDocumentRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([IndexedDocumentRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveUnlocked(_ records: [IndexedDocumentRecord], defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Spotlight 全文索引与 Siri 屏幕感知（NSUserActivity）
enum SpotlightAndActivity {
    static let activityType = "io.github.dropmd.editing"
    private static let domainIdentifier = "io.github.dropmd.documents"
    /// 主 App 注册后，在每次更新 Spotlight 索引时同步更新 AppIntents IndexedEntity
    static var onIndexDocument: (@Sendable (IndexedDocumentRecord) -> Void)?

    static func indexDocument(url: URL, text: String, headings: [DocumentHeading]) {
        let title = DocumentTitleSuggester.fallbackTitle(from: text) ?? url.deletingPathExtension().lastPathComponent
        let keywords = Array(headings.prefix(20).map(\.title))
        let excerpt = String(text.prefix(8000))

        let attr = CSSearchableItemAttributeSet(contentType: .markdownText)
        attr.title = title
        attr.displayName = url.lastPathComponent
        attr.contentURL = url
        attr.keywords = keywords
        attr.textContent = excerpt
        let item = CSSearchableItem(uniqueIdentifier: url.path, domainIdentifier: domainIdentifier, attributeSet: attr)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }

        let record = IndexedDocumentRecord(
            path: url.path,
            title: title,
            displayName: url.lastPathComponent,
            keywords: keywords,
            excerpt: String(text.prefix(2000)),
            updatedAt: Date()
        )
        IndexedDocumentStore.upsert(record)
        onIndexDocument?(record)
    }

    @MainActor
    static func updateWindowActivity(window: NSWindow?, url: URL?, text: String, headings: [DocumentHeading]) {
        guard let window else { return }
        let activity: NSUserActivity
        if let existing = window.userActivity, existing.activityType == activityType {
            activity = existing
        } else {
            activity = NSUserActivity(activityType: activityType)
            window.userActivity = activity
        }
        let title = url?.lastPathComponent ?? DocumentTitleSuggester.fallbackTitle(from: text) ?? String(localized: "未命名")
        activity.title = title
        activity.isEligibleForSearch = url != nil
        activity.isEligibleForHandoff = false
        let attr = CSSearchableItemAttributeSet(contentType: .markdownText)
        attr.title = title
        attr.contentURL = url
        attr.keywords = Array(headings.prefix(12).map(\.title))
        attr.textContent = String(text.prefix(2000))
        activity.contentAttributeSet = attr
        if let url {
            activity.userInfo = ["path": url.path]
        } else {
            activity.userInfo = nil
        }
        activity.needsSave = false
        activity.becomeCurrent()
    }
}
