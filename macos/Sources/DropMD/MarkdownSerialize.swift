import Foundation

// 段落模型 → Markdown 文本

extension MarkdownCodec {
    static func serialize(_ blocks: [MDBlock]) -> String {
        var out = ""
        var prev: MDBlock?
        var numbering = MDNumbering()
        var listTypes: [Int: Bool] = [:]   // 各层级最近一个列表项是否为有序列表
        var contentCols: [Int] = []          // 各层级项目文字开始的列：下一层缩进到这里（1. 下面 3 格），否则会被读成同级
        for block in blocks {
            var text: String
            var newList = false
            // 列表项里的代码块：缩进到上一项的文字下面
            var codeIndent: Int?
            if case .code(_, _, .some) = block, case .line(let p)? = prev, let d = p.kind.listDepth, d < contentCols.count {
                codeIndent = contentCols[d]
            }
            if case .line(let line) = block, let d = line.kind.listDepth {
                listTypes = listTypes.filter { $0.key <= d }
                if let wasOrdered = listTypes[d], wasOrdered != line.kind.isOrdered { newList = true }
                listTypes[d] = line.kind.isOrdered
            } else if codeIndent != nil {
                // 保留各层缩进和列表类型：代码块后面的项还属于同一个列表
            } else {
                listTypes = [:]
                contentCols = []
            }
            let number = numbering.number(for: block)?.n ?? 0
            switch block {
            case .line(let line):
                var indent = 0
                if let d = line.kind.listDepth {
                    indent = d == 0 ? 0 : d - 1 < contentCols.count ? contentCols[d - 1] : (contentCols.last ?? 0) + 2
                    contentCols = Array(contentCols.prefix(d)) + [indent + (line.kind.isOrdered ? "\(number).".count + 1 : 2)]
                }
                text = render(line, number: number, indent: indent)
            case .code(let lang, let lines, _):
                let longest = lines.map { longestRun(of: "`", in: $0) }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                text = fence + lang + "\n" + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + fence
                if let n = codeIndent {
                    let pad = String(repeating: " ", count: n)
                    text = text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : pad + $0 }.joined(separator: "\n")
                }
            case .table(let rows, let align):
                text = renderTable(rows, align)
            case .rule:
                text = "---"
            case .details(let summary, let body, let open):
                let inner = serialize(body).trimmingCharacters(in: .newlines)
                let title = summary.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                // <summary> 之后要空一行，里面的 Markdown 才会被解析
                text = (open ? "<details open>" : "<details>") + "\n<summary>" + title + "</summary>\n\n" + (inner.isEmpty ? "" : inner + "\n\n") + "</details>"
            case .raw(let s):
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
        // 列表项里的代码块：原文前后有没有空行就照原样（有空行的列表项间距大）
        if case .code(_, _, let gap?) = b, case .line(let x) = a, x.kind.listDepth != nil { return gap ? "\n\n" : "\n" }
        if case .code(_, _, let gap?) = a, case .line(let y) = b, y.kind.listDepth != nil { return gap ? "\n\n" : "\n" }
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

    private static func render(_ line: MDLine, number: Int, indent: Int) -> String {
        switch line.kind {
        case .body:
            let body = keepingBreaks(inline(line.runs))
            return body.isEmpty ? "&nbsp;" : body   // 空段落用 &nbsp; 保留
        case .heading(let level):
            let body = oneLine(inline(line.runs, heading: true))
            return String(repeating: "#", count: min(max(level, 1), 6)) + (body.isEmpty ? "" : " " + body)
        case .quote:
            let body = oneLine(inline(line.runs))
            return body.isEmpty ? ">" : "> " + body
        case .bullet:
            return item(indent, "-", keepingBreaks(inline(line.runs)))
        case .ordered:
            return item(indent, "\(number).", keepingBreaks(inline(line.runs)))
        case .task(_, let done):
            return item(indent, done ? "- [x]" : "- [ ]", keepingBreaks(inline(line.runs)))
        }
    }

    /// 段落里换行后的一行若会被读成列表、标题等，就改回空格
    private static func keepingBreaks(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        var out = lines[0]
        for l in lines.dropFirst() { out += (startsBlock(l) || isSetextUnderline(l) ? " " : "\n") + l }
        return out
    }

    /// 段落里的换行只在正文里保留（正文改成标题、列表等时合并为空格）
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    private static func item(_ spaces: Int, _ marker: String, _ body: String) -> String {
        let indent = String(repeating: " ", count: spaces)
        // 续行缩进到项目文字下面
        let text = body.replacingOccurrences(of: "\n", with: "\n" + indent + String(repeating: " ", count: marker.count + 1))
        return indent + marker + (body.isEmpty ? "" : " " + text)
    }

    private static func renderTable(_ rows: [[[MDRun]]], _ align: [String]) -> String {
        guard !rows.isEmpty else { return "" }
        let cols = max(1, rows.map { $0.count }.max() ?? 1)
        var lines: [String] = []
        for (r, row) in rows.enumerated() {
            let cells = (0..<cols).map { c in c < row.count ? oneLine(inline(row[c], heading: r == 0, inCell: true)) : "" }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if r == 0 { lines.append("|" + (0..<cols).map { c in " \(c < align.count ? align[c] : "---") |" }.joined()) }
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
        case link(String, String?), underline, sup, sub, kbd, strike, highlight, bold, italic

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
            case .link(let url, let title): return "](" + MarkdownCodec.encodeURL(url) + (title.map { " " + $0 } ?? "") + ")"
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
                out += "![" + escapeAlt(r.text) + "](" + encodeURL(src) + (r.title.map { " " + $0 } ?? "") + ")"
                continue
            }
            if r.literal {
                transition([])
                out += r.text
                continue
            }
            if r.code {
                transition(r.link.map { [.link($0, r.title)] } ?? [])
                out += codeSpan(r.text)
                continue
            }
            var wanted: [Mark] = []
            if let url = r.link { wanted.append(.link(url, r.title)) }
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
        return (out + pending).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)   // 换行前的空格会变成强制换行
            .replacingOccurrences(of: "\u{2028}", with: "<br>")
    }

    /// 合并样式完全相同的相邻文字
    private static func merged(_ runs: [MDRun]) -> [MDRun] {
        var out: [MDRun] = []
        for r in runs where !r.text.isEmpty || r.image != nil {
            if var last = out.last, last.image == nil, r.image == nil, !last.literal, !r.literal,
               last.code == r.code, last.bold == r.bold, last.italic == r.italic,
               last.underline == r.underline, last.strike == r.strike, last.highlight == r.highlight,
               last.sup == r.sup, last.sub == r.sub, last.kbd == r.kbd,
               last.link == r.link, last.title == r.title {
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
