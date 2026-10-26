import Foundation

// 段落模型 → Markdown 文本

extension MarkdownCodec {
    static func serialize(_ blocks: [MDBlock]) -> String {
        var out = ""
        var prev: MDBlock?
        var orderedDepth: Int?   // 上一个块是有序列表项时的层级
        var number = 0
        var listTypes: [Int: Bool] = [:]   // 各层级最近一个列表项是否为有序列表
        for block in blocks {
            var text: String
            var newList = false
            if case .line(let line) = block, let d = line.kind.listDepth {
                listTypes = listTypes.filter { $0.key <= d }
                if let wasOrdered = listTypes[d], wasOrdered != line.kind.isOrdered { newList = true }
                listTypes[d] = line.kind.isOrdered
            } else {
                listTypes = [:]
            }
            switch block {
            case .line(let line):
                if case .ordered(let d) = line.kind {
                    number = (orderedDepth == d) ? number + 1 : 1
                    orderedDepth = d
                } else {
                    orderedDepth = nil
                }
                text = render(line, number: number)
            case .code(let lang, let lines):
                orderedDepth = nil
                let longest = lines.map { longestRun(of: "`", in: $0) }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                text = fence + lang + "\n" + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + fence
            case .table(let rows):
                orderedDepth = nil
                text = renderTable(rows)
            case .rule:
                orderedDepth = nil
                text = "---"
            case .details(let summary, let body):
                orderedDepth = nil
                let inner = serialize(body).trimmingCharacters(in: .newlines)
                let title = summary.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                // <summary> 之后要空一行，里面的 Markdown 才会被解析
                text = "<details>\n<summary>" + title + "</summary>\n\n" + (inner.isEmpty ? "" : inner + "\n\n") + "</details>"
            case .raw(let s):
                orderedDepth = nil
                text = s
            }
            if text.isEmpty { continue }
            // 同一层级的无序列表与有序列表之间要空行，否则会连成一个列表
            if let p = prev { out += newList ? "\n\n" : separator(p, block) }
            out += text
            prev = block
        }
        return out.isEmpty ? "" : out + "\n"
    }

    private static func separator(_ a: MDBlock, _ b: MDBlock) -> String {
        // 提示框的标题行开始一个新的引用块，与上面的引用之间要空行，否则会连成一个
        if case .line(let y) = b, y.kind == .quote, y.runs.count == 1, y.runs[0].literal,
           MDCallout(header: y.runs[0].text) != nil { return "\n\n" }
        if case .line(let x) = a, case .line(let y) = b, x.kind.tight, y.kind.tight {
            // 引用与列表之间要空行
            if x.kind.listDepth == nil, y.kind.listDepth != nil { return "\n\n" }
            if x.kind.listDepth != nil, y.kind.listDepth == nil { return "\n\n" }
            return "\n"
        }
        if case .raw = a, case .raw = b { return "\n" }
        return "\n\n"
    }

    private static func render(_ line: MDLine, number: Int) -> String {
        switch line.kind {
        case .body:
            let body = inline(line.runs)
            return body.isEmpty ? "&nbsp;" : body   // 空段落用 &nbsp; 保留
        case .heading(let level):
            let body = inline(line.runs, heading: true)
            return String(repeating: "#", count: min(max(level, 1), 6)) + (body.isEmpty ? "" : " " + body)
        case .quote:
            let body = inline(line.runs)
            return body.isEmpty ? ">" : "> " + body
        case .bullet(let d):
            return item(d, "-", inline(line.runs))
        case .ordered(let d):
            return item(d, "\(number).", inline(line.runs))
        case .task(let d, let done):
            return item(d, done ? "- [x]" : "- [ ]", inline(line.runs))
        }
    }

    private static func item(_ depth: Int, _ marker: String, _ body: String) -> String {
        String(repeating: "  ", count: max(depth, 0)) + marker + (body.isEmpty ? "" : " " + body)
    }

    private static func renderTable(_ rows: [[[MDRun]]]) -> String {
        guard !rows.isEmpty else { return "" }
        let cols = max(1, rows.map { $0.count }.max() ?? 1)
        var lines: [String] = []
        for (r, row) in rows.enumerated() {
            let cells = (0..<cols).map { c in c < row.count ? inline(row[c], heading: r == 0, inCell: true) : "" }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if r == 0 { lines.append("|" + String(repeating: " --- |", count: cols)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func longestRun(of ch: Character, in s: String) -> Int {
        var longest = 0, run = 0
        for x in s {
            if x == ch {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    // MARK: - 行内

    private enum Mark: Equatable {
        case link(String), underline, sup, sub, kbd, strike, highlight, bold, italic

        var opening: String {
            switch self {
            case .link: return "["
            case .underline: return "<u>"
            case .sup: return "<sup>"
            case .sub: return "<sub>"
            case .kbd: return "<kbd>"
            case .strike: return "~~"
            case .highlight: return "=="
            case .bold: return "**"
            case .italic: return "*"
            }
        }

        var closing: String {
            switch self {
            case .link(let url): return "](" + MarkdownCodec.encodeURL(url) + ")"
            case .underline: return "</u>"
            case .sup: return "</sup>"
            case .sub: return "</sub>"
            case .kbd: return "</kbd>"
            case .strike: return "~~"
            case .highlight: return "=="
            case .bold: return "**"
            case .italic: return "*"
            }
        }
    }

    /// 标题和表头本身就是粗体，其中的粗体不再单独标记
    static func inline(_ runs: [MDRun], heading: Bool = false, inCell: Bool = false) -> String {
        var out = ""
        var open: [Mark] = []
        var pending = ""   // 尚未输出的空白：标记不能紧挨空白，需要把空白移到标记外面

        func transition(_ needed: [Mark]) {
            var k = 0
            while k < open.count && k < needed.count && open[k] == needed[k] { k += 1 }
            for m in open[k...].reversed() { out += m.closing }
            open.removeSubrange(k...)
            out += pending
            pending = ""
            for m in needed[k...] {
                out += m.opening
                open.append(m)
            }
        }

        for r in merged(runs) {
            if let src = r.image {
                transition([])
                out += "![" + escapeAlt(r.text) + "](" + encodeURL(src) + ")"
                continue
            }
            if r.literal {
                transition([])
                out += r.text
                continue
            }
            if r.code {
                transition(r.link.map { [.link($0)] } ?? [])
                out += codeSpan(r.text)
                continue
            }
            var wanted: [Mark] = []
            if let url = r.link { wanted.append(.link(url)) }
            if r.underline { wanted.append(.underline) }
            if r.sup { wanted.append(.sup) }
            if r.sub { wanted.append(.sub) }
            if r.kbd { wanted.append(.kbd) }
            if r.strike { wanted.append(.strike) }
            if r.highlight { wanted.append(.highlight) }
            if r.bold && !heading { wanted.append(.bold) }
            if r.italic { wanted.append(.italic) }
            // 尽量沿用已经打开的标记，避免 **a****b** 这样的写法
            var keep: [Mark] = []
            for m in open {
                guard wanted.contains(m) else { break }
                keep.append(m)
            }

            let (lead, core, trail) = splitWhitespace(r.text)
            if core.isEmpty {
                pending += r.text
                transition(keep)   // 只关闭不再需要的标记，空白放在标记外面
                continue
            }
            pending += lead
            transition(keep + wanted.filter { !keep.contains($0) })
            let atStart = open.isEmpty && out.trimmingCharacters(in: .whitespaces).isEmpty
            out += escape(core, atStart: atStart, inCell: inCell)
            pending = trail
        }
        transition([])
        // 段内换行写成 <br>
        return (out + pending).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2028}", with: "<br>")
    }

    /// 合并样式完全相同的相邻文字
    private static func merged(_ runs: [MDRun]) -> [MDRun] {
        var out: [MDRun] = []
        for r in runs where !r.text.isEmpty || r.image != nil {
            if var last = out.last, last.image == nil, r.image == nil, !last.literal, !r.literal,
               last.code == r.code, last.bold == r.bold, last.italic == r.italic,
               last.underline == r.underline, last.strike == r.strike, last.highlight == r.highlight,
               last.sup == r.sup, last.sub == r.sub, last.kbd == r.kbd,
               last.link == r.link {
                last.text += r.text
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func splitWhitespace(_ s: String) -> (String, String, String) {
        let chars = Array(s)
        var a = 0
        while a < chars.count && chars[a].isWhitespace { a += 1 }
        var b = chars.count
        while b > a && chars[b - 1].isWhitespace { b -= 1 }
        return (String(chars[0..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    private static func escape(_ s: String, atStart: Bool, inCell: Bool) -> String {
        let chars = Array(s)
        // 行首的“1. ”会被当成有序列表
        var orderedMarker = -1
        if atStart {
            var d = 0
            while d < chars.count && chars[d].isNumber { d += 1 }
            if d > 0, d < chars.count, chars[d] == "." || chars[d] == ")" { orderedMarker = d }
        }
        var out = ""
        for (i, ch) in chars.enumerated() {
            switch ch {
            case "\\", "*", "`", "[", "]", "<", "~", "$":
                out += "\\" + String(ch)
            case "|":
                out += inCell ? "\\|" : "|"
            case "=":
                // 两个等号相邻会被当成 ==高亮==
                let paired = (i > 0 && chars[i - 1] == "=") || (i + 1 < chars.count && chars[i + 1] == "=")
                out += paired ? "\\=" : "="
            case "_":
                let inWord = i > 0 && i + 1 < chars.count
                    && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                    && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                out += inWord ? "_" : "\\_"
            case "#", ">", "+", "-":
                out += (atStart && i == 0) ? "\\" + String(ch) : String(ch)
            default:
                out += (i == orderedMarker) ? "\\" + String(ch) : String(ch)
            }
        }
        return out
    }

    private static func escapeAlt(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func encodeURL(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: longestRun(of: "`", in: text) + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + pad + text + pad + fence
    }
}
