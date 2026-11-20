import AppKit

extension RichTextView {
    // MARK: - 表格中移动

    func cell(at location: Int) -> NSTextTableBlock? {
        guard let storage = textStorage, location < storage.length else { return nil }
        return RichBridge.tableBlock(of: storage.attributes(at: location, effectiveRange: nil))
    }

    /// 光标移到表格下面一段；表格在文末时先在下面新建一个空段落（否则表格后面写不了字）
    @discardableResult
    func moveBelowTable(_ location: Int) -> Bool {
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager,
              let table = lm.tableRange(around: NSRange(location: location, length: 0), in: storage) else { return false }
        let end = NSMaxRange(table)
        if end < storage.length {
            setSelectedRange(NSRange(location: end, length: 0))
            scrollRangeToVisible(selectedRange())
        } else {
            let s = NSMutableAttributedString()
            if !(storage.string as NSString).substring(with: table).hasSuffix("\n") {
                s.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: end - 1, effectiveRange: nil)))
            }
            let caret = end + s.length
            s.append(RichBridge.paragraph(NSAttributedString(), kind: .body))
            replace(NSRange(location: end, length: 0), with: s, caret: caret)
        }
        refreshTypingAttributes()
        return true
    }

    /// 光标在表格最后一行
    private func inLastTableRow(_ location: Int) -> Bool {
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager, let here = cell(at: location),
              let table = lm.tableRange(around: NSRange(location: location, length: 0), in: storage),
              let last = cell(at: NSMaxRange(table) - 1) else { return false }
        return here.startingRow == last.startingRow
    }

    /// 光标在这一段（这一格）折行后的最后一行
    private func onLastLine(_ location: Int) -> Bool {
        guard let lm = layoutManager, let storage = textStorage, storage.length > 0 else { return true }
        let para = paragraphRange(at: min(location, storage.length - 1))
        let last = max(para.location, NSMaxRange(para) - 1)
        func top(_ i: Int) -> CGFloat { lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil).minY }
        return top(min(location, last)) == top(last)
    }

    /// 在表格最后一行按下方向键：跳到表格下面（表格在文末时新建一段，系统默认移不出去）。
    /// 格子里的字折成几行时，先在格子里往下走，到最后一行再跳出
    override func moveDown(_ sender: Any?) {
        let at = selectedRange().location
        if selectedRange().length == 0, inLastTableRow(at), onLastLine(at), moveBelowTable(at) { return }
        super.moveDown(sender)
    }

    /// 光标在表格中时移到下一格 / 上一格，返回是否处理。
    /// 最后一格：addRow 时（Tab）在末尾加一行，否则（回车）跳到表格下面，和 Word 相同
    func moveCell(forward: Bool, addRow: Bool = true) -> Bool {
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
            guard addRow else { return moveBelowTable(para.location) }
            // 最后一格：在表格末尾新增一行
            let row = NSMutableAttributedString()
            // 新的一行沿用各列原来的宽度
            var widths: [Int: CGFloat] = [:]
            textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { value, _, _ in
                if let b = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, b.table === current.table {
                    widths[b.startingColumn] = b.value(for: .width)
                }
            }
            let cols = current.table.numberOfColumns
            for c in 0..<cols {
                row.append(RichBridge.cellParagraph(table: current.table, row: current.startingRow + 1, column: c,
                                                    runs: [], baseURL: baseURL, width: widths[c] ?? 100 / CGFloat(cols)))
            }
            if paragraphAttributes(para)[DMKey.inDetails] != nil { RichBridge.markInDetails(row) }   // 折叠块里的表格：新行也在折叠块里
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

    // MARK: - 表格：右键菜单里的插入 / 删除行和列、对齐、删除表格、复制表格

    /// 光标所在表格的范围、所在行（0 是表头）、所在列、列数；不在表格里时为 nil
    func tableContext() -> (range: NSRange, row: Int, column: Int, columns: Int)? {
        let at = selectedRange().location
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager, let here = cell(at: at),
              let range = lm.tableRange(around: NSRange(location: at, length: 0), in: storage) else { return nil }
        return (range, here.startingRow, here.startingColumn, here.table.numberOfColumns)
    }

    /// 改表格的 Markdown（第 0 行表头、第 1 行分隔线、之后一行一行），整张表重建，光标放到第 caretRow 行第 caretColumn 格。
    /// 走一遍 Markdown 比逐格改 NSTextTableBlock 简单：后面各行的行号、表头样式、列宽都跟着重算
    func rewriteTable(caretRow: Int, caretColumn: Int = 0, _ edit: (inout [String]) -> Void) {
        guard let storage = textStorage, let ctx = tableContext() else { return }
        let old = storage.attributedSubstring(from: ctx.range)
        var lines = RichBridge.markdown(from: old).components(separatedBy: "\n").filter { !$0.isEmpty }
        edit(&lines)
        let new = NSMutableAttributedString(attributedString: RichBridge.attributed(markdown: lines.joined(separator: "\n") + "\n", baseURL: baseURL))
        // 只要表格本身：表格在文末时转换会在后面补一个空段落
        var end = 0
        new.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: new.length)) { value, range, _ in
            if (value as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock { end = NSMaxRange(range) }
        }
        guard end > 0 else { return }
        new.deleteCharacters(in: NSRange(location: end, length: new.length - end))
        if old.attribute(DMKey.inDetails, at: 0, effectiveRange: nil) != nil { RichBridge.markInDetails(new) }
        var caret = 0
        new.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: new.length)) { value, range, stop in
            if let b = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, b.startingRow == caretRow,
               b.startingColumn == caretColumn {
                caret = range.location
                stop.pointee = true
            }
        }
        replace(ctx.range, with: new, caret: ctx.range.location + caret)
        refreshTypingAttributes()
    }

    @objc func insertTableRowBelow(_ sender: Any?) {
        guard let ctx = tableContext() else { return }
        rewriteTable(caretRow: ctx.row + 1) { lines in
            lines.insert("|" + String(repeating: "  |", count: ctx.columns), at: min(ctx.row + 2, lines.count))
        }
    }

    @objc func insertTableRowAbove(_ sender: Any?) {
        guard let ctx = tableContext(), ctx.row > 0 else { return }
        rewriteTable(caretRow: ctx.row) { lines in
            lines.insert("|" + String(repeating: "  |", count: ctx.columns), at: min(ctx.row + 1, lines.count))
        }
    }

    /// 每一行按格拆开改，再拼回 Markdown（分隔线那一行是第 1 行）
    private func rewriteColumns(caretColumn: Int, _ edit: (_ line: Int, _ cells: inout [String]) -> Void) {
        guard let ctx = tableContext() else { return }
        rewriteTable(caretRow: ctx.row, caretColumn: caretColumn) { lines in
            lines = lines.enumerated().map { i, line in
                var cells = MarkdownCodec.splitRow(line)
                edit(i, &cells)
                return "| " + cells.joined(separator: " | ") + " |"
            }
        }
    }

    @objc func insertTableColumnLeft(_ sender: Any?) {
        guard let ctx = tableContext() else { return }
        rewriteColumns(caretColumn: ctx.column) { i, cells in cells.insert(i == 1 ? "---" : "", at: min(ctx.column, cells.count)) }
    }

    @objc func insertTableColumnRight(_ sender: Any?) {
        guard let ctx = tableContext() else { return }
        rewriteColumns(caretColumn: ctx.column + 1) { i, cells in cells.insert(i == 1 ? "---" : "", at: min(ctx.column + 1, cells.count)) }
    }

    @objc func deleteTableColumn(_ sender: Any?) {
        guard let ctx = tableContext(), ctx.columns > 1 else { return }
        rewriteColumns(caretColumn: max(ctx.column - 1, 0)) { _, cells in if ctx.column < cells.count { cells.remove(at: ctx.column) } }
    }

    /// 这一列的对齐（菜单项的 representedObject 是 ":--"、":-:"、"--:"），写进分隔线那一行
    @objc func alignTableColumn(_ sender: Any?) {
        guard let ctx = tableContext(), let marker = (sender as? NSMenuItem)?.representedObject as? String else { return }
        rewriteColumns(caretColumn: ctx.column) { i, cells in if i == 1, ctx.column < cells.count { cells[ctx.column] = marker } }
    }

    /// 光标所在列现在的对齐：":--"、":-:"、"--:"，没设过是 "---"
    func tableColumnMarker() -> String {
        guard let storage = textStorage, let ctx = tableContext() else { return "---" }
        let lines = RichBridge.markdown(from: storage.attributedSubstring(from: ctx.range)).components(separatedBy: "\n")
        guard lines.count > 1 else { return "---" }
        let cells = MarkdownCodec.splitRow(lines[1])
        guard ctx.column < cells.count else { return "---" }
        let t = cells[ctx.column]
        switch (t.hasPrefix(":"), t.hasSuffix(":")) {
        case (true, true): return ":-:"
        case (true, false): return ":--"
        case (false, true): return "--:"
        default: return "---"
        }
    }

    /// 整张表格复制成 Markdown 文字
    @objc func copyTable(_ sender: Any?) {
        guard let storage = textStorage, let ctx = tableContext() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(RichBridge.markdown(from: storage.attributedSubstring(from: ctx.range)), forType: .string)
    }

    @objc func deleteTableRow(_ sender: Any?) {
        guard let ctx = tableContext(), ctx.row > 0 else { return }
        rewriteTable(caretRow: ctx.row - 1) { lines in
            if ctx.row + 1 < lines.count { lines.remove(at: ctx.row + 1) }
        }
    }

    @objc func deleteTable(_ sender: Any?) {
        guard let ctx = tableContext() else { return }
        replace(ctx.range, with: NSAttributedString(), caret: ctx.range.location)
        refreshTypingAttributes()
    }


    // MARK: - 表格：重画时整张表一起画（只重画几格时，边框线会被擦掉一截、补不回来）

    /// 画之前先把要画到的表格整张排好：刚打开时系统只排到能看见的地方，一行里有的格子还没排，
    /// 先画出来的格子高度不对，线就断开（操作一下整张表重画才好）
    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager as? RichLayoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 {
            let origin = textContainerOrigin
            let glyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            if glyphs.length > 0 {
                let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                var i = chars.location
                while i < NSMaxRange(chars) {
                    if let table = lm.tableRange(around: NSRange(location: i, length: 0), in: storage) {
                        lm.ensureLayout(forCharacterRange: table)
                        i = NSMaxRange(table)
                    } else {
                        i = NSMaxRange((storage.string as NSString).paragraphRange(for: NSRange(location: i, length: 0)))
                    }
                }
            }
        }
        super.draw(dirtyRect)
    }


    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(rectWithTables(invalidRect))
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rectWithTables(rect), avoidAdditionalLayout: flag)
    }

    /// 重画区域碰到表格时，扩大到整张表格（不触发排版：只用已经排好的位置）
    func rectWithTables(_ rect: NSRect) -> NSRect {
        guard !expandingRedraw, !rect.isEmpty, let lm = layoutManager as? RichLayoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return rect }
        expandingRedraw = true
        defer { expandingRedraw = false }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        guard glyphs.length > 0 else { return rect }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out = rect
        var done: [NSRange] = []
        for i in [chars.location, NSMaxRange(chars) - 1] where i >= 0 && i < storage.length {
            guard let table = lm.tableRange(around: NSRange(location: i, length: 0), in: storage), !done.contains(table) else { continue }
            done.append(table)
            let g = lm.glyphRange(forCharacterRange: table, actualCharacterRange: nil)
            guard let first = lm.textContainer(forGlyphAt: g.location, effectiveRange: nil, withoutAdditionalLayout: true),
                  first === container else { continue }
            out = out.union(lm.boundingRect(forGlyphRange: g, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -2))
        }
        return out
    }

    // MARK: - 表格：拖两列的交界调整列宽（系统自带的只认边框那一条线，很难点中）

    /// 正在拖的交界：表格的范围、交界左边那一列、这一列左边缘和表格总宽（视图坐标）、两列合计的百分比
    struct ColumnDrag { let range: NSRange; let column: Int; let left: CGFloat; let width: CGFloat; let pair: CGFloat }

    private func tableBlock(at i: Int) -> NSTextTableBlock? {
        (textStorage?.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
    }

    /// 鼠标在表格两列交界左右 5 点内时，返回这条交界
    func columnBoundary(at point: NSPoint) -> ColumnDrag? {
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager, let container = textContainer else { return nil }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        guard let range = (lm as? RichLayoutManager)?.tableRange(around: NSRange(location: index, length: 0), in: storage) else { return nil }
        let origin = textContainerOrigin
        let whole = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        guard point.y >= whole.minY + origin.y, point.y <= whole.maxY + origin.y else { return nil }
        // 第一行各格的位置（各行列宽相同）
        var cells: [Int: (block: NSTextTableBlock, rect: NSRect)] = [:]
        var i = range.location
        while i < NSMaxRange(range) {
            let para = paragraphRange(at: i)
            if let b = tableBlock(at: i), b.startingRow == 0, cells[b.startingColumn] == nil {
                let g = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
                cells[b.startingColumn] = (b, lm.boundsRect(for: b, glyphRange: g))
            }
            i = NSMaxRange(para)
        }
        let columns = cells.keys.sorted()
        guard columns.count > 1, columns == Array(0..<columns.count), let first = cells[0], let last = cells[columns.count - 1] else { return nil }
        for c in 0..<columns.count - 1 {
            let x = cells[c]!.rect.maxX + origin.x
            if abs(point.x - x) <= 5 {
                return ColumnDrag(range: range, column: c, left: cells[c]!.rect.minX + origin.x,
                                  width: last.rect.maxX - first.rect.minX,
                                  pair: cells[c]!.block.value(for: .width) + cells[c + 1]!.block.value(for: .width))
            }
        }
        return nil
    }

    /// 拖到 x：交界左右两列重新分这两列合计的宽度（每列至少 8%）。只改显示，Markdown 不记列宽
    private func dragColumn(_ drag: ColumnDrag, to x: CGFloat) {
        guard let storage = textStorage, NSMaxRange(drag.range) <= storage.length, drag.width > 0 else { return }
        let leftPct = min(max((x - drag.left) / drag.width * 100, 8), drag.pair - 8)
        var i = drag.range.location
        while i < NSMaxRange(drag.range) {
            let para = paragraphRange(at: i)
            if let b = tableBlock(at: i) {
                if b.startingColumn == drag.column { b.setValue(leftPct, type: .percentageValueType, for: .width) }
                if b.startingColumn == drag.column + 1 { b.setValue(drag.pair - leftPct, type: .percentageValueType, for: .width) }
            }
            i = NSMaxRange(para)
        }
        layoutManager?.invalidateLayout(forCharacterRange: drag.range, actualCharacterRange: nil)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = columnDrag else { return super.mouseDragged(with: event) }
        NSCursor.resizeLeftRight.set()
        dragColumn(drag, to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard columnDrag != nil else { return super.mouseUp(with: event) }
        columnDrag = nil
    }
}
