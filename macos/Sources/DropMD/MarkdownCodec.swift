import Foundation

// 富文本编辑区与 Markdown 文件之间的中间模型。
// 只依赖 Foundation（不依赖 AppKit），可以单独测试。

/// 一段样式相同的文字
struct MDRun: Equatable {
    var text: String = ""
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var highlight = false     // ==高亮==
    var sup = false   // <sup>上标</sup>
    var sub = false     // <sub>下标</sub>
    var kbd = false           // <kbd>键盘按键</kbd>
    var code = false          // 行内代码
    var literal = false       // 原样保存的文字（例如 $公式$），保存时不转义
    var link: String?         // 链接地址（与 Markdown 中的写法相同）
    var title: String?        // 链接、图片的提示文字，保存原文（含引号），如 "标题"
    var image: String?        // 图片地址，保存原文（可能有 %20 这样的编码）；此时 text 为替代文字
    var linkTitle: String?    // 带链接的图片：链接的提示文字（title 是图片自己的）
}

/// 提示框（GitHub 写法：引用的第一行是 [!NOTE] 等）
enum MDCallout: String, CaseIterable {
    case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"

    var title: String {
        switch self {
        case .note: return String(localized: "注意")
        case .tip: return String(localized: "提示")
        case .important: return String(localized: "重要")
        case .warning: return String(localized: "警告")
        case .caution: return String(localized: "小心")
        }
    }

    var header: String { "[!\(rawValue)]" }

    /// 引用中的一行是否是提示框的标题行（如 [!NOTE]）
    init?(header text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[!"), t.hasSuffix("]") else { return nil }
        self.init(rawValue: String(t.dropFirst(2).dropLast()).uppercased())
    }
}

/// 段落类型
enum MDLineKind: Equatable {
    case body
    case heading(Int)         // 1…6
    case quote
    case bullet(Int)          // 嵌套层级，从 0 开始
    case ordered(Int)
    case task(Int, Bool)      // 层级、是否已完成

    /// 相邻时不需要空行分隔（列表项、引用）
    var tight: Bool {
        switch self {
        case .quote, .bullet, .ordered, .task: return true
        default: return false
        }
    }

    /// 列表项的层级；不是列表项时为 nil
    var listDepth: Int? {
        switch self {
        case .bullet(let d), .ordered(let d), .task(let d, _): return d
        default: return nil
        }
    }

    var isOrdered: Bool {
        if case .ordered = self { return true }
        return false
    }
}

struct MDLine: Equatable {
    var kind: MDLineKind
    var runs: [MDRun]
    var start: Int? = nil     // 有序列表不从 1 开始时，第一项的编号（如 5.）
}

/// 有序列表的编号：每一层各自计数，遇到列表以外的内容重新开始（解析和保存共用）
struct MDNumbering {
    private var counts: [Int: Int] = [:]

    /// 有序列表项的编号，以及它是不是这一串的第一项；不是有序列表项时为 nil
    mutating func number(for block: MDBlock) -> (n: Int, first: Bool)? {
        if case .code(_, _, .some) = block { return nil }   // 列表项里的代码块不打断编号
        guard case .line(let line) = block, let d = line.kind.listDepth else { counts = [:]; return nil }
        counts = counts.filter { $0.key <= d }
        guard line.kind.isOrdered else { counts[d] = nil; return nil }
        let first = counts[d] == nil
        let n = counts[d].map { $0 + 1 } ?? (line.start ?? 1)
        counts[d] = n
        return (n, first)
    }
}

enum MDBlock: Equatable {
    case line(MDLine)
    /// listGap：属于上面的列表项时不为 nil（AI 常写的“1. 安装：”下面的代码），true 表示前后有空行
    case code(lang: String, lines: [String], listGap: Bool? = nil)   // lang：``` 后面的整段文字
    case table([[[MDRun]]], align: [String] = [])   // 行 → 单元格 → 文字，第一行为表头；align：各列的 ---、:--、:-:、--:
    case rule
    case details(summary: String, body: [MDBlock], open: Bool)   // 折叠块 <details>；open：<details open>，默认展开
    case raw(String)          // 编辑器不支持的内容（HTML、公式块等），原样保存
}

/// Markdown ⇄ 段落模型。只实现 Word 式编辑需要的常用语法，其余内容原样保留。
enum MarkdownCodec {
    // MARK: - 解析（块）

    static func parse(_ source: String) -> [MDBlock] {
        parseWithSource(source).blocks
    }

    /// 一段原文（lines）解析出的块（blocks）。保存时没改过的块直接写回这段原文
    struct SourceGroup {
        let blocks: Range<Int>
        let lines: Range<Int>
    }

    static func parseWithSource(_ source: String) -> (blocks: [MDBlock], groups: [SourceGroup], lines: [String]) {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var indents: [Int] = []   // 列表缩进栈，用于计算嵌套层级
        var i = 0
        // 文件开头的 YAML 信息（--- … ---，Obsidian、Hugo 等用）：原样保存
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            blocks.append(.raw(lines[0...end].joined(separator: "\n")))
            i = end + 1
        }
        var sources: [SourceGroup] = []
        var firstBlock = 0, firstLine = 0
        func closeGroup() {
            if blocks.count > firstBlock {
                var end = min(i, lines.count)
                while end > firstLine, isBlank(lines[end - 1]) { end -= 1 }
                sources.append(SourceGroup(blocks: firstBlock..<blocks.count, lines: firstLine..<end))
            }
            firstBlock = blocks.count
            firstLine = i
        }
        while i < lines.count {
            closeGroup()
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // 缩进 4 格的代码块
            if indents.isEmpty, leadingWidth(line) >= 4 {
                var body: [String] = []
                while i < lines.count && (isBlank(lines[i]) || leadingWidth(lines[i]) >= 4) {
                    body.append(dropIndent(lines[i], 4))
                    i += 1
                }
                while let last = body.last, isBlank(last) { body.removeLast() }
                blocks.append(.code(lang: "", lines: body))
                continue
            }

            if let fence = fenceOpening(line) {
                indents = []
                var body: [String] = []
                i += 1
                while i < lines.count && !isFenceClosing(lines[i], fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(lang: fence.lang, lines: body))
                continue
            }
            if let m = groups(headingPattern, line) {
                indents = []
                let content = m[2].replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                blocks.append(.line(MDLine(kind: .heading(m[1].count), runs: parseInline(content))))
                i += 1
                continue
            }
            if groups(rulePattern, line) != nil {
                indents = []
                blocks.append(.rule)
                i += 1
                continue
            }
            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                indents = []
                var rows = [splitRow(line)]
                let align = splitRow(lines[i + 1]).map { cell -> String in
                    let t = cell.trimmingCharacters(in: .whitespaces)
                    switch (t.hasPrefix(":"), t.hasSuffix(":")) {
                    case (true, true): return ":-:"
                    case (true, false): return ":--"
                    case (false, true): return "--:"
                    default: return "---"
                    }
                }
                i += 2
                while i < lines.count && lines[i].contains("|") && !isBlank(lines[i]) {
                    rows.append(splitRow(lines[i]))
                    i += 1
                }
                let cols = rows.map { $0.count }.max() ?? 0
                let grid: [[[MDRun]]] = rows.map { row -> [[MDRun]] in
                    (0..<cols).map { c -> [MDRun] in c < row.count ? parseInline(row[c]) : [] }
                }
                blocks.append(.table(grid, align: align))
                continue
            }
            if groups(quotePattern, line) != nil {
                indents = []
                var j = i
                var contents: [String] = []
                while j < lines.count {
                    if let q = groups(quotePattern, lines[j]) {
                        contents.append(q[1])
                    } else if let last = contents.last, !isBlank(last), !isBlank(lines[j]), !startsBlock(lines[j]),
                              groups(setextPattern, lines[j]) == nil {
                        // 不带 > 的续行也属于这段引用，保存时补上 >
                        contents.append(lines[j].trimmingCharacters(in: .whitespaces))
                    } else {
                        break
                    }
                    j += 1
                }
                // 引用里有列表、标题、代码等单页表示不了的内容：整段原样保存
                if contents.contains(where: { startsBlock($0) || leadingWidth($0) >= 4 }) {
                    blocks.append(.raw(lines[i..<j].joined(separator: "\n")))
                } else {
                    for content in contents {
                        // 提示框的标题行原样保存，不能转义成 \[!NOTE\]
                        let runs = MDCallout(header: content) != nil
                            ? [MDRun(text: content.trimmingCharacters(in: .whitespaces), literal: true)] : parseInline(content)
                        blocks.append(.line(MDLine(kind: .quote, runs: runs)))
                    }
                }
                i = j
                continue
            }
            if indents.isEmpty, groups(listPattern, line) != nil, let end = complexListEnd(lines, i) {
                // 只是列表项里带代码块：拆成列表项和代码块，单页里可以编辑
                if let parts = listWithCode(Array(lines[i..<end])) {
                    blocks += parts
                    i = end
                    continue
                }
                // 列表项里有续段、引用等单页表示不了的内容：整个列表原样保存
                var body = Array(lines[i..<end])
                while let last = body.last, isBlank(last) { body.removeLast() }
                blocks.append(.raw(body.joined(separator: "\n")))
                i = end
                continue
            }
            if let m = groups(listPattern, line) {
                let indent = indentWidth(m[1])
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last != indent { indents.append(indent) }
                let depth = indents.count - 1
                var content = m[3]
                var kind: MDLineKind = m[2].first?.isNumber == true ? .ordered(depth) : .bullet(depth)
                if let t = groups(taskPattern, content) {
                    kind = .task(depth, t[1] != " ")
                    content = t[2]
                }
                i += 1
                // 紧接着的续行属于这一项，换行保留
                while i < lines.count && !isBlank(lines[i]) && groups(listPattern, lines[i]) == nil && !startsBlock(lines[i]) {
                    content += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                var item = MDLine(kind: kind, runs: parseInline(content))
                if kind.isOrdered { item.start = Int(m[2].dropLast()) }
                blocks.append(.line(item))
                continue
            }
            if trimmed.lowercased().hasPrefix("<details") {
                indents = []
                var body: [String] = []
                var depth = 0
                repeat {
                    let l = lines[i].lowercased()
                    depth += l.components(separatedBy: "<details").count - 1
                    depth -= l.components(separatedBy: "</details>").count - 1
                    body.append(lines[i])
                    i += 1
                } while i < lines.count && depth > 0
                blocks.append(details(body.joined(separator: "\n")))
                continue
            }
            if isRawStart(line) {
                indents = []
                var body: [String] = []
                while i < lines.count && !isBlank(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.raw(body.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("$$") {
                indents = []
                var body = [line]
                let closed = trimmed.count > 2 && trimmed.hasSuffix("$$")
                i += 1
                if !closed {
                    while i < lines.count {
                        body.append(lines[i])
                        let done = lines[i].contains("$$")
                        i += 1
                        if done { break }
                    }
                }
                blocks.append(.raw(body.joined(separator: "\n")))
                continue
            }
            // \[ … \]（ChatGPT 等常用的公式块）：找得到 \] 才算，原样保存
            if trimmed.hasPrefix("\\["), let end = mathBracketEnd(lines, i) {
                indents = []
                blocks.append(.raw(lines[i...end].joined(separator: "\n")))
                i = end + 1
                continue
            }

            // 多行脚注（[^1]: 后面有缩进的续行或续段）：原样保存
            if indents.isEmpty, groups(footnotePattern, line) != nil {
                var j = i + 1, end = i + 1, multi = false
                while j < lines.count {
                    if isBlank(lines[j]) {
                        var k = j
                        while k < lines.count && isBlank(lines[k]) { k += 1 }
                        guard k < lines.count, leadingWidth(lines[k]) >= 4 else { break }
                        j = k
                        continue
                    }
                    if leadingWidth(lines[j]) == 0, startsBlock(lines[j]) || groups(footnotePattern, lines[j]) != nil { break }
                    if leadingWidth(lines[j]) > 0 { multi = true }
                    j += 1
                    end = j
                }
                if multi {
                    blocks.append(.raw(lines[i..<end].joined(separator: "\n")))
                    i = end
                    continue
                }
            }

            // 普通段落：连续的多行合并为一段
            indents = []
            if trimmed == "&nbsp;" {
                blocks.append(.line(MDLine(kind: .body, runs: [])))
                i += 1
                continue
            }
            var parts = [line]
            i += 1
            while i < lines.count && !isBlank(lines[i]) && !startsBlock(lines[i]) && groups(setextPattern, lines[i]) == nil {
                parts.append(lines[i])
                i += 1
            }
            // 段落下一行是 === 或 ---：一级、二级标题
            var kind = MDLineKind.body
            if i < lines.count, let m = groups(setextPattern, lines[i]) {
                kind = .heading(m[1].hasPrefix("=") ? 1 : 2)
                i += 1
            }
            // 行尾两个空格或反斜杠是强制换行，按 <br> 读入；其他换行在正文里原样保留（中文常这样分行），标题里合并为空格
            let soft = kind == .body ? "\n" : " "
            var text = ""
            for (k, part) in parts.enumerated() {
                var t = part.trimmingCharacters(in: .whitespaces)
                if k == parts.count - 1 { text += t; break }
                // 行尾单数个反斜杠才是换行；双数个是转义后的普通反斜杠（如 C:\\）
                if t.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                    t.removeLast()
                    text += t + "<br>"
                } else {
                    text += t + (part.hasSuffix("  ") ? "<br>" : soft)
                }
            }
            blocks.append(.line(MDLine(kind: kind, runs: parseInline(text))))
        }
        closeGroup()
        // 只在一串有序列表的第一项上记编号，且不是 1 时才记
        var numbering = MDNumbering()
        for k in blocks.indices {
            if let (_, first) = numbering.number(for: blocks[k]), case .line(var l) = blocks[k], !first || l.start == 1 {
                l.start = nil
                blocks[k] = .line(l)
            }
        }
        return (blocks, sources, lines)
    }

    /// 列表从 start 开始；里面有单页表示不了的内容（项里空行后的续段、代码块、引用等）时返回列表的结束位置，否则返回 nil
    private static func complexListEnd(_ lines: [String], _ start: Int) -> Int? {
        var j = start
        var complex = false
        while j < lines.count {
            let l = lines[j]
            if isBlank(l) {
                var k = j + 1
                while k < lines.count && isBlank(lines[k]) { k += 1 }
                guard k < lines.count else { break }
                if groups(listPattern, lines[k]) == nil {
                    guard leadingWidth(lines[k]) >= 2 else { break }   // 空行后没有缩进：列表结束
                    complex = true
                }
                j = k
                continue
            }
            if groups(listPattern, l) == nil {
                if leadingWidth(l) == 0 && startsBlock(l) { break }
                if startsBlock(l.trimmingCharacters(in: .whitespaces)) { complex = true }
            }
            j += 1
        }
        return complex ? j : nil
    }

    /// 列表项里只有代码块时（AI 常写“1. 安装：”下面跟代码）拆成列表项和代码块；还有续段等其他内容时返回 nil
    private static func listWithCode(_ lines: [String]) -> [MDBlock]? {
        var out: [MDBlock] = []
        var chunk: [String] = []   // 连续的列表行，交给 parse
        var contentCol = 0         // 上一个列表项文字开始的列
        func flush() -> Bool {
            guard !chunk.isEmpty else { return true }
            let parsed = parse(chunk.joined(separator: "\n"))
            chunk = []
            guard parsed.allSatisfy({ if case .line(let l) = $0 { return l.kind.listDepth != nil } else { return false } }) else { return false }
            out += parsed
            return true
        }
        var j = 0
        while j < lines.count {
            let l = lines[j]
            if isBlank(l) { j += 1; continue }
            let w = leadingWidth(l)
            if let m = groups(listPattern, l) {
                // 代码块后面的嵌套项：层级算不准，整块原样保存
                if chunk.isEmpty, !out.isEmpty, w > 0 { return nil }
                let gap = l.dropFirst(m[1].count + m[2].count).prefix(while: { $0 == " " }).count
                contentCol = indentWidth(m[1]) + m[2].count + min(max(gap, 1), 4)
                chunk.append(l)
                j += 1
                continue
            }
            if let fence = fenceOpening(dropIndent(l, w)), w >= contentCol, !(chunk.isEmpty && out.isEmpty) {
                guard flush() else { return nil }
                let gap = isBlank(lines[j - 1])
                var body: [String] = []
                j += 1
                while j < lines.count, !isFenceClosing(dropIndent(lines[j], w), fence) {
                    body.append(dropIndent(lines[j], w))
                    j += 1
                }
                guard j < lines.count else { return nil }   // 没有结尾的 ```
                j += 1
                out.append(.code(lang: fence.lang, lines: body, listGap: gap))
                continue
            }
            // 紧跟在列表行后的续行
            if !chunk.isEmpty, !isBlank(lines[j - 1]) {
                chunk.append(l)
                j += 1
                continue
            }
            return nil
        }
        return flush() ? out : nil
    }

    /// 解析 <details><summary>标题</summary>内容</details>
    private static func details(_ text: String) -> MDBlock {
        var inner = text
        var open = false
        if let r = inner.range(of: #"^\s*<details[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            open = inner[r].range(of: #"\sopen\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            inner.removeSubrange(r)
        }
        if let r = inner.range(of: #"</details>\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            inner.removeSubrange(r)
        }
        var summary = ""
        if let r = inner.range(of: #"^\s*<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive]) {
            summary = String(inner[r])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            inner.removeSubrange(r)
        }
        return .details(summary: summary, body: parse(inner), open: open)
    }

    // MARK: - 块级语法的识别

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // 模式均为常量，构造失败属于编程错误
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let headingPattern = re(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$"#)
    private static let footnotePattern = re(#"^ {0,3}\[\^[^\]\s]+\]:"#)
    private static let setextPattern = re(#"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let rulePattern = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quotePattern = re(#"^ {0,3}>[ \t]?(.*)$"#)
    private static let listPattern = re(#"^([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?$"#)
    private static let taskPattern = re(#"^\[([ xX])\](?:[ \t]+(.*))?$"#)
    private static let fencePattern = re(#"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    private static let tableDelimiterPattern = re(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private static let rawStartPattern = re(
        #"^[ \t]*(<!--|</?(div|details|summary|table|section|center|p|img|br|hr|h[1-6])[\s/>])"#, .caseInsensitive)

    /// 返回各捕获组（未参与匹配的组为空字符串）；不匹配时返回 nil
    private static func groups(_ pattern: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = pattern.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { k in
            let r = m.range(at: k)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private struct Fence {
        let mark: Character
        let count: Int
        let lang: String
    }

    private static func fenceOpening(_ line: String) -> Fence? {
        guard let m = groups(fencePattern, line), let mark = m[1].first else { return nil }
        let info = m[2].trimmingCharacters(in: .whitespaces)
        if mark == "`" && info.contains("`") { return nil }
        return Fence(mark: mark, count: m[1].count, lang: info)   // 整行都留着：```python title="a.py"
    }

    private static func isFenceClosing(_ line: String, _ fence: Fence) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= fence.count && t.allSatisfy { $0 == fence.mark }
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        line.contains("-") && groups(tableDelimiterPattern, line) != nil
    }

    /// 引用式链接的地址定义 [编号]: 网址（脚注 [^1]: 除外）
    private static let referencePattern = re(#"^ {0,3}\[[^\]^][^\]]*\]:[ \t]*\S"#)

    private static func isRawStart(_ line: String) -> Bool {
        groups(rawStartPattern, line) != nil || groups(referencePattern, line) != nil
    }

    /// 这一行是否开始一个新的块（用于判断段落在哪里结束）
    static func isSetextUnderline(_ line: String) -> Bool {
        groups(setextPattern, line) != nil
    }

    /// \[ 公式块的最后一行（含 \]）；没有 \] 时返回 nil
    static func mathBracketEnd(_ lines: [String], _ start: Int) -> Int? {
        for k in start..<lines.count {
            let rest = k == start ? String(lines[k].trimmingCharacters(in: .whitespaces).dropFirst(2)) : lines[k]
            if rest.contains("\\]") { return k }
        }
        return nil
    }

    static func startsBlock(_ line: String) -> Bool {
        fenceOpening(line) != nil || groups(headingPattern, line) != nil || groups(rulePattern, line) != nil
            || groups(quotePattern, line) != nil || groups(listPattern, line) != nil || isRawStart(line)
            || line.trimmingCharacters(in: .whitespaces).hasPrefix("$$")
    }

    private static func indentWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// 行首空白的宽度（制表符算 4 格）
    private static func leadingWidth(_ line: String) -> Int {
        indentWidth(String(line.prefix(while: { $0 == " " || $0 == "\t" })))
    }

    /// 去掉行首最多 n 格的空白
    private static func dropIndent(_ line: String, _ n: Int) -> String {
        var s = Substring(line)
        var w = 0
        while w < n, let ch = s.first, ch == " " || ch == "\t" {
            w += ch == "\t" ? 4 : 1
            s.removeFirst()
        }
        return String(s)
    }

    /// 拆分表格的一行；保留 \| 转义，交给行内解析处理
    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped {
                cur.append(ch)
                escaped = false
            } else if ch == "\\" {
                cur.append(ch)
                escaped = true
            } else if ch == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
