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
    var image: String?        // 图片地址；此时 text 为替代文字
}

/// 提示框（GitHub 写法：引用的第一行是 [!NOTE] 等）
enum MDCallout: String, CaseIterable {
    case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"

    var title: String {
        switch self {
        case .note: return "注意"
        case .tip: return "提示"
        case .important: return "重要"
        case .warning: return "警告"
        case .caution: return "小心"
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
}

enum MDBlock: Equatable {
    case line(MDLine)
    case code(lang: String, lines: [String])
    case table([[[MDRun]]])   // 行 → 单元格 → 文字；第一行为表头
    case rule
    case details(summary: String, body: [MDBlock])   // 折叠块 <details>
    case raw(String)          // 编辑器不支持的内容（HTML、公式块等），原样保存
}

/// Markdown ⇄ 段落模型。只实现 Word 式编辑需要的常用语法，其余内容原样保留。
enum MarkdownCodec {
    // MARK: - 解析（块）

    static func parse(_ source: String) -> [MDBlock] {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var indents: [Int] = []   // 列表缩进栈，用于计算嵌套层级
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

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
                i += 2
                while i < lines.count && lines[i].contains("|") && !isBlank(lines[i]) {
                    rows.append(splitRow(lines[i]))
                    i += 1
                }
                let cols = rows.map { $0.count }.max() ?? 0
                let grid: [[[MDRun]]] = rows.map { row -> [[MDRun]] in
                    (0..<cols).map { c -> [MDRun] in c < row.count ? parseInline(row[c]) : [] }
                }
                blocks.append(.table(grid))
                continue
            }
            if let m = groups(quotePattern, line) {
                indents = []
                // 提示框的标题行原样保存，不能转义成 \[!NOTE\]
                let runs = MDCallout(header: m[1]) != nil ? [MDRun(text: m[1].trimmingCharacters(in: .whitespaces), literal: true)]
                                                          : parseInline(m[1])
                blocks.append(.line(MDLine(kind: .quote, runs: runs)))
                i += 1
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
                blocks.append(.line(MDLine(kind: kind, runs: parseInline(content))))
                i += 1
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

            // 普通段落：连续的多行合并为一段
            indents = []
            if trimmed == "&nbsp;" {
                blocks.append(.line(MDLine(kind: .body, runs: [])))
                i += 1
                continue
            }
            var parts = [trimmed]
            i += 1
            while i < lines.count && !isBlank(lines[i]) && !startsBlock(lines[i]) {
                parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            blocks.append(.line(MDLine(kind: .body, runs: parseInline(parts.joined(separator: " ")))))
        }
        return blocks
    }

    /// 解析 <details><summary>标题</summary>内容</details>
    private static func details(_ text: String) -> MDBlock {
        var inner = text
        if let r = inner.range(of: #"^\s*<details[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
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
        return .details(summary: summary, body: parse(inner))
    }

    // MARK: - 块级语法的识别

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // 模式均为常量，构造失败属于编程错误
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let headingPattern = re(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$"#)
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
        let lang = info.components(separatedBy: .whitespaces).first ?? ""
        return Fence(mark: mark, count: m[1].count, lang: lang)
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

    private static func isRawStart(_ line: String) -> Bool {
        groups(rawStartPattern, line) != nil
    }

    /// 这一行是否开始一个新的块（用于判断段落在哪里结束）
    private static func startsBlock(_ line: String) -> Bool {
        fenceOpening(line) != nil || groups(headingPattern, line) != nil || groups(rulePattern, line) != nil
            || groups(quotePattern, line) != nil || groups(listPattern, line) != nil || isRawStart(line)
            || line.trimmingCharacters(in: .whitespaces).hasPrefix("$$")
    }

    private static func indentWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
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
