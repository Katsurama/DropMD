import AppKit
import Foundation
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
    static let defaultValue: Self = .auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动（长文使用私有云）")
        case .onDeviceOnly: return String(localized: "仅本机")
        case .preferCloud: return String(localized: "优先私有云")
        }
    }

    static var current: Self { stored(in: .standard) }

    static func stored(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

/// 文档内问答单条记录
struct DocumentQAItem: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String
    var isLoading = false
    var isError = false

    var displayAnswer: AttributedString {
        guard !isError, let rendered = SiriAIManager.displayText(answer) else { return AttributedString(answer) }
        return rendered
    }
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
    private static var isAIDisabledForTesting: Bool {
        ProcessInfo.processInfo.environment["DROPMD_DISABLE_AI"] == "1"
    }

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

    /// 是否支持系统写作工具（Writing Tools，macOS 15.2+ 且 Apple Silicon 并已启用 Apple Intelligence）
    static var isWritingToolsAvailable: Bool {
        guard !isAIDisabledForTesting else { return false }
        #if arch(arm64)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        if #available(macOS 15.2, *) { return true }
        #endif
        return false
    }

    /// 是否支持系统内置大模型（macOS 26+ 且已开启可用）
    static var isLanguageModelAvailable: Bool {
        guard !isAIDisabledForTesting else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// 是否支持 Apple 私有云计算大模型（macOS 27+）
    static var isPrivateCloudAvailable: Bool {
        guard !isAIDisabledForTesting else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }

    /// 是否支持系统图乐园（Image Playground，macOS 15.2+）
    static var isImagePlaygroundAvailable: Bool {
        guard !isAIDisabledForTesting else { return false }
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

    private static let maxDirectRewriteChars = 12000

    /// 内容太长：模型一次装不下，写回文档又不能截断，请用户选一部分再做
    struct TooLongError: LocalizedError {
        var errorDescription: String? { String(localized: "内容太长，请选中其中一部分再试。") }
    }

    #if canImport(FoundationModels)
    /// 统一会话调度：按偏好与字数优先尝试私有云，失败时自动回退到本机模型
    @available(macOS 26.0, *)
    private static func runWithSession<T>(
        contentLength: Int,
        instructions: (Bool) -> String,
        operation: (LanguageModelSession, Bool) async throws -> T
    ) async throws -> T {
        let wantCloud = shouldUsePrivateCloud(preference: AIModelPreference.current, contentLength: contentLength)
        if #available(macOS 27.0, *), wantCloud {
            let cloudModel = PrivateCloudComputeLanguageModel()
            if cloudModel.isAvailable {
                do {
                    let cloudSession = LanguageModelSession(model: cloudModel, instructions: instructions(true))
                    return try await operation(cloudSession, true)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 断网或私有云暂不可用时静默回退到本机端侧模型，并按本机上限重建输入
                }
            }
        }
        let localSession = LanguageModelSession(instructions: instructions(false))
        return try await operation(localSession, false)
    }
    #endif

    /// 使用系统内置大模型将杂乱纯文本整理为结构清晰的 Markdown
    @available(macOS 26.0, *)
    static func smartFormatMarkdown(_ input: String) async throws -> String {
        #if canImport(FoundationModels)
        // 超出上限时不调用模型：会装不下，截断后写回又会丢内容
        guard input.count <= maxDirectRewriteChars else { throw TooLongError() }
        let instructions = """
        You are a Markdown formatting assistant.
        Reformat the user's text into clean, well-structured Markdown (with appropriate # headings, lists, bold emphasis, or tables when fitting).
        Keep the exact original language, meaning, and all factual content without adding or deleting information.
        Output only the Markdown body without wrapping it in a ```markdown code fence.
        """
        let response = try await runWithSession(contentLength: input.count, instructions: { _ in instructions }) { session, _ in
            try await session.respond(to: input)
        }
        return stripOuterMarkdownFence(response.content)
        #else
        return input
        #endif
    }

    static func stripOuterMarkdownFence(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        let first = lines[0].trimmingCharacters(in: .whitespaces).lowercased()
        let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
        guard (first == "```" || first == "```markdown" || first == "```md"), last == "```" else {
            return text
        }
        // 扫描内部围栏配对，防止首尾两个独立代码块被误拆
        var innerFenceTicks: Int?
        for line in lines.dropFirst().dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { continue }
            let ticks = trimmed.prefix(while: { $0 == "`" }).count
            let rest = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
            if let openTicks = innerFenceTicks {
                if rest.isEmpty && ticks >= openTicks {
                    innerFenceTicks = nil
                }
            } else if rest.isEmpty {
                return text
            } else if !rest.contains("`") {
                innerFenceTicks = ticks
            }
        }
        guard innerFenceTicks == nil else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                return stripMarkupForDisplay(s)
            }
            .filter { !$0.isEmpty }
    }

    /// 回复与摘要的显示：只解析行内格式；行首列表标记换成圆点、待办框换成勾选框符号，标题去掉 #
    static func displayText(_ raw: String) -> AttributedString? {
        let text = raw.components(separatedBy: "\n").map { line -> String in
            var s = stripMarkupForDisplay(line)
            if let r = s.range(of: #"^([-*+]\s+)?(\*\*|__)?\[[ xX]\]\s+"#, options: .regularExpression) {
                let marker = s[r].contains(where: { $0 == "x" || $0 == "X" }) ? "☑ " : "☐ "
                let emphasis = s[r].contains("**") ? "**" : s[r].contains("__") ? "__" : ""
                s.replaceSubrange(r, with: marker + emphasis)
            } else if let r = s.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                s.replaceSubrange(r, with: "• ")
            } else if let r = s.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                s.removeSubrange(r)
            }
            return s
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var rendered = try? AttributedString(markdown: text, options: options) else { return nil }
        // 生成的文字可选取，不把模型给出的地址变成可点击的链接。
        rendered.link = nil
        return rendered
    }

    /// 模型常照抄原文的 HTML 标签与脚注标记，显示时去掉
    static func stripMarkupForDisplay(_ text: String) -> String {
        // 仅移除常见 HTML 标签，保留 Array<String> 或 <api-key> 等尖括号内容
        text.replacingOccurrences(
            of: #"(?i)</?(?:br|sub|sup|kbd|span|div|p|a|b|i|em|strong|u|s|del|ins|mark|code|small|img|details|summary|font|center)(?:\s[^<>]*)?/?>"#,
            with: "",
            options: .regularExpression
        )
            .replacingOccurrences(of: #"\[\^[^\]\s]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"==(\S(?:[^=]*?\S)?)=="#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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
        // 保留空表头占位，避免后续数据列左移或丢失
        let cleanHeaders = headers.map(sanitize)
        guard !cleanHeaders.allSatisfy(\.isEmpty) else { return "" }
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

    /// 只替换 YAML 的行，或在 BOM 之后插入；正文的换行和空白不参与解析、重写。
    static func yamlFrontMatterEdit(_ yaml: String, in markdown: String) -> (range: Range<String.Index>, replacement: String)? {
        let cleanYAML = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanYAML.isEmpty else { return nil }
        let newline = markdown.first { $0 == "\n" || $0 == "\r\n" } == "\r\n" ? "\r\n" : "\n"
        let replacement = cleanYAML.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: newline)
        if let existing = MarkdownCodec.yamlFrontMatter(in: markdown) {
            return (existing.range, replacement)
        }
        let start = markdown.hasPrefix("\u{FEFF}") ? markdown.index(after: markdown.startIndex) : markdown.startIndex
        return (start..<start, replacement + newline + (start == markdown.endIndex ? "" : newline))
    }

    static func upsertYAMLFrontMatter(_ yaml: String, into markdown: String) -> String {
        guard let edit = yamlFrontMatterEdit(yaml, in: markdown) else { return markdown }
        return markdown.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// 为问答准备文档上下文：短文保留全文，长文保留开头概览并按问题关键词挑选最相关段落
    static func prepareContextForQA(document: String, question: String, maxChars: Int) -> String {
        let normalized = document.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, maxChars > 0 else { return "" }
        if normalized.count <= maxChars { return normalized }

        var paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count > 1 else { return String(normalized.prefix(maxChars)) }

        let keywords = extractQueryTokens(from: question)
        // 首段导语预算不超过总预算一半，确保关键词命中段落始终有空间
        let leadBudget = min(maxChars / 2, max(400, maxChars / 3))
        if paragraphs[0].count > leadBudget {
            paragraphs[0] = String(paragraphs[0].prefix(leadBudget))
        }
        var selectedIndices: Set<Int> = []
        var usedChars = 0

        for i in paragraphs.indices {
            let p = paragraphs[i]
            if i == 0 && p.isEmpty { continue }
            let cost = usedChars == 0 ? p.count : p.count + 2
            if usedChars + cost <= leadBudget || i == 0 {
                selectedIndices.insert(i)
                usedChars += cost
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
            let len = usedChars == 0 ? paragraphs[item.idx].count : paragraphs[item.idx].count + 2
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
                if (0x4E00...0x9FFF).contains(scalar.value)
                    || (0x3400...0x4DBF).contains(scalar.value)
                    || (0x3040...0x30FF).contains(scalar.value) {
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
        // 保留假名与 CJK 扩展 A 单字词元，避免日文与生僻字问答召回失效
        return Array(Set(tokens.filter {
            $0.count >= 2 || ($0.unicodeScalars.first.map {
                $0.value >= 0x4E00 || (0x3400...0x4DBF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
            } ?? false)
        }))
    }

    /// 将所选混乱文本转换为结构化 Markdown 表格
    @available(macOS 26.0, *)
    static func convertToMarkdownTable(_ input: String) async throws -> String {
        #if canImport(FoundationModels)
        // 超出上限时不调用模型：会装不下，截断后写回又会丢内容
        guard input.count <= maxDirectRewriteChars else { throw TooLongError() }
        let instructions = """
        Convert the user's text or data into a structured table with concise column headers and aligned rows.
        Keep the exact original language and factual values.
        """
        let response = try await runWithSession(contentLength: input.count, instructions: { _ in instructions }) { session, _ in
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
        let response = try await runWithSession(contentLength: trimmed.count, instructions: { _ in instructions }) { session, _ in
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
        let instructions = """
        Generate metadata (concise title, 3 to 5 topical tags, and a one-sentence summary) for the user's Markdown document in the exact same language as the document.
        """
        let response = try await runWithSession(contentLength: markdown.count, instructions: { _ in instructions }) { session, isCloud in
            try await session.respond(to: String(markdown.prefix(isCloud ? 16000 : 8000)), generating: GeneratedFrontMatter.self)
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

    /// 文档问答的要求：只按文档回答，不自我介绍；文档里没有就直说
    static func qaInstructions(context: String) -> String {
        """
        You answer the user's questions about the document below.
        - Use only the content of the document. If the document does not contain the answer, say so in one short sentence.
        - Reply in the same language as the user's question.
        - Be brief and direct. Do not introduce yourself, do not mention being an AI model or Apple, and do not repeat the question.
        - Use a short bullet list only when listing several items; otherwise answer in one or two sentences.

        --- Document ---
        \(context)
        --- End of document ---
        """
    }

    /// 针对当前文档回答用户提问（支持最近几轮追问上下文）
    @available(macOS 26.0, *)
    static func answerQuestion(
        _ question: String,
        document: String,
        history: [(question: String, answer: String)]
    ) async throws -> String {
        #if canImport(FoundationModels)
        var promptParts: [String] = []
        let recent = history.suffix(3).filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !recent.isEmpty {
            let histText = recent.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
            promptParts.append(histText)
        }
        promptParts.append(question)
        let prompt = promptParts.joined(separator: "\n\n")
        let response = try await runWithSession(
            contentLength: document.count,
            instructions: { isCloud in
                let context = prepareContextForQA(document: document, question: question, maxChars: isCloud ? 20000 : 5500)
                return qaInstructions(context: context)
            }
        ) { session, _ in
            try await session.respond(to: prompt)
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return ""
        #endif
    }
}

/// Writing Tools（写作工具）保护范围：确保润色/改写全文时不改坏代码块、行内代码、数学公式、YAML 头部与附件
enum WritingToolsGuard {
    static func isExcludedAttribute(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        // 同时排除展示型 HTML 与提示框标题，防止写作工具改坏原文
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
            || attrs[DMKey.htmlRaw] != nil
            || attrs[DMKey.htmlHidden] != nil
            || attrs[DMKey.htmlInline] != nil
            || attrs[DMKey.callout] != nil
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
