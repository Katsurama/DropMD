import AppKit

extension RichTextView {
    // MARK: - 键盘

    override func insertNewline(_ sender: Any?) {
        if selectedRange().length == 0, !hasMarkedText() { moveCaretOutOfObjects(newline: true) } else { expandSelectionToObjects() }
        let para = paragraphRange(at: selectedRange().location)
        let attrs = paragraphAttributes(para)
        // 表格中回车移到下一格（每个单元格只能有一个段落）
        if RichBridge.tableBlock(of: attrs) != nil, moveCell(forward: true, addRow: false) { return }
        let kind = RichBridge.kind(of: attrs)
        let content = (string as NSString).substring(with: para)
            .replacingOccurrences(of: RichStyle.taskTodo, with: "")
            .replacingOccurrences(of: RichStyle.taskDone, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let math = attrs[DMKey.math] != nil
        // YAML 信息、HTML 中间的空行再按回车：删掉空行，到整块后面开始正文（原地变正文会把块切开，结尾的 --- 或 </div> 单独成块）
        if kind == .raw, !math, content.isEmpty, selectedRange().length == 0, exitRawBlock(from: para, attrs: attrs) { return }
        // 在空的列表项、引用、原样内容（YAML 信息、HTML）中再按回车：结束列表（与 Word 相同）
        if (kind.isList || kind == .quote || (kind == .raw && !math)) && content.isEmpty && selectedRange().length == 0 {
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
        case .heading, .rule:
            applyKinds { _ in .body }
        case .raw where math:   // 公式块后面是正文；YAML 信息、HTML 里回车只是换行
            applyKinds { _ in .body }
        case .task(let d, _):
            applyKinds { _ in .task(d, false) }
        case .raw:   // 记下刚开出的空行：这一行上再按回车就离开原样内容
            let p = paragraphRange(at: selectedRange().location)
            if (string as NSString).substring(with: p).trimmingCharacters(in: .newlines).isEmpty { rawNewlineAt = p.location }
        default:
            break
        }
    }

    /// 空行后面还有同一块原样内容时：刚按回车开出的空行再按回车，删掉空行、在整块后面插一个正文空段落并把光标放过去；
    /// 原文里本来就有的空行（如原样列表里的空行）只是普通换行。空行已在块末尾时返回 false（交给下面变成正文）
    private func exitRawBlock(from para: NSRange, attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = string as NSString
        let inDetails = attrs[DMKey.inDetails] != nil
        let id = attrs[DMKey.codeBlock] as? String
        func sameBlock(_ a: [NSAttributedString.Key: Any]) -> Bool {
            let other = a[DMKey.codeBlock] as? String
            return RichBridge.kind(of: a) == .raw && a[DMKey.math] == nil && (a[DMKey.inDetails] != nil) == inDetails
                && (id == nil || other == nil || id == other)
        }
        var end = NSMaxRange(para)
        while end < ns.length, sameBlock(paragraphAttributes(paragraphRange(at: end))) {
            end = NSMaxRange(paragraphRange(at: end))
        }
        guard end > NSMaxRange(para) else { return false }
        guard rawNewlineAt == para.location else {
            // 原文里本来就有的空行：只是换行；开出的新空行再按回车就离开
            super.insertNewline(nil)
            rawNewlineAt = paragraphRange(at: selectedRange().location).location
            return true
        }
        var body = RichStyle.typingAttributes(for: .body)
        if inDetails {
            body[DMKey.inDetails] = attrs[DMKey.inDetails]
            body[.paragraphStyle] = RichStyle.paragraphStyle(.body, inDetails: true)
        }
        // 两步小改动合成一次撤销：先删空行，再在块后插正文空段落（文末也插，保存时末尾的空段落会去掉）。
        // 撤销时最后还原的是空行，光标回到空行上；重做时最后一步是插入，光标在正文空段落上
        let insert = NSMutableAttributedString()
        if !ns.substring(to: end).hasSuffix("\n") {   // 最后一行没有换行：先补上，属于原样内容
            insert.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: end - 1, effectiveRange: nil)))
        }
        let at = end - para.length
        let bodyAt = at + insert.length
        insert.append(NSAttributedString(string: "\n", attributes: body))
        guard isEditable else { return true }
        breakUndoCoalescing()   // 前面连续打的字是另一步撤销，否则一次撤销连打的字一起撤掉、光标位置也对不上
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        // 撤销后光标在空行开头、重做后在正文空段落上，都不选中恢复的换行（否则一打字就把换行替换掉）。
        // 撤销组里的动作倒着执行：最先登记的最后执行，所以前后各登记一个，来回互相登记
        let caretBack = NSRange(location: para.location, length: 0)
        let caretOn = NSRange(location: bodyAt, length: 0)
        func undoTail() { undoManager?.registerUndo(withTarget: self) { tv in tv.setSelectedRange(caretBack); redoHead() } }
        func undoHead() { undoManager?.registerUndo(withTarget: self) { _ in redoTail() } }
        func redoHead() { undoManager?.registerUndo(withTarget: self) { _ in undoTail() } }
        func redoTail() {
            undoManager?.registerUndo(withTarget: self) { tv in tv.setSelectedRange(caretOn); tv.typingAttributes = body; undoHead() }
        }
        undoTail()
        guard shouldChangeText(in: para, replacementString: "") else { return true }
        storage.replaceCharacters(in: para, with: "")
        didChangeText()
        guard shouldChangeText(in: NSRange(location: at, length: 0), replacementString: insert.string) else { return true }
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: insert)
        didChangeText()
        undoHead()
        rawNewlineAt = nil
        typingAttributes = body
        setSelectedRange(caretOn)
        typingAttributes = body
        scrollRangeToVisible(selectedRange())
        return true
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
    /// 一整块、不能只改一部分的东西：找不到的图片的占位文字、提示框的标题（保存时整个写回原文）
    func objectRange(at index: Int) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        let all = NSRange(location: 0, length: storage.length)
        var range = NSRange()
        for key in [DMKey.imageID, DMKey.callout] where storage.attribute(key, at: index, longestEffectiveRange: &range, in: all) != nil {
            // 真正的图片是一个附件字符，本来就是一整个
            return range.length > 1 ? range : nil
        }
        return nil
    }

    /// 选区只盖住它们的一部分时，扩大到整个（删掉就整个删掉，不会只删几个字、保存时又整个写回去）
    private func expandSelectionToObjects() {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        var r = sel
        if let a = objectRange(at: sel.location) { r = NSUnionRange(r, a) }
        if let b = objectRange(at: NSMaxRange(sel) - 1) { r = NSUnionRange(r, b) }
        if r != sel { setSelectedRange(r) }
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, deleteSelectionWithTables() { return }
        if sel.length == 0, let storage = textStorage, sel.location < storage.length {
            let para = paragraphRange(at: sel.location)
            let atEnd = sel.location >= NSMaxRange(para) - 1
            // 格子末尾：不把下一格并进来
            if cell(at: sel.location) != nil, atEnd { return }
            // 表格上面一段的末尾：第一下选中整张表格，再按一下删掉（不把第一格并上来）
            if atEnd, cell(at: NSMaxRange(para)) != nil {
                if let lm = layoutManager as? RichLayoutManager,
                   let table = lm.tableRange(around: NSRange(location: NSMaxRange(para), length: 0), in: storage) {
                    setSelectedRange(table)
                }
                return
            }
        }
        if sel.length == 0, let r = objectRange(at: sel.location) { setSelectedRange(r) } else { expandSelectionToObjects() }
        super.deleteForward(sender)
    }

    /// 选区碰到表格时删除（和 Word / Notion 相同），返回是否处理：
    /// 选区在一张表格里、跨了几格 → 清空这几格的字，格子留着；选区从表格里伸到表格外 → 整张表格一起删
    private func deleteSelectionWithTables() -> Bool {
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager else { return false }
        var sel = selectedRange()
        let startTable = lm.tableRange(around: NSRange(location: sel.location, length: 0), in: storage)
        let endTable = lm.tableRange(around: NSRange(location: NSMaxRange(sel) - 1, length: 0), in: storage)
        // 从第一格选到最后一格（不用选到最后一个字）：算选中了整张表格
        if let t = startTable, t == endTable, sel.length > 0, (storage.string as NSString).substring(with: sel).contains("\n"),
           paragraphRange(at: sel.location).location == t.location,
           NSMaxRange(paragraphRange(at: NSMaxRange(sel) - 1)) == NSMaxRange(t) {
            sel = t
        }
        // 从某一行的第一格选到某一行的最后一格：删掉这几行（选到了表头就删整张表，Markdown 表格不能没有表头）
        if let t = startTable, t == endTable, sel != t, (storage.string as NSString).substring(with: sel).contains("\n"),
           let first = cell(at: sel.location), let last = cell(at: NSMaxRange(sel) - 1),
           first.startingColumn == 0, last.startingColumn == last.table.numberOfColumns - 1, last.startingRow >= first.startingRow {
            if first.startingRow == 0 {
                sel = t
            } else {
                deleteTableRows(first.startingRow...last.startingRow, at: sel.location)
                return true
            }
        }
        if let t = startTable, t == endTable, NSUnionRange(t, sel) == t, sel != t {
            let picked = storage.attributedSubstring(from: sel)
            guard picked.string.contains("\n") else { return false }   // 只在一格里：照常删
            // 只留下格子之间的分段符（带着各格的格式），字都去掉
            let kept = NSMutableAttributedString(attributedString: picked)
            var i = kept.length - 1
            while i >= 0 {
                if (kept.string as NSString).character(at: i) != 0x0A { kept.deleteCharacters(in: NSRange(location: i, length: 1)) }
                i -= 1
            }
            replace(sel, with: kept, caret: sel.location)
            refreshTypingAttributes()
            return true
        }
        guard startTable != nil || endTable != nil else { return false }
        if let t = startTable { sel = NSUnionRange(sel, t) }
        if let t = endTable { sel = NSUnionRange(sel, t) }
        replace(sel, with: NSAttributedString(), caret: sel.location)
        refreshTypingAttributes()
        return true
    }

    /// 表格第 row 行的格子都是空的
    private func rowIsEmpty(_ row: Int, in table: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        var i = table.location
        while i < NSMaxRange(table) {
            let para = paragraphRange(at: i)
            if let b = cell(at: i), b.startingRow == row,
               !(storage.string as NSString).substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            i = NSMaxRange(para)
        }
        return true
    }

    /// 删掉表格里的几行（不含表头），光标放到原来下面那一行的第一格；后面没有行了就放到上一行
    private func deleteTableRows(_ rows: ClosedRange<Int>, at location: Int) {
        setSelectedRange(NSRange(location: location, length: 0))
        guard tableContext() != nil, rows.lowerBound > 0 else { return }
        var total = 0
        rewriteTable(caretRow: 0) { lines in
            for r in rows.reversed() where r + 1 < lines.count { lines.remove(at: r + 1) }
            total = lines.count - 2   // 剩下的行数（不含表头）
        }
        let target = min(rows.lowerBound, total)
        moveCaret(toRow: target)
    }

    /// 光标移到表格（光标所在的那张）第 row 行第一格
    private func moveCaret(toRow row: Int, lastCellEnd: Bool = false) {
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager,
              let table = lm.tableRange(around: NSRange(location: selectedRange().location, length: 0), in: storage) else { return }
        var target: NSRange?
        var i = table.location
        while i < NSMaxRange(table) {
            let para = paragraphRange(at: i)
            if let b = cell(at: i), b.startingRow == row {
                if target == nil || lastCellEnd { target = para }
                if !lastCellEnd { break }
            }
            i = NSMaxRange(para)
        }
        guard let target else { return }
        setSelectedRange(NSRange(location: lastCellEnd ? max(NSMaxRange(target) - 1, target.location) : target.location, length: 0))
        refreshTypingAttributes()
    }

    /// 光标在格子开头按退格：表格全空时删掉整张表；整行都空时删掉这一行（表头除外）；
    /// 否则跳到上一格末尾（第一格不动），不把两格并在一起。
    /// 光标在表格下面一段的开头：第一下选中整张表格，再按一下删掉（不把这一段并进表格）。返回是否处理
    private func deleteBackwardAtTable(_ location: Int) -> Bool {
        guard let storage = textStorage, let lm = layoutManager as? RichLayoutManager, location > 0 || cell(at: location) != nil else { return false }
        let para = paragraphRange(at: min(location, max(storage.length - 1, 0)))
        if location < storage.length, cell(at: location) != nil {
            guard location == para.location, let table = lm.tableRange(around: NSRange(location: location, length: 0), in: storage) else { return false }
            let text = (storage.string as NSString).substring(with: table)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, location == table.location {
                replace(table, with: NSAttributedString(), caret: table.location)
                refreshTypingAttributes()
            } else if let here = cell(at: location), here.startingColumn == 0, here.startingRow > 0, rowIsEmpty(here.startingRow, in: table) {
                let row = here.startingRow
                deleteTableRows(row...row, at: location)
                moveCaret(toRow: row - 1, lastCellEnd: true)
            } else if location > table.location {
                setSelectedRange(NSRange(location: location - 1, length: 0))
                refreshTypingAttributes()
            }
            return true
        }
        guard location > 0, cell(at: location - 1) != nil else { return false }
        let here = location < storage.length ? para : NSRange(location: location, length: 0)
        guard location == here.location, let table = lm.tableRange(around: NSRange(location: location - 1, length: 0), in: storage) else { return false }
        setSelectedRange(table)
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, deleteSelectionWithTables() { return }
        if sel.length > 0 { expandSelectionToObjects() }
        if sel.length == 0 {
            let para = paragraphRange(at: sel.location)
            let kind = currentKind
            // 待办的开头是“☐ ”两个字符，光标在方框后面也算段首
            let start = { if case .task = kind { return para.location + 2 } else { return para.location } }()
            if sel.location <= start, para.length > 0, kind.isList || kind == .quote {
                if kind.depth > 0 { changeDepth(-1) } else { applyKinds { _ in .body } }
                return
            }
            if deleteBackwardAtTable(sel.location) { return }
            if let r = objectRange(at: sel.location - 1) { setSelectedRange(r) }
        }
        super.deleteBackward(sender)
    }

    /// 自动格式：在段首输入“- ”“1. ”“# ”“> ”“[] ”后按空格，自动转换为对应样式
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, !hasMarkedText() { moveCaretOutOfObjects(); expandSelectionToObjects() }
        if let s = string as? String, s == " ", selectedRange().length == 0, autoFormat() { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// 输入法开始拼字时也一样（拼好的字会替换掉拼写中的文字，位置在这里就定了）
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, !hasMarkedText() { moveCaretOutOfObjects(); expandSelectionToObjects() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    /// 光标在“不是正文的东西”里面时，打的字保存后会挪到旁边（重新打开时位置就变了）。
    /// 打字前先把光标挪到保存后的位置，屏幕上看到的就是保存后的样子：
    /// 找不到的图片的占位文字中间 → 占位文字后面；待办方框前面 → 方框后面；提示框标题行 → 标题下面新的一行
    func moveCaretOutOfObjects(newline: Bool = false) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let sel = selectedRange()
        guard sel.length == 0, sel.location <= storage.length else { return }
        let loc = sel.location
        let para = paragraphRange(at: min(loc, storage.length - 1))
        guard para.length > 0 else { return }
        let attrs = storage.attributes(at: para.location, effectiveRange: nil)
        // 提示框标题行：标题要单独一行才算提示框，这一行里打的字保存时放到下一行
        if attrs[DMKey.callout] != nil, loc >= para.location, loc <= NSMaxRange(para) {
            var end = NSMaxRange(para)
            if end > para.location, (string as NSString).character(at: end - 1) == 0x0A { end -= 1 }
            setSelectedRange(NSRange(location: end, length: 0))
            if !newline { insertNewline(nil) }
            return
        }
        // 待办方框前面（方框和后面的空格是一体的）
        if case .task = RichBridge.kind(of: attrs), loc == para.location || loc == para.location + 1,
           para.length >= 2 {
            let box = (string as NSString).substring(with: NSRange(location: para.location, length: 1))
            if box == RichStyle.taskTodo || box == RichStyle.taskDone {
                setSelectedRange(NSRange(location: min(para.location + 2, NSMaxRange(para)), length: 0))
                return
            }
        }
        // 占位文字中间（前后两个字是同一张图片）
        guard loc > 0, loc < storage.length,
              let id = storage.attribute(DMKey.imageID, at: loc - 1, effectiveRange: nil) as? String,
              storage.attribute(DMKey.imageID, at: loc, effectiveRange: nil) as? String == id else { return }
        var range = NSRange()
        _ = storage.attribute(DMKey.imageID, at: loc, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
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
}
