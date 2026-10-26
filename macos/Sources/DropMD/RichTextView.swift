import AppKit

/// 字符样式
enum RichTrait {
    case bold, italic, underline, strike, highlight, sup, sub, kbd

    func isOn(_ a: [NSAttributedString.Key: Any]) -> Bool {
        switch self {
        case .bold: return RichStyle.isBold(a[.font] as? NSFont)
        case .italic: return ((a[.obliqueness] as? Double) ?? 0) != 0
        case .underline: return a[DMKey.link] == nil && ((a[.underlineStyle] as? Int) ?? 0) != 0
        case .strike: return ((a[.strikethroughStyle] as? Int) ?? 0) != 0
        case .highlight: return a[DMKey.highlight] != nil
        case .sup: return ((a[.superscript] as? Int) ?? 0) > 0
        case .sub: return ((a[.superscript] as? Int) ?? 0) < 0
        case .kbd: return a[DMKey.kbd] != nil
        }
    }

    func apply(_ a: [NSAttributedString.Key: Any], on: Bool) -> [NSAttributedString.Key: Any] {
        var a = a
        switch self {
        case .bold:
            let font = (a[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
            a[.font] = RichStyle.setBold(font, on)
        case .italic:
            a[.obliqueness] = on ? RichStyle.italicObliqueness : nil
        case .underline:
            a[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .strike:
            a[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .sup, .sub:
            let base = RichStyle.baseFont(for: RichBridge.kind(of: a))
            let bold = RichStyle.isBold(a[.font] as? NSFont)
            let font = a[DMKey.inlineCode] != nil || a[DMKey.kbd] != nil
                ? NSFont.monospacedSystemFont(ofSize: RichStyle.codeSize, weight: .regular) : base
            a[.superscript] = on ? (self == .sup ? 1 : -1) : nil
            a[.font] = RichStyle.setBold(on ? RichStyle.scaled(font, 0.75) : font, bold)
        case .kbd:
            a[DMKey.kbd] = on ? true : nil
            a[.font] = on ? NSFont.monospacedSystemFont(ofSize: RichStyle.codeSize - 1, weight: .medium)
                          : RichStyle.baseFont(for: RichBridge.kind(of: a))
            a[.backgroundColor] = on ? RichStyle.codeBackground : nil
        case .highlight:
            a[DMKey.highlight] = on ? true : nil
            if a[DMKey.inlineCode] == nil {
                a[.backgroundColor] = on ? RichStyle.highlightBackground : nil
            }
        }
        return a
    }
}

/// 在列表段落的缩进区画出项目符号和编号（它们不属于正文，不会写入文件）
final class RichLayoutManager: NSLayoutManager {
    private static let bullets = ["•", "◦", "▪"]

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            guard para.length > 0 else { break }
            let attrs = storage.attributes(at: para.location, effectiveRange: nil)
            let inDetails = attrs[DMKey.inDetails] != nil
            let shift = inDetails ? RichStyle.detailsIndent : 0
            // 下一段也是引用 / 折叠块内容时，竖线延伸到下一段，连成一条
            let next = loc < ns.length ? storage.attributes(at: loc, effectiveRange: nil) : [:]
            if inDetails { drawBar(para, origin: origin, x: 7, color: RichStyle.lineColor, joinsNext: next[DMKey.inDetails] != nil) }
            let kind = RichBridge.kind(of: attrs)
            if kind == .quote {
                // 下一段是提示框的标题行时是新的引用块，不连在一起
                let nextText = loc < ns.length ? ns.substring(with: ns.paragraphRange(for: NSRange(location: loc, length: 0))) : ""
                let nextStartsCallout = MDCallout(header: nextText.trimmingCharacters(in: .newlines)) != nil
                drawBar(para, origin: origin, x: shift + 4, color: .tertiaryLabelColor,
                        joinsNext: RichBridge.kind(of: next) == .quote && !nextStartsCallout)
            }
            if kind == .rule { drawRule(para, origin: origin, shift: shift) }
            let marker: String
            let depth: Int
            switch kind {
            case .summary:
                marker = "▸"
                depth = 0
            case .bullet(let d):
                marker = Self.bullets[d % Self.bullets.count]
                depth = d
            case .ordered(let d):
                marker = "\(number(at: para.location, depth: d, in: storage))."
                depth = d
            default:
                continue
            }
            let glyph = glyphIndexForCharacter(at: para.location)
            guard glyph < numberOfGlyphs else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph).y
            let font = (attrs[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
            let markerAttrs: [NSAttributedString.Key: Any] = [
                .font: font.isFixedPitch ? NSFont.systemFont(ofSize: font.pointSize) : RichStyle.setBold(font, false),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = (marker as NSString).size(withAttributes: markerAttrs)
            let markerWidth = kind == .summary ? RichStyle.detailsIndent : RichStyle.indent
            let right = origin.x + line.minX + shift + CGFloat(depth) * RichStyle.indent + markerWidth - 6
            let point = NSPoint(x: right - size.width, y: origin.y + line.minY + baseline - font.ascender)
            (marker as NSString).draw(at: point, withAttributes: markerAttrs)
        }
    }

    /// 代码块：连续的代码段落画成一整块圆角底色（不按行画，避免一条条的横条）
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawCodeBlocks(glyphsToShow, origin: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// 行内代码、按键、高亮：底色只包住文字，画成圆角（系统默认填满整行高度，显得很笨重）。
    /// 选中文字的底色等其他背景仍按系统方式绘制。
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let container = textContainers.first,
              let own = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor,
              own == color else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        let font = (storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont)
            ?? RichStyle.baseFont(for: .body)
        let origin = container.textView?.textContainerOrigin ?? .zero
        color.setFill()
        for i in 0..<rectCount {
            let r = rectArray[i]
            let glyph = glyphIndex(for: NSPoint(x: r.midX - origin.x, y: r.midY - origin.y), in: container)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = origin.y + line.minY + location(forGlyphAt: glyph).y
            let box = NSRect(x: r.minX - 1, y: baseline - font.ascender - 2,
                             width: r.width + 2, height: font.ascender - font.descender + 4)
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
    }

    private func isCodeParagraph(at location: Int, in storage: NSTextStorage) -> Bool {
        switch RichBridge.kind(of: storage.attributes(at: location, effectiveRange: nil)) {
        case .code, .raw: return true
        default: return false
        }
    }

    private func drawCodeBlocks(_ glyphsToShow: NSRange, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            var block = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            guard isCodeParagraph(at: block.location, in: storage) else {
                loc = NSMaxRange(block)
                continue
            }
            // 向前、向后找到整个代码块
            while block.location > 0 {
                let prev = ns.paragraphRange(for: NSRange(location: block.location - 1, length: 0))
                guard isCodeParagraph(at: prev.location, in: storage) else { break }
                block = NSUnionRange(prev, block)
            }
            while NSMaxRange(block) < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0))
                guard isCodeParagraph(at: next.location, in: storage) else { break }
                block = NSUnionRange(block, next)
            }
            loc = NSMaxRange(block)
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let pad = container.lineFragmentPadding
            let shift = storage.attribute(DMKey.inDetails, at: block.location, effectiveRange: nil) != nil
                ? RichStyle.detailsIndent : 0
            let rect = NSRect(x: origin.x + first.minX + pad + shift, y: origin.y + first.minY - 6,
                              width: first.width - pad * 2 - shift, height: last.maxY - first.minY + 10)
            RichStyle.codeBlockBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    /// 段落左侧的竖线（引用、折叠块内容）
    private func drawBar(_ para: NSRange, origin: NSPoint, x: CGFloat, color: NSColor, joinsNext: Bool = false) {
        guard let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let rect = boundingRect(forGlyphRange: glyphs, in: container)
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        // 与下一段相连时画到本段最后一行的底部（包括段后间距）
        let bottom = joinsNext ? lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY : rect.maxY
        color.setFill()
        NSRect(x: origin.x + line.minX + x, y: origin.y + rect.minY, width: 3, height: bottom - rect.minY).fill()
    }

    /// 分隔线：横跨整个正文宽度
    private func drawRule(_ para: NSRange, origin: NSPoint, shift: CGFloat) {
        guard let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: para.location)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let pad = container.lineFragmentPadding
        let x = origin.x + line.minX + pad + shift
        RichStyle.lineColor.setFill()
        NSRect(x: x, y: (origin.y + line.midY).rounded() - 0.5,
               width: max(0, origin.x + line.maxX - pad - x), height: 1).fill()
    }

    /// 有序列表项的编号：向前数同一层级、连续的有序列表项
    private func number(at location: Int, depth: Int, in storage: NSTextStorage) -> Int {
        let ns = storage.string as NSString
        var n = 1
        var loc = location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            loc = prev.location
            switch RichBridge.kind(of: storage.attributes(at: prev.location, effectiveRange: nil)) {
            case .ordered(let d) where d == depth: n += 1
            case .ordered(let d) where d > depth: continue
            case .bullet(let d) where d > depth: continue
            case .task(let d, _) where d > depth: continue
            default: return n
            }
        }
        return n
    }
}

/// 光标处的样式，用于“格式”面板显示当前状态
struct SelectionState: Equatable {
    var kind: RichKind = .body
    var active: Set<EditorAction> = []
}

/// Word / Pages 式的富文本编辑区。内容保存时转换为 Markdown。
final class RichTextView: NSTextView {
    var baseURL: URL?

    // MARK: - 页面外观：整个编辑区同一底色，文字在居中的版心中

    private static let columnWidth: CGFloat = 672   // 版心最大宽度
    private static let minMargin: CGFloat = 32      // 窗口较窄时左右至少留出的距离
    private static let topMargin: CGFloat = 56

    override func layout() {
        super.layout()
        let margin = max(Self.minMargin, ((bounds.width - Self.columnWidth) / 2).rounded())
        let inset = NSSize(width: margin, height: Self.topMargin)
        if abs(textContainerInset.width - inset.width) > 0.5 || textContainerInset.height != inset.height {
            textContainerInset = inset
        }
    }

    /// 编辑区改变大小（打开窗口、显示格式面板）时，系统会把光标滚到可见处，但计算时没有扣除工具栏遮住的部分，
    /// 刚打开的文档会被往下滚一段。这里保持原来的滚动位置，只有光标真的看不见时才滚动。
    override func setFrameSize(_ newSize: NSSize) {
        guard let scroll = enclosingScrollView else { return super.setFrameSize(newSize) }
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        super.setFrameSize(newSize)
        guard clip.bounds.origin != origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        if let lm = layoutManager, let tc = textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: selectedRange().location, length: 0),
                                       actualCharacterRange: nil)
            var caret = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            caret.origin.y += textContainerOrigin.y
            // 去掉被工具栏等遮住的部分（clip 视图坐标的 y 轴向下）
            let top = clip.bounds.minY + clip.contentInsets.top
            let bottom = clip.bounds.maxY - clip.contentInsets.bottom
            if caret.maxY > bottom || caret.minY < top { scrollRangeToVisible(selectedRange()) }
        }
    }

    override func drawBackground(in rect: NSRect) {
        // 不画纸张（纸张在中间像一个方块）
        RichStyle.paperColor.setFill()
        rect.fill()
    }

    /// 光标处的段落样式与文字样式
    var selectionState: SelectionState {
        let range = selectedRange()
        var attrs = typingAttributes
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        }
        let kind = currentKind
        var active: Set<EditorAction> = []
        if RichTrait.bold.isOn(attrs) && !kind.isHeading { active.insert(.bold) }
        if RichTrait.italic.isOn(attrs) { active.insert(.italic) }
        if RichTrait.underline.isOn(attrs) { active.insert(.underline) }
        if RichTrait.strike.isOn(attrs) { active.insert(.strike) }
        if RichTrait.highlight.isOn(attrs) { active.insert(.highlight) }
        if attrs[DMKey.inlineCode] != nil { active.insert(.inlineCode) }
        if RichTrait.sup.isOn(attrs) { active.insert(.superscriptText) }
        if RichTrait.sub.isOn(attrs) { active.insert(.subscriptText) }
        if RichTrait.kbd.isOn(attrs) { active.insert(.kbd) }
        return SelectionState(kind: kind, active: active)
    }

    // MARK: - 粘贴：只保留 Markdown 能保存的格式

    override func paste(_ sender: Any?) {
        let start = selectedRange().location
        super.paste(sender)
        let end = selectedRange().location
        if end > start { normalizePasted(NSRange(location: start, length: end - start)) }
    }

    private static let keptKeys: Set<NSAttributedString.Key> = [
        .font, .underlineStyle, .strikethroughStyle, .obliqueness, .link, .attachment, .superscript,
        DMKey.inlineCode, DMKey.kbd, DMKey.highlight, DMKey.literal, DMKey.link, DMKey.image, DMKey.alt,
    ]

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
            a[.foregroundColor] = a[DMKey.link] != nil ? NSColor.linkColor
                : a[DMKey.literal] != nil ? NSColor.systemPurple : RichStyle.bodyColor
            if a[DMKey.highlight] != nil { a[.backgroundColor] = RichStyle.highlightBackground }
            if a[DMKey.inlineCode] != nil { a[.backgroundColor] = RichStyle.codeBackground }
            if a[.paragraphStyle] == nil {
                a[.paragraphStyle] = RichStyle.paragraphStyle(paragraphKind)
                for (k, v) in RichStyle.marks(for: paragraphKind) { a[k] = v }
            }
            return a
        }
    }

    // MARK: - 基础

    private func paragraphRange(at location: Int) -> NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
    }

    private func paragraphAttributes(_ para: NSRange) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, para.length > 0, para.location < storage.length else { return typingAttributes }
        return storage.attributes(at: para.location, effectiveRange: nil)
    }

    /// 光标所在段落的样式
    var currentKind: RichKind {
        RichBridge.kind(of: paragraphAttributes(paragraphRange(at: selectedRange().location)))
    }

    /// 选区覆盖的段落（不含文末没有字符的空段落）
    private func paragraphRanges(covering range: NSRange) -> [NSRange] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        let lastChar = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        var loc = paragraphRange(at: min(range.location, ns.length)).location
        var result: [NSRange] = []
        while loc <= lastChar && loc < ns.length {
            let p = paragraphRange(at: loc)
            result.append(p)
            loc = NSMaxRange(p)
        }
        return result
    }

    /// 用富文本替换一段内容（可撤销）
    private func replace(_ range: NSRange, with s: NSAttributedString, caret: Int? = nil) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: s.string) else { return }
        storage.replaceCharacters(in: range, with: s)
        didChangeText()
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(caret ?? range.location + s.length, length), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// 修改一段文字的属性（可撤销）
    private func changeAttributes(in range: NSRange, _ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let storage = textStorage, range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        var parts: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range, options: []) { a, r, _ in parts.append((r, a)) }
        storage.beginEditing()
        for (r, a) in parts { storage.setAttributes(transform(a), range: r) }
        storage.endEditing()
        didChangeText()
    }

    // MARK: - 字符样式

    func toggle(_ trait: RichTrait) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            typingAttributes = trait.apply(typingAttributes, on: !trait.isOn(typingAttributes))
            return
        }
        var allOn = true
        storage.enumerateAttributes(in: range, options: []) { a, _, stop in
            if !trait.isOn(a) {
                allOn = false
                stop.pointee = true
            }
        }
        changeAttributes(in: range) { trait.apply($0, on: !allOn) }
    }

    func toggleInlineCode() {
        let range = selectedRange()
        func apply(_ a: [NSAttributedString.Key: Any], on: Bool) -> [NSAttributedString.Key: Any] {
            var a = a
            if on {
                a[DMKey.inlineCode] = true
                a[.font] = NSFont.monospacedSystemFont(ofSize: RichStyle.codeSize, weight: .regular)
                a[.backgroundColor] = RichStyle.codeBackground
            } else {
                a[DMKey.inlineCode] = nil
                a[.font] = RichStyle.baseFont(for: RichBridge.kind(of: a))
                a[.backgroundColor] = nil
            }
            return a
        }
        guard range.length > 0, let storage = textStorage else {
            typingAttributes = apply(typingAttributes, on: typingAttributes[DMKey.inlineCode] == nil)
            return
        }
        let on = storage.attribute(DMKey.inlineCode, at: range.location, effectiveRange: nil) == nil
        changeAttributes(in: range) { apply($0, on: on) }
    }

    /// 设置链接；url 为 nil 时去掉链接
    func setLink(_ url: String?) {
        let range = selectedRange()
        func apply(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var a = a
            if let url {
                a[DMKey.link] = url
                a[.link] = URL(string: url)
                a[.foregroundColor] = NSColor.linkColor
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                a[DMKey.link] = nil
                a[.link] = nil
                a[.foregroundColor] = RichStyle.bodyColor
                a[.underlineStyle] = nil
            }
            return a
        }
        if range.length > 0 {
            changeAttributes(in: range, apply)
        } else if let url {
            var a = typingAttributes
            a[DMKey.inlineCode] = nil
            replace(range, with: NSAttributedString(string: url, attributes: apply(a)))
        }
    }

    /// 段内换行（不分段），保存为 <br>
    func insertSoftBreak() {
        insertText("\u{2028}", replacementRange: selectedRange())
    }

    /// 插入原样保存的文字（例如 $公式$）
    func insertLiteral(_ text: String) {
        var a = typingAttributes
        a[DMKey.literal] = true
        a[.foregroundColor] = NSColor.systemPurple
        replace(selectedRange(), with: NSAttributedString(string: text, attributes: a))
    }

    // MARK: - 段落样式

    /// 把选中段落设为某种样式；toggle 为真且已是该样式时恢复为正文
    func setKind(_ kind: RichKind, toggle: Bool = false) {
        let first = currentKind
        let target: RichKind = (toggle && first == kind) ? .body : kind
        applyKinds { _ in target }
    }

    /// 列表缩进层级 +1 / -1
    func changeDepth(_ delta: Int) {
        applyKinds { k in
            let d = k.depth + delta
            switch k {
            case .bullet: return d < 0 ? .body : .bullet(min(d, 5))
            case .ordered: return d < 0 ? .body : .ordered(min(d, 5))
            case .task(_, let done): return d < 0 ? .body : .task(min(d, 5), done)
            default: return k
            }
        }
    }

    func applyKinds(_ map: (RichKind) -> RichKind) {
        let all = paragraphRanges(covering: selectedRange())
        // 光标在文末的空段落（或空文档）里：只改变之后输入文字的样式
        if all.isEmpty {
            let target = map(RichBridge.kind(of: typingAttributes))
            typingAttributes = RichStyle.typingAttributes(for: target)
            if case .task(_, let done) = target {
                insertText((done ? RichStyle.taskDone : RichStyle.taskTodo) + " ", replacementRange: selectedRange())
            }
            return
        }
        guard let storage = textStorage else { return }
        // 表格内的段落和分隔线不改样式
        let paragraphs = all.filter { p in
            let a = storage.attributes(at: p.location, effectiveRange: nil)
            return RichBridge.tableBlock(of: a) == nil && RichBridge.kind(of: a) != .rule
        }
        guard !paragraphs.isEmpty else {
            NSSound.beep()
            return
        }
        let selection = selectedRange()
        var shift = 0
        var lastTarget = RichKind.body
        // 从后往前处理，前面段落的位置不受影响
        for p in paragraphs.reversed() {
            let old = RichBridge.kind(of: storage.attributes(at: p.location, effectiveRange: nil))
            if p == paragraphs.last { lastTarget = map(old) }
            let delta = restyle(p, to: map(old), from: old)
            // 光标在段首时，段首新插入的待办方框也算在光标前面（输入的文字在方框之后）
            if p.location < selection.location || (delta > 0 && p.location == selection.location) { shift += delta }
        }
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: max(0, min(selection.location + shift, length)),
                                 length: max(0, min(selection.length, length - min(selection.location + shift, length)))))
        // 文末的空待办去掉方框后变成空段落，没有文字可以带样式，之后输入的文字直接用新样式
        if selectedRange().location == length, paragraphRange(at: length).length == 0 {
            typingAttributes = RichStyle.typingAttributes(for: lastTarget)
        }
        refreshTypingAttributes()
    }

    /// 光标所在段落还没有文字时，之后输入的文字使用这个段落的样式。
    /// 否则在文档中间回车后，新段落的文字会沿用上一段的样式（标题后回车仍是标题、折叠块标题后变粗体）。
    private func refreshTypingAttributes() {
        guard let storage = textStorage, selectedRange().length == 0 else { return }
        let para = paragraphRange(at: selectedRange().location)
        guard para.length > 0, para.location < storage.length else { return }
        let content = (string as NSString).substring(with: para)
            .replacingOccurrences(of: RichStyle.taskTodo, with: "")
            .replacingOccurrences(of: RichStyle.taskDone, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty else { return }
        let a = storage.attributes(at: para.location, effectiveRange: nil)
        var t = RichStyle.typingAttributes(for: RichBridge.kind(of: a))
        t[.paragraphStyle] = a[.paragraphStyle]
        if a[DMKey.inDetails] != nil { t[DMKey.inDetails] = true }
        typingAttributes = t
    }

    /// 修改一个段落的样式，返回段落开头插入（正数）或删除（负数）的字符数
    @discardableResult
    private func restyle(_ para: NSRange, to target: RichKind, from oldKind: RichKind) -> Int {
        guard let storage = textStorage, para.length > 0 else { return 0 }
        let start = para.location
        var delta = 0
        // 1. 待办方框
        let ns = storage.string as NSString
        let first = ns.substring(with: NSRange(location: start, length: 1))
        let hasBox = first == RichStyle.taskTodo || first == RichStyle.taskDone
        if case .task(_, let done) = target {
            let want = done ? RichStyle.taskDone : RichStyle.taskTodo
            if !hasBox {
                let box = want + " "
                let r = NSRange(location: start, length: 0)
                if shouldChangeText(in: r, replacementString: box) {
                    storage.replaceCharacters(in: r, with: box)
                    didChangeText()
                    delta = (box as NSString).length
                }
            } else if first != want {
                let r = NSRange(location: start, length: 1)
                if shouldChangeText(in: r, replacementString: want) {
                    storage.replaceCharacters(in: r, with: want)
                    didChangeText()
                }
            }
        } else if hasBox {
            let hasSpace = para.length > 1 && ns.substring(with: NSRange(location: start + 1, length: 1)) == " "
            let r = NSRange(location: start, length: hasSpace ? 2 : 1)
            if shouldChangeText(in: r, replacementString: "") {
                storage.replaceCharacters(in: r, with: "")
                didChangeText()
                delta = -r.length
            }
        }
        // 2. 属性
        let range = paragraphRange(at: start)
        guard range.length > 0 else { return delta }
        let inDetails = storage.attribute(DMKey.inDetails, at: range.location, effectiveRange: nil) != nil
        let style = RichStyle.paragraphStyle(target, inDetails: inDetails && target != .summary)
        changeAttributes(in: range) { old in
            var a = old
            for k in DMKey.paragraphKeys { a[k] = nil }
            a[.paragraphStyle] = style
            if target == .summary { a[DMKey.inDetails] = nil }
            let inline = a[DMKey.inlineCode] != nil || a[DMKey.kbd] != nil
            if !inline { a[.backgroundColor] = a[DMKey.highlight] != nil ? RichStyle.highlightBackground : nil }
            if a[DMKey.link] == nil && a[DMKey.literal] == nil { a[.foregroundColor] = RichStyle.bodyColor }
            if a[.attachment] == nil && !inline && a[DMKey.kbd] == nil {
                var bold = RichStyle.isBold(a[.font] as? NSFont)
                if target.isHeading {
                    bold = true
                } else if oldKind.isHeading || oldKind == .summary || target.isMonospaced || oldKind.isMonospaced {
                    bold = false
                }
                let font = RichStyle.setBold(RichStyle.baseFont(for: target), bold)
                a[.font] = ((a[.superscript] as? Int) ?? 0) != 0 ? RichStyle.scaled(font, 0.75) : font
            }
            for (k, v) in RichStyle.marks(for: target) { a[k] = v }
            return a
        }
        return delta
    }

    // MARK: - 插入

    /// 在当前段落之后插入整块内容（表格、分隔线）；当前段落为空时插在它的位置
    private func insertBlock(_ block: NSAttributedString, caretOffset: Int) {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let para = paragraphRange(at: selectedRange().location)
        let text = ns.substring(with: para)
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && RichBridge.tableBlock(of: paragraphAttributes(para)) == nil
        let at = isEmpty ? para.location : NSMaxRange(para)
        let s = NSMutableAttributedString()
        if !isEmpty, !text.hasSuffix("\n"), !text.hasSuffix("\u{2029}") {
            s.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: para.location, effectiveRange: nil)))
        }
        let blockStart = s.length
        s.append(block)
        if at >= ns.length {
            s.append(RichBridge.paragraph(NSAttributedString(), kind: .body))   // 让光标能移到块之后
        }
        replace(NSRange(location: at, length: 0), with: s, caret: at + blockStart + caretOffset)
        typingAttributes = paragraphAttributes(paragraphRange(at: selectedRange().location))
    }

    func insertTable(rows: Int = 3, columns: Int = 3) {
        let table = RichBridge.makeTable(columns: columns)
        let s = NSMutableAttributedString()
        for r in 0..<rows {
            for c in 0..<columns {
                let runs = r == 0 ? [MDRun(text: "标题 \(c + 1)")] : []
                s.append(RichBridge.cellParagraph(table: table, row: r, column: c, runs: runs, baseURL: baseURL))
            }
        }
        insertBlock(s, caretOffset: 0)
    }

    func insertRule() {
        let rule = RichBridge.paragraph(RichBridge.ruleAttachment(), kind: .rule)
        insertBlock(rule, caretOffset: rule.length)
    }

    /// 插入折叠块：标题 + 内容
    func insertDetails() {
        let s = NSMutableAttributedString()
        let title = "点击展开"
        s.append(RichBridge.paragraph(NSAttributedString(string: title, attributes: RichStyle.attributes(for: MDRun(), kind: .summary)),
                                      kind: .summary))
        let body = NSMutableAttributedString(attributedString: RichBridge.paragraph(
            NSAttributedString(string: "折叠的内容", attributes: RichStyle.attributes(for: MDRun(), kind: .body)), kind: .body))
        RichBridge.markInDetails(body)
        s.append(body)
        insertBlock(s, caretOffset: 0)
        setSelectedRange(NSRange(location: selectedRange().location, length: (title as NSString).length))
    }

    /// 把光标所在段落放入（或移出）折叠块
    private func setInDetails(_ on: Bool) {
        let para = paragraphRange(at: selectedRange().location)
        let kind = RichBridge.kind(of: paragraphAttributes(para))
        let style = RichStyle.paragraphStyle(kind, inDetails: on)
        guard para.length > 0 else {
            typingAttributes[DMKey.inDetails] = on ? true : nil
            typingAttributes[.paragraphStyle] = style
            return
        }
        changeAttributes(in: para) { old in
            var a = old
            a[DMKey.inDetails] = on ? true : nil
            if RichBridge.tableBlock(of: a) == nil { a[.paragraphStyle] = style }
            return a
        }
        typingAttributes = paragraphAttributes(paragraphRange(at: selectedRange().location))
    }

    /// 提示框：引用的第一行是 [!NOTE] 等，第二行是内容（选中，直接输入即可替换）
    func insertCallout(_ type: MDCallout) {
        var header = MDRun(text: type.header)
        header.literal = true
        let s = NSMutableAttributedString()
        s.append(RichBridge.paragraph(RichBridge.runsString([header], kind: .quote, baseURL: baseURL), kind: .quote))
        s.append(RichBridge.paragraph(RichBridge.runsString([MDRun(text: "内容")], kind: .quote, baseURL: baseURL), kind: .quote))
        insertBlock(s, caretOffset: (type.header as NSString).length + 1)
        setSelectedRange(NSRange(location: selectedRange().location, length: 2))
    }

    /// 公式块：$$ 公式 $$，原样保存
    func insertMathBlock(_ formula: String) {
        let p = RichBridge.paragraph(RichBridge.runsString([MDRun(text: "$$ \(formula) $$")], kind: .raw, baseURL: baseURL),
                                     kind: .raw)
        insertBlock(p, caretOffset: p.length)
    }

    /// 脚注：光标处插入 [^n]，文末添加“[^n]: 说明”
    func insertFootnote(label: String, note: String) {
        guard let storage = textStorage else { return }
        var ref = MDRun(text: "[^\(label)]")
        ref.literal = true
        let caret = selectedRange()
        let refString = RichBridge.runsString([ref], kind: .body, baseURL: baseURL)
        replace(caret, with: refString)
        let afterRef = selectedRange().location
        let s = NSMutableAttributedString()
        if storage.length > 0 && !string.hasSuffix("\n") {
            s.append(NSAttributedString(string: "\n", attributes: RichStyle.attributes(for: MDRun(), kind: .body)))
        }
        s.append(RichBridge.paragraph(RichBridge.runsString([ref, MDRun(text: ": \(note)")], kind: .body, baseURL: baseURL),
                                      kind: .body))
        replace(NSRange(location: storage.length, length: 0), with: s, caret: afterRef)
    }

    func insertImage(path: String, alt: String) {
        replace(selectedRange(), with: RichBridge.imageString(path: path, alt: alt, baseURL: baseURL))
    }

    // MARK: - 表格中移动

    private func cell(at location: Int) -> NSTextTableBlock? {
        guard let storage = textStorage, location < storage.length else { return nil }
        return RichBridge.tableBlock(of: storage.attributes(at: location, effectiveRange: nil))
    }

    /// 光标在表格中时移到下一格 / 上一格，返回是否处理
    private func moveCell(forward: Bool) -> Bool {
        let para = paragraphRange(at: selectedRange().location)
        guard para.length > 0, let current = cell(at: para.location) else { return false }
        if forward {
            let next = NSMaxRange(para)
            if let n = cell(at: next), n.table === current.table {
                setSelectedRange(NSRange(location: next, length: 0))
                scrollRangeToVisible(selectedRange())
                refreshTypingAttributes()
                return true
            }
            // 最后一格：在表格末尾新增一行
            let row = NSMutableAttributedString()
            for c in 0..<current.table.numberOfColumns {
                row.append(RichBridge.cellParagraph(table: current.table, row: current.startingRow + 1, column: c,
                                                    runs: [], baseURL: baseURL))
            }
            replace(NSRange(location: next, length: 0), with: row, caret: next)
            refreshTypingAttributes()
        } else if para.location > 0 {
            let prev = paragraphRange(at: para.location - 1)
            if let p = cell(at: prev.location), p.table === current.table {
                setSelectedRange(NSRange(location: prev.location, length: 0))
            }
        }
        return true
    }

    // MARK: - 键盘

    override func insertNewline(_ sender: Any?) {
        let para = paragraphRange(at: selectedRange().location)
        let attrs = paragraphAttributes(para)
        // 表格中回车移到下一格（每个单元格只能有一个段落）
        if RichBridge.tableBlock(of: attrs) != nil, moveCell(forward: true) { return }
        let kind = RichBridge.kind(of: attrs)
        let content = (string as NSString).substring(with: para)
            .replacingOccurrences(of: RichStyle.taskTodo, with: "")
            .replacingOccurrences(of: RichStyle.taskDone, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 在空的列表项、引用中再按回车：结束列表（与 Word 相同）
        if (kind.isList || kind == .quote) && content.isEmpty {
            applyKinds { _ in .body }
            return
        }
        // 折叠块标题末尾回车：后面已有空的内容段落时直接移过去，不再多插一个空行
        if kind == .summary, selectedRange().location == NSMaxRange(para) - 1, NSMaxRange(para) < (string as NSString).length {
            let next = paragraphRange(at: NSMaxRange(para))
            let nextAttrs = paragraphAttributes(next)
            let nextText = (string as NSString).substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
            if nextAttrs[DMKey.inDetails] != nil, nextText.isEmpty {
                setSelectedRange(NSRange(location: next.location, length: 0))
                refreshTypingAttributes()
                return
            }
        }
        // 折叠块内容中的空行再按回车：离开折叠块
        if kind == .body && content.isEmpty && attrs[DMKey.inDetails] != nil {
            setInDetails(false)
            return
        }
        super.insertNewline(sender)
        switch kind {
        case .summary:
            // 标题之后是折叠的内容
            applyKinds { _ in .body }
            setInDetails(true)
        case .heading, .rule, .raw:
            applyKinds { _ in .body }
        case .task(let d, _):
            applyKinds { _ in .task(d, false) }
        default:
            break
        }
    }

    override func insertTab(_ sender: Any?) {
        if moveCell(forward: true) { return }
        if currentKind.isList {
            changeDepth(1)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if moveCell(forward: false) { return }
        if currentKind.isList {
            changeDepth(-1)
            return
        }
        super.insertBacktab(sender)
    }

    /// 在列表项、待办、引用的开头按退格：先减少缩进 / 变回正文（与 Notion、Word 相同），再按一次才与上一段合并
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0 {
            let para = paragraphRange(at: sel.location)
            let kind = currentKind
            // 待办的开头是“☐ ”两个字符，光标在方框后面也算段首
            let start = { if case .task = kind { return para.location + 2 } else { return para.location } }()
            if sel.location <= start, para.length > 0, kind.isList || kind == .quote {
                if kind.depth > 0 { changeDepth(-1) } else { applyKinds { _ in .body } }
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// 自动格式：在段首输入“- ”“1. ”“# ”“> ”“[] ”后按空格，自动转换为对应样式
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s == " ", selectedRange().length == 0, autoFormat() { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    private static let fullWidthMarks: [Character: Character] = [
        "－": "-", "—": "-", "＊": "*", "＋": "+", "》": ">", "＞": ">", "【": "[", "】": "]", "［": "[", "］": "]",
        "＃": "#", "。": ".", "．": ".", "ｘ": "x", "Ｘ": "X", "　": " ",
    ]

    private func autoFormat() -> Bool {
        guard let storage = textStorage else { return false }
        let caret = selectedRange().location
        let para = paragraphRange(at: caret)
        guard caret > para.location, caret - para.location <= 7 else { return false }
        let attrs = paragraphAttributes(para)
        guard RichBridge.kind(of: attrs) == .body, RichBridge.tableBlock(of: attrs) == nil else { return false }
        // 中文输入法会把符号换成全角（》【】。＃等），先换回半角再判断
        let prefix = String((self.string as NSString).substring(with: NSRange(location: para.location, length: caret - para.location))
            .map { Self.fullWidthMarks[$0] ?? $0 })
        let target: RichKind
        switch prefix {
        case "-", "*", "+", "•", "·": target = .bullet(0)
        case ">": target = .quote
        case "[]", "[ ]": target = .task(0, false)
        case "[x]", "[X]": target = .task(0, true)
        default:
            if prefix.allSatisfy({ $0 == "#" }) && prefix.count <= 6 {
                target = .heading(prefix.count)
            } else if prefix.count > 1, prefix.hasSuffix("."), prefix.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
                target = .ordered(0)
            } else {
                return false
            }
        }
        let r = NSRange(location: para.location, length: caret - para.location)
        guard shouldChangeText(in: r, replacementString: "") else { return false }
        storage.replaceCharacters(in: r, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: para.location, length: 0))
        applyKinds { _ in target }
        return true
    }

    // MARK: - 鼠标：点击方框勾选 / 取消勾选待办

    override func mouseDown(with event: NSEvent) {
        if let storage = textStorage, storage.length > 0 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if index < storage.length {
                let para = paragraphRange(at: index)
                let ns = string as NSString
                if para.length > 0, index <= para.location + 1,
                   case .task(let d, let done) = RichBridge.kind(of: storage.attributes(at: para.location, effectiveRange: nil)) {
                    let box = ns.substring(with: NSRange(location: para.location, length: 1))
                    if box == RichStyle.taskTodo || box == RichStyle.taskDone {
                        setSelectedRange(NSRange(location: para.location, length: 0))
                        applyKinds { _ in .task(d, !done) }
                        setSelectedRange(NSRange(location: min(para.location + 2, (string as NSString).length), length: 0))
                        return
                    }
                }
            }
        }
        super.mouseDown(with: event)
    }
}
