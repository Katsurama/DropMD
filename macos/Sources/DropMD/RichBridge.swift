import AppKit

/// Markdown 段落模型 ⇄ 富文本（NSAttributedString）
enum RichBridge {
    // MARK: - Markdown → 富文本

    static func attributed(markdown: String, baseURL: URL?) -> NSAttributedString {
        attributed(from: MarkdownCodec.parse(markdown), baseURL: baseURL)
    }

    static func attributed(from blocks: [MDBlock], baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()

        var lastRaw = false
        var listDepth = 0   // 上一个列表项的层级：列表项里的代码块缩进到它的文字下面
        for block in blocks {
            if case .line(let l) = block, let d = l.kind.listDepth { listDepth = d }
            // 相邻的两段原样内容之间空一行，否则保存时会连成一段
            if case .raw(let text) = block, !isMathBlock(text) {
                if lastRaw { out.append(paragraph(runsString([], kind: .raw, baseURL: baseURL), kind: .raw)) }
                lastRaw = true
            } else {
                lastRaw = false
            }
            switch block {
            case .line(let line):
                let kind = RichKind(line.kind)
                var content = runsString(line.runs, kind: kind, baseURL: baseURL)
                if case .task(_, let done) = kind {
                    let box = NSMutableAttributedString(string: (done ? RichStyle.taskDone : RichStyle.taskTodo) + " ",
                                                        attributes: RichStyle.attributes(for: MDRun(), kind: kind))
                    box.append(content)
                    content = box
                }
                let p = NSMutableAttributedString(attributedString: paragraph(content, kind: kind))
                if let start = line.start { p.addAttribute(DMKey.start, value: start, range: NSRange(location: 0, length: p.length)) }
                out.append(p)

            case .code(let lang, let lines, let listGap):
                // 相邻的代码块之间显示一个空行（不保存），看得出是两块，光标也能停在中间
                if out.length > 0, out.attribute(DMKey.code, at: out.length - 1, effectiveRange: nil) != nil {
                    let gap = NSMutableAttributedString(attributedString: paragraph(NSAttributedString(), kind: .body))
                    gap.addAttribute(DMKey.codeGap, value: true, range: NSRange(location: 0, length: gap.length))
                    out.append(gap)
                }
                let id = UUID().uuidString
                for l in (lines.isEmpty ? [""] : lines) {
                    let p = NSMutableAttributedString(attributedString:
                        paragraph(runsString([MDRun(text: l)], kind: .code(lang), baseURL: baseURL), kind: .code(lang)))
                    p.addAttribute(DMKey.codeBlock, value: id, range: NSRange(location: 0, length: p.length))
                    if let listGap {
                        p.addAttribute(DMKey.listCode, value: listGap, range: NSRange(location: 0, length: p.length))
                        let style = (p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                        if let style {
                            style.firstLineHeadIndent += CGFloat(listDepth + 1) * RichStyle.indent
                            style.headIndent += CGFloat(listDepth + 1) * RichStyle.indent
                            p.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: p.length))
                        }
                    }
                    out.append(p)
                }

            case .table(let rows, let align):
                let cols = max(1, rows.map { $0.count }.max() ?? 1)
                let table = makeTable(columns: cols)
                for (r, row) in rows.enumerated() {
                    for c in 0..<cols {
                        out.append(cellParagraph(table: table, row: r, column: c, runs: c < row.count ? row[c] : [],
                                                 baseURL: baseURL, alignment: alignment(c < align.count ? align[c] : "---")))
                    }
                }

            case .rule:
                out.append(paragraph(ruleAttachment(), kind: .rule))

            case .raw(let text) where isMathBlock(text):
                out.append(mathBlockParagraph(text))

            case .raw(let text):
                for l in text.components(separatedBy: "\n") {
                    out.append(paragraph(runsString([MDRun(text: l)], kind: .raw, baseURL: baseURL), kind: .raw))
                }

            case .details(let summary, let body, let open):
                let title = NSMutableAttributedString(attributedString: paragraph(
                    runsString([MDRun(text: summary)], kind: .summary, baseURL: baseURL), kind: .summary))
                // 与浏览器相同：打开文件时 <details> 是收起的，<details open> 是展开的
                title.addAttribute(open ? DMKey.detailsOpen : DMKey.collapsed, value: true,
                                   range: NSRange(location: 0, length: title.length))
                out.append(title)
                // 编辑器中不支持嵌套折叠块，内层的原样保留
                let inner: [MDBlock] = body.map { b in
                    if case .details = b {
                        return .raw(MarkdownCodec.serialize([b]).trimmingCharacters(in: .newlines))
                    }
                    return b
                }
                let content = NSMutableAttributedString(attributedString: attributed(from: inner, baseURL: baseURL))
                if content.length == 0 {
                    content.append(paragraph(NSAttributedString(), kind: .body))
                }
                markInDetails(content)
                out.append(content)
            }
        }
        // 文末是表格或分隔线时补一个空段落，光标才能移到它后面（保存时会去掉）
        switch blocks.last {
        case .table?, .rule?, .details?:
            out.append(paragraph(NSAttributedString(), kind: .body))
        default:
            break
        }
        return out
    }

    /// 把一段内容标记为折叠块中的内容，并增加缩进
    static func markInDetails(_ s: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: s.length)
        guard whole.length > 0 else { return }
        var styles: [(NSRange, NSParagraphStyle)] = []
        s.enumerateAttribute(.paragraphStyle, in: whole, options: []) { value, range, _ in
            if let p = value as? NSParagraphStyle { styles.append((range, p)) }
        }
        for (range, p) in styles {
            // 表格整体右移（单元格里的文字不再额外缩进）
            if let cell = p.textBlocks.first as? NSTextTableBlock {
                cell.table.setWidth(RichStyle.detailsIndent, type: .absoluteValueType, for: .margin, edge: .minX)
                continue
            }
            guard let m = p.mutableCopy() as? NSMutableParagraphStyle else { continue }
            m.firstLineHeadIndent += RichStyle.detailsIndent
            m.headIndent += RichStyle.detailsIndent
            s.addAttribute(.paragraphStyle, value: m, range: range)
        }
        s.addAttribute(DMKey.inDetails, value: true, range: whole)
    }

    /// 一个完整段落：内容 + 换行符，并设置段落样式
    static func paragraph(_ content: NSAttributedString, kind: RichKind, block: NSTextBlock? = nil) -> NSAttributedString {
        let p = NSMutableAttributedString(attributedString: content)
        // 换行符也带上字体，空段落才有正确的行高
        p.append(NSAttributedString(string: "\n", attributes: RichStyle.attributes(for: MDRun(), kind: kind)))
        let whole = NSRange(location: 0, length: p.length)
        p.addAttribute(.paragraphStyle, value: RichStyle.paragraphStyle(kind, block: block), range: whole)
        for (key, value) in RichStyle.marks(for: kind) {
            p.addAttribute(key, value: value, range: whole)
        }
        return p
    }

    static func runsString(_ runs: [MDRun], kind: RichKind, baseURL: URL?) -> NSMutableAttributedString {
        let s = NSMutableAttributedString()
        for r in runs {
            if let src = r.image {
                s.append(imageString(path: src, alt: r.text, title: r.title, link: r.link, linkTitle: r.linkTitle, baseURL: baseURL))
            } else if r.literal, isInlineMath(r.text) {
                s.append(mathString(r.text, display: false, attributes: RichStyle.attributes(for: r, kind: kind)))
            } else if r.literal, let c = MDCallout(header: r.text) {
                // 提示框标题行显示为中文标题，保存时写回原文
                var a = RichStyle.attributes(for: r, kind: kind)
                a[DMKey.callout] = r.text.trimmingCharacters(in: .whitespaces)
                s.append(NSAttributedString(string: c.title, attributes: a))
            } else {
                // 段落里的单个换行显示为空格
                let a = RichStyle.attributes(for: r, kind: kind)
                var soft = a
                soft[DMKey.softBreak] = true
                for (k, part) in r.text.components(separatedBy: "\n").enumerated() {
                    if k > 0 { s.append(NSAttributedString(string: " ", attributes: soft)) }
                    s.append(NSAttributedString(string: part, attributes: a))
                }
            }
        }
        return s
    }

    // MARK: 表格

    static func makeTable(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = max(columns, 1)
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        return table
    }

    /// 表格列的对齐：Markdown 的 :--、:-:、--: ⇄ 单元格段落的对齐方式
    static func alignment(_ marker: String) -> NSTextAlignment {
        [":--": .left, ":-:": .center, "--:": .right][marker] ?? .natural
    }

    static func marker(_ alignment: NSTextAlignment) -> String {
        [NSTextAlignment.left: ":--", .center: ":-:", .right: "--:"][alignment] ?? "---"
    }

    static func cellParagraph(table: NSTextTable, row: Int, column: Int, runs: [MDRun], baseURL: URL?,
                              alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(RichStyle.lineColor)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        // 第一行是表头：加粗、浅色底
        var cellRuns = runs
        if row == 0 {
            block.backgroundColor = RichStyle.headerBackground
            cellRuns = runs.map { r in
                var r = r
                r.bold = true
                return r
            }
        }
        let p = NSMutableAttributedString(attributedString: paragraph(runsString(cellRuns, kind: .body, baseURL: baseURL),
                                                                      kind: .body, block: block))
        if alignment != .natural,
           let style = (p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.alignment = alignment
            p.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: p.length))
        }
        return p
    }

    // MARK: 图片与分隔线

    static let maxImageWidth: CGFloat = 560

    static func imageString(path: String, alt: String, title: String? = nil, link: String? = nil, linkTitle: String? = nil, baseURL: URL?) -> NSAttributedString {
        var image: NSImage?
        let lower = path.lowercased()
        let embedded = lower.hasPrefix("data:")
        if embedded {
            image = URL(string: path).flatMap { try? Data(contentsOf: $0) }.flatMap { NSImage(data: $0) }
        // 网络图片为保护隐私不加载
        } else if !lower.hasPrefix("http:"), !lower.hasPrefix("https:"), !lower.hasPrefix("//"), !path.isEmpty {
            image = NSImage(contentsOf: URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: baseURL))
        }
        var marks: [NSAttributedString.Key: Any] = [DMKey.image: path, DMKey.alt: alt]
        marks[DMKey.title] = title
        marks[DMKey.link] = link
        marks[DMKey.linkTitle] = linkTitle
        marks[DMKey.imageID] = UUID().uuidString
        guard let loaded = image, loaded.size.width > 0, loaded.size.height > 0 else {
            // 找不到图片时显示占位文字，保存时仍写回原来的图片地址
            var a = RichStyle.attributes(for: MDRun(), kind: .body)
            a[.foregroundColor] = NSColor.secondaryLabelColor
            for (k, v) in marks { a[k] = v }
            return NSAttributedString(string: String(localized: "［图片：\(alt.isEmpty ? (embedded ? "data:" : path) : alt)］"), attributes: a)
        }
        let attachment = NSTextAttachment()
        attachment.image = loaded
        let scale = min(1, maxImageWidth / loaded.size.width)
        attachment.bounds = CGRect(x: 0, y: 0, width: loaded.size.width * scale, height: loaded.size.height * scale)
        let s = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        s.addAttributes(marks, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: 公式

    static func isInlineMath(_ text: String) -> Bool {
        text.count >= 3 && text.hasPrefix("$") && text.hasSuffix("$") && !text.hasPrefix("$$")
            || text.count >= 5 && text.hasPrefix("\\(") && text.hasSuffix("\\)")
    }

    static func isMathBlock(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 5 && (t.hasPrefix("$$") && t.hasSuffix("$$") || t.hasPrefix("\\[") && t.hasSuffix("\\]"))
    }

    /// 公式显示为一张图片（一个字符），保存时写回原文
    static func mathString(_ source: String, display: Bool, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let font = (attributes[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(source: source, display: display, font: font)
        let s = NSMutableAttributedString(attachment: attachment)
        var a = attributes
        a[DMKey.math] = source
        a[DMKey.literal] = nil
        a[.foregroundColor] = nil
        s.addAttributes(a, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// 公式块：单独一段、居中
    static func mathBlockParagraph(_ source: String) -> NSAttributedString {
        let p = NSMutableAttributedString(attributedString: paragraph(
            mathString(source, display: true, attributes: RichStyle.attributes(for: MDRun(), kind: .body)), kind: .raw))
        let style = (RichStyle.paragraphStyle(.body).mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.alignment = .center
        p.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: p.length))
        return p
    }

    /// 复制粘贴后：按原文重建公式、图片和分隔线（剪贴板里不存图片本身）
    static func restoringAttachments(_ source: NSAttributedString, baseURL: URL?) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: s.length)
        var jobs: [(NSRange, NSAttributedString)] = []
        s.enumerateAttributes(in: whole, options: []) { a, range, _ in
            if let math = a[DMKey.math] as? String {
                // 每个公式一个字符
                for i in 0..<range.length {
                    jobs.append((NSRange(location: range.location + i, length: 1),
                                 mathString(math, display: isMathBlock(math), attributes: a)))
                }
            } else if let path = a[DMKey.image] as? String {
                let image = NSMutableAttributedString(attributedString: imageString(path: path, alt: (a[DMKey.alt] as? String) ?? "",
                                                                                         title: a[DMKey.title] as? String, link: a[DMKey.link] as? String,
                                                                                         linkTitle: a[DMKey.linkTitle] as? String, baseURL: baseURL))
                var rest = a
                rest[.attachment] = nil
                for (k, v) in rest where image.attribute(k, at: 0, effectiveRange: nil) == nil {
                    image.addAttribute(k, value: v, range: NSRange(location: 0, length: image.length))
                }
                jobs.append((range, image))
            } else if a[DMKey.rule] != nil, (s.string as NSString).substring(with: range).contains("\u{FFFC}") {
                let rule = NSMutableAttributedString(attributedString: ruleAttachment())
                rule.addAttributes(a, range: NSRange(location: 0, length: rule.length))
                let ns = s.string as NSString
                let at = ns.range(of: "\u{FFFC}", range: range)
                jobs.append((at, rule))
            }
        }
        for (range, value) in jobs.reversed() { s.replaceCharacters(in: range, with: value) }
        return s
    }

    /// 分隔线占位（透明）。线本身由 RichLayoutManager 按整行宽度画出，与正文、代码块左右对齐。
    static func ruleAttachment() -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 1, height: 9), flipped: false) { _ in true }
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - 富文本 → Markdown

    static func markdown(from storage: NSAttributedString) -> String {
        MarkdownCodec.serialize(blocks(from: storage))
    }

    private enum Item {
        case line(MDLine)
        case code(String, String, listGap: Bool?, id: String?)
        case raw(String)
        case rule
        case summary(String, open: Bool)
        case math(String)
        case cell(NSTextTable, Int, Int, [MDRun], NSTextAlignment)
    }

    private struct Entry {
        let item: Item
        let inDetails: Bool
    }

    static func blocks(from storage: NSAttributedString) -> [MDBlock] {
        let ns = storage.string as NSString
        var items: [Entry] = []
        var index = 0
        while index < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(para)
            var content = para
            if content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x2029 || last == 0x0D { content.length -= 1 }
            }
            let attrs = para.length > 0 ? storage.attributes(at: para.location, effectiveRange: nil) : [:]
            if attrs[DMKey.codeGap] != nil, content.length == 0 { continue }
            items.append(Entry(item: classify(storage, ns, content: content, attrs: attrs),
                               inDetails: attrs[DMKey.inDetails] != nil))
        }
        // 末尾的空段落没有意义，不写入文件
        while let last = items.last {
            guard case .line(let l) = last.item, l.kind == .body, !last.inDetails,
                  l.runs.allSatisfy({ $0.text.isEmpty && $0.image == nil }) else { break }
            items.removeLast()
        }
        return group(items)
    }

    /// 段落的样式（以段落第一个字符的属性为准）
    static func kind(of a: [NSAttributedString.Key: Any]) -> RichKind {
        if a[DMKey.rule] != nil { return .rule }
        if a[DMKey.summary] != nil { return .summary }
        if let lang = a[DMKey.code] as? String { return .code(lang) }
        if a[DMKey.raw] != nil { return .raw }
        if let level = a[DMKey.heading] as? Int { return .heading(level) }
        if let state = a[DMKey.task] as? Int { return .task((a[DMKey.depth] as? Int) ?? 0, state == 2) }
        if let list = a[DMKey.list] as? String {
            let depth = (a[DMKey.depth] as? Int) ?? 0
            return list == "ordered" ? .ordered(depth) : .bullet(depth)
        }
        if a[DMKey.quote] != nil { return .quote }
        return .body
    }

    static func tableBlock(of a: [NSAttributedString.Key: Any]) -> NSTextTableBlock? {
        (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
    }

    private static func classify(_ storage: NSAttributedString, _ ns: NSString, content: NSRange,
                                 attrs: [NSAttributedString.Key: Any]) -> Item {
        if let block = tableBlock(of: attrs) {
            return .cell(block.table, block.startingRow, block.startingColumn, runs(storage, content),
                         (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural)
        }
        let k = kind(of: attrs)
        if k == .raw, let source = attrs[DMKey.math] as? String { return .math(source) }
        switch k {
        case .rule:
            return .rule
        case .code(let lang):
            return .code(lang, plainText(ns, content), listGap: attrs[DMKey.listCode] as? Bool, id: attrs[DMKey.codeBlock] as? String)
        case .raw:
            return .raw(plainText(ns, content))
        case .summary:
            return .summary(plainText(ns, content), open: attrs[DMKey.detailsOpen] != nil)
        case .task:
            var r = content
            if r.length >= 2 {
                let box = ns.substring(with: NSRange(location: r.location, length: 1))
                if box == RichStyle.taskTodo || box == RichStyle.taskDone {
                    let skip = ns.substring(with: NSRange(location: r.location + 1, length: 1)) == " " ? 2 : 1
                    r = NSRange(location: r.location + skip, length: r.length - skip)
                }
            }
            return .line(MDLine(kind: k.lineKind, runs: runs(storage, r)))
        default:
            return .line(MDLine(kind: k.lineKind, runs: runs(storage, content), start: attrs[DMKey.start] as? Int))
        }
    }

    private static func plainText(_ ns: NSString, _ range: NSRange) -> String {
        ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func runs(_ storage: NSAttributedString, _ range: NSRange) -> [MDRun] {
        guard range.length > 0 else { return [] }
        let ns = storage.string as NSString
        var out: [MDRun] = []
        var lastImageRange: NSRange?
        var lastImageID: String?
        var lastCalloutEnd = -1
        storage.enumerateAttributes(in: range, options: []) { a, sub, _ in
            if let header = a[DMKey.callout] as? String {
                // 标题文字被拆成几段（如改了其中一个字的格式）时也只写一次
                if lastCalloutEnd == sub.location, out.last?.text == header { lastCalloutEnd = NSMaxRange(sub); return }
                var r = MDRun(text: header)
                r.literal = true
                out.append(r)
                lastCalloutEnd = NSMaxRange(sub)
                return
            }
            if let source = a[DMKey.math] as? String {
                // 每个公式是一个字符；相邻的相同公式各写一次
                for _ in 0..<sub.length {
                    var r = MDRun(text: source)
                    r.literal = true
                    out.append(r)
                }
                return
            }
            if let src = a[DMKey.image] as? String {
                // 同一张图片（或其占位文字）只写一次
                if let prev = lastImageRange, NSMaxRange(prev) == sub.location, a[DMKey.imageID] as? String == lastImageID { return }
                var r = MDRun(text: (a[DMKey.alt] as? String) ?? "")
                r.image = src
                r.title = a[DMKey.title] as? String
                r.link = a[DMKey.link] as? String
                r.linkTitle = a[DMKey.linkTitle] as? String
                out.append(r)
                lastImageRange = sub
                lastImageID = a[DMKey.imageID] as? String
                return
            }
            var text = ns.substring(with: sub)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            if a[DMKey.softBreak] != nil { text = text.replacingOccurrences(of: " ", with: "\n") }
            var r = MDRun(text: text)
            r.bold = RichStyle.isBold(a[.font] as? NSFont)
            r.italic = ((a[.obliqueness] as? Double) ?? 0) != 0
            r.underline = ((a[.underlineStyle] as? Int) ?? 0) != 0
            r.strike = ((a[.strikethroughStyle] as? Int) ?? 0) != 0
            r.highlight = a[DMKey.highlight] != nil
            let shift = (a[.superscript] as? Int) ?? 0
            r.sup = shift > 0
            r.sub = shift < 0
            r.kbd = a[DMKey.kbd] != nil
            r.code = a[DMKey.inlineCode] != nil
            r.literal = a[DMKey.literal] != nil
            r.link = a[DMKey.link] as? String
            if r.link != nil {
                r.title = a[DMKey.title] as? String
                // 链接本身显示为带下划线，不算用户加的下划线
                r.underline = false
            }
            out.append(r)
        }
        return out
    }

    private static func group(_ entries: [Entry]) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var i = 0
        while i < entries.count {
            let zone = entries[i].inDetails
            // 连续、且同在（或同不在）折叠块中的项目
            func next(_ k: Int) -> Item? { k < entries.count && entries[k].inDetails == zone ? entries[k].item : nil }
            switch entries[i].item {
            case .summary(let title, let open):
                var body: [Entry] = []
                i += 1
                while i < entries.count && entries[i].inDetails {
                    body.append(Entry(item: entries[i].item, inDetails: false))
                    i += 1
                }
                // 内容末尾的空段落（表格后为放光标补的）不写入文件，否则会保存成 &nbsp;
                while let last = body.last, case .line(let l) = last.item, l.kind == .body,
                      l.runs.allSatisfy({ $0.text.isEmpty && $0.image == nil }) {
                    body.removeLast()
                }
                blocks.append(.details(summary: title, body: group(body), open: open))
            case .line(let l):
                blocks.append(.line(l))
                i += 1
            case .rule:
                blocks.append(.rule)
                i += 1
            case .math(let source):
                blocks.append(.raw(source))
                i += 1
            case .code(let lang, _, let listGap, let id):
                var lines: [String] = []
                while let item = next(i) {
                    guard case .code(_, let text, _, let other) = item, other == id else { break }
                    lines.append(text)
                    i += 1
                }
                blocks.append(.code(lang: lang, lines: lines, listGap: listGap))
            case .raw:
                var lines: [String] = []
                while let item = next(i) {
                    guard case .raw(let text) = item else { break }
                    lines.append(text)
                    i += 1
                }
                blocks.append(.raw(lines.joined(separator: "\n")))
            case .cell(let table, _, _, _, _):
                var cells: [(row: Int, col: Int, runs: [MDRun])] = []
                var aligns: [Int: NSTextAlignment] = [:]   // 按表头一行的对齐方式保存
                while let item = next(i) {
                    guard case .cell(let t, let r, let c, let rs, let a) = item, t === table else { break }
                    cells.append((r, c, rs))
                    if r == 0 { aligns[c] = a }
                    i += 1
                }
                let rows = (cells.map { $0.row }.max() ?? -1) + 1
                let cols = max(table.numberOfColumns, (cells.map { $0.col }.max() ?? -1) + 1)
                var grid = Array(repeating: Array(repeating: [MDRun](), count: cols), count: rows)
                for cell in cells where cell.row >= 0 && cell.col >= 0 {
                    grid[cell.row][cell.col] = cell.runs
                }
                blocks.append(.table(grid, align: (0..<cols).map { marker(aligns[$0] ?? .natural) }))
            }
        }
        return blocks
    }
}
