import AppKit
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// 智能模型使用偏好（存储在 UserDefaults）
enum AIModelPreference: String, CaseIterable, Identifiable {
    case auto
    case onDeviceOnly
    case preferCloud

    static let storageKey = "aiModelPreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动（长文使用私有云）")
        case .onDeviceOnly: return String(localized: "仅本机")
        case .preferCloud: return String(localized: "优先私有云")
        }
    }

    static var current: AIModelPreference {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AIModelPreference(rawValue: raw) ?? .auto
    }
}

/// 文档内问答单条记录
struct DocumentQAItem: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String
    var isLoading = false
    var isError = false
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct GeneratedMarkdownTable {
    @Guide(description: "Column headers")
    var headers: [String]
    @Guide(description: "Table rows, each matching the column count")
    var rows: [[String]]
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedTaskList {
    @Guide(description: "Actionable todo items extracted from the text")
    var items: [String]
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedFrontMatter {
    @Guide(description: "Concise document title")
    var title: String
    @Guide(description: "3 to 5 topical tags")
    var tags: [String]
    @Guide(description: "One-sentence summary")
    var summary: String
}
#endif

/// Apple Intelligence / Siri AI 功能可用性检测与端侧/私有云大模型调用
enum SiriAIManager {
    /// 是否支持系统原生离线翻译弹窗（macOS 14.4+）
    static var isTranslationAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// 是否支持系统原生离线整篇文档翻译（macOS 15.0+）
    static var isDocumentTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 是否支持系统写作工具（Writing Tools，macOS 15.2+）
    static var isWritingToolsAvailable: Bool {
        if #available(macOS 15.2, *) { return true }
        return false
    }

    /// 是否支持系统内置大模型（macOS 26+ 且已开启可用）
    static var isLanguageModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// 是否支持 Apple 私有云计算大模型（macOS 27+）
    static var isPrivateCloudAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }

    /// 是否支持系统图乐园（Image Playground，macOS 15.2+）
    static var isImagePlaygroundAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.2, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }

    /// 根据用户偏好与文本长度判断是否尝试使用私有云模型
    static func shouldUsePrivateCloud(preference: AIModelPreference, contentLength: Int, threshold: Int = 2400) -> Bool {
        switch preference {
        case .onDeviceOnly:
            return false
        case .preferCloud:
            return true
        case .auto:
            return contentLength > threshold
        }
    }

    #if canImport(FoundationModels)
    /// 统一会话调度：按偏好与字数优先尝试私有云，失败时自动回退到本机模型
    @available(macOS 26.0, *)
    private static func runWithSession<T>(
        instructions: String,
        contentLength: Int,
        operation: (LanguageModelSession) async throws -> T
    ) async throws -> T {
        let wantCloud = shouldUsePrivateCloud(preference: AIModelPreference.current, contentLength: contentLength)
        if #available(macOS 27.0, *), wantCloud {
            let cloudModel = PrivateCloudComputeLanguageModel()
            if cloudModel.isAvailable {
                do {
                    let cloudSession = LanguageModelSession(model: cloudModel, instructions: instructions)
                    return try await operation(cloudSession)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 断网或私有云暂不可用时静默回退到本机端侧模型
                }
            }
        }
        let localSession = LanguageModelSession(instructions: instructions)
        return try await operation(localSession)
    }
    #endif

    /// 使用系统内置大模型将杂乱纯文本整理为结构清晰的 Markdown
    @available(macOS 26.0, *)
    static func smartFormatMarkdown(_ input: String) async throws -> String {
        #if canImport(FoundationModels)
        let instructions = """
        You are a Markdown formatting assistant.
        Reformat the user's text into clean, well-structured Markdown (with appropriate # headings, lists, bold emphasis, or tables when fitting).
        Keep the exact original language, meaning, and all factual content without adding or deleting information.
        Output only the Markdown body without wrapping it in a ```markdown code fence.
        """
        let response = try await runWithSession(instructions: instructions, contentLength: input.count) { session in
            try await session.respond(to: input)
        }
        return stripOuterMarkdownFence(response.content)
        #else
        return input
        #endif
    }

    static func stripOuterMarkdownFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        let first = lines[0].trimmingCharacters(in: .whitespaces).lowercased()
        let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
        if (first == "```" || first == "```markdown" || first == "```md"), last == "```" {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// 按段落切分为不超过 maxChars 的块（用于长文档本机端侧大模型分段摘要）
    static func splitIntoChunks(_ text: String, maxChars: Int = 2400) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let limit = max(200, maxChars)
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        for para in paragraphs {
            if para.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var idx = para.startIndex
                while idx < para.endIndex {
                    let next = para.index(idx, offsetBy: limit, limitedBy: para.endIndex) ?? para.endIndex
                    let slice = String(para[idx..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !slice.isEmpty { chunks.append(slice) }
                    idx = next
                }
                continue
            }
            let candidate = current.isEmpty ? para : "\(current)\n\n\(para)"
            if candidate.count <= limit {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = para
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 使用系统 Siri AI 模型生成文章要点列表（支持整篇全文与所选片段，长文支持私有云单次或本机分段汇总）
    @available(macOS 26.0, *)
    static func summarizeBullets(_ input: String, isSelection: Bool = false) async throws -> [String] {
        #if canImport(FoundationModels)
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let scopeDirective = isSelection
            ? "Summarize only the user's selected excerpt into 3 to 5 concise bullet points in the exact same language as the excerpt."
            : "Summarize the entire document broadly across all its major sections into 3 to 5 concise bullet points in the exact same language as the document. Do not focus on just one paragraph."

        let directInstructions = """
        \(scopeDirective)
        Each line must start with "- ".
        Output only the bullet list without any heading, intro, or code fence.
        """

        // 若满足私有云条件，优先尝试单次私有云全局摘要，失败自动回退到本机分段处理
        if #available(macOS 27.0, *),
           shouldUsePrivateCloud(preference: AIModelPreference.current, contentLength: normalized.count) {
            let cloudModel = PrivateCloudComputeLanguageModel()
            if cloudModel.isAvailable {
                do {
                    let cloudSession = LanguageModelSession(model: cloudModel, instructions: directInstructions)
                    let payload = String(normalized.prefix(24000))
                    let raw = try await cloudSession.respond(to: payload).content
                    let parsed = parseSummaryBullets(from: raw)
                    if !parsed.isEmpty { return parsed }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 回退到本机分段逻辑
                }
            }
        }

        let chunks = Array(splitIntoChunks(normalized, maxChars: 2400).prefix(12))
        guard !chunks.isEmpty else { return [] }

        let rawBullets: String
        if chunks.count == 1 {
            let session = LanguageModelSession(instructions: directInstructions)
            rawBullets = try await session.respond(to: chunks[0]).content
        } else {
            // 长文分段提炼要点，再合并由新会话汇总（纯本机离线运行，避免超出上下文上限）
            var partials: [String] = []
            let chunkInstructions = """
            Extract 2 to 3 key bullet points from this excerpt in the exact same language as the excerpt.
            Each line must start with "- ".
            Output only the bullet points.
            """
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let s = LanguageModelSession(instructions: chunkInstructions)
                let part = try await s.respond(to: "Part \(i + 1):\n\n\(chunk)").content
                let clean = stripOuterMarkdownFence(part)
                if !clean.isEmpty { partials.append(clean) }
            }
            try Task.checkCancellation()
            let combineInstructions = """
            Synthesize the following excerpt summaries from the entire document into 3 to 5 concise, non-redundant overall bullet points in the exact same language.
            Each line must start with "- ".
            Output only the final bullet list without any heading, intro, or code fence.
            """
            let finalSession = LanguageModelSession(instructions: combineInstructions)
            rawBullets = try await finalSession.respond(to: partials.joined(separator: "\n\n")).content
        }
        return parseSummaryBullets(from: rawBullets)
        #else
        return []
        #endif
    }

    static func parseSummaryBullets(from raw: String) -> [String] {
        let stripped = stripOuterMarkdownFence(raw)
        return stripped.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // 循环剥离重复的列表标记（如 "- - 正文" 或 "* • 正文"）
                while true {
                    if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ") {
                        s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    } else if let r = s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                        s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                }
                return s
            }
            .filter { !$0.isEmpty }
    }

    static func formatSummaryCallout(bullets: [String]) -> String {
        let clean = bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "" }
        return (["> [!NOTE]"] + clean.map { "> - \($0)" }).joined(separator: "\n")
    }

    static func formatSummaryCallout(from raw: String) -> String {
        formatSummaryCallout(bullets: parseSummaryBullets(from: raw))
    }

    /// 将摘要提示框插入 YAML 之后，若紧随其后为一级标题（# ...）则插在一级标题正下方
    static func insertSummaryCallout(_ callout: String, into markdown: String) -> String {
        let cleanCallout = callout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCallout.isEmpty else { return markdown }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let (blocks, groups, lines) = MarkdownCodec.parseWithSource(normalized)

        var insertLine = 0
        var groupIndex = 0
        if let first = groups.first,
           case .raw(let rawText) = blocks[first.blocks.lowerBound],
           rawText.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
            insertLine = first.lines.upperBound
            groupIndex = 1
        }
        if groupIndex < groups.count {
            let g = groups[groupIndex]
            if g.blocks.lowerBound < blocks.count,
               case .line(let line) = blocks[g.blocks.lowerBound],
               case .heading(1) = line.kind {
                insertLine = g.lines.upperBound
            }
        }

        let before = lines[..<min(insertLine, lines.count)]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        let after = lines[min(insertLine, lines.count)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)

        let parts = [before, cleanCallout, after].filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: - 结构化写作小工具（@Generable）与文档内问答

    /// 将表头与行数据规范化为标准 Markdown 表格
    static func formatMarkdownTable(headers: [String], rows: [[String]]) -> String {
        let sanitize: (String) -> String = { raw in
            raw.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleanHeaders = headers.map(sanitize).filter { !$0.isEmpty }
        guard !cleanHeaders.isEmpty else { return "" }
        let colCount = cleanHeaders.count
        var lines: [String] = [
            "| " + cleanHeaders.joined(separator: " | ") + " |",
            "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |",
        ]
        for row in rows {
            var cells = row.prefix(colCount).map(sanitize)
            if cells.count < colCount {
                cells.append(contentsOf: Array(repeating: "", count: colCount - cells.count))
            }
            if cells.allSatisfy({ $0.isEmpty }) { continue }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// 标准化待办事项条目，去空去重后生成 `- [ ] ...` 列表
    static func formatTaskList(_ items: [String]) -> String {
        var seen: Set<String> = []
        var lines: [String] = []
        for raw in items {
            let cleaned = parseSummaryBullets(from: raw).joined(separator: " ")
                .replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            lines.append("- [ ] \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    /// 生成安全转义的 YAML Front Matter
    static func formatYAMLFrontMatter(title: String, date: String, tags: [String], summary: String) -> String {
        let quote: (String) -> String = { raw in
            let oneLine = raw.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let escaped = oneLine
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenTags: Set<String> = []
        let cleanTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenTags.insert($0).inserted }

        var out: [String] = ["---"]
        if !cleanTitle.isEmpty { out.append("title: \(quote(cleanTitle))") }
        if !cleanDate.isEmpty { out.append("date: \(cleanDate)") }
        if !cleanTags.isEmpty {
            out.append("tags:")
            for tag in cleanTags {
                out.append("  - \(quote(tag))")
            }
        }
        if !cleanSummary.isEmpty { out.append("summary: \(quote(cleanSummary))") }
        out.append("---")
        return out.joined(separator: "\n")
    }

    /// 若文档开头已有 `---` YAML 块则替换之，否则插入文档开头并空一行
    static func upsertYAMLFrontMatter(_ yaml: String, into markdown: String) -> String {
        let cleanYAML = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanYAML.isEmpty else { return markdown }
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let (blocks, groups, lines) = MarkdownCodec.parseWithSource(normalized)
        var bodyStartLine = 0
        if let first = groups.first,
           first.blocks.lowerBound < blocks.count,
           case .raw(let rawText) = blocks[first.blocks.lowerBound],
           rawText.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
            bodyStartLine = first.lines.upperBound
        }
        let body = lines[min(bodyStartLine, lines.count)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return body.isEmpty ? cleanYAML + "\n" : cleanYAML + "\n\n" + body + "\n"
    }

    /// 为问答准备文档上下文：短文保留全文，长文保留开头概览并按问题关键词挑选最相关段落
    static func prepareContextForQA(document: String, question: String, maxChars: Int) -> String {
        let normalized = document.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, maxChars > 0 else { return "" }
        if normalized.count <= maxChars { return normalized }

        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count > 1 else { return String(normalized.prefix(maxChars)) }

        let keywords = extractQueryTokens(from: question)
        let leadBudget = max(400, maxChars / 3)
        var selectedIndices: Set<Int> = []
        var usedChars = 0

        for i in paragraphs.indices {
            let p = paragraphs[i]
            if usedChars + p.count + 2 <= leadBudget || i == 0 {
                selectedIndices.insert(i)
                usedChars += p.count + 2
            } else {
                break
            }
        }

        let scored = paragraphs.indices
            .filter { !selectedIndices.contains($0) }
            .map { idx -> (idx: Int, score: Int) in
                let lower = paragraphs[idx].lowercased()
                let score = keywords.reduce(0) { acc, kw in
                    acc + (lower.contains(kw) ? max(1, kw.count) : 0)
                }
                return (idx, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.idx < rhs.idx
            }

        for item in scored {
            let len = paragraphs[item.idx].count + 2
            if usedChars + len <= maxChars {
                selectedIndices.insert(item.idx)
                usedChars += len
            }
        }

        let ordered = selectedIndices.sorted().map { paragraphs[$0] }
        let joined = ordered.joined(separator: "\n\n")
        return joined.count <= maxChars ? joined : String(joined.prefix(maxChars))
    }

    private static func extractQueryTokens(from question: String) -> [String] {
        let lower = question.lowercased()
        var tokens: [String] = []
        var buffer = ""
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let s = String(scalar)
                if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
                    || scalar.value >= 0x3040 && scalar.value <= 0x30FF {
                    if !buffer.isEmpty {
                        tokens.append(buffer)
                        buffer = ""
                    }
                    tokens.append(s)
                } else {
                    buffer.append(s)
                }
            } else if !buffer.isEmpty {
                tokens.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { tokens.append(buffer) }
        return Array(Set(tokens.filter { $0.count >= 2 || ($0.unicodeScalars.first.map { $0.value >= 0x4E00 } ?? false) }))
    }

    /// 将所选混乱文本转换为结构化 Markdown 表格
    @available(macOS 26.0, *)
    static func convertToMarkdownTable(_ input: String) async throws -> String {
        #if canImport(FoundationModels)
        let instructions = """
        Convert the user's text or data into a structured table with concise column headers and aligned rows.
        Keep the exact original language and factual values.
        """
        let response = try await runWithSession(instructions: instructions, contentLength: input.count) { session in
            try await session.respond(to: input, generating: GeneratedMarkdownTable.self)
        }
        return formatMarkdownTable(headers: response.content.headers, rows: response.content.rows)
        #else
        return ""
        #endif
    }

    /// 从文本或全文中提取可执行的待办任务清单
    @available(macOS 26.0, *)
    static func extractTaskList(_ input: String) async throws -> String {
        #if canImport(FoundationModels)
        let instructions = """
        Extract concrete, actionable todo items or next steps from the user's text in the exact same language as the text.
        Keep each item concise and clear. Return an empty list if there are no actionable items.
        """
        let trimmed = String(input.prefix(12000))
        let response = try await runWithSession(instructions: instructions, contentLength: trimmed.count) { session in
            try await session.respond(to: trimmed, generating: GeneratedTaskList.self)
        }
        return formatTaskList(response.content.items)
        #else
        return ""
        #endif
    }

    /// 为当前 Markdown 文档生成结构化 YAML Front Matter（title / date / tags / summary）
    @available(macOS 26.0, *)
    static func generateFrontMatter(for markdown: String, date: Date = Date()) async throws -> String {
        #if canImport(FoundationModels)
        let preferCloud = isPrivateCloudAvailable
            && shouldUsePrivateCloud(preference: AIModelPreference.current, contentLength: markdown.count)
        let excerpt = String(markdown.prefix(preferCloud ? 16000 : 8000))
        let instructions = """
        Generate metadata (concise title, 3 to 5 topical tags, and a one-sentence summary) for the user's Markdown document in the exact same language as the document.
        """
        let response = try await runWithSession(instructions: instructions, contentLength: excerpt.count) { session in
            try await session.respond(to: excerpt, generating: GeneratedFrontMatter.self)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        return formatYAMLFrontMatter(
            title: response.content.title,
            date: dateString,
            tags: response.content.tags,
            summary: response.content.summary
        )
        #else
        return ""
        #endif
    }

    /// 针对当前文档回答用户提问（支持最近几轮追问上下文）
    @available(macOS 26.0, *)
    static func answerQuestion(
        _ question: String,
        document: String,
        history: [(question: String, answer: String)]
    ) async throws -> String {
        #if canImport(FoundationModels)
        let useCloud = isPrivateCloudAvailable
            && shouldUsePrivateCloud(preference: AIModelPreference.current, contentLength: document.count)
        let maxChars = useCloud ? 20000 : 5500
        let context = prepareContextForQA(document: document, question: question, maxChars: maxChars)
        let instructions = """
        Answer concisely in the same language as the user's message, using the provided document when relevant. If the document does not mention the requested information, say so clearly.
        """
        var promptParts = ["Document content:\n\n\(context)"]
        let recent = history.suffix(3).filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !recent.isEmpty {
            let histText = recent.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
            promptParts.append("Recent conversation:\n\(histText)")
        }
        promptParts.append("Current question: \(question)")
        let prompt = promptParts.joined(separator: "\n\n---\n\n")
        let response = try await runWithSession(instructions: instructions, contentLength: document.count) { session in
            try await session.respond(to: prompt)
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return ""
        #endif
    }
}

/// 保格式整篇 Markdown 翻译核心（跳过代码块、行内代码、数学公式、YAML/HTML、图片与链接地址）
enum MarkdownTranslator {
    struct Segment: Sendable {
        let id: String
        let text: String
    }

    static func extractSegments(from markdown: String) -> [Segment] {
        var blocks = MarkdownCodec.parse(markdown)
        var segments: [Segment] = []
        var nextID = 0
        visitTranslatableStrings(&blocks) { raw in
            let (_, core, _) = splitEdgeWhitespace(raw)
            guard !core.isEmpty else { return }
            segments.append(Segment(id: "\(nextID)", text: core))
            nextID += 1
        }
        return segments
    }

    static func applyTranslations(_ translations: [String: String], to markdown: String) -> String {
        var blocks = MarkdownCodec.parse(markdown)
        var nextID = 0
        visitTranslatableStrings(&blocks) { raw in
            let (leading, core, trailing) = splitEdgeWhitespace(raw)
            guard !core.isEmpty else { return }
            let id = "\(nextID)"
            nextID += 1
            if let translated = translations[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translated.isEmpty {
                raw = leading + translated + trailing
            }
        }
        return MarkdownCodec.serialize(blocks)
    }

    private static func visitTranslatableStrings(_ blocks: inout [MDBlock], _ visit: (inout String) -> Void) {
        for i in blocks.indices {
            switch blocks[i] {
            case .line(var line):
                visitRuns(&line.runs, visit)
                blocks[i] = .line(line)
            case .table(var rows, let align):
                for r in rows.indices {
                    for c in rows[r].indices {
                        visitRuns(&rows[r][c], visit)
                    }
                }
                blocks[i] = .table(rows, align: align)
            case .details(var summary, var body, let open):
                visit(&summary)
                visitTranslatableStrings(&body, visit)
                blocks[i] = .details(summary: summary, body: body, open: open)
            case .code, .rule, .raw:
                break
            }
        }
    }

    private static func visitRuns(_ runs: inout [MDRun], _ visit: (inout String) -> Void) {
        for i in runs.indices {
            if runs[i].code || runs[i].kbd || runs[i].literal || runs[i].image != nil {
                continue
            }
            visit(&runs[i].text)
        }
    }

    private static func splitEdgeWhitespace(_ s: String) -> (leading: String, core: String, trailing: String) {
        guard !s.isEmpty else { return ("", "", "") }
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, scalars[start].properties.isWhitespace {
            start = scalars.index(after: start)
        }
        guard start < scalars.endIndex else { return (s, "", "") }
        var end = scalars.endIndex
        while end > start {
            let prev = scalars.index(before: end)
            if scalars[prev].properties.isWhitespace {
                end = prev
            } else {
                break
            }
        }
        let leading = String(scalars[..<start])
        let core = String(scalars[start..<end])
        let trailing = String(scalars[end...])
        return (leading, core, trailing)
    }
}

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
        guard SystemLanguageModel.default.isAvailable else { return nil }
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

/// Writing Tools（写作工具）保护范围：确保润色/改写全文时不改坏代码块、行内代码、数学公式、YAML 头部与附件
enum WritingToolsGuard {
    static func isExcludedAttribute(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        attrs[DMKey.code] != nil
            || attrs[DMKey.inlineCode] != nil
            || attrs[DMKey.kbd] != nil
            || attrs[DMKey.raw] != nil
            || attrs[DMKey.rule] != nil
            || attrs[DMKey.math] != nil
            || attrs[DMKey.literal] != nil
            || attrs[DMKey.image] != nil
            || attrs[.attachment] != nil
            || attrs[DMKey.codeGap] != nil
    }

    /// 单页富文本视图中需要排除在 Writing Tools 之外的区间
    static func ignoredRanges(in storage: NSTextStorage, enclosingRange: NSRange) -> [NSValue] {
        let full = NSRange(location: 0, length: storage.length)
        let scope = NSIntersectionRange(enclosingRange, full)
        guard scope.length > 0 else { return [] }

        var rawRanges: [NSRange] = []
        storage.enumerateAttributes(in: scope, options: []) { attrs, range, _ in
            if isExcludedAttribute(attrs) {
                rawRanges.append(range)
            }
        }
        return mergeRanges(rawRanges).map { NSValue(range: $0) }
    }

    private static let sourceRegexes: [NSRegularExpression] = [
        // 开头 YAML front matter
        #"(?s)\A---[ \t]*\n.*?\n(?:---|\.\.\.)[ \t]*(?:\n|\z)"#,
        // 围栏代码块
        #"(?m)^[ \t]*(?:`{3,}|~{3,})[\s\S]*?^[ \t]*(?:`{3,}|~{3,})[ \t]*$"#,
        // 数学公式块与行内公式
        #"\$\$[\s\S]*?\$\$|\$[^\n$]+\$"#,
        // 行内代码
        #"`[^`\n]+`"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 双页源码视图中需要排除在 Writing Tools 之外的区间（YAML / 代码块 / 公式 / 行内代码）
    static func ignoredRanges(inSource text: String, enclosingRange: NSRange) -> [NSValue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let scope = NSIntersectionRange(enclosingRange, full)
        guard scope.length > 0 else { return [] }

        var matches: [NSRange] = []
        for regex in sourceRegexes {
            for m in regex.matches(in: text, range: full) {
                let clipped = NSIntersectionRange(m.range, scope)
                if clipped.length > 0 { matches.append(clipped) }
            }
        }
        return mergeRanges(matches).map { NSValue(range: $0) }
    }

    private static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if r.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(r))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}

/// 系统 Vision 图片文字识别（用于单页图片右键提取文字与替代文本智能预填）
enum ImageTextExtractor {
    static func recognizeText(at url: URL) -> String? {
        guard let cgImage = loadCGImage(at: url) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        let lines = (req.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        if let image = NSImage(contentsOf: url),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let data = try? Data(contentsOf: url),
              let pdf = NSPDFImageRep(data: data) else { return nil }
        let bounds = pdf.bounds
        let scale: CGFloat = 2
        let w = max(1, Int(ceil(bounds.width * scale)))
        let h = max(1, Int(ceil(bounds.height * scale)))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        pdf.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
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
