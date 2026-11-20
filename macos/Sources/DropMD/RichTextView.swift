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
            let font = a[DMKey.inlineCode] != nil ? NSFont.monospacedSystemFont(ofSize: RichStyle.inlineCodeSize, weight: .regular)
                : a[DMKey.kbd] != nil ? NSFont.monospacedSystemFont(ofSize: RichStyle.codeSize - 1, weight: .medium) : base
            a[.superscript] = on ? (self == .sup ? 1 : -1) : nil
            a[.font] = RichStyle.setBold(on ? RichStyle.scaled(font, 0.75) : font, bold)
        case .kbd:
            a[DMKey.kbd] = on ? true : nil
            a[.font] = on ? NSFont.monospacedSystemFont(ofSize: RichStyle.codeSize - 1, weight: .medium)
                          : RichStyle.baseFont(for: RichBridge.kind(of: a))
            a[.backgroundColor] = on ? RichStyle.kbdBackground : nil
        case .highlight:
            a[DMKey.highlight] = on ? true : nil
            if a[DMKey.inlineCode] == nil {
                a[.backgroundColor] = on ? RichStyle.highlightBackground : nil
            }
        }
        return a
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

    // 下面这些由各分文件的功能使用（扩展里不能放存储属性）
    /// 由编辑器窗口设置：执行菜单栏 / 工具栏的同一个命令
    var onAction: ((EditorAction) -> Void)?
    /// 由编辑器窗口设置：打开链接（和按住 ⌘ 点链接相同）
    var onOpenLink: ((Any) -> Void)?
    /// 按下右键前的选区：系统会先自动选中点到的词，那不算用户选的字
    var selectionBeforeMenu: NSRange?
    var expandingRedraw = false
    var columnDrag: ColumnDrag?

    // MARK: - 页面外观：整个编辑区同一底色，文字在居中的版心中

    private static let topMargin: CGFloat = 56
    private var marginObserver: NSObjectProtocol?

    /// 在“显示 → 页边距”或设置里改了页边距：马上重新排版
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard marginObserver == nil, window != nil else { return }
        marginObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true; self?.needsDisplay = true; self?.updateBlink() }
        }
    }

    deinit {
        if let marginObserver { NotificationCenter.default.removeObserver(marginObserver) }
    }

    override func layout() {
        super.layout()
        let inset = NSSize(width: PageMargin.current.margin(for: bounds.width), height: Self.topMargin)
        if abs(textContainerInset.width - inset.width) > 0.5 || textContainerInset.height != inset.height {
            textContainerInset = inset
        }
        // 文字栏宽度变了（打开窗口、拉窗口、开关格式面板）：表格要重新排，否则还按旧宽度显示，要手动拉一下窗口才对
        let width = textContainer?.size.width ?? 0
        if abs(width - laidOutWidth) > 0.5, let storage = textStorage, storage.length > 0 {
            laidOutWidth = width
            var hasTable = false
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if ((value as? NSParagraphStyle)?.textBlocks.isEmpty == false) { hasTable = true; stop.pointee = true }
            }
            if hasTable {
                layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                needsDisplay = true
            }
        }
    }
    private var laidOutWidth: CGFloat = 0

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
        // 双页：标出左边原文光标的位置（设置里可关掉、可选样式）
        guard SourceMarkStyle.isOn else { return }
        switch SourceMarkStyle.current {
        case .box:
            if let box = markRect(), box.intersects(rect.insetBy(dx: -10, dy: -10)) {
                let path = NSBezierPath(roundedRect: box.insetBy(dx: -8, dy: -4), xRadius: 6, yRadius: 6)
                RichStyle.markColor.withAlphaComponent(0.07).setFill()
                path.fill()
                RichStyle.markColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        case .bar:
            if let bar = markBarRect(), bar.intersects(rect) {
                RichStyle.markColor.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        case .caret:
            if caretBlinkOn, let caret = markCaretRect(), caret.intersects(rect) {
                RichStyle.markColor.setFill()
                caret.fill()
            }
        }
    }

    /// 双页：左边原文光标所在的那一段在这里的范围；右边自己在编辑时不画
    var sourceCursorRange: NSRange? {
        didSet { if sourceCursorRange != oldValue { needsDisplay = true } }
    }

    /// 双页：左边原文光标在这里大约对应的位置（“光标”样式用）
    var sourceCaretLocation: Int? {
        didSet {
            guard sourceCaretLocation != oldValue else { return }
            caretBlinkOn = true
            needsDisplay = true
            updateBlink()
        }
    }

    private var caretBlinkOn = true
    private var blinkTimer: Timer?

    /// “光标”样式时让标记闪烁（和系统光标一样快）；不需要时停掉
    private func updateBlink() {
        let need = sourceCaretLocation != nil && SourceMarkStyle.isOn && SourceMarkStyle.current == .caret
        if need, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }   // 窗口关了：定时器也停掉
                    guard let r = self.markCaretRect() else { return }
                    self.caretBlinkOn.toggle()
                    self.setNeedsDisplay(r.insetBy(dx: -2, dy: -2))
                }
            }
        } else if !need {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    /// 侧边线：画在文字栏左边的页边里，比引用、提示框的竖线和列表符号都靠左，不挡内容
    func markBarRect() -> NSRect? {
        guard let box = markRect() else { return nil }
        let x = max(4, textContainerOrigin.x - 14)
        return NSRect(x: x, y: box.minY, width: 3, height: box.height)
    }

    /// 光标：对应位置那个字前面的一条竖线，高度是那一行
    func markCaretRect() -> NSRect? {
        guard markRect() != nil, let loc = sourceCaretLocation, let lm = layoutManager, let tc = textContainer,
              let length = textStorage?.length, length > 0 else { return nil }
        let at = min(loc, length)
        let glyph = lm.glyphIndexForCharacter(at: min(at, length - 1))
        let line = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = lm.location(forGlyphAt: glyph).x + lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
        // 在最后一个字后面（段末）：放到那个字的右边
        if at >= length || (string as NSString).character(at: at) == 0x0A, at > 0 {
            let prev = lm.glyphIndexForCharacter(at: at - 1)
            let r = lm.boundingRect(forGlyphRange: NSRange(location: prev, length: 1), in: tc)
            if (string as NSString).character(at: at - 1) != 0x0A { x = r.maxX }
        }
        return NSRect(x: textContainerOrigin.x + x - 1, y: textContainerOrigin.y + line.minY, width: 2, height: line.height)
    }

    /// 标记的位置（文字区坐标）：横跨整个文字栏，高度是那一段
    func markRect() -> NSRect? {
        guard let range = sourceCursorRange, window?.firstResponder !== self,
              let lm = layoutManager, let tc = textContainer, let length = textStorage?.length,
              range.location < length else { return nil }
        let r = NSRange(location: range.location, length: min(range.length, length - range.location))
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var top = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        var bottom = lm.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY
        // 表格：按格子的外框算（含边框和内边距），不按格子里文字的位置，否则框比表格小一圈、上下对不齐
        var i = r.location
        while i < NSMaxRange(r) {
            let para = (string as NSString).paragraphRange(for: NSRange(location: i, length: 0))
            if let block = cell(at: i) {
                let g = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
                let bounds = lm.boundsRect(for: block, glyphRange: g)
                top = min(top, bounds.minY)
                bottom = max(bottom, bounds.maxY)
            }
            i = NSMaxRange(para)
        }
        let pad = tc.lineFragmentPadding
        return NSRect(x: textContainerOrigin.x + pad, y: textContainerOrigin.y + top,
                      width: tc.size.width - pad * 2, height: bottom - top)
    }

    /// 将要成为焦点时调用（在接收打字之前）：双页里先把等着做的重排做完，免得在旧内容上打字、冲掉左边刚改的字
    var onFocus: (() -> Void)?
    /// 获得或失去输入焦点时通知控制器同步工具栏与格式面板
    var onFocusChange: ((Bool) -> Void)?

    // 点进右边编辑时去掉标记，离开时再显示
    override func becomeFirstResponder() -> Bool {
        defer { needsDisplay = true }
        onFocus?()
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        defer { needsDisplay = true }
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
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

    /// 提示框标题整体保存为 [!TIP] 等：在它旁边输入的文字不接着用标题的样式，否则保存时会被吞掉
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var newValue = newValue
            newValue[DMKey.collapsed] = nil   // 在收起的标题末尾回车，新段落不应跟着“收起”
            newValue[DMKey.math] = nil        // 在公式后输入的文字不是公式，否则保存时被写成公式原文
            newValue[DMKey.softBreak] = nil   // 在换行后输入的空格不是换行
            // 在原样内容（<span>、[^1] 等）后面输入的是普通文字：不跟着原样保存，否则打的 *字* 下次打开变成斜体。在它中间输入才算修改它
            if newValue[DMKey.literal] != nil, let storage = textStorage {
                let at = selectedRange().location
                if at >= storage.length || storage.attribute(DMKey.literal, at: at, effectiveRange: nil) == nil {
                    newValue[DMKey.literal] = nil
                    let kind = RichBridge.kind(of: newValue)
                    newValue[.foregroundColor] = RichStyle.textColor(for: kind)
                    newValue[.superscript] = nil   // 脚注显示成上标
                    newValue[.font] = RichStyle.baseFont(for: kind)
                }
            }
            if newValue[DMKey.rule] != nil {   // 在分隔线旁输入的文字不是分隔线，否则保存时变成另一条线
                newValue = RichStyle.typingAttributes(for: .body)
            }
            if newValue[DMKey.image] != nil {   // 在图片旁输入的文字不是图片，否则保存时被吞掉
                for k in [DMKey.image, DMKey.imageID, DMKey.alt, DMKey.title, DMKey.link, DMKey.linkTitle] { newValue[k] = nil }
                let kind = RichBridge.kind(of: newValue)
                newValue[.foregroundColor] = RichStyle.textColor(for: kind)
                newValue[.font] = RichStyle.baseFont(for: kind)   // 图片不带字体，否则变成系统默认的小字
            }
            guard newValue[DMKey.callout] != nil else { super.typingAttributes = newValue; return }
            var a = RichStyle.typingAttributes(for: RichBridge.kind(of: newValue))
            a[.paragraphStyle] = newValue[.paragraphStyle]
            a[DMKey.inDetails] = newValue[DMKey.inDetails]
            super.typingAttributes = a
        }
    }

    // MARK: - 基础

    func paragraphRange(at location: Int) -> NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
    }

    func paragraphAttributes(_ para: NSRange) -> [NSAttributedString.Key: Any] {
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
    func replace(_ range: NSRange, with s: NSAttributedString, caret: Int? = nil) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: s.string) else { return }
        storage.replaceCharacters(in: range, with: s)
        didChangeText()
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(caret ?? range.location + s.length, length), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// 修改一段文字的属性（可撤销）
    func changeAttributes(in range: NSRange, _ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
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
                a[.font] = NSFont.monospacedSystemFont(ofSize: RichStyle.inlineCodeSize, weight: .regular)
                a[.backgroundColor] = RichStyle.codeBackground
                if a[DMKey.link] == nil { a[.foregroundColor] = RichStyle.inlineCodeColor }
            } else {
                a[DMKey.inlineCode] = nil
                let kind = RichBridge.kind(of: a)
                a[.font] = RichStyle.baseFont(for: kind)
                a[.backgroundColor] = nil
                if a[DMKey.link] == nil { a[.foregroundColor] = RichStyle.textColor(for: kind) }
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
                a[DMKey.title] = nil
                a[.link] = URL(string: url)
                a[.foregroundColor] = NSColor.linkColor
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                a[.underlineColor] = RichStyle.linkUnderlineColor
            } else {
                a[DMKey.link] = nil
                a[DMKey.title] = nil
                a[.link] = nil
                a[.foregroundColor] = a[DMKey.inlineCode] != nil ? RichStyle.inlineCodeColor : RichStyle.textColor(for: RichBridge.kind(of: a))
                a[.underlineStyle] = nil
                a[.underlineColor] = nil
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
            // 真正的分隔线有那条线（附件）；在分隔线后按回车得到的空行只是带着它的标记，要能改回正文
            // 公式块也不改：改成标题等样式后，保存出来就不再是公式了
            let mathBlock = (a[DMKey.math] as? String).map(RichBridge.isMathBlock) ?? false
            return RichBridge.tableBlock(of: a) == nil && (RichBridge.kind(of: a) != .rule || a[.attachment] == nil) && !mathBlock
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
    func refreshTypingAttributes() {
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
    func restyle(_ para: NSRange, to target: RichKind, from oldKind: RichKind) -> Int {
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
            if a[DMKey.link] == nil && a[DMKey.literal] == nil {
                a[.foregroundColor] = a[DMKey.inlineCode] != nil ? RichStyle.inlineCodeColor : RichStyle.textColor(for: target)
            }
            a[.kern] = target == .heading(1) ? -0.4 : target == .heading(2) ? -0.2 : nil
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

    /// 在当前段落之后插入整块内容（表格、分隔线）；当前段落为空时插在它的位置。
    /// 当前段落在折叠块里时，插入的内容也放进折叠块（插入折叠块本身除外：不支持折叠块套折叠块）
    private func insertBlock(_ block: NSAttributedString, caretOffset: Int, keepInDetails: Bool = true) {
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
        let content = NSMutableAttributedString(attributedString: block)
        let pa = paragraphAttributes(para)   // 折叠块的标题行也算在折叠块里
        if keepInDetails, pa[DMKey.inDetails] != nil || pa[DMKey.summary] != nil { RichBridge.markInDetails(content) }
        s.append(content)
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
                let runs = r == 0 ? [MDRun(text: String(localized: "标题 \(c + 1)"))] : []
                s.append(RichBridge.cellParagraph(table: table, row: r, column: c, runs: runs, baseURL: baseURL,
                                                  width: 100 / CGFloat(columns)))
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
        let title = String(localized: "点击展开")
        s.append(RichBridge.paragraph(NSAttributedString(string: title, attributes: RichStyle.attributes(for: MDRun(), kind: .summary)),
                                      kind: .summary))
        let body = NSMutableAttributedString(attributedString: RichBridge.paragraph(
            NSAttributedString(string: String(localized: "折叠的内容"), attributes: RichStyle.attributes(for: MDRun(), kind: .body)), kind: .body))
        RichBridge.markInDetails(body)
        s.append(body)
        insertBlock(s, caretOffset: 0, keepInDetails: false)
        setSelectedRange(NSRange(location: selectedRange().location, length: (title as NSString).length))
    }

    /// 把光标所在段落放入（或移出）折叠块
    func setInDetails(_ on: Bool) {
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
        let body = String(localized: "内容")
        s.append(RichBridge.paragraph(RichBridge.runsString([MDRun(text: body)], kind: .quote, baseURL: baseURL), kind: .quote))
        insertBlock(s, caretOffset: (type.title as NSString).length + 1)
        setSelectedRange(NSRange(location: selectedRange().location, length: (body as NSString).length))
    }

    /// 公式块：$$ 公式 $$，显示为居中的公式，保存时写回原文
    func insertMathBlock(_ formula: String) {
        let p = RichBridge.mathBlockParagraph("$$\n\(formula)\n$$")
        insertBlock(p, caretOffset: p.length)
    }

    /// 行内公式：$公式$，显示为公式
    func insertInlineMath(_ formula: String) {
        var a = typingAttributes
        a[DMKey.literal] = nil
        replace(selectedRange(), with: RichBridge.mathString("$\(formula)$", display: false, attributes: a))
    }

    /// 双击公式时修改：参数是原文（$…$ 或 $$…$$），返回新的原文；取消时返回 nil
    var editMath: ((String) -> String?)?

    /// 点击位置上的公式
    private func mathRange(at point: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length, storage.attribute(DMKey.math, at: index, effectiveRange: nil) != nil else { return nil }
        return NSRange(location: index, length: 1)
    }

    /// 修改一个公式（可撤销）
    func editMath(at range: NSRange) {
        guard let storage = textStorage, let source = storage.attribute(DMKey.math, at: range.location, effectiveRange: nil) as? String,
              let new = editMath?(source), new != source else { return }
        var a = storage.attributes(at: range.location, effectiveRange: nil)
        a[.attachment] = nil
        let display = RichBridge.isMathBlock(source)
        replace(range, with: RichBridge.mathString(new, display: display, attributes: a), caret: NSMaxRange(range))
    }

    /// 脚注：光标处插入 [^n]，文末添加“[^n]: 说明”
    func insertFootnote(label: String, note: String) {
        guard let storage = textStorage else { return }
        var ref = MDRun(text: "[^\(label)]")
        ref.literal = true
        let caret = selectedRange()
        let refString = RichBridge.runsString([ref], kind: .body, baseURL: baseURL)
        replace(caret, with: fitted(refString, to: paragraphAttributes(paragraphRange(at: caret.location))))
        let afterRef = selectedRange().location
        let s = NSMutableAttributedString()
        // 文末表格、折叠块后面那个空的占位段落：说明直接写在这一段，否则保存时多出一个空段（&nbsp;）
        let last = paragraphRange(at: max(storage.length - 1, 0)), lastAttrs = paragraphAttributes(last)
        var at = NSRange(location: storage.length, length: 0)
        if last.length == 1, last.location > 0, string.hasSuffix("\n"), RichBridge.kind(of: lastAttrs) == .body,
           lastAttrs[DMKey.inDetails] == nil, RichBridge.tableBlock(of: lastAttrs) == nil {
            at = last
        } else if storage.length > 0 && !string.hasSuffix("\n") {
            s.append(NSAttributedString(string: "\n", attributes: RichStyle.attributes(for: MDRun(), kind: .body)))
        }
        s.append(RichBridge.paragraph(RichBridge.runsString([ref, MDRun(text: ": \(note)")], kind: .body, baseURL: baseURL),
                                      kind: .body))
        replace(at, with: s, caret: afterRef)
    }

    func insertImage(path: String, alt: String) {
        let image = RichBridge.imageString(path: Self.encodedImagePath(path), alt: alt, baseURL: baseURL)
        replace(selectedRange(), with: fitted(image, to: paragraphAttributes(paragraphRange(at: selectedRange().location))))
    }

    /// 放进一段里的内容：去掉它自己的段落格式，换成这一段的（列表、表格、折叠块、缩进），否则这一段会被拆开。
    /// 放进表格单元格时换行改成空格，一个格子不会拆成几个
    static let paragraphLevelKeys = DMKey.paragraphKeys + [.paragraphStyle, DMKey.inDetails, DMKey.codeGap]

    func fitted(_ s: NSAttributedString, to dest: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        if RichBridge.tableBlock(of: dest) != nil {
            out.mutableString.replaceOccurrences(of: "\n", with: " ", range: NSRange(location: 0, length: out.length))
        }
        let whole = NSRange(location: 0, length: out.length)
        for k in Self.paragraphLevelKeys {
            out.removeAttribute(k, range: whole)
            if let v = dest[k] { out.addAttribute(k, value: v, range: whole) }
        }
        return out
    }

    /// 文件名里的 % # ? 在 Markdown 地址里有别的意思，要编码
    static func encodedImagePath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23").replacingOccurrences(of: "?", with: "%3F")
    }

    // MARK: - 折叠块：收起 / 展开（只改变显示，不改文件）

    /// 文字是 title 的第 occurrence 个标题段落（从 0 数）。按文字找，不按第几个标题：
    /// 只有图片的标题、折叠块里的折叠块等，目录和单页数出来的标题个数可能不一样
    func headingParagraph(title: String, occurrence: Int) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        var loc = 0, k = 0
        while loc < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(p)
            guard case .heading = RichBridge.kind(of: storage.attributes(at: p.location, effectiveRange: nil)),
                  ns.substring(with: p).trimmingCharacters(in: .whitespacesAndNewlines) == title else { continue }
            if k == occurrence { return p }
            k += 1
        }
        return nil
    }

    /// 收起或展开光标所在（或指定）的折叠块
    func setCollapsed(_ on: Bool, summary para: NSRange) {
        guard let storage = textStorage, para.length > 0 else { return }
        storage.beginEditing()
        if on {
            storage.addAttribute(DMKey.collapsed, value: true, range: para)
        } else {
            storage.removeAttribute(DMKey.collapsed, range: para)
        }
        storage.endEditing()
        // 光标在收起的内容里时移到标题末尾，否则会在看不见的地方输入
        if on, let lm = layoutManager as? RichLayoutManager,
           let body = lm.hiddenRanges.first(where: { $0.location == NSMaxRange(para) }),
           NSLocationInRange(selectedRange().location, body) || NSIntersectionRange(selectedRange(), body).length > 0 {
            setSelectedRange(NSRange(location: NSMaxRange(para) - 1, length: 0))
        }
        needsDisplay = true
    }

    /// 光标或选区进入收起的内容（方向键、查找、撤销等）时展开，避免在看不见的地方编辑
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, let lm = layoutManager as? RichLayoutManager else { return }
        let hidden = lm.hiddenRanges
        guard !hidden.isEmpty else { return }
        for value in ranges {
            let r = value.rangeValue
            for body in hidden where NSLocationInRange(r.location, body) || NSIntersectionRange(r, body).length > 0 {
                guard body.location > 0 else { continue }
                setCollapsed(false, summary: paragraphRange(at: body.location - 1))
            }
        }
    }

    // MARK: - 鼠标：点击方框勾选 / 取消勾选待办；点击折叠块标题前的三角收起 / 展开

    /// 鼠标下面能点的东西：折叠块的三角、待办的方框
    private enum ClickTarget { case summary(NSRange), task(NSRange) }

    private func clickTarget(at point: NSPoint) -> ClickTarget? {
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard index < storage.length else { return nil }
        let para = paragraphRange(at: index)
        guard para.length > 0 else { return nil }
        let attrs = storage.attributes(at: para.location, effectiveRange: nil)
        if attrs[DMKey.summary] != nil {
            // 三角画在标题文字左边的缩进里
            let glyph = lm.glyphIndexForCharacter(at: para.location)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let textX = textContainerOrigin.x + line.minX + lm.location(forGlyphAt: glyph).x
            if point.x < textX, point.y >= textContainerOrigin.y + line.minY, point.y < textContainerOrigin.y + line.maxY {
                return .summary(para)
            }
        }
        if index <= para.location + 1, case .task = RichBridge.kind(of: attrs) {
            let box = (string as NSString).substring(with: NSRange(location: para.location, length: 1))
            if box == RichStyle.taskTodo || box == RichStyle.taskDone { return .task(para) }
        }
        return nil
    }

    /// 移到能点的地方时显示手形指针（链接由系统处理）；移到代码块上时在右上角显示“复制”按钮
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateCopyButton(at: point)
        if clickTarget(at: point) != nil || overCopyButton(point) { NSCursor.pointingHand.set() }
        else if columnBoundary(at: point) != nil { NSCursor.resizeLeftRight.set() }
    }

    /// 鼠标在代码块的“复制”按钮上（按钮在编辑区里面，系统按编辑区显示 I 形指针，要自己改成手形）
    private func overCopyButton(_ point: NSPoint) -> Bool {
        !copyButton.isHidden && copyButton.frame.contains(point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateCopyButton(at: nil)
    }

    override func didChangeText() {
        super.didChangeText()
        updateCopyButton(at: nil)   // 打字后代码块的位置可能变了
    }

    // MARK: - 代码块的“复制”按钮（与 GitHub 相同：鼠标移上去才出现）

    private var copyBlock: NSRange?
    private lazy var copyButton: NSButton = {
        let b = NSButton(image: Self.copyIcon, target: self, action: #selector(copyCodeBlock))
        b.bezelStyle = .accessoryBarAction
        b.isBordered = true
        b.toolTip = String(localized: "复制代码")
        b.setAccessibilityLabel(String(localized: "复制代码"))
        b.isHidden = true
        addSubview(b)
        return b
    }()
    private static let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!
    private static let copiedIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!

    private func updateCopyButton(at point: NSPoint?) {
        guard let point, let lm = layoutManager as? RichLayoutManager, let container = textContainer, lm.numberOfGlyphs > 0 else {
            if copyBlock != nil { copyBlock = nil; copyButton.isHidden = true }
            return
        }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: inContainer, in: container)
        let block = lm.codeBlock(at: lm.characterIndexForGlyph(at: glyph))
        guard let block, var rect = lm.codeBlockRect(block) else { return updateCopyButton(at: nil) }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // 鼠标在代码块下面的空白处时，系统也会找到代码块的最后一个字：按底色的范围再判断一次
        guard rect.contains(point) else { return updateCopyButton(at: nil) }
        if block != copyBlock { copyButton.image = Self.copyIcon }
        copyBlock = block
        let size = NSSize(width: 28, height: 24)
        copyButton.frame = NSRect(x: rect.maxX - size.width - 6, y: rect.minY + 5, width: size.width, height: size.height)
        copyButton.isHidden = false
    }

    @objc private func copyCodeBlock() {
        guard let block = copyBlock, let storage = textStorage, NSMaxRange(block) <= storage.length else { return }
        var text = (storage.string as NSString).substring(with: block)
        if text.hasSuffix("\n") { text.removeLast() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.image = Self.copiedIcon
        copyButton.setAccessibilityLabel(String(localized: "已复制"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.copyButton.image = Self.copyIcon
            self.copyButton.setAccessibilityLabel(String(localized: "复制代码"))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clickTarget(at: point) != nil || overCopyButton(point) {
            NSCursor.pointingHand.set()
        } else if columnBoundary(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let r = mathRange(at: convert(event.locationInWindow, from: nil)) {
            setSelectedRange(r)
            editMath(at: r)
            return
        }
        if let drag = columnBoundary(at: convert(event.locationInWindow, from: nil)) {
            columnDrag = drag
            NSCursor.resizeLeftRight.set()
            return
        }
        switch clickTarget(at: convert(event.locationInWindow, from: nil)) {
        case .summary(let para):
            setCollapsed(textStorage?.attribute(DMKey.collapsed, at: para.location, effectiveRange: nil) == nil, summary: para)
        case .task(let para):
            guard case .task(let d, let done) = RichBridge.kind(of: textStorage!.attributes(at: para.location, effectiveRange: nil)) else { return }
            setSelectedRange(NSRange(location: para.location, length: 0))
            applyKinds { _ in .task(d, !done) }
            setSelectedRange(NSRange(location: min(para.location + 2, (string as NSString).length), length: 0))
        case nil:
            if let storage = textStorage, storage.length > 0, event.clickCount == 1, cell(at: storage.length - 1) != nil,
               let lm = layoutManager, let container = textContainer,
               convert(event.locationInWindow, from: nil).y > textContainerOrigin.y + lm.usedRect(for: container).maxY {
                moveBelowTable(storage.length - 1)
                return
            }
            super.mouseDown(with: event)
        }
    }
}
