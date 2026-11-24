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
