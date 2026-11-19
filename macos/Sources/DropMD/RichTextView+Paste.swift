import AppKit

extension RichTextView {
    // MARK: - 粘贴：只保留 Markdown 能保存的格式

    /// 刚粘贴进来的内容：去掉保存不了的格式，链接、列表转成单页的写法
    func cleanPasted(_ range: NSRange, html: String? = nil) {
        let lists = pastedLists(range)   // 清理格式前先记下：清理后系统的列表信息就没了
        normalizePasted(range)
        if let html { applyHTMLFormats(html, range) }
        listify(lists)
    }

    /// HTML 里的一段文字：是否粗体、斜体，属于几级标题（0 = 不是标题）
    static func htmlChunks(_ html: String) -> [(text: String, bold: Bool, italic: Bool, heading: Int)] {
        let token = try! NSRegularExpression(pattern: #"<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|[^<]+"#, options: .dotMatchesLineSeparators)
        let italicStyle = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-style\s*:\s*italic"#, options: .caseInsensitive)   // 不算 Word 的 mso-bidi-font-style
        let boldStyle = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-weight\s*:\s*(bold|[6-9]00)"#, options: .caseInsensitive)
        let notBold = try! NSRegularExpression(pattern: #"(^|[;\s"'])font-weight\s*:\s*(normal|[1-4]00)"#, options: .caseInsensitive)   // Google 文档整篇包在 <b style="font-weight:normal"> 里
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
                let text = decodeEntities(ns.substring(with: m.range))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                let level = open.last { $0.tag.count == 2 && $0.tag.first == "h" }.flatMap { Int($0.tag.dropFirst()) } ?? 0
                out.append((text, open.contains { $0.bold }, open.contains { $0.italic }, (1...6).contains(level) ? level : 0))
            }
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let entity = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-z]+);"#)
        var out = s
        for m in entity.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let body = Range(m.range(at: 1), in: out) else { continue }
            let name = String(out[body])
            let value: UInt32? = name.lowercased().hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16) : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
            let char = value.flatMap(Unicode.Scalar.init).map { $0 == "\u{A0}" ? " " : String(Character($0)) } ?? names[name]
            if let char { out.replaceSubrange(whole, with: char) }
        }
        return out
    }

    /// 系统读剪贴板时丢掉两样：中文的粗体、斜体（网页的字体没有对应字形）和标题（读成粗体正文）。HTML 里还写着：
    /// 只读它的文字，不交给系统的网页读取。按顺序逐段对上粘贴的文字，对不上的段不处理，所以不会标错地方
    private func applyHTMLFormats(_ html: String, _ range: NSRange) {
        // shortcut: 超过 1 MB 的 HTML 不处理（只是少了斜体和标题），真有人遇到再改
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
            let kind = RichBridge.kind(of: paragraphAttributes(para))
            // 整段都是标题才改：粘贴到一行中间时不动这一行
            if kind == .body, compact(ns.substring(with: para)) == compact(h.text) {
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
        DMKey.inlineCode, DMKey.kbd, DMKey.highlight, DMKey.literal, DMKey.link, DMKey.title, DMKey.linkTitle, DMKey.imageID, DMKey.softBreak, DMKey.image, DMKey.alt, DMKey.callout, DMKey.math,
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
            guard super.readSelection(from: pboard, type: type) else { return false }
            let inserted = (textStorage?.length ?? 0) - before + sel.length
            if inserted > 0 { cleanPasted(NSRange(location: sel.location, length: inserted), html: pboard.string(forType: .html)) }
            return true
        }
        // 只接受文字、字体、颜色、段落样式等固定的类型（剪贴板内容可能来自别的程序）
        let classes: [AnyClass] = [NSAttributedString.self, NSString.self, NSNumber.self, NSDictionary.self, NSArray.self,
                                   NSFont.self, NSColor.self, NSURL.self, NSParagraphStyle.self, NSTextTab.self,
                                   NSTextTable.self, NSTextTableBlock.self]
        guard let data = pboard.data(forType: type),
              let s = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSAttributedString else { return false }
        replace(selectedRange(), with: RichBridge.restoringAttachments(s, baseURL: baseURL))
        return true
    }

    /// 从网页、Word 等粘贴的文字：去掉颜色、字体、对齐等无法保存的格式，统一为编辑器的样式
    private func normalizePasted(_ range: NSRange) {
        let paragraphKind = currentKind
        changeAttributes(in: range) { old in
            // 从本编辑器复制的段落保留原样式
            if old[DMKey.heading] != nil || old[DMKey.list] != nil || old[DMKey.task] != nil
                || old[DMKey.code] != nil || old[DMKey.quote] != nil || old[DMKey.summary] != nil {
                return old
            }
            var a = old.filter { Self.keptKeys.contains($0.key) }
            if RichBridge.tableBlock(of: old) != nil { a[.paragraphStyle] = old[.paragraphStyle] }
            let font = old[.font] as? NSFont
            if a[DMKey.inlineCode] == nil, a[.attachment] == nil {
                a[.font] = RichStyle.setBold(RichStyle.baseFont(for: paragraphKind), RichStyle.isBold(font))
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
            a[.foregroundColor] = a[DMKey.link] != nil ? NSColor.linkColor
                : a[DMKey.literal] != nil ? NSColor.systemPurple
                : a[DMKey.inlineCode] != nil ? RichStyle.inlineCodeColor : RichStyle.bodyColor
            if a[DMKey.highlight] != nil { a[.backgroundColor] = RichStyle.highlightBackground }
            if a[DMKey.inlineCode] != nil { a[.backgroundColor] = RichStyle.codeBackground }
            if a[.paragraphStyle] == nil {
                a[.paragraphStyle] = RichStyle.paragraphStyle(paragraphKind)
                for (k, v) in RichStyle.marks(for: paragraphKind) { a[k] = v }
            }
            return a
        }
    }
}
