import Foundation

/// 段落模型 → 独立的 HTML 文件（Word 式编辑模式下导出 HTML 时使用）
enum MarkdownHTML {
    static func document(_ blocks: [MDBlock], title: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="DropMD">
        <title>\(escape(title))</title>
        <style>
        \(style)
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(body(blocks))
        </article>
        </body>
        </html>

        """
    }

    static func body(_ blocks: [MDBlock]) -> String {
        var out: [String] = []
        var openLists: [String] = []   // 当前打开的 <ul>/<ol>
        func closeLists(to depth: Int) {
            while openLists.count > depth { out.append("</li></\(openLists.removeLast())>") }
        }
        for block in blocks {
            if case .line(let line) = block, let depth = line.kind.listDepth {
                let tag = line.kind.isOrdered ? "ol" : "ul"
                if openLists.count > depth + 1 { closeLists(to: depth + 1) }
                if openLists.count == depth + 1 {
                    if openLists[depth] == tag {
                        out.append("</li>")
                    } else {
                        closeLists(to: depth)
                    }
                }
                while openLists.count < depth + 1 {
                    out.append("<\(tag)>")
                    openLists.append(tag)
                }
                var item = inline(line.runs)
                if case .task(_, let done) = line.kind {
                    item = "<input type=\"checkbox\" disabled\(done ? " checked" : "")> " + item
                }
                out.append("<li>" + item)
                continue
            }
            closeLists(to: 0)
            switch block {
            case .line(let line):
                switch line.kind {
                case .heading(let l):
                    let n = min(max(l, 1), 6)
                    out.append("<h\(n)>\(inline(line.runs))</h\(n)>")
                case .quote:
                    if line.runs.count == 1, line.runs[0].literal, let c = MDCallout(header: line.runs[0].text) {
                        out.append("<blockquote class=\"callout callout-\(c.rawValue.lowercased())\"><p><strong>\(c.title)</strong></p></blockquote>")
                    } else {
                        out.append("<blockquote><p>\(inline(line.runs))</p></blockquote>")
                    }
                default:
                    let text = inline(line.runs)
                    out.append(text.isEmpty ? "<p>&nbsp;</p>" : "<p>\(text)</p>")
                }
            case .code(let lang, let lines):
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(lines.joined(separator: "\n")))</code></pre>")
            case .table(let rows):
                var t = ["<table>"]
                for (r, row) in rows.enumerated() {
                    let cell = r == 0 ? "th" : "td"
                    t.append("<tr>" + row.map { "<\(cell)>\(inline($0))</\(cell)>" }.joined() + "</tr>")
                }
                t.append("</table>")
                out.append(t.joined(separator: "\n"))
            case .rule:
                out.append("<hr>")
            case .details(let summary, let inner):
                out.append("<details>\n<summary>\(escape(summary))</summary>\n\(body(inner))\n</details>")
            case .raw(let s):
                // 原样保存的内容：HTML 直接输出，公式块等以文字显示
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
                    out.append(s)
                } else {
                    out.append("<pre class=\"raw\">\(escape(s))</pre>")
                }
            }
        }
        closeLists(to: 0)
        return out.joined(separator: "\n")
    }

    static func inline(_ runs: [MDRun]) -> String {
        var out = ""
        for r in runs {
            if let src = r.image {
                let lower = src.lowercased()
                // 网络图片为保护隐私不加载
                if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") {
                    out += "<span class=\"blocked-image\">网络图片未加载（隐私保护）\(r.text.isEmpty ? "" : "：" + escape(r.text))</span>"
                } else {
                    out += "<img src=\"\(escape(MarkdownCodec.encodeURL(src)))\" alt=\"\(escape(r.text))\">"
                }
                continue
            }
            var s = escape(r.text).replacingOccurrences(of: "\u{2028}", with: "<br>")
            if r.code { s = "<code>\(s)</code>" }
            if r.kbd { s = "<kbd>\(s)</kbd>" }
            if r.sup { s = "<sup>\(s)</sup>" }
            if r.sub { s = "<sub>\(s)</sub>" }
            if r.italic { s = "<em>\(s)</em>" }
            if r.bold { s = "<strong>\(s)</strong>" }
            if r.strike { s = "<del>\(s)</del>" }
            if r.highlight { s = "<mark>\(s)</mark>" }
            if r.underline { s = "<u>\(s)</u>" }
            if let url = r.link {
                let lower = url.lowercased().trimmingCharacters(in: .whitespaces)
                // 不输出 javascript: 等可执行的链接
                let safe = !(lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:"))
                s = safe ? "<a href=\"\(escape(MarkdownCodec.encodeURL(url)))\">\(s)</a>" : s
            }
            out += s
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    :root { color-scheme: light dark; }
    body { margin: 0; font: 16px/1.75 -apple-system, "PingFang SC", "Hiragino Sans", "Helvetica Neue", sans-serif; }
    .markdown-body { max-width: 820px; margin: 0 auto; padding: 28px 36px 80px; word-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.4em 0 .6em; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    p, ul, ol, blockquote, table, pre, details { margin: 0 0 1em; }
    blockquote { margin-left: 0; padding: .2em 1em; color: #6e6e73; border-left: 4px solid #d2d2d7; }
    code { font: .9em "SF Mono", Menlo, monospace; background: rgba(127,127,127,.15); padding: .15em .35em; border-radius: 5px; }
    pre { background: rgba(127,127,127,.12); padding: 14px 16px; border-radius: 10px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #d2d2d7; padding: 6px 12px; }
    th { background: rgba(127,127,127,.12); }
    mark { background: #fff3b0; color: inherit; }
    kbd { font: .85em "SF Mono", Menlo, monospace; padding: .1em .4em; border: 1px solid #c7c7cc; border-bottom-width: 2px; border-radius: 5px; }
    img { max-width: 100%; }
    hr { border: 0; border-top: 1px solid #d2d2d7; margin: 2em 0; }
    details { border: 1px solid #d2d2d7; border-radius: 8px; padding: .5em 1em; }
    summary { cursor: pointer; font-weight: 600; }
    li > input[type=checkbox] { margin-right: .4em; }
    .blocked-image { color: #6e6e73; font-size: .85em; }
    @media (prefers-color-scheme: dark) {
      blockquote, th, td, hr, details { border-color: #3a3a3c; }
      mark { background: #5c4b00; }
    }
    """
}
