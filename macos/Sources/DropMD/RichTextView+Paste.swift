import AppKit

extension RichTextView {
    // MARK: - 粘贴：只保留 Markdown 能保存的格式

    /// 刚粘贴进来的内容：去掉保存不了的格式，链接、列表转成单页的写法
    /// kind：粘贴前目标段落的样式（标题、列表等），只贴进一行字时照用，否则从段首替换时这一段会变回正文
    func cleanPasted(_ range: NSRange, html: String? = nil, inDetails: Bool = false, kind: RichKind? = nil) {
        let lists = pastedLists(range)   // 清理格式前先记下：清理后系统的列表信息就没了
        normalizePasted(range, inDetails: inDetails, kind: kind)
        if let html { applyHTMLFormats(html, range) }
        listify(lists)
    }

    private static let htmlToken = try! NSRegularExpression(pattern: #"<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|[^<]+"#, options: .dotMatchesLineSeparators)
    private static let htmlItalic = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-style\s*:\s*italic"#, options: .caseInsensitive)   // 不算 Word 的 mso-bidi-font-style
    private static let htmlBold = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-weight\s*:\s*(bold|[6-9]00)"#, options: .caseInsensitive)
    private static let htmlNotBold = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-weight\s*:\s*(normal|[1-4]00)"#, options: .caseInsensitive)   // Google 文档整篇包在 <b style="font-weight:normal"> 里

    /// HTML 里的一段文字：是否粗体、斜体，属于几级标题（0 = 不是标题）
    static func htmlChunks(_ html: String) -> [(text: String, bold: Bool, italic: Bool, heading: Int)] {
        let token = htmlToken, italicStyle = htmlItalic, boldStyle = htmlBold, notBold = htmlNotBold
        let voidTags: Set<String> = ["br", "img", "meta", "link", "hr", "input", "col", "base", "wbr"]
        let hidden: Set<String> = ["head", "style", "script", "title"]
        let ns = html as NSString
        var open: [(tag: String, bold: Bool, italic: Bool)] = []
        var out: [(text: String, bold: Bool, italic: Bool, heading: Int)] = []
        for m in token.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 2).location != NSNotFound {
                let tag = ns.substring(with: m.range(at: 2)).lowercased()
                let attrs = ns.substring(with: m.range(at: 3))
                if ns.substring(with: m.range(at: 1)) == "/" {
                    if let i = open.lastIndex(where: { $0.tag == tag }) { open.removeSubrange(i...) }
                } else if !voidTags.contains(tag), !attrs.hasSuffix("/") {
                    func has(_ r: NSRegularExpression) -> Bool { r.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) != nil }
                    open.append((tag, ((tag == "b" || tag == "strong") && !has(notBold)) || has(boldStyle), tag == "em" || tag == "i" || has(italicStyle)))
                }
            } else if ns.character(at: m.range.location) != 60, !open.contains(where: { hidden.contains($0.tag) }) {   // 60 = <，即注释
                let text = MarkdownCodec.decodeHTMLEntities(ns.substring(with: m.range), nbspAsSpace: true)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                let level = open.last { $0.tag.count == 2 && $0.tag.first == "h" }.flatMap { Int($0.tag.dropFirst()) } ?? 0
                out.append((text, open.contains { $0.bold }, open.contains { $0.italic }, (1...6).contains(level) ? level : 0))
            }
        }
        return out
    }

    /// 系统读剪贴板时丢掉两样：中文的粗体、斜体（网页的字体没有对应字形）和标题（读成粗体正文）。HTML 里还写着：
    /// 只读它的文字，不交给系统的网页读取。按顺序逐段对上粘贴的文字，对不上的段不处理，所以不会标错地方
    private func applyHTMLFormats(_ html: String, _ range: NSRange) {
        // 超过 1 MB 的 HTML 跳过解析，避免粘贴超大网页内容时卡顿
        guard let storage = textStorage, html.utf8.count < 1_000_000 else { return }
        let chunks = Self.htmlChunks(html)
        guard chunks.contains(where: { $0.bold || $0.italic || $0.heading > 0 }) else { return }
        let ns = storage.string as NSString
        let end = NSMaxRange(range)
        var from = range.location
        var italics: [NSRange] = [], bolds: [NSRange] = []
        var headings: [Int: (level: Int, text: String)] = [:]   // 段落开头 → 标题级别、这一段里属于标题的文字
        for c in chunks {
            let r = ns.range(of: c.text, range: NSRange(location: from, length: end - from))
            if r.location == NSNotFound { continue }
            from = NSMaxRange(r)
            if c.italic { italics.append(r) }
            if c.bold, c.heading == 0 { bolds.append(r) }
            if c.heading > 0 {
                let start = paragraphRange(at: r.location).location
                headings[start] = (c.heading, (headings[start]?.text ?? "") + c.text)
            }
        }
        for r in italics where storage.attribute(DMKey.inlineCode, at: r.location, effectiveRange: nil) == nil {
            changeAttributes(in: r) { old in
                var a = old
                a[.obliqueness] = RichStyle.italicObliqueness
                return a
            }
        }
        for r in bolds where storage.attribute(DMKey.inlineCode, at: r.location, effectiveRange: nil) == nil {
            changeAttributes(in: r) { old in
                var a = old
                if let font = old[.font] as? NSFont { a[.font] = RichStyle.setBold(font, true) }
                return a
            }
        }
        func compact(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        for (start, h) in headings {
            let para = paragraphRange(at: start)
            let attrs = paragraphAttributes(para)
            let kind = RichBridge.kind(of: attrs)
            // 整段都是标题才改：粘贴到一行中间或表格单元格里时不动这一行
            if kind == .body, RichBridge.tableBlock(of: attrs) == nil, compact(ns.substring(with: para)) == compact(h.text) {
                restyle(para, to: .heading(h.level), from: kind)
            }
        }
    }

    /// 粘贴内容里系统标成列表的段落（文本编辑、Word、网页的列表带 NSTextList）及其层级
    private func pastedLists(_ range: NSRange) -> [(NSRange, Int)] {
        guard let storage = textStorage else { return [] }
        let ns = storage.string as NSString
        var out: [(NSRange, Int)] = []
        var loc = range.location
        while loc < NSMaxRange(range), loc < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if let lists = (storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists,
               !lists.isEmpty {
                out.append((p, lists.count - 1))
            }
            loc = NSMaxRange(p)
        }
        return out
    }

    /// 这些段落的文字以“•⇥”“1⇥”这样的列表符号开头：去掉符号，改成单页的列表
    private func listify(_ paras: [(NSRange, Int)]) {
        guard let storage = textStorage else { return }
        for (p, depth) in paras.reversed() {   // 从后往前改，前面段落的位置不变
            let text = (storage.string as NSString).substring(with: p)
            guard let m = text.range(of: #"^\t*(\S{1,4})\t"#, options: .regularExpression) else { continue }
            let marker = text[m].trimmingCharacters(in: .whitespaces)
            let ordered = marker.first?.isNumber == true || marker.first?.isLetter == true
            let cut = NSRange(location: p.location, length: (String(text[m]) as NSString).length)
            guard shouldChangeText(in: cut, replacementString: "") else { continue }
            storage.replaceCharacters(in: cut, with: "")
            didChangeText()
            let para = paragraphRange(at: p.location)
            _ = restyle(para, to: ordered ? .ordered(depth) : .bullet(depth), from: RichBridge.kind(of: paragraphAttributes(para)))
        }
    }

    private static let keptKeys: Set<NSAttributedString.Key> = [
        .font, .underlineStyle, .strikethroughStyle, .obliqueness, .link, .attachment, .superscript,
        DMKey.inlineCode, DMKey.kbd, DMKey.highlight, DMKey.literal, DMKey.link, DMKey.title, DMKey.linkTitle,
        DMKey.imageID, DMKey.imageWidth, DMKey.imageHeight, DMKey.softBreak, DMKey.image, DMKey.alt, DMKey.callout, DMKey.math,
        DMKey.htmlInline, DMKey.htmlInlineID,
    ]

    // MARK: - 在单页之间复制：另存一份带 DropMD 属性的内容，公式、图片粘贴后不丢

    private static let richType = NSPasteboard.PasteboardType("io.github.dropmd.rich")

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.richType] + super.writablePasteboardTypes
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.richType] + super.readablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.richType else { return super.writeSelection(to: pboard, type: type) }
        guard let storage = textStorage else { return false }
        let s = NSMutableAttributedString()
        for value in selectedRanges { s.append(storage.attributedSubstring(from: value.rangeValue)) }
        guard s.length > 0 else { return false }
        // 公式、图片、分隔线不存图片本身，粘贴时按原文重建
        s.removeAttribute(.attachment, range: NSRange(location: 0, length: s.length))
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: true) else { return false }
        return pboard.setData(data, forType: type)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.richType else {
            // 粘贴和拖入都走这里：别的程序来的内容去掉保存不了的格式，链接、列表转成单页的写法
            let sel = selectedRange(), before = textStorage?.length ?? 0
            let destPara = paragraphRange(at: sel.location)
            let dest = paragraphAttributes(destPara)
            let emptyDest = (string as NSString).substring(with: destPara).trimmingCharacters(in: .newlines).isEmpty
            // 贴进表格单元格或折叠块标题行：只要文字，换行改成空格（只能有一段，否则整张表或折叠块被拆开）
            if RichBridge.tableBlock(of: dest) != nil || dest[DMKey.summary] != nil,
               let text = pboard.string(forType: .string) ?? pboard.string(forType: .html).map({ Self.htmlChunks($0).map(\.text).joined(separator: " ") }) {
                let flat = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
                replace(sel, with: fitInline(RichBridge.runsString([MDRun(text: flat)], kind: .body, baseURL: baseURL), to: dest))
                return true
            }
            // 多行贴进代码块：只要纯文字，每行都用这一块的格式（语言、块编号），否则网页的富文本把代码块拆成正文段落
            if Self.isCodeBlock(dest), let text = pboard.string(forType: .string), text.contains(where: \.isNewline) {
                replace(sel, with: codeText(text, to: dest))
                return true
            }
            guard super.readSelection(from: pboard, type: type) else { return false }
            let inserted = (textStorage?.length ?? 0) - before + sel.length
            if inserted > 0 {
                let range = NSRange(location: sel.location, length: inserted)
                let oneLine = !(string as NSString).substring(with: range).contains { $0.isNewline }
                let beforeClean = textStorage?.length ?? 0
                cleanPasted(range, html: pboard.string(forType: .html), inDetails: dest[DMKey.inDetails] != nil,
                            kind: oneLine ? RichBridge.kind(of: dest) : nil)
                // cleanPasted 可能删字（如列表符号“•\t”），范围按长度变化缩短，否则越界或改到下一段
                let cleaned = NSRange(location: sel.location, length: max(0, inserted + (textStorage?.length ?? 0) - beforeClean))
                let keepHeading = emptyDest && RichBridge.kind(of: dest) == .body
                    && RichBridge.kind(of: paragraphAttributes(paragraphRange(at: sel.location))).isHeading
                if oneLine, cleaned.length > 0, !keepHeading {   // 列表层级、代码块编号等段落属性也照目标段落
                    changeAttributes(in: cleaned) { old in
                        var a = old
                        for k in Self.paragraphLevelKeys { a[k] = dest[k] }
                        return a
                    }
                }
            }
            return true
        }
        // 只接受文字、字体、颜色、段落样式等固定的类型（剪贴板内容可能来自别的程序）
        let classes: [AnyClass] = [NSAttributedString.self, NSString.self, NSNumber.self, NSDictionary.self, NSArray.self,
                                   NSFont.self, NSColor.self, NSURL.self, NSParagraphStyle.self, NSTextTab.self,
                                   NSTextTable.self, NSTextTableBlock.self]
        guard let data = pboard.data(forType: type),
              let s = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString else { return false }
        let pasted = NSMutableAttributedString(attributedString: RichBridge.restoringAttachments(s, baseURL: baseURL))
        let dest = paragraphAttributes(paragraphRange(at: selectedRange().location))
        if !pasted.string.contains("\n") || RichBridge.tableBlock(of: dest) != nil || dest[DMKey.summary] != nil {
            // 一行里的字、或贴进表格单元格、折叠块标题行：用目标这一段的格式和字号，不把这一段（或整张表、折叠块）拆开
            replace(selectedRange(), with: fitInline(pasted, to: dest))
            return true
        }
        if Self.isCodeBlock(dest) {
            // 多段贴进代码块：都当作这一块的代码（纯文字），不保留别的语言、块编号，否则这一块被拆开
            var text = ""
            pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { a, r, _ in
                text += (a[DMKey.math] as? String) ?? (pasted.string as NSString).substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
            replace(selectedRange(), with: codeText(text, to: dest))
            return true
        }
        if dest[DMKey.inDetails] != nil {
            // 多段贴进折叠块：没有折叠块标记的段落补上，否则保存时折叠块在这里提前结束
            var outside: [NSRange] = []
            pasted.enumerateAttribute(DMKey.inDetails, in: NSRange(location: 0, length: pasted.length)) { v, r, _ in
                if v == nil { outside.append(r) }
            }
            for r in outside {
                let part = NSMutableAttributedString(attributedString: pasted.attributedSubstring(from: r))
                RichBridge.markInDetails(part)
                pasted.replaceCharacters(in: r, with: part)
            }
        } else {
            // 贴到折叠块外：只保留剪贴板里自带完整折叠块（有标题行）的内容，游离的折叠块标记和缩进全部去掉
            Self.stripOrphanDetails(pasted)
        }
        // 引用、原样内容的块编号是复制来源那里的：每段换一个新编号（复制来的两段仍是两段，也不和文中别的块重号）；
        // 只有一段、贴进同一种块的中间时，用目标那一块的编号，不把它切开
        let all = NSRange(location: 0, length: pasted.length)
        for (key, isKind) in [(DMKey.quoteBlock, { (a: [NSAttributedString.Key: Any]) in RichBridge.kind(of: a) == .quote }),
                              (DMKey.codeBlock, { (a: [NSAttributedString.Key: Any]) in a[DMKey.raw] != nil && a[DMKey.math] == nil })] {
            var ids: [String: String] = [:]
            pasted.enumerateAttributes(in: all) { a, r, _ in
                guard isKind(a), let old = a[key] as? String else { return }
                if ids[old] == nil { ids[old] = UUID().uuidString }
                pasted.addAttribute(key, value: ids[old]!, range: r)
            }
            // 提示框标题行开始的是新的一段：贴的内容里有提示框、或贴在提示框标题行上，都不沿用目标的编号
            var hasCallout = false
            pasted.enumerateAttribute(DMKey.callout, in: all) { v, _, stop in if v != nil { hasCallout = true; stop.pointee = true } }
            let calloutInvolved = key == DMKey.quoteBlock && (hasCallout || dest[DMKey.callout] != nil)
            if ids.count == 1, isKind(dest), let target = dest[key] as? String, !calloutInvolved {
                pasted.enumerateAttributes(in: all) { a, r, _ in
                    if isKind(a), a[key] != nil { pasted.addAttribute(key, value: target, range: r) }
                }
            }
        }
        replace(selectedRange(), with: pasted)
        return true
    }

    /// 段落在代码块里（公式块不算）
    private static func isCodeBlock(_ a: [NSAttributedString.Key: Any]) -> Bool {
        guard case .code = RichBridge.kind(of: a) else { return false }
        return a[DMKey.math] == nil
    }

    /// 贴进代码块的纯文字：保留换行，每行都用目标段落的字体和段落属性（语言、块编号、列表归属、段落样式）
    private func codeText(_ text: String, to dest: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let plain = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // 不用 runsString：它把段落里的换行变成显示为空格的软换行，代码的每一行要保持是单独的一段
        let run = MDRun(text: plain)
        return fitted(NSAttributedString(string: plain, attributes: RichStyle.attributes(for: run, kind: RichBridge.kind(of: dest))), to: dest)
    }

    /// 贴到折叠块外时，去掉没有对应折叠块标题的游离折叠标记与缩进（保留各自原有的段落样式）
    private static func stripOrphanDetails(_ s: NSMutableAttributedString) {
        let ns = s.string as NSString
        var loc = 0
        var inOwnDetails = false
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            let a = s.attributes(at: para.location, effectiveRange: nil)
            if a[DMKey.summary] != nil {
                inOwnDetails = true
            } else if a[DMKey.inDetails] != nil {
                if !inOwnDetails { unmarkInDetails(s, in: para) }
            } else {
                inOwnDetails = false
                s.removeAttribute(DMKey.inDetails, range: para)
            }
        }
    }

    /// 撤回 RichBridge.markInDetails 对段落做过的折叠块标记与缩进
    private static func unmarkInDetails(_ s: NSMutableAttributedString, in range: NSRange) {
        var styles: [(NSRange, NSParagraphStyle)] = []
        s.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, r, _ in
            if let p = value as? NSParagraphStyle { styles.append((r, p)) }
        }
        for (r, p) in styles {
            if let cell = p.textBlocks.first as? NSTextTableBlock {
                cell.table.setWidth(0, type: .absoluteValueType, for: .margin, edge: .minX)
                continue
            }
            guard let m = p.mutableCopy() as? NSMutableParagraphStyle else { continue }
            m.firstLineHeadIndent = max(0, m.firstLineHeadIndent - RichStyle.detailsIndent)
            m.headIndent = max(0, m.headIndent - RichStyle.detailsIndent)
            s.addAttribute(.paragraphStyle, value: m, range: r)
        }
        s.removeAttribute(DMKey.inDetails, range: range)
    }

    private static let newlineRuns = try! NSRegularExpression(pattern: #"[\r\n]+"#)

    /// 行内粘贴：改用目标段落的字体、字号与字距，保留粗体、斜体、行内代码、链接等行内格式
    private func fitInline(_ s: NSAttributedString, to dest: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        if RichBridge.tableBlock(of: dest) != nil || dest[DMKey.summary] != nil {
            for m in Self.newlineRuns.matches(in: out.string, range: NSRange(location: 0, length: out.length)).reversed() {
                let edge = m.range.location == 0 || NSMaxRange(m.range) == out.length
                out.replaceCharacters(in: m.range, with: edge ? "" : " ")
            }
        }
        guard out.length > 0 else { return out }
        let destKind = RichBridge.kind(of: dest)
        let destImplicitBold = destKind.isHeading || destKind == .summary || RichBridge.tableBlock(of: dest)?.startingRow == 0
        let kern = RichStyle.kern(for: destKind)
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length), options: []) { a, r, _ in
            runs.append((r, a))
        }
        for (r, old) in runs {
            if old[.attachment] != nil || old[DMKey.image] != nil { continue }
            var a = old
            if destKind.isMonospaced {
                for key in [DMKey.inlineCode, DMKey.kbd, DMKey.highlight, DMKey.link, DMKey.title, DMKey.literal] { a[key] = nil }
                for key: NSAttributedString.Key in [.link, .backgroundColor, .obliqueness, .underlineStyle, .underlineColor, .strikethroughStyle, .superscript, .kern] {
                    a[key] = nil
                }
                a[.font] = RichStyle.baseFont(for: destKind)
                a[.foregroundColor] = RichStyle.textColor(for: destKind)
            } else {
                let srcKind = RichBridge.kind(of: old)
                let srcImplicitBold = srcKind.isHeading || srcKind == .summary || RichBridge.tableBlock(of: old)?.startingRow == 0
                var bold = RichStyle.isBold(old[.font] as? NSFont)
                if destImplicitBold {
                    bold = true
                } else if srcImplicitBold || srcKind.isMonospaced {
                    bold = false
                }
                var font: NSFont
                if a[DMKey.inlineCode] != nil {
                    font = .monospacedSystemFont(ofSize: RichStyle.inlineCodeSize, weight: .regular)
                    if bold { font = RichStyle.setBold(font, true) }
                } else if a[DMKey.kbd] != nil {
                    font = RichStyle.kbdFont
                    if bold { font = RichStyle.setBold(font, true) }
                } else {
                    font = RichStyle.setBold(RichStyle.baseFont(for: destKind), bold)
                }
                if ((a[.superscript] as? Int) ?? 0) != 0 { font = RichStyle.scaled(font, 0.75) }
                a[.font] = font
                a[.kern] = kern
                if a[DMKey.link] == nil && a[DMKey.literal] == nil {
                    a[.foregroundColor] = a[DMKey.inlineCode] != nil ? RichStyle.inlineCodeColor : RichStyle.textColor(for: destKind)
                }
            }
            out.setAttributes(a, range: r)
        }
        return fitted(out, to: dest)
    }

    /// 从网页、Word 等粘贴的文字：去掉颜色、字体、对齐等无法保存的格式，统一为编辑器的样式
    private func normalizePasted(_ range: NSRange, inDetails: Bool, kind: RichKind?) {
        let paragraphKind = kind ?? currentKind
        changeAttributes(in: range) { old in
            // 从本编辑器复制的段落保留原样式
            if old[DMKey.heading] != nil || old[DMKey.list] != nil || old[DMKey.task] != nil
                || old[DMKey.code] != nil || old[DMKey.quote] != nil || old[DMKey.summary] != nil {
                return old
            }
            var a = old.filter { Self.keptKeys.contains($0.key) }
            if RichBridge.tableBlock(of: old) != nil { a[.paragraphStyle] = old[.paragraphStyle] }
            let font = old[.font] as? NSFont
            if a[DMKey.inlineCode] == nil, a[DMKey.kbd] == nil, a[.attachment] == nil {
                let bold = paragraphKind.isHeading || paragraphKind == .summary || (!paragraphKind.isMonospaced && RichStyle.isBold(font))
                a[.font] = RichStyle.setBold(RichStyle.baseFont(for: paragraphKind), bold)
                a[.kern] = RichStyle.kern(for: paragraphKind)
                if let font, font.fontDescriptor.symbolicTraits.contains(.italic) {
                    a[.obliqueness] = RichStyle.italicObliqueness
                }
            }
            // 网页、文本编辑里的链接只有系统的 .link，转成单页的链接，否则保存时只剩下划线
            if a[DMKey.link] == nil, let link = a[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String)
                if let url, !url.isEmpty {
                    a[DMKey.link] = url
                    a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if a[DMKey.link] != nil { a[.underlineColor] = RichStyle.linkUnderlineColor }
            a[.foregroundColor] = a[DMKey.link] != nil ? NSColor.linkColor
                : a[DMKey.literal] != nil ? NSColor.systemPurple
                : a[DMKey.inlineCode] != nil ? RichStyle.inlineCodeColor : RichStyle.textColor(for: paragraphKind)
            if a[DMKey.highlight] != nil { a[.backgroundColor] = RichStyle.highlightBackground }
            if a[DMKey.inlineCode] != nil { a[.backgroundColor] = RichStyle.codeBackground }
            if inDetails { a[DMKey.inDetails] = true }
            if a[.paragraphStyle] == nil {
                a[.paragraphStyle] = RichStyle.paragraphStyle(paragraphKind, inDetails: inDetails)
                for (k, v) in RichStyle.marks(for: paragraphKind) { a[k] = v }
            }
            return a
        }
    }
}
