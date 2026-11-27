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
    var quoteStart = false    // 引用：上面紧挨着另一段引用，中间原文有空行（保存时要空行，否则连成一段）
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

    /// 公式块（$$…$$ 或 \\[…\\]），在段落模型里是原样内容
    static func isMathBlock(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 5 && (t.hasPrefix("$$") && t.hasSuffix("$$") || t.hasPrefix("\\[") && t.hasSuffix("\\]"))
    }

    static func parse(_ source: String) -> [MDBlock] {
        parseWithSource(source).blocks
    }

    /// 一段原文（lines）解析出的块（blocks）。保存时没改过的块直接写回这段原文
    struct SourceGroup {
        let blocks: Range<Int>
        let lines: Range<Int>
    }

    /// 文件开头的 YAML 范围，不含 BOM 和闭合行之后的换行。
    static func yamlFrontMatter(in source: String) -> (range: Range<String.Index>, lineCount: Int)? {
        let start = source.hasPrefix("\u{FEFF}") ? source.index(after: source.startIndex) : source.startIndex
        var lineStart = start
        var lineCount = 0
        while true {
            let lineEnd = source[lineStart...].firstIndex { $0 == "\n" || $0 == "\r\n" } ?? source.endIndex
            let line = source[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            lineCount += 1
            if lineCount == 1 {
                guard line == "---" else { return nil }
            } else if line == "---" || line == "..." {
                return (start..<lineEnd, lineCount)
            }
            guard lineEnd < source.endIndex else { return nil }
            lineStart = source.index(after: lineEnd)
        }
    }

    /// 用于撤销或重做 YAML 修改：只覆盖仍匹配的开头片段（可含插入时加的换行）。
    static func replacingYAMLFrontMatterPrefix(_ expected: String, with replacement: String, in source: String) -> String? {
        let offset = source.hasPrefix("\u{FEFF}") ? 1 : 0
        guard let span = Range(NSRange(location: offset, length: expected.utf16.count), in: source),
              source[span].utf8.elementsEqual(expected.utf8) else { return nil }
        if let yaml = yamlFrontMatter(in: source) {
            guard yaml.range.upperBound <= span.upperBound else { return nil }
        } else if !expected.isEmpty {
            return nil
        }
        return source.replacingCharacters(in: span, with: replacement)
    }

    static func parseWithSource(_ source: String) -> (blocks: [MDBlock], groups: [SourceGroup], lines: [String]) {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var indents: [Int] = []   // 列表缩进栈，用于计算嵌套层级
        var i = 0
        // 文件开头的 YAML 信息（--- … ---，Obsidian、Hugo 等用）：原样保存
        if let frontMatter = yamlFrontMatter(in: source) {
            i = frontMatter.lineCount
            blocks.append(.raw(lines[..<i].joined(separator: "\n")))
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
                    // 上一块也是引用：两段之间原文有空行（否则会在上面的循环里连成一段）
                    var newBlock: Bool = { if case .line(let l)? = blocks.last { return l.kind == .quote }; return false }()
                    for content in contents {
                        // 提示框的标题行原样保存，不能转义成 \[!NOTE\]
                        let runs = MDCallout(header: content) != nil
                            ? [MDRun(text: content.trimmingCharacters(in: .whitespaces), literal: true)] : parseInline(content)
                        blocks.append(.line(MDLine(kind: .quote, runs: runs, quoteStart: newBlock)))
                        newBlock = false
                    }
                }
                i = j
                continue
            }
            if indents.isEmpty, groups(listPattern, line) != nil, let end = complexListEnd(lines, i) {
                // 只是列表项里带代码块：拆成列表项和代码块，单页里可以编辑，并保留每块的原文范围
                if let parts = listWithCode(Array(lines[i..<end]), lineOffset: i, blockOffset: blocks.count) {
                    blocks += parts.blocks
                    sources += parts.groups
                    i = end
                    firstBlock = blocks.count
                    firstLine = i
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
                if m[2].first?.isNumber == true { item.start = Int(m[2].dropLast()) }   // 编号待办（1. [ ]）也记下编号
                blocks.append(.line(item))
                continue
            }
            if trimmed.first == "<", let opening = detailsOpening(in: lines, at: i) {
                indents = []
                // 先消费完整的开标签，再解析内部；残缺或相似的标签走普通 HTML/正文。
                i = opening.lastLine
                var part = opening.rest
                var body: [String] = []
                var trailing = ""
                var depth = 1
                var fence: Fence?   // 代码块里的 <details>、</details> 是代码，不算
                var inComment = false
                var codeEnd: (line: Int, utf16Offset: Int)?
                while true {
                    var prefix = ""
                    if let f = fence {
                        if isFenceClosing(part, f) { fence = nil }
                    } else if codeEnd.map({ i < $0.line }) == true {
                        // 跨行代码 span 的中间行不参与 HTML 标签计数。
                    } else if !inComment, codeEnd == nil, let f = fenceOpening(part) {
                        fence = f
                    } else if inComment || codeEnd != nil || part.contains("<") || part.contains("`") {
                        if !inComment, codeEnd == nil, i > opening.lastLine,
                           let nested = detailsOpening(in: lines, at: i), nested.lastLine > i {
                            depth += 1
                            body.append(contentsOf: lines[i..<nested.lastLine])
                            i = nested.lastLine
                            part = nested.rest
                            prefix = String(lines[i].dropLast(part.count))
                        }
                        if let close = detailsClosing(in: part, at: i, lines: lines, depth: &depth, inComment: &inComment, codeEnd: &codeEnd) {
                            trailing = String(part[close.upperBound...])
                            part = String(part[..<close.lowerBound])
                        }
                    }
                    body.append(prefix + part)
                    i += 1
                    guard i < lines.count, depth > 0 else { break }
                    part = lines[i]
                }
                blocks.append(details(body.joined(separator: "\n"), openingTag: opening.tag))
                if !isBlank(trailing) { blocks.append(.raw(trailing)) }
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
            // 表格可以紧跟在段落后面（不空行），GitHub 和预览都这样显示；表头和分隔行列数相同才算（否则是 --- 二级标题）
            func startsTable(_ k: Int) -> Bool {
                lines[k].contains("|") && k + 1 < lines.count && isTableDelimiter(lines[k + 1])
                    && splitRow(lines[k]).count == splitRow(lines[k + 1]).count
            }
            while i < lines.count && !isBlank(lines[i]) && !startsBlock(lines[i]) && groups(setextPattern, lines[i]) == nil && !startsTable(i) {
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
        return mergeAdjacentRaw(blocks, sources, lines)
    }

    /// 中间没有空行、紧挨着的两段原样内容（YAML 信息后的 HTML、列表后的 HTML、多行脚注）合成一段：
    /// 单页里是一张卡片，保存时按原文写回，不会在中间多出空行
    private static func mergeAdjacentRaw(_ blocks: [MDBlock], _ sources: [SourceGroup], _ lines: [String])
        -> (blocks: [MDBlock], groups: [SourceGroup], lines: [String]) {
        guard sources.reduce(0, { $0 + $1.blocks.count }) == blocks.count else { return (blocks, sources, lines) }
        var outBlocks: [MDBlock] = []
        var outGroups: [SourceGroup] = []
        for g in sources {
            var groupBlocks = Array(blocks[g.blocks])
            if let prev = outGroups.last, prev.lines.upperBound == g.lines.lowerBound,
               case .raw(let a)? = outBlocks.last, case .raw(let b)? = groupBlocks.first,
               !isMathBlock(a), !isMathBlock(b) {
                outBlocks[outBlocks.count - 1] = .raw(a + "\n" + b)
                groupBlocks.removeFirst()
                outBlocks += groupBlocks
                outGroups[outGroups.count - 1] = SourceGroup(blocks: prev.blocks.lowerBound..<outBlocks.count,
                                                              lines: prev.lines.lowerBound..<g.lines.upperBound)
            } else {
                let start = outBlocks.count
                outBlocks += groupBlocks
                outGroups.append(SourceGroup(blocks: start..<outBlocks.count, lines: g.lines))
            }
        }
        return (outBlocks, outGroups, lines)
    }

    /// 列表从 start 开始；里面有单页表示不了的内容（项里空行后的续段、代码块、引用等）时返回列表的结束位置，否则返回 nil
    private static func complexListEnd(_ lines: [String], _ start: Int) -> Int? {
        var j = start
        var complex = false
        var fence: Fence?
        var afterFence = false
        while j < lines.count {
            let l = lines[j]
            if let f = fence {
                if isFenceClosing(l, f) {
                    fence = nil
                    afterFence = true
                }
                j += 1
                continue
            }
            if isBlank(l) {
                afterFence = false
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
                let w = leadingWidth(l)
                // 缩进代码块刚结束且下一行无缩进时结束列表
                if w == 0 && (afterFence || startsBlock(l)) { break }
                if w > 0, let f = fenceOpening(dropIndent(l, w)) {
                    fence = f
                    complex = true
                    afterFence = false
                    j += 1
                    continue
                }
                if startsBlock(l.trimmingCharacters(in: .whitespaces)) { complex = true }
            }
            afterFence = false
            j += 1
        }
        return complex ? j : nil
    }

    /// 列表项里只有代码块时（AI 常写“1. 安装：”下面跟代码）拆成列表项和代码块，并保留各自的原文分组；还有续段等其他内容时返回 nil
    private static func listWithCode(_ lines: [String], lineOffset: Int, blockOffset: Int) -> (blocks: [MDBlock], groups: [SourceGroup])? {
        var out: [MDBlock] = []
        var outGroups: [SourceGroup] = []
        var chunkStart: Int?       // 当前连续列表片段在 lines 中的起点
        var chunkEnd = 0
        var contentCol = 0         // 上一个列表项文字开始的列
        var lastChunk: [String] = []   // 代码块前的列表行：代码块后的嵌套项要连着它解析，层级才对
        func flush() -> Bool {
            guard let start = chunkStart else { return true }
            let slice = Array(lines[start..<chunkEnd])
            let context = !out.isEmpty && leadingWidth(slice[0]) > 0 ? lastChunk : []
            // 这几行自己还是“复杂列表”（列表项下面缩进写了引用、标题、HTML 等）：交给 parse 会回到这里，没完没了直到崩溃。整块原样保存
            guard complexListEnd(context + slice, 0) == nil else { return false }
            let contextBlocks = context.isEmpty ? 0 : parse(context.joined(separator: "\n")).count
            let parsed = parseWithSource((context + slice).joined(separator: "\n"))
            let newBlocks = Array(parsed.blocks.dropFirst(contextBlocks))
            lastChunk = context + slice
            chunkStart = nil
            guard !newBlocks.isEmpty, newBlocks.allSatisfy({ if case .line(let l) = $0 { return l.kind.listDepth != nil } else { return false } }) else { return false }
            let baseBlock = blockOffset + out.count - contextBlocks
            let baseLine = lineOffset + start - context.count
            for g in parsed.groups where g.blocks.lowerBound >= contextBlocks {
                outGroups.append(SourceGroup(
                    blocks: (g.blocks.lowerBound + baseBlock)..<(g.blocks.upperBound + baseBlock),
                    lines: (g.lines.lowerBound + baseLine)..<(g.lines.upperBound + baseLine)))
            }
            out += newBlocks
            return true
        }
        var j = 0
        while j < lines.count {
            let l = lines[j]
            if isBlank(l) { j += 1; continue }
            let w = leadingWidth(l)
            if let m = groups(listPattern, l) {
                let gap = l.dropFirst(m[1].count + m[2].count).prefix(while: { $0 == " " }).count
                contentCol = indentWidth(m[1]) + m[2].count + min(max(gap, 1), 4)
                if chunkStart == nil { chunkStart = j }
                chunkEnd = j + 1
                j += 1
                continue
            }
            if let fence = fenceOpening(dropIndent(l, w)), w >= contentCol, !(chunkStart == nil && out.isEmpty) {
                guard flush() else { return nil }
                let gap = isBlank(lines[j - 1])
                let fenceStart = j
                var body: [String] = []
                j += 1
                while j < lines.count, !isFenceClosing(dropIndent(lines[j], w), fence) {
                    body.append(dropIndent(lines[j], w))
                    j += 1
                }
                guard j < lines.count else { return nil }   // 没有结尾的 ```
                j += 1
                let b = blockOffset + out.count
                out.append(.code(lang: fence.lang, lines: body, listGap: gap))
                outGroups.append(SourceGroup(blocks: b..<(b + 1), lines: (lineOffset + fenceStart)..<(lineOffset + j)))
                continue
            }
            // 紧跟在列表行后的续行
            if chunkStart != nil, !isBlank(lines[j - 1]) {
                chunkEnd = j + 1
                j += 1
                continue
            }
            // 代码块后面紧跟不缩进的正文：列表到这里结束（代码块后面不能续行）
            if chunkStart == nil, !out.isEmpty, w == 0 {
                let rest = parseWithSource(lines[j...].joined(separator: "\n"))
                let baseBlock = blockOffset + out.count
                let baseLine = lineOffset + j
                out += rest.blocks
                for g in rest.groups {
                    outGroups.append(SourceGroup(
                        blocks: (g.blocks.lowerBound + baseBlock)..<(g.blocks.upperBound + baseBlock),
                        lines: (g.lines.lowerBound + baseLine)..<(g.lines.upperBound + baseLine)))
                }
                return (out, outGroups)
            }
            return nil
        }
        return flush() ? (out, outGroups) : nil
    }

    private static let detailsTokenPattern = re(
        #"\\[\\`<]|`+|<!--|<details(?=[ \t]|/?>)(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>|</details[ \t]*>"#, .caseInsensitive)
    private static let backtickPattern = re(#"`+"#)
    private static let detailsNamePattern = re(#"^[ \t]*<details(?=$|[ \t]|/?>)"#, .caseInsensitive)
    private static let detailsAttributePattern = re(
        #"\s+([^\s=/>]+)(?:\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+))?"#)

    /// 只计真正的标签；行内代码和注释中的标签必须留在原文里。
    private static func detailsClosing(
        in line: String, at row: Int, lines: [String], depth: inout Int, inComment: inout Bool,
        codeEnd: inout (line: Int, utf16Offset: Int)?
    ) -> Range<String.Index>? {
        var start = String.Index(utf16Offset: codeEnd?.utf16Offset ?? 0, in: line)
        codeEnd = nil
        func closeTicks(in text: String, from start: String.Index, count: Int) -> NSRange? {
            backtickPattern.matches(in: text, range: NSRange(start..., in: text))
                .first { $0.range.length == count && Range($0.range, in: text) != nil }?.range
        }
        while start < line.endIndex {
            if inComment {
                guard let end = line.range(of: "-->", range: start..<line.endIndex) else { break }
                start = end.upperBound
                inComment = false
                continue
            }
            guard let match = detailsTokenPattern.firstMatch(in: line, range: NSRange(start..., in: line)),
                  let range = Range(match.range, in: line) else { break }
            start = range.upperBound
            let token = line[range]
            if token.first == "`" {
                let count = match.range.length
                if let end = closeTicks(in: line, from: start, count: count) {
                    start = String.Index(utf16Offset: NSMaxRange(end), in: line)
                } else {
                    for next in (row + 1)..<lines.count {
                        let continuation = lines[next]
                        if isBlank(continuation) || startsBlock(continuation) || isSetextUnderline(continuation) { break }
                        if let end = closeTicks(in: continuation, from: continuation.startIndex, count: count) {
                            codeEnd = (next, NSMaxRange(end))
                            return nil
                        }
                    }
                }
            } else if token == "<!--" {
                inComment = true
            } else if token.hasPrefix("<") {
                depth += token.hasPrefix("</") ? -1 : 1
                if depth == 0 { return range }
            }
        }
        return nil
    }

    private static func detailsOpening(in lines: [String], at start: Int) -> (tag: String, rest: String, lastLine: Int)? {
        let first = lines[start]
        guard let match = detailsNamePattern.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let name = Range(match.range, in: first) else { return nil }
        var tag = String(first[name])
        var quote: Character?
        for i in start..<lines.count {
            let fragment = i == start ? first[name.upperBound...] : lines[i][...]
            if i != start, isBlank(lines[i]), quote == nil { return nil }
            for index in fragment.indices {
                let character = fragment[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "<" {
                    return nil
                } else if character == ">" {
                    return (tag + fragment[...index], String(fragment[fragment.index(after: index)...]), i)
                }
            }
            tag += fragment + "\n"
        }
        return nil
    }

    /// 解析已剥除 <details> / </details> 的内容。
    private static func details(_ text: String, openingTag: String) -> MDBlock {
        var inner = text
        let open = detailsAttributePattern.matches(in: openingTag, range: NSRange(openingTag.startIndex..., in: openingTag)).contains { match in
            Range(match.range(at: 1), in: openingTag).map { openingTag[$0].lowercased() == "open" } == true
        }
        var summary = ""
        if let r = inner.range(of: #"^\s*<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive]) {
            summary = decodeHTMLEntities(
                String(inner[r]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression),
                nbspAsSpace: true
            ).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[ \t]*[\r\n]+[ \t\r\n]*"#, with: " ", options: .regularExpression)   // 折叠摘要内部换行与空白
            inner.removeSubrange(r)
        }
        return .details(summary: summary, body: parse(inner), open: open)
    }

    private static let htmlEntityRegex = re(#"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)

    /// 解码常见命名及十进制/十六进制 HTML 实体；`nbspAsSpace` 为 true 时将 `&nbsp;` 转普通空格
    static func decodeHTMLEntities(_ s: String, nbspAsSpace: Bool = false) -> String {
        guard s.contains("&") else { return s }
        let nbsp = nbspAsSpace ? " " : "\u{00A0}"
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": nbsp]
        var out = s
        for m in htmlEntityRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let body = Range(m.range(at: 1), in: out) else { continue }
            let name = String(out[body])
            let lower = name.lowercased()
            let value: UInt32? = lower.hasPrefix("#x") ? UInt32(lower.dropFirst(2), radix: 16)
                : lower.hasPrefix("#") ? UInt32(lower.dropFirst()) : nil
            let char = value.flatMap(Unicode.Scalar.init).map { $0 == "\u{00A0}" ? nbsp : String(Character($0)) } ?? names[lower]
            if let char { out.replaceSubrange(whole, with: char) }
        }
        return out
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
    static func splitRow(_ line: String) -> [String] {
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
