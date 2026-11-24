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

/// Apple Intelligence / Siri AI 功能可用性检测与端侧大模型调用
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

    /// 是否支持系统内置大模型（macOS 26+ 且已开启可用）
    static var isLanguageModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
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
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: input)
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

    /// 100% 使用系统本机 Siri AI 模型生成文章摘要要点列表（短文直出、长文分段汇总）
    @available(macOS 26.0, *)
    static func summarizeBullets(_ input: String) async throws -> [String] {
        #if canImport(FoundationModels)
        let chunks = Array(splitIntoChunks(input, maxChars: 2400).prefix(12))
        guard !chunks.isEmpty else { return [] }

        let rawBullets: String
        if chunks.count == 1 {
            let instructions = """
            Summarize the user's document into 3 to 5 concise bullet points in the exact same language as the document.
            Each line must start with "- ".
            Output only the bullet list without any heading, intro, or code fence.
            """
            let session = LanguageModelSession(instructions: instructions)
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
            Synthesize the following excerpt summaries into 3 to 5 concise, non-redundant overall bullet points in the exact same language.
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

/// Spotlight 全文索引与 Siri 屏幕感知（NSUserActivity）
enum SpotlightAndActivity {
    static let activityType = "io.github.dropmd.editing"
    private static let domainIdentifier = "io.github.dropmd.documents"

    static func indexDocument(url: URL, text: String, headings: [DocumentHeading]) {
        let attr = CSSearchableItemAttributeSet(contentType: .markdownText)
        attr.title = DocumentTitleSuggester.fallbackTitle(from: text) ?? url.deletingPathExtension().lastPathComponent
        attr.displayName = url.lastPathComponent
        attr.contentURL = url
        attr.keywords = Array(headings.prefix(20).map(\.title))
        attr.textContent = String(text.prefix(8000))
        let item = CSSearchableItem(uniqueIdentifier: url.path, domainIdentifier: domainIdentifier, attributeSet: attr)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
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
