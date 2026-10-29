import AppKit

/// Markdown 段落模型 ⇄ 富文本（NSAttributedString）
enum RichBridge {
    // MARK: - Markdown → 富文本

    static func attributed(markdown: String, baseURL: URL?) -> NSAttributedString {
        attributed(from: MarkdownCodec.parse(markdown), baseURL: baseURL)
    }

    static func attributed(from blocks: [MDBlock], baseURL: URL?) -> NSAttributedString {
        let out = NSMutableAttributedString()

        for block in blocks {
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
                out.append(paragraph(content, kind: kind))

            case .code(let lang, let lines):
                for l in (lines.isEmpty ? [""] : lines) {
                    out.append(paragraph(runsString([MDRun(text: l)], kind: .code(lang), baseURL: baseURL), kind: .code(lang)))
                }

            case .table(let rows):
                let cols = max(1, rows.map { $0.count }.max() ?? 1)
                let table = makeTable(columns: cols)
                for (r, row) in rows.enumerated() {
                    for c in 0..<cols {
                        out.append(cellParagraph(table: table, row: r, column: c,
                                                 runs: c < row.count ? row[c] : [], baseURL: baseURL))
                    }
                }

            case .rule:
                out.append(paragraph(ruleAttachment(), kind: .rule))

            case .raw(let text):
                for l in text.components(separatedBy: "\n") {
                    out.append(paragraph(runsString([MDRun(text: l)], kind: .raw, baseURL: baseURL), kind: .raw))
                }

            case .details(let summary, let body):
                out.append(paragraph(runsString([MDRun(text: summary)], kind: .summary, baseURL: baseURL), kind: .summary))
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
                s.append(imageString(path: src, alt: r.text, baseURL: baseURL))
            } else if r.literal, let c = MDCallout(header: r.text) {
                // 提示框标题行显示为中文标题，保存时写回原文
                var a = RichStyle.attributes(for: r, kind: kind)
                a[DMKey.callout] = r.text.trimmingCharacters(in: .whitespaces)
                s.append(NSAttributedString(string: c.title, attributes: a))
            } else {
                s.append(NSAttributedString(string: r.text, attributes: RichStyle.attributes(for: r, kind: kind)))
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

    static func cellParagraph(table: NSTextTable, row: Int, column: Int, runs: [MDRun], baseURL: URL?) -> NSAttributedString {
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
        return paragraph(runsString(cellRuns, kind: .body, baseURL: baseURL), kind: .body, block: block)
    }

    // MARK: 图片与分隔线

    static let maxImageWidth: CGFloat = 560

    static func imageString(path: String, alt: String, baseURL: URL?) -> NSAttributedString {
        var image: NSImage?
        let lower = path.lowercased()
        // 网络图片为保护隐私不加载
        if !lower.hasPrefix("http:"), !lower.hasPrefix("https:"), !lower.hasPrefix("//"), !path.isEmpty {
            image = NSImage(contentsOf: URL(fileURLWithPath: path, relativeTo: baseURL))
        }
        let marks: [NSAttributedString.Key: Any] = [DMKey.image: path, DMKey.alt: alt]
        guard let loaded = image, loaded.size.width > 0, loaded.size.height > 0 else {
            // 找不到图片时显示占位文字，保存时仍写回原来的图片地址
            var a = RichStyle.attributes(for: MDRun(), kind: .body)
            a[.foregroundColor] = NSColor.secondaryLabelColor
            for (k, v) in marks { a[k] = v }
            return NSAttributedString(string: "［图片：\(alt.isEmpty ? path : alt)］", attributes: a)
        }
        let attachment = NSTextAttachment()
        attachment.image = loaded
        let scale = min(1, maxImageWidth / loaded.size.width)
        attachment.bounds = CGRect(x: 0, y: 0, width: loaded.size.width * scale, height: loaded.size.height * scale)
        let s = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        s.addAttributes(marks, range: NSRange(location: 0, length: s.length))
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
        case code(String, String)
        case raw(String)
        case rule
        case summary(String)
        case cell(NSTextTable, Int, Int, [MDRun])
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
            return .cell(block.table, block.startingRow, block.startingColumn, runs(storage, content))
        }
        let k = kind(of: attrs)
        switch k {
        case .rule:
            return .rule
        case .code(let lang):
            return .code(lang, plainText(ns, content))
        case .raw:
            return .raw(plainText(ns, content))
        case .summary:
            return .summary(plainText(ns, content))
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
            return .line(MDLine(kind: k.lineKind, runs: runs(storage, content)))
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
            if let src = a[DMKey.image] as? String {
                // 同一张图片（或其占位文字）只写一次
                if let prev = lastImageRange, NSMaxRange(prev) == sub.location, out.last?.image == src { return }
                var r = MDRun(text: (a[DMKey.alt] as? String) ?? "")
                r.image = src
                out.append(r)
                lastImageRange = sub
                return
            }
            let text = ns.substring(with: sub)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
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
            case .summary(let title):
                var body: [Entry] = []
                i += 1
                while i < entries.count && entries[i].inDetails {
                    body.append(Entry(item: entries[i].item, inDetails: false))
                    i += 1
                }
                blocks.append(.details(summary: title, body: group(body)))
            case .line(let l):
                blocks.append(.line(l))
                i += 1
            case .rule:
                blocks.append(.rule)
                i += 1
            case .code(let lang, _):
                var lines: [String] = []
                while let item = next(i) {
                    guard case .code(_, let text) = item else { break }
                    lines.append(text)
                    i += 1
                }
                blocks.append(.code(lang: lang, lines: lines))
            case .raw:
                var lines: [String] = []
                while let item = next(i) {
                    guard case .raw(let text) = item else { break }
                    lines.append(text)
                    i += 1
                }
                blocks.append(.raw(lines.joined(separator: "\n")))
            case .cell(let table, _, _, _):
                var cells: [(row: Int, col: Int, runs: [MDRun])] = []
                while let item = next(i) {
                    guard case .cell(let t, let r, let c, let rs) = item, t === table else { break }
                    cells.append((r, c, rs))
                    i += 1
                }
                let rows = (cells.map { $0.row }.max() ?? -1) + 1
                let cols = max(table.numberOfColumns, (cells.map { $0.col }.max() ?? -1) + 1)
                var grid = Array(repeating: Array(repeating: [MDRun](), count: cols), count: rows)
                for cell in cells where cell.row >= 0 && cell.col >= 0 {
                    grid[cell.row][cell.col] = cell.runs
                }
                blocks.append(.table(grid))
            }
        }
        return blocks
    }
}
