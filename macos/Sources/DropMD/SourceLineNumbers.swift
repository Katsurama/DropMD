import AppKit

/// GitHub 代码视图风格的源码编辑区配色（随浅色 / 深色外观动态变化）。
enum SourceGutterStyle {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 光标所在行的极淡背景高亮（使用淡蓝调，避免与查找栏的黄色高亮冲突）。
    static let caretLineHighlightColor = NSColor(name: "DropMD.source.caretLine") { a in
        isDark(a)
            ? NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 0.08)
            : NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 0.055)
    }

    /// 双页对应位置：整行高亮，与 GitHub 点行号选中行相同（Primer attention-muted）
    static let markLineColor = NSColor(name: "DropMD.source.markLine") { a in
        isDark(a)
            ? NSColor(srgbRed: 0.733, green: 0.502, blue: 0.035, alpha: 0.15)
            : NSColor(srgbRed: 1.0, green: 0.973, blue: 0.773, alpha: 1)
    }

    /// 行号栏右侧与编辑区之间的细分隔线颜色。
    static let separatorColor = NSColor(name: "DropMD.source.gutterSeparator") { a in
        isDark(a)
            ? NSColor(srgbRed: 0.30, green: 0.33, blue: 0.37, alpha: 0.65)
            : NSColor(srgbRed: 0.82, green: 0.85, blue: 0.88, alpha: 0.85)
    }

    /// 普通行号颜色（GitHub Primer 次级灰）。
    static let lineNumberColor = NSColor(name: "DropMD.source.lineNumber") { a in
        isDark(a)
            ? NSColor(srgbRed: 0.49, green: 0.52, blue: 0.56, alpha: 1)
            : NSColor(srgbRed: 0.43, green: 0.47, blue: 0.51, alpha: 1)
    }
}

/// 双页的两个编辑区用的滚动视图：双页时滚动条只在滚动时出现（只出现在正在滚动的一边），单页时跟系统设置
final class SplitScrollView: NSScrollView {
    var overlayScrollers = false { didSet { applyScrollerStyle() } }
    private var styleObserver: NSObjectProtocol?

    deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    private func applyScrollerStyle() {
        scrollerStyle = overlayScrollers ? .overlay : NSScroller.preferredScrollerStyle
        verticalScroller?.alphaValue = overlayScrollers ? 0 : 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
        styleObserver = nil
        guard window != nil else { return }
        applyScrollerStyle()
        // 系统设置里改了“显示滚动条”后，系统会把样式改回去：等它改完再设回来
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyScrollerStyle() } }
        }
    }

    private var fadeOut: DispatchWorkItem?
    private static weak var shown: SplitScrollView?
    private var hoverArea: NSTrackingArea?

    /// 双页：只在自己滚动、或鼠标移到滚动条上时显示，停下约 1 秒后淡出。
    /// 不靠系统淡出：接着鼠标时系统会让覆盖式滚动条一直显示；跟着另一边同步滚动时也不显示
    private func showScrollerBriefly() {
        guard overlayScrollers, let scroller = verticalScroller else { return }
        // 同一时间只显示一边：换到另一边滚动时，前一边的滚动条立刻收起
        if let other = Self.shown, other !== self { other.fadeOut?.cancel(); other.verticalScroller?.alphaValue = 0 }
        Self.shown = self
        scroller.alphaValue = 1
        fadeOut?.cancel()
        let work = DispatchWorkItem { [weak self, weak scroller] in
            guard let self, let scroller else { return }
            // 正在拖动滚动条时不淡出
            if NSEvent.pressedMouseButtons != 0 || self.pointerOnScroller() { return self.showScrollerBriefly() }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; scroller.animator().alphaValue = 0 }
        }
        fadeOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func pointerOnScroller() -> Bool {
        guard let scroller = verticalScroller, let window else { return false }
        return scroller.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        showScrollerBriefly()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if pointerOnScroller() { showScrollerBriefly() }
    }
}

/// 带当前逻辑行背景高亮的源码文本视图（仅在无选区时绘制）。
final class SourceTextView: NSTextView {
    private var lastCaretLineRect: NSRect = .zero

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if pointerOnScroller(event) { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if pointerOnScroller(event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }
    private var scaleObservers: [NSObjectProtocol] = []

    /// 双页：右边光标对应的原文行（字符范围），整行高亮，行号栏同一行也高亮
    var markedLines: NSRange? {
        didSet {
            guard markedLines != oldValue else { return }
            needsDisplay = true
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    /// 高亮行在视图中的矩形（整行宽，折行时包括所有视觉行）
    func markedLinesRect() -> NSRect {
        guard let r = markedLines, r.length > 0, let lm = layoutManager, let tc = textContainer, tc.containerSize.width > 0,
              lm.numberOfGlyphs > 0, NSMaxRange(r) <= (string as NSString).length else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let first = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return NSRect(x: 0, y: first.minY + textContainerOrigin.y, width: bounds.width, height: last.maxY - first.minY)
    }

    // 字号（显示 → 字号）与单页相同：整块按比例放大；设置一改、窗口换屏幕都马上重新计算
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scaleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        scaleObservers = window == nil ? [] : TextScale.observe(self)
    }

    deinit {
        scaleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func layout() {
        super.layout()
        TextScale.apply(to: enclosingScrollView)
        fitWidthToClipView()
    }

    // 加了行号栏后，滚动区域先按 0 宽排版时正文宽度会被挤成 0（文字一字一行、看不见）：始终和可见区域一样宽
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        fitWidthToClipView()
    }

    private func fitWidthToClipView() {
        guard superview is NSClipView else { return }
        if let width = visibleWidth, abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: frame.height)) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let lineRect = caretLineRect()
        lastCaretLineRect = lineRect
        if !lineRect.isEmpty, lineRect.intersects(rect) {
            SourceGutterStyle.caretLineHighlightColor.setFill()
            lineRect.intersection(rect).fill()
        }
        let mark = markedLinesRect()
        if !mark.isEmpty, mark.intersects(rect) {
            SourceGutterStyle.markLineColor.setFill()
            mark.intersection(rect).fill()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        let oldRect = lastCaretLineRect
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        let newRect = caretLineRect()
        if oldRect != newRect {
            if !oldRect.isEmpty { setNeedsDisplay(oldRect) }
            if !newRect.isEmpty { setNeedsDisplay(newRect) }
            lastCaretLineRect = newRect
        }
    }

    override func didChangeText() {
        let oldRect = lastCaretLineRect
        super.didChangeText()
        let newRect = caretLineRect()
        if !oldRect.isEmpty { setNeedsDisplay(oldRect) }
        if !newRect.isEmpty { setNeedsDisplay(newRect) }
        lastCaretLineRect = newRect
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // 自动换行：宽度等于看得见的部分（行号栏占的位置是内边距，要扣掉，否则右边被挡住、能横向拖动）
        if let w = visibleWidth { size.width = w }
        super.setFrameSize(size)
        if !lastCaretLineRect.isEmpty { setNeedsDisplay(lastCaretLineRect) }
    }

    /// 可见区域的宽度（扣掉行号栏等内边距）
    private var visibleWidth: CGFloat? {
        guard let clip = superview as? NSClipView else { return nil }
        let w = clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
        return w > 0 ? w : nil
    }

    /// 不能横向滚动：始终停在最左边（行号栏的内边距之外）
    override func adjustScroll(_ newVisible: NSRect) -> NSRect {
        var r = super.adjustScroll(newVisible)
        r.origin.x = -((superview as? NSClipView)?.contentInsets.left ?? 0)
        return r
    }

    /// 供 textStorage 编辑通知调用：不访问 layoutManager，仅标记旧的光标行区域需要重绘。
    func markLastCaretLineDirty() {
        if !lastCaretLineRect.isEmpty { setNeedsDisplay(lastCaretLineRect) }
    }

    /// 计算当前光标所在逻辑行在视图坐标中的整行矩形（折行时覆盖所有视觉行）；有选区时返回 .zero。
    private func caretLineRect() -> NSRect {
        guard markedLines == nil else { return .zero }   // 正在标对应位置（光标在右边）：只显示一条高亮
        guard selectedRanges.count == 1, let sel = selectedRanges.first?.rangeValue, sel.length == 0 else {
            return .zero
        }
        guard let lm = layoutManager, let tc = textContainer, tc.containerSize.width > 0 else {
            return .zero
        }
        let ns = string as NSString
        let len = ns.length
        let originY = textContainerOrigin.y
        guard sel.location <= len else { return .zero }

        if len == 0 {
            let r = lm.extraLineFragmentRect
            let h = r.height > 0 ? r.height : lm.defaultLineHeight(for: MarkdownHighlighter.baseFont)
            return NSRect(x: 0, y: r.minY + originY, width: bounds.width, height: h)
        }

        if sel.location == len, ns.character(at: len - 1) == 0x0A {
            let r = lm.extraLineFragmentRect
            guard r.height > 0 else { return .zero }
            return NSRect(x: 0, y: r.minY + originY, width: bounds.width, height: r.height)
        }

        let probe = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        guard glyphRange.length > 0, NSMaxRange(glyphRange) <= lm.numberOfGlyphs else {
            return .zero
        }
        let first = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphRange) - 1, effectiveRange: nil)
        return NSRect(x: 0, y: first.minY + originY, width: bounds.width, height: last.maxY - first.minY)
    }
}

/// 左侧逻辑行号栏：仅绘制可见行，增量维护换行偏移缓存以适配万行以上文档。
final class SourceLineNumberRulerView: NSRulerView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let digitWidth = ceil(("8" as NSString).size(withAttributes: [.font: font]).width)
    private static let horizontalPadding: CGFloat = 12
    private static let rightAlignedStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()
    private static let normalAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: SourceGutterStyle.lineNumberColor,
        .paragraphStyle: rightAlignedStyle,
    ]
    private static let activeAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: rightAlignedStyle,
    ]

    /// 各逻辑行起始 UTF-16 偏移量；恒定满足 [0] + 每个 0x0A 后的偏移。
    private var lineStarts: [Int] = [0]
    private var cachedLength: Int = 0
    private var lastActiveLine: Int?

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true   // macOS 14 起默认不裁剪：填背景时会盖住右边的正文
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        textView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        rebuildLineStarts(from: textView.string as NSString)
        updateRuleThickness()
        lastActiveLine = activeLineIndex(in: textView)

        let nc = NotificationCenter.default
        if let storage = textView.textStorage {
            nc.addObserver(self, selector: #selector(handleTextStorageEditing(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        nc.addObserver(self, selector: #selector(needsRedraw(_:)),
                       name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        nc.addObserver(self, selector: #selector(needsRedraw(_:)),
                       name: NSView.frameDidChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(selectionDidChange(_:)),
                       name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("不支持") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 增量行号缓存

    private func scanNewlines(in ns: NSString, range: NSRange) -> [Int] {
        guard range.length > 0 else { return [] }
        var result: [Int] = []
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: min(chunkSize, range.length))
        var offset = range.location
        let end = NSMaxRange(range)
        while offset < end {
            let count = min(chunkSize, end - offset)
            ns.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 0x0A {
                result.append(offset + i + 1)
            }
            offset += count
        }
        return result
    }

    private func rebuildLineStarts(from ns: NSString) {
        var starts = [0]
        starts.append(contentsOf: scanNewlines(in: ns, range: NSRange(location: 0, length: ns.length)))
        lineStarts = starts
        cachedLength = ns.length
    }

    private func updateLineStarts(for storage: NSTextStorage) {
        let edited = storage.editedRange
        let delta = storage.changeInLength
        let newLen = storage.length
        let oldStart = edited.location
        let oldEnd = NSMaxRange(edited) - delta

        guard cachedLength + delta == newLen, oldStart >= 0, oldStart <= oldEnd, oldEnd <= cachedLength else {
            rebuildLineStarts(from: storage.string as NSString)
            return
        }

        let firstRemove = firstIndex(greaterThan: oldStart)
        let firstKeep = firstIndex(greaterThan: oldEnd)
        let inserted = scanNewlines(in: storage.string as NSString, range: edited)

        if delta != 0 {
            for i in firstKeep..<lineStarts.count {
                lineStarts[i] += delta
            }
        }
        if firstRemove != firstKeep || !inserted.isEmpty {
            lineStarts.replaceSubrange(firstRemove..<firstKeep, with: inserted)
        }
        cachedLength = newLen
    }

    private func firstIndex(greaterThan value: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) >> 1
            if lineStarts[mid] > value {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    private func lineIndex(forCharacter charIndex: Int) -> Int {
        max(0, firstIndex(greaterThan: charIndex) - 1)
    }

    private func activeLineIndex(in tv: NSTextView) -> Int? {
        guard tv.selectedRanges.count == 1, let sel = tv.selectedRanges.first?.rangeValue, sel.length == 0 else {
            return nil
        }
        return lineIndex(forCharacter: sel.location)
    }

    private func updateRuleThickness() {
        var digits = 0
        var n = max(1, lineStarts.count)
        while n > 0 {
            digits += 1
            n /= 10
        }
        let target = ceil(CGFloat(max(2, digits)) * Self.digitWidth) + Self.horizontalPadding * 2
        if abs(ruleThickness - target) > 0.5 {
            ruleThickness = target
        }
    }

    // MARK: - 通知响应

    @objc private func handleTextStorageEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage else { return }
        if storage.editedMask.contains(.editedCharacters) {
            updateLineStarts(for: storage)
            updateRuleThickness()
            if let tv = clientView as? NSTextView {
                lastActiveLine = activeLineIndex(in: tv)
            }
        }
        (clientView as? SourceTextView)?.markLastCaretLineDirty()
        needsDisplay = true
    }

    @objc private func selectionDidChange(_ note: Notification) {
        guard let tv = clientView as? NSTextView else { return }
        let current = activeLineIndex(in: tv)
        if current != lastActiveLine {
            lastActiveLine = current
            needsDisplay = true
        }
    }

    @objc private func needsRedraw(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 直接绘制行号栏，避免父类画出传统 AppKit 标尺边框
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return }

        tv.backgroundColor.setFill()
        rect.intersection(bounds).fill()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let hairline = 1.0 / max(1.0, scale)
        let mark = (tv as? SourceTextView)?.markedLines
        let activeLine = mark == nil ? activeLineIndex(in: tv) : nil   // 正在标对应位置时只显示一条高亮
        let originY = tv.textContainerOrigin.y
        let dirtyInTV = convert(rect, to: tv)
        let containerTop = max(0, dirtyInTV.minY - originY)
        let containerBottom = max(containerTop, dirtyInTV.maxY - originY)
        let labelWidth = max(0, bounds.width - Self.horizontalPadding)
        let gutterAscender = Self.font.ascender

        if tc.containerSize.width > 0, containerBottom > containerTop, lm.numberOfGlyphs > 0 {
            let searchRect = NSRect(x: 0, y: containerTop, width: tc.containerSize.width, height: containerBottom - containerTop)
            let visibleGlyphRange = lm.glyphRange(forBoundingRect: searchRect, in: tc)
            if visibleGlyphRange.length > 0 {
                var lineIdx = lineIndex(forCharacter: lm.characterIndexForGlyph(at: visibleGlyphRange.location))
                lm.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { lineRect, _, _, glyphRange, _ in
                    let charLoc = lm.characterIndexForGlyph(at: glyphRange.location)
                    while lineIdx + 1 < self.lineStarts.count && self.lineStarts[lineIdx + 1] <= charLoc {
                        lineIdx += 1
                    }
                    // 行号栏不在缩放区域里：位置和高度都从正文坐标换算过来（字号放大时一起变）
                    let lineInRuler = self.convert(NSRect(x: 0, y: lineRect.minY + originY, width: 1, height: lineRect.height), from: tv)
                    let yInRuler = lineInRuler.minY
                    let zoom = lineInRuler.height / max(lineRect.height, 1)
                    if lineIdx == activeLine {
                        SourceGutterStyle.caretLineHighlightColor.setFill()
                        NSRect(x: 0, y: yInRuler, width: self.bounds.width - hairline, height: lineInRuler.height).fill()
                    }
                    let marked = mark.map { NSLocationInRange(charLoc, $0) } ?? false
                    if marked {
                        SourceGutterStyle.markLineColor.setFill()
                        NSRect(x: 0, y: yInRuler, width: self.bounds.width - hairline, height: lineInRuler.height).fill()
                    }
                    // 折行时仅在逻辑行首个视觉行绘制行号
                    if charLoc == self.lineStarts[lineIdx] {
                        let drawY = yInRuler + lm.location(forGlyphAt: glyphRange.location).y * zoom - gutterAscender
                        let attrs = lineIdx == activeLine || marked ? Self.activeAttributes : Self.normalAttributes
                        let labelRect = NSRect(x: 0, y: drawY, width: labelWidth, height: max(lineInRuler.height, 18))
                        ("\(lineIdx + 1)" as NSString).draw(in: labelRect, withAttributes: attrs)
                    }
                }
            }
        }

        // 处理空文档或末尾换行后的最后一行
        let ns = tv.string as NSString
        var extraRect = lm.extraLineFragmentRect
        if extraRect.height <= 0, ns.length == 0 {
            extraRect = NSRect(x: 0, y: 0, width: tc.containerSize.width, height: lm.defaultLineHeight(for: MarkdownHighlighter.baseFont))
        }
        if extraRect.height > 0, ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            let extraInRuler = convert(NSRect(x: 0, y: extraRect.minY + originY, width: 1, height: extraRect.height), from: tv)
            let extraY = extraInRuler.minY
            if extraY < rect.maxY, extraY + extraInRuler.height > rect.minY {
                let extraIdx = max(0, lineStarts.count - 1)
                if extraIdx == activeLine {
                    SourceGutterStyle.caretLineHighlightColor.setFill()
                    NSRect(x: 0, y: extraY, width: bounds.width - hairline, height: extraInRuler.height).fill()
                }
                let drawY = extraY + max(0, MarkdownHighlighter.baseFont.ascender * extraInRuler.height / max(extraRect.height, 1) - gutterAscender)
                let attrs = extraIdx == activeLine ? Self.activeAttributes : Self.normalAttributes
                let labelRect = NSRect(x: 0, y: drawY, width: labelWidth, height: max(extraInRuler.height, 18))
                ("\(extraIdx + 1)" as NSString).draw(in: labelRect, withAttributes: attrs)
            }
        }

        SourceGutterStyle.separatorColor.setFill()
        NSRect(x: bounds.width - hairline, y: rect.minY, width: hairline, height: rect.height).fill()
    }
}
