import AppKit

/// 在列表段落的缩进区画出项目符号和编号（它们不属于正文，不会写入文件）；隐藏收起的折叠块内容
final class RichLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private static let bullets = ["•", "◦", "▪"]

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    // MARK: 收起的折叠块：内容不生成字形、行高为 0（文字仍在，保存不受影响）

    /// 收起的折叠块中的内容（缓存；文字或属性改变后重新计算）
    var hiddenRanges: [NSRange] {
        if let c = hiddenCache { return c }
        let c = collapsedRanges()
        hiddenCache = c
        return c
    }
    private var hiddenCache: [NSRange]?

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        let before = hiddenCache ?? []
        hiddenCache = nil
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)
        // 改到了表格里的字：整张表格重新排。否则只重排正在改的那一格，同一行别的格子高度不跟着变，线会断开
        if editMask.contains(.editedCharacters), let table = tableRange(around: newCharRange, in: textStorage) {
            invalidateLayout(forCharacterRange: table, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: table)
        }
        let now = hiddenRanges
        guard now != before else { return }
        // 收起、展开，或折叠块被编辑：前后两次隐藏的内容都重新排版
        let all = NSRange(location: 0, length: textStorage.length)
        for r in before + now {
            let c = NSIntersectionRange(r, all)
            if c.length > 0 {
                invalidateGlyphs(forCharacterRange: c, changeInLength: 0, actualCharacterRange: nil)
                invalidateLayout(forCharacterRange: c, actualCharacterRange: nil)
            }
        }
    }

    /// 包含这段文字的整张表格（同一个 NSTextTable 的所有格子）；不在表格里时为 nil
    func tableRange(around range: NSRange, in storage: NSTextStorage) -> NSRange? {
        guard storage.length > 0 else { return nil }
        let at = min(range.location, storage.length - 1)
        func table(_ i: Int) -> NSTextTable? {
            ((storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)?.table
        }
        guard let t = table(at) else { return nil }
        // 一段一段跳着找（同一段的格式相同），不用一个字一个字查
        let ns = storage.string as NSString
        var range = ns.paragraphRange(for: NSRange(location: at, length: 0))
        while range.location > 0, table(range.location - 1) === t {
            range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0)))
        }
        while NSMaxRange(range) < storage.length, table(NSMaxRange(range)) === t {
            range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        return range
    }

    /// 标题之后、连续的折叠块内容段落
    private func collapsedRanges() -> [NSRange] {
        guard let s = textStorage, s.length > 0 else { return [] }
        let ns = s.string as NSString
        var out: [NSRange] = []
        s.enumerateAttribute(DMKey.collapsed, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            // 以标题段落第一个字的属性为准（与段落样式相同）
            let para = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            guard value != nil, para.location == range.location,
                  s.attribute(DMKey.summary, at: range.location, effectiveRange: nil) != nil else { return }
            let start = NSMaxRange(para)
            guard start < s.length else { return }
            var body = NSRange()
            let rest = NSRange(location: start, length: s.length - start)
            if s.attribute(DMKey.inDetails, at: start, longestEffectiveRange: &body, in: rest) != nil { out.append(body) }
        }
        return out
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let hidden = hiddenRanges
        guard let storage = textStorage else { return 0 }
        let ns = storage.string as NSString
        var newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length {
            let c = charIndexes[i]
            // 换行符保留：隐藏的段落仍各占一行（行高为 0），不会并到标题那一行，点击标题行末尾也不会进入隐藏的内容
            if ns.character(at: c) != 0x0A && hidden.contains(where: { NSLocationInRange(c, $0) }) {
                newProps[i] = .null
                changed = true
            } else if isTaskBox(c, in: storage) {
                // 待办方框不画字（☐ 比文字小），由 drawGlyphs 画成方框；宽度见 boundingBoxForControlGlyphAt
                newProps[i] = .controlCharacter
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// 待办段落开头的 ☐ / ☑
    private func isTaskBox(_ i: Int, in storage: NSTextStorage) -> Bool {
        let ns = storage.string as NSString
        let ch = ns.character(at: i)
        guard ch == 0x2610 || ch == 0x2611, i == 0 || ns.character(at: i - 1) == 0x0A else { return false }
        return storage.attribute(DMKey.task, at: i, effectiveRange: nil) != nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, isTaskBox(charIndex, in: storage) else { return action }
        return .whitespace
    }

    /// 方框连同后面的空格正好占一格缩进：待办的文字和圆点列表的文字对齐
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let font = (textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? RichStyle.baseFont(for: .body)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: glyphPosition.x, y: 0, width: max(RichStyle.indent - space, 0), height: font.ascender - font.descender)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.length > 0, hiddenRanges.contains(where: { NSIntersectionRange($0, chars) == chars }) else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let hidden = hiddenRanges
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            guard para.length > 0 else { break }
            if hidden.contains(where: { NSLocationInRange(para.location, $0) }) { continue }
            let attrs = storage.attributes(at: para.location, effectiveRange: nil)
            let inDetails = attrs[DMKey.inDetails] != nil
            let shift = inDetails ? RichStyle.detailsIndent : 0
            // 下一段也是引用 / 折叠块内容时，竖线延伸到下一段，连成一条
            let nextHidden = hidden.contains(where: { NSLocationInRange(loc, $0) })
            let next = loc < ns.length && !nextHidden ? storage.attributes(at: loc, effectiveRange: nil) : [:]
            if inDetails { drawBar(para, origin: origin, x: 7, color: RichStyle.lineColor, joinsNext: next[DMKey.inDetails] != nil) }
            let kind = RichBridge.kind(of: attrs)
            if kind == .quote {
                // 下一段是提示框的标题行时是新的引用块，不连在一起
                let nextStartsCallout = next[DMKey.callout] != nil
                // 提示框的竖线用它的颜色（与双页预览、GitHub 相同），普通引用是灰色
                let color = callout(at: para.location, in: storage).map(RichStyle.calloutColor) ?? .tertiaryLabelColor
                drawBar(para, origin: origin, x: shift + 4, color: color,
                        joinsNext: RichBridge.kind(of: next) == .quote && !nextStartsCallout)
            }
            if kind == .rule { drawRule(para, origin: origin, shift: shift) }
            let marker: String
            let depth: Int
            switch kind {
            case .summary:
                marker = attrs[DMKey.collapsed] != nil ? "▸" : "▾"
                depth = 0
            case .bullet(let d):
                marker = Self.bullets[d % Self.bullets.count]
                depth = d
            case .ordered(let d):
                marker = "\(number(at: para.location, depth: d, in: storage))."
                depth = d
            case .task(let d, _):
                if isTaskBox(para.location, in: storage) { drawTaskBox(at: para.location, depth: d, shift: shift, origin: origin) }
                continue
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

    /// 待办方框：和文字差不多高的圆角方框，完成时蓝底白勾（参考 Notion），位置和圆点列表的圆点对齐
    private func drawTaskBox(at index: Int, depth: Int, shift: CGFloat, origin: NSPoint) {
        guard let storage = textStorage else { return }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? RichStyle.baseFont(for: .body)
        let side = (font.pointSize * 0.875).rounded()
        let right = origin.x + line.minX + shift + CGFloat(depth + 1) * RichStyle.indent - 6
        let midY = origin.y + line.minY + location(forGlyphAt: glyph).y - font.capHeight / 2
        let box = NSRect(x: right - side, y: midY - side / 2, width: side, height: side)
        if (storage.string as NSString).character(at: index) == 0x2611 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
            tick.line(to: NSPoint(x: box.minX + side * 0.42, y: box.minY + side * 0.72))
            tick.line(to: NSPoint(x: box.minX + side * 0.77, y: box.minY + side * 0.30))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
    }

    /// 代码块：连续的代码段落画成一整块圆角底色（不按行画，避免一条条的横条）
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawCodeBlocks(glyphsToShow, origin: origin)
        drawCallouts(glyphsToShow, origin: origin)
        // 收起的内容不画背景：隐藏的表格边框会缩成一个小方块画在左上角
        var start = glyphsToShow.location
        for hidden in hiddenRanges.map({ glyphRange(forCharacterRange: $0, actualCharacterRange: nil) }).sorted(by: { $0.location < $1.location })
        where NSMaxRange(hidden) > start && hidden.location < NSMaxRange(glyphsToShow) {
            if hidden.location > start { super.drawBackground(forGlyphRange: NSRange(location: start, length: hidden.location - start), at: origin) }
            start = NSMaxRange(hidden)
        }
        if start < NSMaxRange(glyphsToShow) {
            super.drawBackground(forGlyphRange: NSRange(location: start, length: NSMaxRange(glyphsToShow) - start), at: origin)
        }
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
        let attrs = storage.attributes(at: location, effectiveRange: nil)
        if attrs[DMKey.math] != nil { return false }   // 公式块显示为公式，不画代码底色
        switch RichBridge.kind(of: attrs) {
        case .code, .raw: return true
        default: return false
        }
    }

    /// 包含这个位置的整个代码块（连续的代码段落）；不是代码时为 nil
    func codeBlock(at location: Int) -> NSRange? {
        guard let storage = textStorage, location < storage.length, isCodeParagraph(at: location, in: storage) else { return nil }
        let ns = storage.string as NSString
        var block = ns.paragraphRange(for: NSRange(location: location, length: 0))
        guard !hiddenRanges.contains(where: { NSLocationInRange(block.location, $0) }) else { return nil }
        // 只连同一类的段落：代码连代码，原文（YAML 信息、HTML）连原文，折叠块里外不连
        func group(_ at: Int) -> String {
            let a = storage.attributes(at: at, effectiveRange: nil)
            return "\(a[DMKey.raw] != nil)\(a[DMKey.inDetails] != nil)"
        }
        let mine = group(location)
        func same(_ at: Int) -> Bool { isCodeParagraph(at: at, in: storage) && group(at) == mine }
        while block.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: block.location - 1, length: 0))
            guard same(prev.location) else { break }
            block = NSUnionRange(prev, block)
        }
        while NSMaxRange(block) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0))
            guard same(next.location) else { break }
            block = NSUnionRange(block, next)
        }
        return block
    }

    /// 代码块底色的位置（文字容器的坐标）
    func codeBlockRect(_ block: NSRange) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        // 用实际占用的高度：行框里还含有代码块前后多留的空（codeEdgeSpacing），底色不画进去
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let top = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        let last = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let pad = container.lineFragmentPadding
        // 折叠块里、列表项里的代码块整体右移：按段落缩进算（代码块本身的内边距是 RichStyle.codePadding）
        let style = storage.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle
        let shift = max(0, (style?.headIndent ?? RichStyle.codePadding) - RichStyle.codePadding)
        return NSRect(x: first.minX + pad + shift, y: top - 10, width: first.width - pad * 2 - shift, height: last.maxY - top + 20)
    }

    /// 代码块：连续的代码段落画成一整块圆角底色（不按行画，避免一条条的横条）
    private func drawCodeBlocks(_ glyphsToShow: NSRange, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            guard let block = codeBlock(at: loc) else {
                loc = NSMaxRange(ns.paragraphRange(for: NSRange(location: loc, length: 0)))
                continue
            }
            loc = NSMaxRange(block)
            guard let rect = codeBlockRect(block)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            RichStyle.codeBlockBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    /// 提示框：整块画一层淡淡的底色（与双页预览相同），右边是圆角
    private func drawCallouts(_ glyphsToShow: NSRange, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let hidden = hiddenRanges
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        // 从屏幕上第一段所在的提示框开头算起，否则往下滚时提示框上半截不画
        while loc > 0, RichBridge.kind(of: storage.attributes(at: loc, effectiveRange: nil)) == .quote,
              storage.attribute(DMKey.callout, at: loc, effectiveRange: nil) == nil {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard RichBridge.kind(of: storage.attributes(at: prev.location, effectiveRange: nil)) == .quote else { break }
            loc = prev.location
        }
        while loc < NSMaxRange(chars) && loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            guard let header = storage.attribute(DMKey.callout, at: para.location, effectiveRange: nil) as? String,
                  let type = MDCallout(header: header),
                  !hidden.contains(where: { NSLocationInRange(para.location, $0) }) else { continue }
            // 提示框到下一个不是引用的段落、或下一个提示框标题为止
            var block = para
            while NSMaxRange(block) < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0))
                let a = storage.attributes(at: next.location, effectiveRange: nil)
                guard RichBridge.kind(of: a) == .quote, a[DMKey.callout] == nil,
                      !hidden.contains(where: { NSLocationInRange(next.location, $0) }) else { break }
                block = NSUnionRange(block, next)
            }
            loc = NSMaxRange(block)
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            guard glyphs.length > 0, let container = textContainers.first else { continue }
            let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let top = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
            let bottom = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY
            let shift = storage.attribute(DMKey.inDetails, at: para.location, effectiveRange: nil) != nil ? RichStyle.detailsIndent : 0
            let x = origin.x + first.minX + shift + 4
            let rect = NSRect(x: x, y: origin.y + top - 4, width: origin.x + first.maxX - container.lineFragmentPadding - x,
                              height: bottom - top + 8)
            RichStyle.calloutColor(type).withAlphaComponent(0.08).setFill()
            let path = NSBezierPath()
            let r: CGFloat = 6
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
            path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + r), controlPoint1: NSPoint(x: rect.maxX, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
            path.curve(to: NSPoint(x: rect.maxX - r, y: rect.maxY), controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY), controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.close()
            path.fill()
        }
    }

    /// 引用段落属于哪种提示框：向前找到这个引用块的第一段，看它是不是提示框标题行
    func callout(at location: Int, in storage: NSTextStorage) -> MDCallout? {
        let ns = storage.string as NSString
        var para = ns.paragraphRange(for: NSRange(location: location, length: 0))
        while true {
            if let header = storage.attribute(DMKey.callout, at: para.location, effectiveRange: nil) as? String {
                return MDCallout(header: header)
            }
            guard para.location > 0 else { return nil }
            let prev = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
            guard RichBridge.kind(of: storage.attributes(at: prev.location, effectiveRange: nil)) == .quote else { return nil }
            para = prev
        }
    }

    /// 代码块前后多留一点空（代码块里各行的段间距是 0，否则底色会断开），免得和上下的文字、提示框贴在一起
    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        codeEdgeSpacing(glyphIndex, after: true)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        codeEdgeSpacing(glyphIndex, after: false)
    }

    /// 系统调用这两个方法时，返回值代替段落样式里的段前 / 段后间距，所以先取段落样式的值，再给代码块、引用和提示框前后加上多留的空
    private func codeEdgeSpacing(_ glyphIndex: Int, after: Bool) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        let ns = storage.string as NSString
        let char = min(characterIndexForGlyph(at: glyphIndex), storage.length - 1)
        let para = ns.paragraphRange(for: NSRange(location: char, length: 0))
        // 段后间距只在段落最后一行之后，段前间距只在第一行之前
        guard after ? char >= NSMaxRange(para) - 1 : char == para.location else { return 0 }
        let attrs = storage.attributes(at: para.location, effectiveRange: nil)
        let style = attrs[.paragraphStyle] as? NSParagraphStyle
        // 系统在文档开头不加段前间距
        let base = (after ? style?.paragraphSpacing : para.location == 0 ? 0 : style?.paragraphSpacingBefore) ?? 0
        guard RichBridge.tableBlock(of: attrs) == nil else { return base }   // 表格里的格子不加
        // 相邻的段落（after 时是下一段，否则是上一段）
        let neighbor: Int? = after ? (NSMaxRange(para) < ns.length ? NSMaxRange(para) : nil)
                                   : (para.location > 0 ? ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0)).location : nil)
        guard let neighbor else { return base }
        let other = storage.attributes(at: neighbor, effectiveRange: nil)
        let kind = RichBridge.kind(of: attrs)
        var extra: CGFloat = 0
        // 表格前后：表格上面留一点，下面留得和代码块一样多（表格后的文字不贴着表格）
        if RichBridge.tableBlock(of: other) != nil { extra = after ? 6 : 14 }
        // 列表结束后：列表项之间比较紧，整个列表结束时补足一段正常的空
        if after, kind.isList, !RichBridge.kind(of: other).isList { extra = max(extra, 6) }
        // 折叠块（收起或展开）后面的文字
        if !after, attrs[DMKey.inDetails] == nil, attrs[DMKey.summary] == nil,
           other[DMKey.inDetails] != nil || other[DMKey.summary] != nil { extra = max(extra, 10) }
        // 代码块、引用 / 提示框：整块前后多留空（块里各行之间不加，否则底色会断开）
        let isCode = isCodeParagraph(at: para.location, in: storage)
        if isCode || kind == .quote {
            let same: Bool
            if isCode {
                same = isCodeParagraph(at: neighbor, in: storage)
            } else {
                // 提示框标题行开始新的一块
                same = RichBridge.kind(of: other) == .quote && (after ? other[DMKey.callout] == nil : attrs[DMKey.callout] == nil)
            }
            if !same { extra = max(extra, isCode ? (after ? 18 : 14) : 6) }
        }
        return base + extra
    }

    /// 段落左侧的竖线（引用、折叠块内容）
    private func drawBar(_ para: NSRange, origin: NSPoint, x: CGFloat, color: NSColor, joinsNext: Bool = false) {
        guard let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        var line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        // 与下一段相连时画到本段最后一行的底部（包括段后间距）
        var bottom = joinsNext ? lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY : rect.maxY
        // 表格单元格：竖线画在正文左边（不画进每个单元格），高度是整个单元格，各行连成一条
        if let storage = textStorage, let cell = RichBridge.tableBlock(of: storage.attributes(at: para.location, effectiveRange: nil)) {
            guard cell.startingColumn == 0 else { return }   // 每行只画一次（颜色半透明，叠画会变深）
            line.origin.x = 0
            rect = boundsRect(for: cell, glyphRange: glyphs)
            bottom = rect.maxY
        }
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
    func number(at location: Int, depth: Int, in storage: NSTextStorage) -> Int {
        let ns = storage.string as NSString
        var n = 1
        var loc = location
        // 列表不从 1 开始时（5. 五），第一项上记着起始编号
        if let start = storage.attribute(DMKey.start, at: location, effectiveRange: nil) as? Int { return start }
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            loc = prev.location
            let a = storage.attributes(at: prev.location, effectiveRange: nil)
            if a[DMKey.listCode] != nil { continue }   // 列表项里的代码块不打断编号
            switch RichBridge.kind(of: a) {
            case .ordered(let d) where d == depth:
                if let start = a[DMKey.start] as? Int { return start + n }
                n += 1
            case .ordered(let d) where d > depth: continue
            case .bullet(let d) where d > depth: continue
            case .task(let d, _) where d > depth: continue
            default: return n
            }
        }
        return n
    }
}
