import Foundation

/// 保格式整篇 Markdown 翻译核心（跳过代码块、行内代码、数学公式、YAML/HTML、图片与链接地址）
enum MarkdownTranslator {
    struct Segment: Sendable {
        let id: String
        let text: String
    }

    static func extractSegments(from markdown: String) -> [Segment] {
        var blocks = MarkdownCodec.parse(markdown)
        var segments: [Segment] = []
        var nextID = 0
        visitTranslatableStrings(&blocks) { raw in
            let (_, core, _) = splitEdgeWhitespace(raw)
            guard !core.isEmpty else { return }
            segments.append(Segment(id: "\(nextID)", text: core))
            nextID += 1
        }
        return segments
    }

    static func applyTranslations(_ translations: [String: String], to markdown: String) -> String {
        var blocks = MarkdownCodec.parse(markdown)
        var nextID = 0
        visitTranslatableStrings(&blocks) { raw in
            let (leading, core, trailing) = splitEdgeWhitespace(raw)
            guard !core.isEmpty else { return }
            let id = "\(nextID)"
            nextID += 1
            if let translated = translations[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translated.isEmpty {
                raw = leading + translated + trailing
            }
        }
        return MarkdownCodec.serialize(blocks)
    }

    private static func visitTranslatableStrings(_ blocks: inout [MDBlock], _ visit: (inout String) -> Void) {
        for i in blocks.indices {
            switch blocks[i] {
            case .line(var line):
                visitRuns(&line.runs, visit)
                blocks[i] = .line(line)
            case .table(var rows, let align):
                for r in rows.indices {
                    for c in rows[r].indices {
                        visitRuns(&rows[r][c], visit)
                    }
                }
                blocks[i] = .table(rows, align: align)
            case .details(var summary, var body, let open):
                visit(&summary)
                visitTranslatableStrings(&body, visit)
                blocks[i] = .details(summary: summary, body: body, open: open)
            case .code, .rule, .raw:
                break
            }
        }
    }

    private static func visitRuns(_ runs: inout [MDRun], _ visit: (inout String) -> Void) {
        for i in runs.indices {
            // 自动链接（显示的就是网址）和 [[双链]] 不翻译：译了网址文字、链接目标就坏了
            if runs[i].code || runs[i].kbd || runs[i].literal || runs[i].image != nil
                || (runs[i].link != nil && runs[i].text == runs[i].link) {
                continue
            }
            // [[双链]] 原样留着，只翻译它前后的文字
            let text = runs[i].text
            guard let wiki = try? NSRegularExpression(pattern: #"\[\[[^\]\n]*\]\]"#),
                  case let found = wiki.matches(in: text, range: NSRange(text.startIndex..., in: text)), !found.isEmpty else {
                visit(&runs[i].text)
                continue
            }
            var out = "", cursor = text.startIndex
            for m in found {
                guard let r = Range(m.range, in: text) else { continue }
                var piece = String(text[cursor..<r.lowerBound])
                if !piece.isEmpty { visit(&piece) }
                out += piece + text[r]
                cursor = r.upperBound
            }
            var tail = String(text[cursor...])
            if !tail.isEmpty { visit(&tail) }
            runs[i].text = out + tail
        }
    }

    private static func splitEdgeWhitespace(_ s: String) -> (leading: String, core: String, trailing: String) {
        guard !s.isEmpty else { return ("", "", "") }
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, scalars[start].properties.isWhitespace {
            start = scalars.index(after: start)
        }
        guard start < scalars.endIndex else { return (s, "", "") }
        var end = scalars.endIndex
        while end > start {
            let prev = scalars.index(before: end)
            if scalars[prev].properties.isWhitespace {
                end = prev
            } else {
                break
            }
        }
        let leading = String(scalars[..<start])
        let core = String(scalars[start..<end])
        let trailing = String(scalars[end...])
        return (leading, core, trailing)
    }
}
