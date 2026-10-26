import Foundation

// 行内语法的解析：**粗体**、*斜体*、~~删除线~~、==高亮==、<u>下划线</u>、`代码`、[链接](地址)、![图片](路径)、$公式$、[^脚注]

extension MarkdownCodec {
    static func parseInline(_ s: String) -> [MDRun] {
        let chars = Array(s)
        return InlineParser(c: chars).parse(0, chars.count, InlineStyle())
    }
}

private struct InlineStyle {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var highlight = false
    var sup = false
    var sub = false
    var kbd = false
    var link: String?

    func run(_ text: String) -> MDRun {
        MDRun(text: text, bold: bold, italic: italic, underline: underline, strike: strike, highlight: highlight,
              sup: sup, sub: sub, kbd: kbd, link: link)
    }

    /// 行内 HTML 标签对应的样式
    func with(tag: String) -> InlineStyle {
        var s = self
        switch tag {
        case "u": s.underline = true
        case "sup": s.sup = true
        case "sub": s.sub = true
        case "kbd": s.kbd = true
        case "mark": s.highlight = true
        case "b", "strong": s.bold = true
        case "i", "em": s.italic = true
        case "s", "del": s.strike = true
        default: break
        }
        return s
    }

    static let tags = ["u", "sup", "sub", "kbd", "mark", "b", "strong", "i", "em", "s", "del"]
}

private struct LinkMatch {
    let labelLo: Int
    let labelHi: Int
    let url: String
    let end: Int
}

private struct InlineParser {
    let c: [Character]

    /// 解析 c[lo..<hi]
    func parse(_ lo: Int, _ hi: Int, _ st: InlineStyle) -> [MDRun] {
        var out: [MDRun] = []
        var buf = ""
        func flush() {
            if !buf.isEmpty {
                out.append(st.run(buf))
                buf = ""
            }
        }
        var i = lo
        while i < hi {
            let ch = c[i]

            // 反斜杠转义
            if ch == "\\", i + 1 < hi, isPunct(c[i + 1]) {
                buf.append(c[i + 1])
                i += 2
                continue
            }

            // 行内代码
            if ch == "`" {
                let n = runLength(ch, i, hi)
                if let close = closingBackticks(n, from: i + n, hi) {
                    flush()
                    var code = String(c[(i + n)..<close])
                    if code.count > 2, code.first == " ", code.last == " " {
                        code = String(code.dropFirst().dropLast())
                    }
                    out.append(MDRun(text: code, code: true, link: st.link))
                    i = close + n
                    continue
                }
                buf += String(repeating: ch, count: n)
                i += n
                continue
            }

            // 图片
            if ch == "!", i + 1 < hi, c[i + 1] == "[", let m = linkAt(i + 1, hi) {
                flush()
                var r = MDRun(text: String(c[m.labelLo..<m.labelHi]))
                r.image = m.url.removingPercentEncoding ?? m.url
                out.append(r)
                i = m.end
                continue
            }

            // 脚注引用 [^1]：原样保留
            if ch == "[", i + 1 < hi, c[i + 1] == "^", let end = footnoteEnd(i, hi) {
                flush()
                var r = MDRun(text: String(c[i..<end]))
                r.literal = true
                out.append(r)
                i = end
                continue
            }

            // 链接
            if ch == "[", let m = linkAt(i, hi) {
                flush()
                var inner = st
                inner.link = m.url
                out += parse(m.labelLo, m.labelHi, inner)
                i = m.end
                continue
            }

            if ch == "<" {
                // <br>：段内换行
                if let len = ["<br>", "<br/>", "<br />"].first(where: { matches($0, at: i, hi) })?.count {
                    flush()
                    out.append(st.run("\u{2028}"))
                    i += len
                    continue
                }
                // <u> <sup> <sub> <kbd> <mark> 等成对的标签
                if let tag = InlineStyle.tags.first(where: { matches("<\($0)>", at: i, hi) }),
                   let close = find("</\(tag)>", from: i + tag.count + 2, hi) {
                    flush()
                    out += parse(i + tag.count + 2, close, st.with(tag: tag))
                    i = close + tag.count + 3
                    continue
                }
                // <https://自动链接>
                if let end = find(">", from: i + 1, hi) {
                    let url = String(c[(i + 1)..<end])
                    if isAutolink(url) {
                        flush()
                        var r = st.run(url)
                        r.link = url
                        out.append(r)
                        i = end + 1
                        continue
                    }
                }
            }

            // $公式$：原样保留
            if ch == "$", let end = mathEnd(i, hi) {
                flush()
                var r = MDRun(text: String(c[i..<end]))
                r.literal = true
                out.append(r)
                i = end
                continue
            }

            // 强调：* ** *** _ __ ___ ~~ ==
            if ch == "*" || ch == "_" || ch == "~" || ch == "=" {
                let n = runLength(ch, i, hi)
                var style = st
                var usable = true
                if ch == "~" {
                    if n == 2 { style.strike = true } else { usable = false }
                } else if ch == "=" {
                    if n == 2 { style.highlight = true } else { usable = false }
                } else if n == 1 {
                    style.italic = true
                } else if n == 2 {
                    style.bold = true
                } else if n == 3 {
                    style.bold = true
                    style.italic = true
                } else {
                    usable = false
                }
                if usable, canOpen(ch, i, n, hi), let close = closingDelimiter(ch, n, from: i + n, hi) {
                    flush()
                    out += parse(i + n, close, style)
                    i = close + n
                    continue
                }
                // ***a* b**：先按粗体处理，剩下的 * 在内部作为斜体
                if n == 3, ch == "*" || ch == "_", canOpen(ch, i, n, hi), let close = closingDelimiter(ch, 2, from: i + 2, hi) {
                    flush()
                    var bold = st
                    bold.bold = true
                    out += parse(i + 2, close, bold)
                    i = close + 2
                    continue
                }
                buf += String(repeating: ch, count: n)
                i += n
                continue
            }

            buf.append(ch)
            i += 1
        }
        flush()
        return out
    }

    // MARK: - 辅助

    private func isPunct(_ ch: Character) -> Bool {
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(ch)
    }

    private func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private func runLength(_ ch: Character, _ i: Int, _ hi: Int) -> Int {
        var n = 0
        while i + n < hi && c[i + n] == ch { n += 1 }
        return n
    }

    private func matches(_ s: String, at i: Int, _ hi: Int) -> Bool {
        let p = Array(s)
        guard i + p.count <= hi else { return false }
        return Array(c[i..<(i + p.count)]) == p
    }

    private func find(_ s: String, from: Int, _ hi: Int) -> Int? {
        var j = from
        while j < hi {
            if matches(s, at: j, hi) { return j }
            j += 1
        }
        return nil
    }

    private func isAutolink(_ s: String) -> Bool {
        let lower = s.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:"))
            && !s.contains(where: { $0.isWhitespace })
    }

    private func closingBackticks(_ n: Int, from: Int, _ hi: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "`" {
                let m = runLength("`", j, hi)
                if m == n { return j }
                j += m
            } else {
                j += 1
            }
        }
        return nil
    }

    /// 起始标记之后必须紧跟非空白字符；_ 不能出现在单词中间
    private func canOpen(_ ch: Character, _ i: Int, _ n: Int, _ hi: Int) -> Bool {
        guard i + n < hi, !c[i + n].isWhitespace else { return false }
        if ch == "_", i > 0, isWordChar(c[i - 1]) { return false }
        return true
    }

    private func closingDelimiter(_ ch: Character, _ n: Int, from start: Int, _ hi: Int) -> Int? {
        var j = start
        while j < hi {
            if c[j] == "\\" {
                j += 2
                continue
            }
            if c[j] == ch {
                let m = runLength(ch, j, hi)
                if m == n, j > start, !c[j - 1].isWhitespace,
                   ch != "_" || !(j + m < hi && isWordChar(c[j + m])) {
                    return j
                }
                j += m
                continue
            }
            j += 1
        }
        return nil
    }

    /// [^标签] 的结束位置（不含）
    private func footnoteEnd(_ i: Int, _ hi: Int) -> Int? {
        var j = i + 2
        while j < hi, c[j] != "]", !c[j].isWhitespace, c[j] != "[" { j += 1 }
        guard j < hi, c[j] == "]", j > i + 2 else { return nil }
        return j + 1
    }

    /// $...$ 的结束位置（不含）。像 $5 和 $10 这样的金额不算公式。
    private func mathEnd(_ i: Int, _ hi: Int) -> Int? {
        guard i + 1 < hi, !c[i + 1].isWhitespace, c[i + 1] != "$" else { return nil }
        var j = i + 2
        while j < hi {
            if c[j] == "$", c[j - 1] != "\\", !c[j - 1].isWhitespace {
                if j + 1 < hi && c[j + 1].isNumber { return nil }
                return j + 1
            }
            j += 1
        }
        return nil
    }

    /// 从 c[open] == "[" 开始匹配 [文字](地址 "标题")
    private func linkAt(_ open: Int, _ hi: Int) -> LinkMatch? {
        var depth = 0
        var j = open
        var close: Int?
        while j < hi {
            if c[j] == "\\" {
                j += 2
                continue
            }
            if c[j] == "[" {
                depth += 1
            } else if c[j] == "]" {
                depth -= 1
                if depth == 0 {
                    close = j
                    break
                }
            }
            j += 1
        }
        guard let k = close, k + 1 < hi, c[k + 1] == "(" else { return nil }
        let start = k + 2
        var q = start
        var paren = 0
        while q < hi {
            if c[q] == "(" {
                paren += 1
            } else if c[q] == ")" {
                if paren == 0 { break }
                paren -= 1
            }
            q += 1
        }
        guard q < hi else { return nil }
        var dest = String(c[start..<q]).trimmingCharacters(in: .whitespaces)
        if let sp = dest.firstIndex(of: " ") { dest = String(dest[..<sp]) }
        if dest.hasPrefix("<") && dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
        return LinkMatch(labelLo: open + 1, labelHi: k, url: dest, end: q + 1)
    }
}
