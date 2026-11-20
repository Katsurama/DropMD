import AppKit

/// 在列表段落的缩进区画出项目符号和编号（它们不属于正文，不会写入文件）；隐藏收起的折叠块内容；
/// 提供仅用于显示的样式（代码块轻量语法高亮、已完成待办淡化与删除线、引用降噪）
final class RichLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private static let codeTypeRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$])[A-Z][A-Za-z0-9_]*\b"#)
    private static let codeNumberRegex = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let codeKeywordRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_$])(?:func|var|let|const|if|else|for|while|return|class|struct|enum|protocol|extension|import|from|def|async|await|try|catch|throw|throws|switch|case|default|guard|defer|break|continue|in|is|as|true|false|nil|null|None|self|Self|super|public|private|internal|static|final|mutating|override|type|interface|package|export|function|new|typeof|void|yield|with|lambda|pass|raise|except|finally|elif|do|match|pub|fn|impl|trait|mod|use|where|mut|ref)(?![A-Za-z0-9_$])"#)
    private static let codeStringOrCommentRegex = try! NSRegularExpression(
        pattern: #"(//[^\n]*|/\*[\s\S]*?\*/|(?:^[ \t]*|(?<=[ \t]))#(?=[ \t]|$)[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#,
        options: [.anchorsMatchLines])

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

    private var pendingStyleRange: NSRange?
    private var styleScheduled = false

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
        // 临时属性会触发显示失效和字形生成，必须等本轮 endEditing 完全结束后再应用
        scheduleDisplayStyles(for: newCharRange, delta: delta)
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

    private func scheduleDisplayStyles(for range: NSRange, delta: Int) {
        if let p = pendingStyleRange {
            let start = min(p.location, range.location)
            let end = max(NSMaxRange(p) + delta, NSMaxRange(range), start)
            pendingStyleRange = NSRange(location: start, length: end - start)
        } else {
            pendingStyleRange = range
        }
        guard !styleScheduled else { return }
        styleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.styleScheduled = false
            guard let range = self.pendingStyleRange else { return }
            self.pendingStyleRange = nil
            self.applyDisplayStyles(in: range)
        }
    }

    /// 刷新全篇纯显示态临时属性（用于打印视图等刚绑定 storage 的场景）
    func refreshAllDisplayStyles() {
        pendingStyleRange = nil
        guard let storage = textStorage, storage.length > 0 else { return }
        applyDisplayStyles(in: NSRange(location: 0, length: storage.length))
    }

    private func applyDisplayStyles(in rawRange: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let safeLoc = min(max(0, rawRange.location), ns.length - 1)
        let safeLen = min(max(0, rawRange.length), ns.length - safeLoc)
        var target = ns.paragraphRange(for: NSRange(location: safeLoc, length: safeLen))
        if case .code = RichBridge.kind(of: storage.attributes(at: target.location, effectiveRange: nil)),
           let b = codeBlock(at: target.location) {
            target = NSUnionRange(target, b)
        }
        let endLoc = max(target.location, NSMaxRange(target) - 1)
        if endLoc != target.location,
           case .code = RichBridge.kind(of: storage.attributes(at: endLoc, effectiveRange: nil)),
           let b = codeBlock(at: endLoc) {
            target = NSUnionRange(target, b)
        }
        removeTemporaryAttribute(.foregroundColor, forCharacterRange: target)
        removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: target)
        removeTemporaryAttribute(.strikethroughColor, forCharacterRange: target)

        var loc = target.location
        while loc < NSMaxRange(target) && loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            guard para.length > 0 else { break }
            let attrs = storage.attributes(at: para.location, effectiveRange: nil)
            switch RichBridge.kind(of: attrs) {
            case .task(_, true):
                var body = para
                if body.length > 0, ns.character(at: NSMaxRange(body) - 1) == 0x0A { body.length -= 1 }
                let prefix = isTaskBox(para.location, in: storage) ? 2 : 0
                if body.length > prefix {
                    let textRange = NSRange(location: body.location + prefix, length: body.length - prefix)
                    addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: textRange)
                    addTemporaryAttribute(.strikethroughColor, value: NSColor.tertiaryLabelColor, forCharacterRange: textRange)
                    storage.enumerateAttributes(in: textRange, options: []) { a, sub, _ in
                        if a[DMKey.link] == nil && a[DMKey.literal] == nil && a[DMKey.image] == nil {
                            addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: sub)
                        }
                    }
                }
            case .quote where callout(at: para.location, in: storage) == nil:
                storage.enumerateAttributes(in: para, options: []) { a, sub, _ in
                    if a[DMKey.link] == nil && a[DMKey.inlineCode] == nil && a[DMKey.literal] == nil
                        && a[DMKey.math] == nil && a[DMKey.image] == nil {
                        addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: sub)
                    }
                }
            case .code(let lang) where !lang.isEmpty:
                let block = codeBlock(at: para.location) ?? para
                loc = max(loc, NSMaxRange(block))
                highlightCodeBlock(block, in: ns)
            default:
                break
            }
        }
    }

    private func highlightCodeBlock(_ block: NSRange, in ns: NSString) {
        // shortcut: 超长代码块不做语法着色，避免编辑大文件卡顿
        guard block.length > 0, block.length <= 200_000 else { return }
        let text = ns.substring(with: block)
        let local = NSRange(location: 0, length: (text as NSString).length)
        func paint(_ re: NSRegularExpression, group: Int = 0, color: NSColor) {
            re.enumerateMatches(in: text, options: [], range: local) { m, _, _ in
                guard let m, group < m.numberOfRanges else { return }
                let r = m.range(at: group)
                guard r.location != NSNotFound, r.length > 0 else { return }
                addTemporaryAttribute(.foregroundColor, value: color,
                                      forCharacterRange: NSRange(location: block.location + r.location, length: r.length))
            }
        }
        paint(Self.codeTypeRegex, color: RichStyle.codeTypeColor)
        paint(Self.codeNumberRegex, color: RichStyle.codeNumberColor)
        paint(Self.codeKeywordRegex, color: RichStyle.codeKeywordColor)
        Self.codeStringOrCommentRegex.enumerateMatches(in: text, options: [], range: local) { m, _, _ in
            guard let m else { return }
            let comment = m.range(at: 1)
            if comment.location != NSNotFound, comment.length > 0 {
                addTemporaryAttribute(.foregroundColor, value: RichStyle.codeCommentColor,
                                      forCharacterRange: NSRange(location: block.location + comment.location, length: comment.length))
                return
            }
            let str = m.range(at: 2)
            if str.location != NSNotFound, str.length > 0 {
                addTemporaryAttribute(.foregroundColor, value: RichStyle.codeStringColor,
                                      forCharacterRange: NSRange(location: block.location + str.location, length: str.length))
            }
        }
        invalidateDisplay(forCharacterRange: block)
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
        let pad = textContainers.first?.lineFragmentPadding ?? 5
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(para)
            guard para.length > 0 else { break }
            if hidden.contains(where: { NSLocationInRange(para.location, $0) }) { continue }
            let attrs = storage.attributes(at: para.location, effectiveRange: nil)
            let inDetails = attrs[DMKey.inDetails] != nil
            let shift = inDetails ? RichStyle.detailsIndent : 0
            let nextHidden = hidden.contains(where: { NSLocationInRange(loc, $0) })
            let next = loc < ns.length && !nextHidden ? storage.attributes(at: loc, effectiveRange: nil) : [:]
            if inDetails {
                drawBar(para, origin: origin, x: 7, color: .separatorColor, joinsNext: next[DMKey.inDetails] != nil, width: 2)
            }
            let kind = RichBridge.kind(of: attrs)
            if kind == .quote {
                if callout(at: para.location, in: storage) == nil {
                    let nextStartsCallout = next[DMKey.callout] != nil
                    drawBar(para, origin: origin, x: shift + pad + 4, color: .separatorColor,
                            joinsNext: RichBridge.kind(of: next) == .quote && !nextStartsCallout, width: 2.5)
                } else if let header = attrs[DMKey.callout] as? String, let type = MDCallout(header: header) {
                    drawSymbol(RichStyle.calloutSymbol(type), pointSize: 13, weight: .semibold,
                               color: RichStyle.calloutColor(type), para: para, centerX: shift + pad + 15, origin: origin)
                }
            }
            if kind == .rule { drawRule(para, origin: origin, shift: shift) }
            switch kind {
            case .summary:
                let icon = attrs[DMKey.collapsed] != nil ? "chevron.right" : "chevron.down"
                drawSymbol(icon, pointSize: 11, weight: .semibold, color: .secondaryLabelColor,
                           para: para, centerX: pad + 10, origin: origin)
            case .bullet(let d):
                let glyph = glyphIndexForCharacter(at: para.location)
                guard glyph < numberOfGlyphs else { continue }
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let font = (attrs[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
                let right = origin.x + line.minX + shift + CGFloat(d + 1) * RichStyle.indent - 6
                let midY = origin.y + line.minY + location(forGlyphAt: glyph).y - font.capHeight / 2
                let cx = right - 4.5
                NSColor.secondaryLabelColor.setFill()
                NSColor.secondaryLabelColor.setStroke()
                switch d % 3 {
                case 0:
                    NSBezierPath(ovalIn: NSRect(x: cx - 2.5, y: midY - 2.5, width: 5, height: 5)).fill()
                case 1:
                    let ring = NSBezierPath(ovalIn: NSRect(x: cx - 2.5, y: midY - 2.5, width: 5, height: 5))
                    ring.lineWidth = 1.2
                    ring.stroke()
                default:
                    NSBezierPath(roundedRect: NSRect(x: cx - 2.25, y: midY - 2.25, width: 4.5, height: 4.5), xRadius: 1, yRadius: 1).fill()
                }
            case .ordered(let d):
                let glyph = glyphIndexForCharacter(at: para.location)
                guard glyph < numberOfGlyphs else { continue }
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = location(forGlyphAt: glyph).y
                let font = (attrs[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
                let numFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.94, weight: .regular)
                let marker = "\(number(at: para.location, depth: d, in: storage))."
                let markerAttrs: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: NSColor.secondaryLabelColor]
                let size = (marker as NSString).size(withAttributes: markerAttrs)
                let right = origin.x + line.minX + shift + CGFloat(d + 1) * RichStyle.indent - 6
                (marker as NSString).draw(at: NSPoint(x: right - size.width, y: origin.y + line.minY + baseline - numFont.ascender), withAttributes: markerAttrs)
            case .task(let d, _):
                if isTaskBox(para.location, in: storage) { drawTaskBox(at: para.location, depth: d, shift: shift, origin: origin) }
            default:
                continue
            }
        }
    }

    private func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor,
                            para: NSRange, centerX: CGFloat, origin: NSPoint) {
        let glyph = glyphIndexForCharacter(at: para.location)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = (textStorage?.attribute(.font, at: para.location, effectiveRange: nil) as? NSFont) ?? RichStyle.baseFont(for: .body)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let midY = origin.y + line.minY + location(forGlyphAt: glyph).y - font.capHeight / 2
        let size = img.size
        let rect = NSRect(x: origin.x + line.minX + centerX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

    /// 行内代码、键盘按键、高亮：按各自类型画圆角胶囊或立体键帽，选中文字等其他背景照旧。
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let container = textContainers.first,
              let own = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor,
              own == color else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        let attrs = storage.attributes(at: charRange.location, effectiveRange: nil)
        let font = (attrs[.font] as? NSFont) ?? RichStyle.baseFont(for: .body)
        let origin = container.textView?.textContainerOrigin ?? .zero
        let isKbd = attrs[DMKey.kbd] != nil
        let isInlineCode = attrs[DMKey.inlineCode] != nil
        let padX: CGFloat = isKbd ? 3 : isInlineCode ? 2.5 : 1.5
        let padY: CGFloat = (isKbd || isInlineCode) ? 2 : 1.5
        let radius: CGFloat = (isKbd || isInlineCode) ? 5 : 4
        for i in 0..<rectCount {
            let r = rectArray[i]
            let glyph = glyphIndex(for: NSPoint(x: r.midX - origin.x, y: r.midY - origin.y), in: container)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = origin.y + line.minY + location(forGlyphAt: glyph).y
            let box = NSRect(x: r.minX - padX, y: baseline - font.ascender - padY,
                             width: r.width + padX * 2, height: font.ascender - font.descender + padY * 2)
            let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            color.setFill()
            path.fill()
            if isKbd {
                RichStyle.kbdBorderColor.setStroke()
                path.lineWidth = 0.75
                path.stroke()
                let lip = NSBezierPath()
                lip.move(to: NSPoint(x: box.minX + 3.5, y: box.maxY - 0.5))
                lip.line(to: NSPoint(x: box.maxX - 3.5, y: box.maxY - 0.5))
                lip.lineWidth = 1.2
                lip.stroke()
            } else if isInlineCode {
                RichStyle.codeBlockBorderColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
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
        return NSRect(x: first.minX + pad + shift, y: top - 12, width: first.width - pad * 2 - shift, height: last.maxY - top + 24)
    }

    /// 代码块：连续的代码段落画成一整块圆角卡片，有语言名时在右上角标出
    private func drawCodeBlocks(_ glyphsToShow: NSRange, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let langAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var loc = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while loc < NSMaxRange(chars) && loc < ns.length {
            guard let block = codeBlock(at: loc) else {
                loc = NSMaxRange(ns.paragraphRange(for: NSRange(location: loc, length: 0)))
                continue
            }
            loc = NSMaxRange(block)
            guard let rect = codeBlockRect(block)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            RichStyle.codeBlockBackground.setFill()
            card.fill()
            RichStyle.codeBlockBorderColor.setStroke()
            card.lineWidth = 0.75
            card.stroke()
            if let lang = storage.attribute(DMKey.code, at: block.location, effectiveRange: nil) as? String, !lang.isEmpty {
                let size = (lang as NSString).size(withAttributes: langAttrs)
                if rect.width > size.width + 56 {
                    (lang as NSString).draw(at: NSPoint(x: rect.maxX - size.width - 42, y: rect.minY + 10), withAttributes: langAttrs)
                }
            }
        }
    }

    /// 提示框：Apple DocC Aside 风格全圆角卡片 + 左强调条 + 细边框
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
            let pad = container.lineFragmentPadding
            let rect = NSRect(x: origin.x + first.minX + shift + pad, y: origin.y + top - 10,
                              width: first.width - pad * 2 - shift, height: bottom - top + 20)
            let accent = RichStyle.calloutColor(type)
            let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.07).setFill()
            card.fill()
            NSGraphicsContext.saveGraphicsState()
            card.addClip()
            accent.withAlphaComponent(0.85).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 3.5, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            accent.withAlphaComponent(0.22).setStroke()
            card.lineWidth = 0.75
            card.stroke()
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
            if !same {
                if isCode {
                    extra = max(extra, after ? 18 : 16)
                } else if callout(at: para.location, in: storage) != nil {
                    extra = max(extra, after ? 14 : 12)
                } else {
                    extra = max(extra, 8)
                }
            }
        }
        return base + extra
    }

    /// 段落左侧的竖线（引用、折叠块内容）
    private func drawBar(_ para: NSRange, origin: NSPoint, x: CGFloat, color: NSColor, joinsNext: Bool = false, width: CGFloat = 2.5) {
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
        NSBezierPath(roundedRect: NSRect(x: origin.x + line.minX + x, y: origin.y + rect.minY, width: width, height: bottom - rect.minY),
                     xRadius: width / 2, yRadius: width / 2).fill()
    }

    /// 分隔线：横跨整个正文宽度
    private func drawRule(_ para: NSRange, origin: NSPoint, shift: CGFloat) {
        guard let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: para.location)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let pad = container.lineFragmentPadding
        let x = origin.x + line.minX + pad + shift
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: (origin.y + line.midY).rounded() - 0.5,
                                         width: max(0, origin.x + line.maxX - pad - x), height: 1),
                     xRadius: 0.5, yRadius: 0.5).fill()
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
