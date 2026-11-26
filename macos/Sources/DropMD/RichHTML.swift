import AppKit

/// 展示型 HTML 的富文本渲染与无损记录（仅作用于单页富文本，不改变 MarkdownCodec 解析与保存模型）
enum RichHTML {
    struct PairedDivs {
        let tags: Set<Int>
        let alignments: [Int: NSTextAlignment]
    }

    // MARK: - 成对对齐容器与独立标签识别

    /// 扫描成对的 `<div align="left|center|right">` ... `</div>` 独立块，返回标签块索引与中间块继承对齐方式。
    /// 普通无 align 属性或未配对的 `<div>` 不会命中，保留原样代码卡片编辑行为。
    static func pairedAlignDivs(in blocks: [MDBlock]) -> PairedDivs {
        var stack: [(index: Int, alignment: NSTextAlignment)] = []
        var pairs: [(open: Int, close: Int, alignment: NSTextAlignment)] = []
        for (idx, block) in blocks.enumerated() {
            guard case .raw(let text) = block else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let align = openingAlignDiv(trimmed) {
                stack.append((idx, align))
            } else if trimmed.lowercased() == "</div>", let top = stack.popLast() {
                pairs.append((top.index, idx, top.alignment))
            }
        }
        var tags: Set<Int> = []
        var alignments: [Int: NSTextAlignment] = [:]
        // 从外到内应用对齐，内层覆盖外层
        for pair in pairs.sorted(by: { $0.open < $1.open }) {
            tags.insert(pair.open)
            tags.insert(pair.close)
            if pair.open + 1 < pair.close {
                for k in (pair.open + 1)..<pair.close {
                    alignments[k] = pair.alignment
                }
            }
        }
        return PairedDivs(tags: tags, alignments: alignments)
    }

    /// 整段是否为单个 `<div align="left|center|right">` 开标签
    private static func openingAlignDiv(_ trimmed: String) -> NSTextAlignment? {
        guard let m = firstMatch(openDivRegex, in: trimmed), m.range.length == trimmed.utf16.count else { return nil }
        let attrs = parseAttributes(trimmed)
        return alignment(attrs["align"])
    }

    /// 生成零高度隐藏容器标记段落（仅保存原始 `<div ...>` / `</div>`）
    static func hiddenMarkerParagraph(raw: String) -> NSAttributedString {
        let p = NSMutableAttributedString(attributedString: RichBridge.paragraph(NSAttributedString(), kind: .body))
        let whole = NSRange(location: 0, length: p.length)
        p.addAttribute(DMKey.htmlRaw, value: raw, range: whole)
        p.addAttribute(DMKey.htmlBlockID, value: UUID().uuidString, range: whole)
        p.addAttribute(DMKey.htmlHidden, value: true, range: whole)
        return p
    }

    /// 独立 `<br>` 块（一个或多个 `<br>` / `<br/>` / `<br />` 与空白）
    static func isBreakOnlyBlock(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty && text.range(of: #"(?i)<br\s*/?>"#, options: .regularExpression) != nil
    }

    /// 独立 `<br>` 块渲染为视觉留白段落并保留原文
    static func breakParagraph(raw: String) -> NSAttributedString {
        let p = NSMutableAttributedString(attributedString: RichBridge.paragraph(NSAttributedString(), kind: .body))
        let whole = NSRange(location: 0, length: p.length)
        p.addAttribute(DMKey.htmlRaw, value: raw, range: whole)
        p.addAttribute(DMKey.htmlBlockID, value: UUID().uuidString, range: whole)
        return p
    }

    // MARK: - 展示型 HTML 块渲染

    /// 尝试将展示型 HTML 块渲染为富文本段落；非展示型块（普通 `<div>`、注释、`<table>` 等）返回 nil 保持灰色原样卡片。
    static func renderBlock(_ text: String, inheritedAlignment: NSTextAlignment?, baseURL: URL?) -> NSAttributedString? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<!--") else { return nil }

        var explicitAlign: NSTextAlignment?
        var bodyHTML = trimmed
        var allowRender = false
        var pureInlineMedia = false

        // 1. 紧凑型 <div align="left|center|right">...</div>
        if let divInner = extractCompactAlignDiv(trimmed) {
            explicitAlign = divInner.alignment
            bodyHTML = divInner.body
            allowRender = true
        // 2. 带 align 属性的 <p align="left|center|right">...</p> 块
        } else if let pAlign = extractAlignedParagraphBlock(trimmed) {
            explicitAlign = pAlign
            allowRender = true
        // 3. 纯图片 / 带链接图片块（仅包含 <img>、<a><img></a>、<br>、&nbsp;）
        } else if isPureMediaBlock(trimmed) {
            allowRender = true
            pureInlineMedia = trimmed.range(of: #"(?i)<br\b|&nbsp;"#, options: .regularExpression) == nil
                && !trimmed.contains("\n")
        }

        guard allowRender else { return nil }
        // 若块内包含表格、脚本、样式或未支持结构标签，回退原样卡片
        guard bodyHTML.range(of: #"(?i)</?(table|thead|tbody|tr|td|th|script|style|iframe|svg|details|summary|ul|ol|li|pre|blockquote)\b"#, options: .regularExpression) == nil else {
            return nil
        }

        // 纯单行 <img> / <a><img></a>（如 <img src="a.png" width="200">）走普通行内图片段落，
        // 允许在其前后打字而不被块级 htmlRaw 吞字，同时仍可 100% 无损写回原标签
        if pureInlineMedia, let inlinePara = renderPureInlineMediaParagraph(trimmed, inheritedAlignment: inheritedAlignment, baseURL: baseURL) {
            return inlinePara
        }

        let effectiveAlign = explicitAlign ?? inheritedAlignment
        let sections = splitParagraphTags(bodyHTML)
        let blockID = UUID().uuidString
        let result = NSMutableAttributedString()

        for section in sections {
            let align = section.align ?? effectiveAlign
            let content = renderInlineHTML(section.html, baseURL: baseURL)
            // 整段仅含本地图片且未指定对齐时与普通图片段保持一致（居中）
            let paraAlign: NSTextAlignment?
            if let align {
                paraAlign = align
            } else if content.containsAttachments && content.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paraAlign = .center
            } else {
                paraAlign = nil
            }
            let p = NSMutableAttributedString(attributedString: RichBridge.paragraph(content, kind: .body))
            if let paraAlign,
               let style = (p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.alignment = paraAlign
                if content.containsAttachments {
                    style.paragraphSpacingBefore = 6
                    style.paragraphSpacing = RichStyle.bodyParagraphSpacing
                }
                p.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: p.length))
            }
            let whole = NSRange(location: 0, length: p.length)
            p.addAttribute(DMKey.htmlRaw, value: text, range: whole)
            p.addAttribute(DMKey.htmlBlockID, value: blockID, range: whole)
            result.append(p)
        }

        return result.length > 0 ? result : nil
    }

    // MARK: - 行内 HTML 片段识别

    /// 匹配单个 `<a ...>` 开标签并返回 `(href, title)`
    static func parseAnchorOpenTag(_ tag: String) -> (href: String, title: String?)? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = firstMatch(openAnchorRegex, in: trimmed), m.range.length == trimmed.utf16.count else { return nil }
        let attrs = parseAttributes(trimmed)
        guard let href = attrs["href"], !href.isEmpty else { return nil }
        let title = attrs["title"].map { "\"\($0)\"" }
        return (href, title)
    }

    /// 是否为 `</a>` 闭标签
    static func isAnchorCloseTag(_ tag: String) -> Bool {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "</a>"
    }

    /// 匹配单个 `<img ...>` 标签并渲染为图片附件或占位文字
    static func renderImageTag(_ tag: String, link: String? = nil, linkTitle: String? = nil, baseURL: URL?) -> NSAttributedString? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = firstMatch(imgTagRegex, in: trimmed), m.range.length == trimmed.utf16.count else { return nil }
        let attrs = parseAttributes(trimmed)
        guard let src = attrs["src"], !src.isEmpty else { return nil }
        let alt = decodeEntities(attrs["alt"] ?? "")
        let title = attrs["title"].map { "\"\(decodeEntities($0))\"" }
        return RichBridge.imageString(
            path: src,
            alt: alt,
            title: title,
            link: link,
            linkTitle: linkTitle,
            htmlWidth: attrs["width"],
            htmlHeight: attrs["height"],
            baseURL: baseURL
        )
    }

    // MARK: - 内部块与行内解析

    private static func extractCompactAlignDiv(_ trimmed: String) -> (alignment: NSTextAlignment, body: String)? {
        guard let open = firstMatch(openDivPrefixRegex, in: trimmed),
              let closeRange = trimmed.range(of: #"(?i)</div>\s*$"#, options: .regularExpression),
              let swiftOpen = Range(open.range, in: trimmed),
              swiftOpen.upperBound <= closeRange.lowerBound else { return nil }
        let openTag = String(trimmed[swiftOpen])
        guard let align = alignment(parseAttributes(openTag)["align"]) else { return nil }
        let body = String(trimmed[swiftOpen.upperBound..<closeRange.lowerBound])
        // 不嵌套未配对的 <div>
        guard body.range(of: #"(?i)</?div\b"#, options: .regularExpression) == nil else { return nil }
        return (align, body)
    }

    private static func extractAlignedParagraphBlock(_ trimmed: String) -> NSTextAlignment? {
        guard let open = firstMatch(openPPrefixRegex, in: trimmed),
              let swiftOpen = Range(open.range, in: trimmed) else { return nil }
        let openTag = String(trimmed[swiftOpen])
        return alignment(parseAttributes(openTag)["align"])
    }

    private static func isPureMediaBlock(_ trimmed: String) -> Bool {
        // 允许仅由 <img ...>、<a ...>...</a>、<br>、&nbsp; 与空白组成的块
        var rest = trimmed
        rest = rest.replacingOccurrences(of: #"(?is)<a\b[^>]*>\s*(?:<img\b[^>]*>\s*)+</a>"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"(?i)<img\b[^>]*>"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: "&nbsp;", with: "")
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmed.range(of: #"(?i)<img\b"#, options: .regularExpression) != nil
    }

    /// 渲染单行纯 `<img>` / `<a><img></a>`（不附带块级 `htmlRaw`，使用 `htmlInline` 无损还原并支持前后自由输入）
    private static func renderPureInlineMediaParagraph(_ trimmed: String, inheritedAlignment: NSTextAlignment?, baseURL: URL?) -> NSAttributedString? {
        let out = NSMutableAttributedString()
        let ns = trimmed as NSString
        let matches = inlineMediaRegex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let between = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if !between.isEmpty {
                    out.append(NSAttributedString(string: between, attributes: RichStyle.attributes(for: MDRun(), kind: .body)))
                }
            }
            let rawToken = ns.substring(with: m.range)
            if rawToken.lowercased().hasPrefix("<a") {
                let openEnd = rawToken.firstIndex(of: ">") ?? rawToken.endIndex
                let openTag = String(rawToken[...openEnd])
                let innerRange = rawToken.index(after: openEnd)..<rawToken.endIndex
                let inner = String(rawToken[innerRange]).replacingOccurrences(of: #"(?i)</a>\s*$"#, with: "", options: .regularExpression)
                guard let anchor = parseAnchorOpenTag(openTag) else { return nil }
                let imgMatches = imgTagRegexGlobal.matches(in: inner, options: [], range: NSRange(location: 0, length: (inner as NSString).length))
                guard imgMatches.count == 1 else { return nil }
                let imgTag = (inner as NSString).substring(with: imgMatches[0].range)
                guard let img = renderImageTag(imgTag, link: anchor.href, linkTitle: anchor.title, baseURL: baseURL) else { return nil }
                let marked = NSMutableAttributedString(attributedString: img)
                let whole = NSRange(location: 0, length: marked.length)
                marked.addAttribute(DMKey.htmlInline, value: rawToken, range: whole)
                marked.addAttribute(DMKey.htmlInlineID, value: UUID().uuidString, range: whole)
                out.append(marked)
            } else if let img = renderImageTag(rawToken, baseURL: baseURL) {
                let marked = NSMutableAttributedString(attributedString: img)
                let whole = NSRange(location: 0, length: marked.length)
                marked.addAttribute(DMKey.htmlInline, value: rawToken, range: whole)
                marked.addAttribute(DMKey.htmlInlineID, value: UUID().uuidString, range: whole)
                out.append(marked)
            } else {
                return nil
            }
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                out.append(NSAttributedString(string: tail, attributes: RichStyle.attributes(for: MDRun(), kind: .body)))
            }
        }
        let p = NSMutableAttributedString(attributedString: RichBridge.paragraph(out, kind: .body))
        if let style = (p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.alignment = inheritedAlignment ?? .center
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = RichStyle.bodyParagraphSpacing
            p.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: p.length))
        }
        return p
    }

    private static func splitParagraphTags(_ html: String) -> [(align: NSTextAlignment?, html: String)] {
        let ns = html as NSString
        let matches = paragraphBlockRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return [(nil, html)]
        }
        var out: [(align: NSTextAlignment?, html: String)] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let between = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !between.isEmpty {
                    out.append((nil, between))
                }
            }
            let openTag = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            let align = alignment(parseAttributes(openTag)["align"])
            out.append((align, inner))
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                out.append((nil, tail))
            }
        }
        return out
    }

    private static func renderInlineHTML(_ html: String, baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var style = InlineHTMLState()
        let ns = html as NSString
        let matches = htmlTokenRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        var cursor = 0

        func appendText(_ raw: String) {
            // 将换行与连续空白折叠为单个空格（与 HTML 行为一致），同时保留 <br> 转出的软换行
            let collapsed = raw.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
            let decoded = decodeEntities(collapsed)
            guard !decoded.isEmpty else { return }
            if out.length == 0, decoded == " " { return }
            out.append(NSAttributedString(string: decoded, attributes: style.attributes()))
        }

        for m in matches {
            if m.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let token = ns.substring(with: m.range)
            let lower = token.lowercased()
            if lower.hasPrefix("<br") {
                // 多重 <br> 在同一块里转为换行，末尾单独的 <br> 不强加空行
                if out.length > 0 {
                    out.append(NSAttributedString(string: "\u{2028}", attributes: style.attributes()))
                }
            } else if lower.hasPrefix("<img") {
                if let img = renderImageTag(token, link: style.link, linkTitle: style.linkTitle, baseURL: baseURL) {
                    out.append(img)
                }
            } else if lower.hasPrefix("<a") {
                if let a = parseAnchorOpenTag(token) {
                    style.link = a.href
                    style.linkTitle = a.title
                }
            } else if lower == "</a>" {
                style.link = nil
                style.linkTitle = nil
            } else if lower == "<b>" || lower == "<strong>" || lower.hasPrefix("<b ") || lower.hasPrefix("<strong ") {
                style.bold += 1
            } else if lower == "</b>" || lower == "</strong>" {
                style.bold = max(0, style.bold - 1)
            } else if lower == "<i>" || lower == "<em>" || lower.hasPrefix("<i ") || lower.hasPrefix("<em ") {
                style.italic += 1
            } else if lower == "</i>" || lower == "</em>" {
                style.italic = max(0, style.italic - 1)
            } else if lower == "<u>" || lower.hasPrefix("<u ") {
                style.underline += 1
            } else if lower == "</u>" {
                style.underline = max(0, style.underline - 1)
            } else if lower == "<s>" || lower == "<del>" || lower.hasPrefix("<s ") || lower.hasPrefix("<del ") {
                style.strike += 1
            } else if lower == "</s>" || lower == "</del>" {
                style.strike = max(0, style.strike - 1)
            } else if lower == "<mark>" || lower.hasPrefix("<mark ") {
                style.highlight += 1
            } else if lower == "</mark>" {
                style.highlight = max(0, style.highlight - 1)
            } else if lower == "<sup>" || lower.hasPrefix("<sup ") {
                style.sup += 1
            } else if lower == "</sup>" {
                style.sup = max(0, style.sup - 1)
            } else if lower == "<sub>" || lower.hasPrefix("<sub ") {
                style.sub += 1
            } else if lower == "</sub>" {
                style.sub = max(0, style.sub - 1)
            } else if lower == "<kbd>" || lower.hasPrefix("<kbd ") {
                style.kbd += 1
            } else if lower == "</kbd>" {
                style.kbd = max(0, style.kbd - 1)
            } else if lower == "<code>" || lower.hasPrefix("<code ") {
                style.code += 1
            } else if lower == "</code>" {
                style.code = max(0, style.code - 1)
            }
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor))
        }
        // 去掉末尾空白与末尾多余软换行
        while out.length > 0 {
            let last = (out.string as NSString).substring(with: NSRange(location: out.length - 1, length: 1))
            if last == " " || last == "\u{2028}" {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            } else {
                break
            }
        }
        return out
    }

    private struct InlineHTMLState {
        var bold = 0
        var italic = 0
        var underline = 0
        var strike = 0
        var highlight = 0
        var sup = 0
        var sub = 0
        var kbd = 0
        var code = 0
        var link: String?
        var linkTitle: String?

        func attributes() -> [NSAttributedString.Key: Any] {
            var run = MDRun()
            run.bold = bold > 0
            run.italic = italic > 0
            run.underline = underline > 0
            run.strike = strike > 0
            run.highlight = highlight > 0
            run.sup = sup > 0
            run.sub = sub > 0
            run.kbd = kbd > 0
            run.code = code > 0
            run.link = link
            run.title = linkTitle
            return RichStyle.attributes(for: run, kind: .body)
        }
    }

    // MARK: - 属性与实体解析工具

    static func parseAttributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = tag as NSString
        let matches = attrRegex.matches(in: tag, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let val: String
            if m.range(at: 2).location != NSNotFound {
                val = ns.substring(with: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                val = ns.substring(with: m.range(at: 3))
            } else if m.range(at: 4).location != NSNotFound {
                val = ns.substring(with: m.range(at: 4))
            } else {
                val = ""
            }
            result[key] = decodeEntities(val)
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        MarkdownCodec.decodeHTMLEntities(text)
    }

    /// 替换 HTML 媒体片段中首个 <img> 标签的 alt 属性，保留其余属性（如 width/height）与外层 <a>
    static func updatingAlt(in html: String, to newAlt: String) -> String {
        let escaped = escapeAttribute(newAlt)
        let ns = html as NSString
        guard let imgMatch = imgTagRegexGlobal.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return html
        }
        let imgRange = imgMatch.range
        let imgTag = ns.substring(with: imgRange)
        let imgNS = imgTag as NSString
        let matches = attrRegex.matches(in: imgTag, options: [], range: NSRange(location: 0, length: imgNS.length))
        let updatedImg: String
        if let altMatch = matches.first(where: { imgNS.substring(with: $0.range(at: 1)).lowercased() == "alt" }) {
            updatedImg = imgNS.replacingCharacters(in: altMatch.range, with: "alt=\"\(escaped)\"")
        } else if imgTag.hasSuffix("/>") {
            let prefix = String(imgTag.dropLast(2))
            let sep = prefix.last?.isWhitespace == true ? "" : " "
            updatedImg = "\(prefix)\(sep)alt=\"\(escaped)\"/>"
        } else if imgTag.hasSuffix(">") {
            let prefix = String(imgTag.dropLast(1))
            let sep = prefix.last?.isWhitespace == true ? "" : " "
            updatedImg = "\(prefix)\(sep)alt=\"\(escaped)\">"
        } else {
            updatedImg = imgTag
        }
        return ns.replacingCharacters(in: imgRange, with: updatedImg)
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func alignment(_ raw: String?) -> NSTextAlignment? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left": return .left
        case "center": return .center
        case "right": return .right
        default: return nil
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let ns = text as NSString
        return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    }

    private static let openDivRegex = try! NSRegularExpression(pattern: #"^<div\b[^>]*>$"#, options: .caseInsensitive)
    private static let openDivPrefixRegex = try! NSRegularExpression(pattern: #"^<div\b[^>]*>"#, options: .caseInsensitive)
    private static let openPPrefixRegex = try! NSRegularExpression(pattern: #"^<p\b[^>]*>"#, options: .caseInsensitive)
    private static let openAnchorRegex = try! NSRegularExpression(pattern: #"^<a\b[^>]*>$"#, options: .caseInsensitive)
    private static let imgTagRegex = try! NSRegularExpression(pattern: #"^<img\b[^>]*>$"#, options: .caseInsensitive)
    private static let imgTagRegexGlobal = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let inlineMediaRegex = try! NSRegularExpression(pattern: #"<a\b[^>]*>\s*<img\b[^>]*>\s*</a>|<img\b[^>]*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let paragraphBlockRegex = try! NSRegularExpression(pattern: #"(<p\b[^>]*>)([\s\S]*?)</p>"#, options: .caseInsensitive)
    private static let htmlTokenRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#, options: [])
    private static let attrRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][a-zA-Z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
        options: []
    )
}
